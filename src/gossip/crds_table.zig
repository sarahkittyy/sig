const std = @import("std");
const AutoArrayHashMap = std.AutoArrayHashMap;
const AutoHashMap = std.AutoHashMap;

const bincode = @import("../bincode/bincode.zig");

const hash = @import("../core/hash.zig");
const Hash = hash.Hash;
const CompareResult = hash.CompareResult;

const CrdsShards = @import("./crds_shards.zig").CrdsShards;

const crds = @import("./crds.zig");
const CrdsValue = crds.CrdsValue;
const CrdsData = crds.CrdsData;
const CrdsVersionedValue = crds.CrdsVersionedValue;
const CrdsValueLabel = crds.CrdsValueLabel;
const LegacyContactInfo = crds.LegacyContactInfo;

const Logger = @import("../trace/log.zig").Logger;

const Transaction = @import("../core/transaction.zig").Transaction;
const Pubkey = @import("../core/pubkey.zig").Pubkey;
const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const RwLock = std.Thread.RwLock;

pub const CrdsError = error{
    OldValue,
    DuplicateValue,
};

pub const HashAndTime = struct { hash: Hash, timestamp: u64 };
// TODO: benchmark other structs?
const PurgedQ = std.TailQueue(HashAndTime);

/// Cluster Replicated Data Store: stores gossip data
/// the self.store uses an AutoArrayHashMap which is a HashMap that also allows for
/// indexing values (value = arrayhashmap[0]). This allows us to insert data
/// into the store and track the indexs of different types for
/// retrieval. We use the 'cursor' value to track what index is the head of the
/// store.
/// Other functions include getters with a cursor
/// (`get_votes_with_cursor`) which allows you to retrieve values which are
/// past a certain cursor index. A listener would use their own cursor to
/// retrieve new values inserted in the store.
/// insertion of values is all based on the CRDSLabel type -- when duplicates
/// are found, the entry with the largest wallclock time (newest) is stored.
pub const CrdsTable = struct {
    store: AutoArrayHashMap(CrdsValueLabel, CrdsVersionedValue),

    // special types tracked with their index
    contact_infos: AutoArrayHashMap(usize, void), // hashset for O(1) insertion/removal
    votes: AutoArrayHashMap(usize, usize),
    epoch_slots: AutoArrayHashMap(usize, usize),
    duplicate_shreds: AutoArrayHashMap(usize, usize),
    shred_versions: AutoHashMap(Pubkey, u16),

    // tracking for cursor to index
    entries: AutoArrayHashMap(u64, usize),

    // used to build pull responses efficiently
    shards: CrdsShards,

    // used when sending pull requests
    purged: HashTimeQueue,

    // head of the store
    cursor: usize = 0,

    // thread safe
    lock: RwLock = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .store = AutoArrayHashMap(CrdsValueLabel, CrdsVersionedValue).init(allocator),
            .contact_infos = AutoArrayHashMap(usize, void).init(allocator),
            .shred_versions = AutoHashMap(Pubkey, u16).init(allocator),
            .votes = AutoArrayHashMap(usize, usize).init(allocator),
            .epoch_slots = AutoArrayHashMap(usize, usize).init(allocator),
            .duplicate_shreds = AutoArrayHashMap(usize, usize).init(allocator),
            .entries = AutoArrayHashMap(u64, usize).init(allocator),
            .shards = try CrdsShards.init(allocator),
            .purged = HashTimeQueue.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.store.deinit();
        self.contact_infos.deinit();
        self.shred_versions.deinit();
        self.votes.deinit();
        self.epoch_slots.deinit();
        self.duplicate_shreds.deinit();
        self.shards.deinit();
        self.entries.deinit();
    }

    pub fn write(self: *Self) void {
        self.lock.lock();
    }

    pub fn release_write(self: *Self) void {
        self.lock.unlock();
    }

    pub fn read(self: *Self) void {
        self.lock.lockShared();
    }

    pub fn release_read(self: *Self) void {
        self.lock.unlockShared();
    }

    pub fn len(self: *Self) usize {
        return self.store.count();
    }

    pub fn insert(self: *Self, value: CrdsValue, now: u64) !void {
        // TODO: check to make sure this sizing is correct or use heap

        var buf = [_]u8{0} ** 2048; // does this break if its called in parallel? / dangle?
        var bytes = try bincode.writeToSlice(&buf, value, bincode.Params.standard);
        const value_hash = Hash.generateSha256Hash(bytes);
        const versioned_value = CrdsVersionedValue{
            .value = value,
            .value_hash = value_hash,
            .timestamp_on_insertion = now,
            .cursor_on_insertion = self.cursor,
        };

        const label = value.label();
        var result = try self.store.getOrPut(label);
        const entry_index = result.index;

        // entry doesnt exist
        if (!result.found_existing) {
            switch (value.data) {
                .LegacyContactInfo => |*info| {
                    try self.contact_infos.put(entry_index, {});
                    try self.shred_versions.put(info.id, info.shred_version);
                },
                .Vote => {
                    try self.votes.put(self.cursor, entry_index);
                },
                .EpochSlots => {
                    try self.epoch_slots.put(self.cursor, entry_index);
                },
                .DuplicateShred => {
                    try self.duplicate_shreds.put(self.cursor, entry_index);
                },
                else => {},
            }

            try self.shards.insert(entry_index, &versioned_value.value_hash);

            try self.entries.put(self.cursor, entry_index);

            result.value_ptr.* = versioned_value;

            self.cursor += 1;

            // should overwrite existing entry
        } else if (crds_overwrites(&versioned_value, result.value_ptr)) {
            const old_entry = result.value_ptr.*;

            switch (value.data) {
                .LegacyContactInfo => |*info| {
                    try self.shred_versions.put(info.id, info.shred_version);
                },
                .Vote => {
                    var did_remove = self.votes.swapRemove(old_entry.cursor_on_insertion);
                    std.debug.assert(did_remove);
                    try self.votes.put(self.cursor, entry_index);
                },
                .EpochSlots => {
                    var did_remove = self.epoch_slots.swapRemove(old_entry.cursor_on_insertion);
                    std.debug.assert(did_remove);
                    try self.epoch_slots.put(self.cursor, entry_index);
                },
                .DuplicateShred => {
                    var did_remove = self.duplicate_shreds.swapRemove(old_entry.cursor_on_insertion);
                    std.debug.assert(did_remove);
                    try self.duplicate_shreds.put(self.cursor, entry_index);
                },
                else => {},
            }

            // remove and insert to make sure the shard ordering is oldest-to-newest
            // NOTE: do we need the ordering to be oldest-to-newest?
            try self.shards.remove(entry_index, &old_entry.value_hash);
            try self.shards.insert(entry_index, &versioned_value.value_hash);

            const did_remove = self.entries.swapRemove(old_entry.cursor_on_insertion);
            std.debug.assert(did_remove);
            try self.entries.put(self.cursor, entry_index);

            self.purged.insert(old_entry.value_hash, now);

            result.value_ptr.* = versioned_value;

            self.cursor += 1;

            // do nothing
        } else {
            const old_entry = result.value_ptr.*;

            if (old_entry.value_hash.cmp(&versioned_value.value_hash) != CompareResult.Equal) {
                // if hash isnt the same and override() is false then msg is old
                self.purged.insert(old_entry.value_hash, now);
                return CrdsError.OldValue;
            } else {
                // hash is the same then its a duplicate
                return CrdsError.DuplicateValue;
            }
        }
    }

    pub fn insert_values(
        self: *Self,
        allocator: std.mem.Allocator,
        values: []crds.CrdsValue,
        timeout: u64,
        logger: *Logger,
    ) std.ArrayList(usize) {
        var now = crds.get_wallclock();

        var failed_insert_indexs = std.ArrayList(usize).init(allocator);
        for (values, 0..) |value, index| {
            const value_time = value.wallclock();
            const is_too_new = value_time > now +| timeout;
            const is_too_old = value_time < now -| timeout;
            if (is_too_new or is_too_old) {
                continue;
            }

            self.insert(value, now) catch |err| {
                switch (err) {
                    CrdsError.OldValue => {
                        logger.debugf("failed to insert into crds: OldValue", .{});
                    },
                    CrdsError.DuplicateValue => {
                        logger.debugf("failed to insert into crds: DuplicateValue", .{});
                    },
                    else => {
                        logger.debugf("failed to insert into crds with unkown error: {any}", .{err});
                    },
                }
                failed_insert_indexs.append(index) catch unreachable;
            };
        }

        return failed_insert_indexs;
    }

    // ** getter functions **
    pub fn get(self: *Self, label: CrdsValueLabel) ?CrdsVersionedValue {
        return self.store.get(label);
    }

    pub fn get_entries_with_cursor(self: *Self, buf: []CrdsVersionedValue, caller_cursor: *usize) ![]CrdsVersionedValue {
        const cursor_indexs = self.entries.keys();
        var index: usize = 0;
        for (cursor_indexs) |cursor_index| {
            if (cursor_index < caller_cursor.*) {
                continue;
            }
            const entry_index = self.entries.get(cursor_index).?;
            var entry = self.store.iterator().values[entry_index];
            buf[index] = entry;
            index += 1;

            if (index == buf.len) {
                break;
            }
        }
        // move up the caller_cursor
        caller_cursor.* += index;
        return buf[0..index];
    }

    pub fn get_votes_with_cursor(self: *Self, buf: []CrdsVersionedValue, caller_cursor: *usize) ![]CrdsVersionedValue {
        const keys = self.votes.keys();
        var index: usize = 0;
        for (keys) |key| {
            if (key < caller_cursor.*) {
                continue;
            }
            const entry_index = self.votes.get(key).?;
            var entry = self.store.iterator().values[entry_index];
            buf[index] = entry;
            index += 1;

            if (index == buf.len) {
                break;
            }
        }
        // move up the caller_cursor
        caller_cursor.* += index;
        return buf[0..index];
    }

    pub fn get_epoch_slots_with_cursor(self: *Self, buf: []CrdsVersionedValue, caller_cursor: *usize) ![]CrdsVersionedValue {
        const keys = self.epoch_slots.keys();
        var index: usize = 0;
        for (keys) |key| {
            if (key < caller_cursor.*) {
                continue;
            }
            const entry_index = self.epoch_slots.get(key).?;
            var entry = self.store.iterator().values[entry_index];
            buf[index] = entry;
            index += 1;

            if (index == buf.len) {
                break;
            }
        }
        // move up the caller_cursor
        caller_cursor.* += index;
        return buf[0..index];
    }

    pub fn get_duplicate_shreds_with_cursor(self: *Self, buf: []CrdsVersionedValue, caller_cursor: *usize) ![]CrdsVersionedValue {
        const keys = self.duplicate_shreds.keys();
        var index: usize = 0;
        for (keys) |key| {
            if (key < caller_cursor.*) {
                continue;
            }
            const entry_index = self.duplicate_shreds.get(key).?;
            var entry = self.store.iterator().values[entry_index];
            buf[index] = entry;
            index += 1;

            if (index == buf.len) {
                break;
            }
        }
        // move up the caller_cursor
        caller_cursor.* += index;
        return buf[0..index];
    }

    pub fn get_contact_infos(self: *const Self, buf: []CrdsVersionedValue) ![]CrdsVersionedValue {
        const store_values = self.store.iterator().values;
        const contact_indexs = self.contact_infos.iterator().keys;

        const size = @min(self.contact_infos.count(), buf.len);

        for (0..size) |i| {
            const index = contact_indexs[i];
            const entry = store_values[index];
            buf[i] = entry;
        }
        return buf[0..size];
    }

    // ** shard getter fcns **
    pub fn get_bitmask_matches(
        self: *const Self,
        alloc: std.mem.Allocator,
        mask: u64,
        mask_bits: u64,
    ) !std.ArrayList(usize) {
        const indexs = try self.shards.find(alloc, mask, @intCast(mask_bits));
        return indexs;
    }
};

pub const HashTimeQueue = struct {
    const QueueT = std.TailQueue(HashAndTime);
    queue: QueueT,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .queue = std.TailQueue(HashAndTime){},
        };
    }

    pub fn len(self: *Self) usize {
        return self.queue.len;
    }

    pub fn insert(self: *Self, v: Hash, now: u64) void {
        var node = PurgedQ.Node{ .data = HashAndTime{
            .hash = v,
            .timestamp = now,
        } };
        self.queue.append(&node);
    }

    pub fn trim(self: *Self, oldest_timestamp: u64) void {
        var curr_ptr = self.queue.first;
        while (curr_ptr) |curr| : (curr_ptr = curr.next) {
            const data_timestamp = curr.data.timestamp;
            if (data_timestamp < oldest_timestamp) {
                self.queue.remove(curr);
            } else {
                break;
            }
        }
    }

    pub fn get_values(self: *Self, alloc: std.mem.Allocator) !std.ArrayList(Hash) {
        var hashes = try std.ArrayList(Hash).initCapacity(alloc, self.queue.len);
        var curr_ptr = self.queue.first;
        while (curr_ptr) |curr| : (curr_ptr = curr.next) {
            hashes.appendAssumeCapacity(curr.data.hash);
        }
        return hashes;
    }
};

pub fn crds_overwrites(new_value: *const CrdsVersionedValue, old_value: *const CrdsVersionedValue) bool {
    // labels must match
    std.debug.assert(@intFromEnum(new_value.value.label()) == @intFromEnum(old_value.value.label()));

    const new_ts = new_value.value.wallclock();
    const old_ts = old_value.value.wallclock();

    if (new_ts > old_ts) {
        return true;
    } else if (new_ts < old_ts) {
        return false;
    } else {
        return old_value.value_hash.cmp(&new_value.value_hash) == CompareResult.Less;
    }
}

test "gossip.HashTimeQueue: trim pruned values" {
    const keypair = try KeyPair.create([_]u8{1} ** 32);

    var seed: u64 = @intCast(std.time.milliTimestamp());
    var rand = std.rand.DefaultPrng.init(seed);
    const rng = rand.random();
    var data = CrdsData{
        .LegacyContactInfo = LegacyContactInfo.random(rng),
    };
    var value = try CrdsValue.initSigned(data, keypair);

    var crds_table = try CrdsTable.init(std.testing.allocator);
    defer crds_table.deinit();

    // timestamp = 100
    try crds_table.insert(value, 100);

    // should lead to prev being pruned
    var new_data = CrdsData{
        .LegacyContactInfo = LegacyContactInfo.random(rng),
    };
    new_data.LegacyContactInfo.id = data.LegacyContactInfo.id;
    // older wallclock
    new_data.LegacyContactInfo.wallclock += data.LegacyContactInfo.wallclock;
    value = try CrdsValue.initSigned(new_data, keypair);
    try crds_table.insert(value, 120);

    try std.testing.expectEqual(crds_table.purged.len(), 1);

    // its timestamp should be 120 so, 130 = clear pruned values
    crds_table.purged.trim(130);

    try std.testing.expectEqual(crds_table.purged.len(), 0);
}

test "gossip.crds_table: insert and get" {
    const keypair = try KeyPair.create([_]u8{1} ** 32);

    var seed: u64 = @intCast(std.time.milliTimestamp());
    var rand = std.rand.DefaultPrng.init(seed);
    const rng = rand.random();
    var value = try CrdsValue.random(rng, keypair);

    var crds_table = try CrdsTable.init(std.testing.allocator);
    defer crds_table.deinit();

    try crds_table.insert(value, 0);

    const label = value.label();
    const x = crds_table.get(label).?;
    _ = x;
}

test "gossip.crds_table: insert and get votes" {
    var kp_bytes = [_]u8{1} ** 32;
    const kp = try KeyPair.create(kp_bytes);
    const pk = kp.public_key;
    var id = Pubkey.fromPublicKey(&pk, true);

    var vote = crds.Vote{ .from = id, .transaction = Transaction.default(), .wallclock = 10 };
    var crds_value = try CrdsValue.initSigned(CrdsData{
        .Vote = .{ 0, vote },
    }, kp);

    var crds_table = try CrdsTable.init(std.testing.allocator);
    defer crds_table.deinit();
    try crds_table.insert(crds_value, 0);

    var cursor: usize = 0;
    var buf: [100]CrdsVersionedValue = undefined;
    var votes = try crds_table.get_votes_with_cursor(&buf, &cursor);

    try std.testing.expect(votes.len == 1);
    try std.testing.expect(cursor == 1);

    // try inserting another vote
    var seed: u64 = @intCast(std.time.milliTimestamp());
    var rand = std.rand.DefaultPrng.init(seed);
    const rng = rand.random();
    id = Pubkey.random(rng, .{});
    vote = crds.Vote{ .from = id, .transaction = Transaction.default(), .wallclock = 10 };
    crds_value = try CrdsValue.initSigned(CrdsData{
        .Vote = .{ 0, vote },
    }, kp);
    try crds_table.insert(crds_value, 1);

    votes = try crds_table.get_votes_with_cursor(&buf, &cursor);
    try std.testing.expect(votes.len == 1);
    try std.testing.expect(cursor == 2);

    const v = try crds_table.get_bitmask_matches(std.testing.allocator, 10, 1);
    defer v.deinit();
}

test "gossip.crds_table: insert and get contact_info" {
    const kp = try KeyPair.create([_]u8{1} ** 32);
    var id = Pubkey.fromPublicKey(&kp.public_key, true);

    var legacy_contact_info = crds.LegacyContactInfo.default(id);
    var crds_value = try CrdsValue.initSigned(CrdsData{
        .LegacyContactInfo = legacy_contact_info,
    }, kp);

    var crds_table = try CrdsTable.init(std.testing.allocator);
    defer crds_table.deinit();

    // test insertion
    try crds_table.insert(crds_value, 0);

    // test retrieval
    var buf: [100]CrdsVersionedValue = undefined;
    var nodes = try crds_table.get_contact_infos(&buf);
    try std.testing.expect(nodes.len == 1);
    try std.testing.expect(nodes[0].value.data.LegacyContactInfo.id.equals(&id));

    // test re-insertion
    const result = crds_table.insert(crds_value, 0);
    try std.testing.expectError(CrdsError.DuplicateValue, result);

    // test re-insertion with greater wallclock
    crds_value.data.LegacyContactInfo.wallclock += 2;
    const v = crds_value.data.LegacyContactInfo.wallclock;
    try crds_table.insert(crds_value, 0);

    // check retrieval
    nodes = try crds_table.get_contact_infos(&buf);
    try std.testing.expect(nodes.len == 1);
    try std.testing.expect(nodes[0].value.data.LegacyContactInfo.wallclock == v);
}

const std = @import("std");
const AutoArrayHashMap = std.AutoArrayHashMap;
const AutoHashMap = std.AutoHashMap;

const bincode = @import("bincode-zig");

const hash = @import("../core/hash.zig");
const Hash = hash.Hash;
const CompareResult = hash.CompareResult;

const SocketAddr = @import("net.zig").SocketAddr;

const crds = @import("./crds.zig");
const CrdsValue = crds.CrdsValue;
const CrdsData = crds.CrdsData;
const CrdsVersionedValue = crds.CrdsVersionedValue;
const CrdsValueLabel = crds.CrdsValueLabel;
const LegacyContactInfo = crds.LegacyContactInfo;

const Transaction = @import("../core/transaction.zig").Transaction;
const Pubkey = @import("../core/pubkey.zig").Pubkey;
const KeyPair = std.crypto.sign.Ed25519.KeyPair;

// tmp upperbound on number for `get_nodes`/`get_votes`/...
// enables stack allocations for buffers in the getter functions
const MAX_N_CONTACT_INFOS = 100;
const MAX_N_VOTES = 20;
const MAX_N_EPOCH_SLOTS = 20;
const MAX_N_DUP_SHREDS = 20;

pub const CrdsError = error{
    OldValue,
};

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
    contact_infos: AutoArrayHashMap(usize, void), // hashset for O(1) insertion/removal
    shred_versions: AutoHashMap(Pubkey, u16),
    votes: AutoArrayHashMap(usize, usize),
    epoch_slots: AutoArrayHashMap(usize, usize),
    duplicate_shreds: AutoArrayHashMap(usize, usize),
    cursor: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .store = AutoArrayHashMap(CrdsValueLabel, CrdsVersionedValue).init(allocator),
            .contact_infos = AutoArrayHashMap(usize, void).init(allocator),
            .shred_versions = AutoHashMap(Pubkey, u16).init(allocator),
            .votes = AutoArrayHashMap(usize, usize).init(allocator),
            .epoch_slots = AutoArrayHashMap(usize, usize).init(allocator),
            .duplicate_shreds = AutoArrayHashMap(usize, usize).init(allocator),
            .cursor = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.store.deinit();
        self.contact_infos.deinit();
        self.shred_versions.deinit();
        self.votes.deinit();
        self.epoch_slots.deinit();
        self.duplicate_shreds.deinit();
    }

    pub fn insert(self: *Self, value: CrdsValue, now: u64) !void {
        // TODO: check to make sure this sizing is correct or use heap
        var buf = [_]u8{0} ** 2048;
        var bytes = try bincode.writeToSlice(&buf, value, bincode.Params.standard);
        const value_hash = Hash.generateSha256Hash(bytes);
        const versioned_value = CrdsVersionedValue{
            .value = value,
            .value_hash = value_hash,
            .local_timestamp = now,
            .num_push_dups = 0,
            .ordinal = self.cursor,
        };

        const label = value.label();
        var result = try self.store.getOrPut(label);

        // entry doesnt exist
        if (!result.found_existing) {
            switch (value.data) {
                .LegacyContactInfo => |*info| {
                    try self.contact_infos.put(result.index, {});
                    try self.shred_versions.put(info.id, info.shred_version);
                },
                .Vote => {
                    try self.votes.put(self.cursor, result.index);
                },
                .EpochSlots => {
                    try self.epoch_slots.put(self.cursor, result.index);
                },
                .DuplicateShred => {
                    try self.duplicate_shreds.put(self.cursor, result.index);
                },
                else => {},
            }

            self.cursor += 1;
            result.value_ptr.* = versioned_value;

            // should overwrite existing entry
        } else if (crds_overwrites(&versioned_value, result.value_ptr)) {
            const old_entry = result.value_ptr.*;

            switch (value.data) {
                .LegacyContactInfo => |*info| {
                    try self.shred_versions.put(info.id, info.shred_version);
                },
                .Vote => {
                    var did_remove = self.votes.swapRemove(old_entry.ordinal);
                    std.debug.assert(did_remove);
                    try self.votes.put(self.cursor, result.index);
                },
                .EpochSlots => {
                    var did_remove = self.epoch_slots.swapRemove(old_entry.ordinal);
                    std.debug.assert(did_remove);
                    try self.epoch_slots.put(self.cursor, result.index);
                },
                .DuplicateShred => {
                    var did_remove = self.duplicate_shreds.swapRemove(old_entry.ordinal);
                    std.debug.assert(did_remove);
                    try self.duplicate_shreds.put(self.cursor, result.index);
                },
                else => {},
            }

            self.cursor += 1;
            result.value_ptr.* = versioned_value;

            // do nothing
        } else {
            return CrdsError.OldValue;
        }
    }

    pub fn get_votes_with_cursor(self: *Self, caller_cursor: *usize) ![]*CrdsVersionedValue {
        const keys = self.votes.keys();
        // initialize this buffer once in struct and re-use on each call?
        var buf: [MAX_N_VOTES]*CrdsVersionedValue = undefined; // max N votes per query (20)
        var index: usize = 0;
        for (keys) |key| {
            if (key < caller_cursor.*) {
                continue;
            }
            const entry_index = self.votes.get(key).?;
            var entry = self.store.iterator().values[entry_index];
            buf[index] = &entry;
            index += 1;

            if (index == MAX_N_VOTES) {
                break;
            }
        }
        // move up the caller_cursor
        caller_cursor.* += index;
        return buf[0..index];
    }

    pub fn get_epoch_slots_with_cursor(self: *Self, caller_cursor: *usize) ![]*CrdsVersionedValue {
        const keys = self.epoch_slots.keys();
        var buf: [MAX_N_EPOCH_SLOTS]*CrdsVersionedValue = undefined;
        var index: usize = 0;
        for (keys) |key| {
            if (key < caller_cursor.*) {
                continue;
            }
            const entry_index = self.epoch_slots.get(key).?;
            var entry = self.store.iterator().values[entry_index];
            buf[index] = &entry;
            index += 1;

            if (index == MAX_N_EPOCH_SLOTS) {
                break;
            }
        }
        // move up the caller_cursor
        caller_cursor.* += index;
        return buf[0..index];
    }

    pub fn get_duplicate_shreds_with_cursor(self: *Self, caller_cursor: *usize) ![]*CrdsVersionedValue {
        const keys = self.duplicate_shreds.keys();
        var buf: [MAX_N_DUP_SHREDS]*CrdsVersionedValue = undefined;
        var index: usize = 0;
        for (keys) |key| {
            if (key < caller_cursor.*) {
                continue;
            }
            const entry_index = self.duplicate_shreds.get(key).?;
            var entry = self.store.iterator().values[entry_index];
            buf[index] = &entry;
            index += 1;

            if (index == MAX_N_DUP_SHREDS) {
                break;
            }
        }
        // move up the caller_cursor
        caller_cursor.* += index;
        return buf[0..index];
    }

    pub fn get_contact_infos(self: *const Self) ![]*CrdsVersionedValue {
        var entry_ptrs: [MAX_N_CONTACT_INFOS]*CrdsVersionedValue = undefined;
        const size = @min(self.contact_infos.count(), MAX_N_CONTACT_INFOS);
        const store_values = self.store.iterator().values;
        const contact_indexs = self.contact_infos.iterator().keys;
        for (0..size) |i| {
            const index = contact_indexs[i];
            const entry = &store_values[index];
            entry_ptrs[i] = entry;
        }
        return entry_ptrs[0..size];
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

test "gossip.crds_table: insert and get votes" {
    var kp_bytes = [_]u8{1} ** 32;
    const kp = try KeyPair.create(kp_bytes);
    const pk = kp.public_key;
    var id = Pubkey.fromPublicKey(&pk, true);

    var vote = crds.Vote{ .from = id, .transaction = Transaction.default(), .wallclock = 10 };
    var crds_value = try CrdsValue.initSigned(CrdsData{
        .Vote = .{ 0, vote },
    }, kp);

    var crds_table = CrdsTable.init(std.testing.allocator);
    defer crds_table.deinit();
    try crds_table.insert(crds_value, 0);

    var cursor: usize = 0;
    var votes = try crds_table.get_votes_with_cursor(&cursor);

    try std.testing.expect(votes.len == 1);
    try std.testing.expect(cursor == 1);

    // try inserting another vote
    id = Pubkey.random(.{});
    vote = crds.Vote{ .from = id, .transaction = Transaction.default(), .wallclock = 10 };
    crds_value = try CrdsValue.initSigned(CrdsData{
        .Vote = .{ 0, vote },
    }, kp);
    try crds_table.insert(crds_value, 1);

    votes = try crds_table.get_votes_with_cursor(&cursor);
    try std.testing.expect(votes.len == 1);
    try std.testing.expect(cursor == 2);
}

test "gossip.crds_table: insert and get contact_info" {
    var kp_bytes = [_]u8{1} ** 32;
    const kp = try KeyPair.create(kp_bytes);
    const pk = kp.public_key;
    var id = Pubkey.fromPublicKey(&pk, true);
    const unspecified_addr = SocketAddr.unspecified();
    var legacy_contact_info = crds.LegacyContactInfo{
        .id = id,
        .gossip = unspecified_addr,
        .tvu = unspecified_addr,
        .tvu_forwards = unspecified_addr,
        .repair = unspecified_addr,
        .tpu = unspecified_addr,
        .tpu_forwards = unspecified_addr,
        .tpu_vote = unspecified_addr,
        .rpc = unspecified_addr,
        .rpc_pubsub = unspecified_addr,
        .serve_repair = unspecified_addr,
        .wallclock = 0,
        .shred_version = 0,
    };
    var crds_value = try CrdsValue.initSigned(CrdsData{
        .LegacyContactInfo = legacy_contact_info,
    }, kp);

    var crds_table = CrdsTable.init(std.testing.allocator);
    defer crds_table.deinit();

    // test insertion
    try crds_table.insert(crds_value, 0);

    // test retrieval
    var nodes = try crds_table.get_contact_infos();
    try std.testing.expect(nodes.len == 1);
    try std.testing.expect(nodes[0].value.data.LegacyContactInfo.id.equals(&id));

    // test re-insertion
    const result = crds_table.insert(crds_value, 0);
    try std.testing.expectError(CrdsError.OldValue, result);

    // test re-insertion with greater wallclock
    crds_value.data.LegacyContactInfo.wallclock = 2;
    try crds_table.insert(crds_value, 0);

    // check retrieval
    nodes = try crds_table.get_contact_infos();
    try std.testing.expect(nodes.len == 1);
    try std.testing.expect(nodes[0].value.data.LegacyContactInfo.wallclock == 2);
}
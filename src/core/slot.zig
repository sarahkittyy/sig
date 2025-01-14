const std = @import("std");
const testing = std.testing;
const bincode = @import("../bincode/bincode.zig");

pub const Slot = struct {
    value: u64,

    const Self = @This();

    pub fn init(slot: u64) Self {
        return Self{
            .value = slot,
        };
    }

    /// returns slot with 0 as value
    pub fn default() Self {
        return Self{ .value = 0 };
    }
};

const logger = std.log.scoped(.slot_tests);

test "slot bincode serializes properly" {
    var rust_serialized = [_]u8{ 239, 16, 0, 0, 0, 0, 0, 0 };
    var slot = Slot{ .value = 4335 };
    var buf = [_]u8{0} ** 1024;
    var ser = try bincode.writeToSlice(buf[0..], slot, bincode.Params.standard);

    try testing.expect(std.mem.eql(u8, ser, rust_serialized[0..]));
}

const std = @import("std");
const bincode = @import("../bincode/bincode.zig");

pub fn ArrayListConfig(comptime Child: type) bincode.FieldConfig(std.ArrayList(Child)) {
    const S = struct {
        pub fn serialize(writer: anytype, data: anytype, params: bincode.Params) !void {
            var list: std.ArrayList(Child) = data;
            try bincode.write(null, writer, @as(u64, list.items.len), params);
            for (list.items) |item| {
                try bincode.write(null, writer, item, params);
            }
            return;
        }

        pub fn deserialize(allocator: ?std.mem.Allocator, reader: anytype, params: bincode.Params) !std.ArrayList(Child) {
            var ally = allocator.?;
            var len = try bincode.read(ally, u64, reader, params);
            var list = try std.ArrayList(Child).initCapacity(ally, @as(usize, len));
            for (0..len) |_| {
                var item = try bincode.read(ally, Child, reader, params);
                try list.append(item);
            }
            return list;
        }
    };

    return bincode.FieldConfig(std.ArrayList(Child)){
        .serializer = S.serialize,
        .deserializer = S.deserialize,
    };
}

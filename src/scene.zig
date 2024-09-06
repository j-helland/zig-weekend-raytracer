const std = @import("std");

const ent = @import("entity.zig");

pub const Scene = struct {
    entity_pool: *std.heap.MemoryPool(ent.IEntity),
};

// pub const Scene = union(enum) {
//     const Self = @This();

//     cornell_box: SceneCornellBox,
// };

// pub const SceneCornellBox = struct {

// };
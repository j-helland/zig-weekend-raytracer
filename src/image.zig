const std = @import("std");

const zstbi = @import("zstbi");

const ERR_COLOR = [3]u8{255, 0, 255}; // magenta

pub const Image = struct {
    const Self = @This();

    image: ?zstbi.Image = null,

    pub fn initFromFile(path: [:0]const u8) !Self {
        defer std.log.debug("Loaded {s}", .{path});

        const forced_num_components = 0;
        return Self{ .image = try zstbi.Image.loadFromFile(path, forced_num_components) };
    }

    pub fn deinit(self: *Self) void {
        if (self.image) |*image| image.deinit();
    }

    pub fn getPixel(self: *const Self, x: usize, y: usize) []const u8 {
        if (self.image) |*image| {
            const row_stride = image.bytes_per_row;
            const col_stride = image.num_components * image.bytes_per_component;

            const cidx = std.math.clamp(x, 0, image.width - 1);
            const ridx = std.math.clamp(y, 0, image.height - 1);
            const start_idx = row_stride * ridx + col_stride * cidx;
            const end_idx = start_idx + image.num_components;

            return image.data[start_idx..end_idx];
        }
        return &ERR_COLOR;
    }

    pub fn getHeight(self: *const Self) usize {
        return 
            if (self.image) |*image| image.height
            else 0;
    }

    pub fn getWidth(self: *const Self) usize {
        return 
            if (self.image) |*image| image.width
            else 0;
    }
};
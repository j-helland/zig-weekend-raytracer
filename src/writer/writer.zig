const std = @import("std");

const math = @import("../math/math.zig");
const mmap = @import("mmap.zig");

pub const WriterPPM = struct {
    const Self = @This();

    const PPM_HEADER_FMT = "P3\n{} {}\n255\n";
    const PPM_PIXEL_FMT = "{d} {d} {d}\n";
    const PPM_PIXEL_NUM_BYTES = "255 255 255\n".len;

    allocator: std.mem.Allocator,
    thread_pool: *std.Thread.Pool,

    pub fn write(self: *Self, out_path: []const u8, data: []const math.Color, num_cols: usize, num_rows: usize) !void {
        // Create and memory map file
        const header = try std.fmt.allocPrint(self.allocator, PPM_HEADER_FMT, .{ num_cols, num_rows });
        defer self.allocator.free(header);
        const content_size = data.len * PPM_PIXEL_NUM_BYTES + header.len;

        const handle = try mmap.MmapHandlePosix.init(out_path, content_size);
        defer handle.deinit();

        // Write header.
        std.mem.copyForwards(u8, handle.ptr, header);

        // Write body.
        const chunk_size = 1024;
        var file_index = header.len;
        var data_index: usize = 0;  
        var wg = std.Thread.WaitGroup{};
        while (data_index < data.len) : (data_index += chunk_size) {
            // Handle uneven chunk partitioning.
            const data_slice = data[data_index..@min(data.len, data_index + chunk_size)];

            var chunk_content_size: usize = 0;
            for (data_slice) |color| {
                chunk_content_size += sizeOfLine(&encodeColor(color));
            }
            defer file_index += chunk_content_size;

            self.thread_pool.spawnWg(&wg, writeChunk, .{ 
                WriterThreadContext{
                    .out_ptr = handle.ptr[file_index..file_index + chunk_content_size],
                    .data = data_slice, 
                },
            });
        }
        self.thread_pool.waitAndWork(&wg);
    }    
};

const WriterThreadContext = struct {
    out_ptr: []u8,
    data: []const math.Color,
};
fn writeChunk(ctx: WriterThreadContext) void {
    var out_idx: usize = 0;
    for (ctx.data) |color| {
        const pixel = encodeColor(color);
        const result = std.fmt.bufPrint(ctx.out_ptr[out_idx..], WriterPPM.PPM_PIXEL_FMT, .{pixel[0], pixel[1], pixel[2]})
            catch @panic("Failed to write chunk");
        out_idx += result.len;
    }
}

fn encodeColor(_color: math.Color) [3]u8 {
    const rgb_max = 256.0;
    const intensity = math.Interval(math.Real){ .min = 0.0, .max = 0.999 };

    // Hack to resolve pixel acne from NaN issues
    var color = discardNaNs(_color);
    color = math.gammaCorrection(color);

    const ir = @as(u8, @intFromFloat(rgb_max * intensity.clamp(color[0])));
    const ig = @as(u8, @intFromFloat(rgb_max * intensity.clamp(color[1])));
    const ib = @as(u8, @intFromFloat(rgb_max * intensity.clamp(color[2])));

    return .{ir, ig, ib};
}

inline fn discardNaNs(color: math.Color) math.Color {
    return math.vec3(
        clampNaN(color[0]),
        clampNaN(color[1]),
        clampNaN(color[2]),
    );
}

inline fn clampNaN(x: math.Real) math.Real {
    if (std.math.isNan(x)) return 0;
    return x;
}

fn sizeOfLine(pixel: *const [3]u8) usize {
    const digits_size = sizeOfDigit(pixel[0]) + sizeOfDigit(pixel[1]) + sizeOfDigit(pixel[2]);
    // Assume the format "{} {} {}\n", which has 3 separating characters.
    return pixel.len + digits_size;
}
test "sizeOfLine" {
    try std.testing.expectEqual(6, sizeOfLine(&.{0, 0, 0}));
    try std.testing.expectEqual(8, sizeOfLine(&.{0, 255, 0}));
    try std.testing.expectEqual(12, sizeOfLine(&.{255, 255, 255}));
}

inline fn sizeOfDigit(digit: u8) usize {
    // Minimal encoding size is 1 for a single base-10 digit.
    // We can shift this to 0x2 for 2 digits. Last, or in the final bit for 0x3 digits.
    var result: usize = 0x1;
    result <<= @intFromBool(digit > 9);
    result |= @intFromBool(digit > 99);
    return result;
}
test "sizeOfDigit" {
    try std.testing.expectEqual(1, sizeOfDigit(std.math.minInt(u8)));
    try std.testing.expectEqual(1, sizeOfDigit(0));
    try std.testing.expectEqual(1, sizeOfDigit(9));
    try std.testing.expectEqual(2, sizeOfDigit(10));
    try std.testing.expectEqual(2, sizeOfDigit(99));
    try std.testing.expectEqual(3, sizeOfDigit(100));
    try std.testing.expectEqual(3, sizeOfDigit(std.math.maxInt(u8)));
}

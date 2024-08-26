const std = @import("std");

const print = std.debug.print;

pub fn main() !void {
    const img_width = 256;
    const img_height = 256;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("P3\n{} {}\n255\n", .{img_width, img_height});

    for (0..img_height) |i| {
        for (0..img_width) |j| {
            const r = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(img_height));
            const g = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(img_width));
            const b = 0.0;

            const factor = 255.999;
            const ir = @as(u8, @intFromFloat(r * factor));
            const ig = @as(u8, @intFromFloat(g * factor));
            const ib = @as(u8, @intFromFloat(b * factor));

            try stdout.print("{} {} {}\n", .{ir, ig, ib});
        }
    }
}


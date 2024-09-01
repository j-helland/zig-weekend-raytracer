const std = @import("std");

pub const ArgParser = struct {
    const Self = @This();

    const ParseArgsError = error{
        ParseIntFailed,
    };

    const UserArgs = struct {
        image_width: usize = 800,
        image_out_path: []const u8 = "image.ppm",
    };

    args_iter: std.process.ArgIterator,
    args: UserArgs = .{},

    pub fn init(allocator: std.mem.Allocator) std.process.ArgIterator.InitError!Self {
        return Self{ .args_iter = try std.process.ArgIterator.initWithAllocator(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.args_iter.deinit();
    }

    pub fn parse(self: *Self) ParseArgsError!*const UserArgs {
        // skip executable
        _ = self.args_iter.next();

        // image width
        if (self.args_iter.next()) |arg| {
            self.args.image_width = std.fmt.parseInt(usize, arg, 10)
                catch return ParseArgsError.ParseIntFailed;
        }

        if (self.args_iter.next()) |arg| {
            self.args.image_out_path = arg;
        }

        if (self.args_iter.next()) |arg| {
            std.log.warn("Ignoring extra args starting at {s}", .{arg});
        }
        return &self.args;
    }
};
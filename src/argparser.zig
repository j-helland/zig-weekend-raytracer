const std = @import("std");

/// Passed in type must provide default values for all fields.
pub fn ArgParser(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const ParseArgsError = error{
            ParseIntFailed,
            ParseTypeParseMethodMissing,
            InvalidArgument,
            UnrecognizedArgument,
        };

        args_iter: std.process.ArgIterator,
        keyvals: std.StringHashMap(?[]const u8),
        args: T = .{},

        pub fn init(allocator: std.mem.Allocator) !Self {
            var self = Self{ 
                .args_iter = try std.process.ArgIterator.initWithAllocator(allocator), 
                .keyvals = std.StringHashMap(?[]const u8).init(allocator),
            };

            // preload so we can detect unknown user args
            inline for (@typeInfo(T).Struct.fields) |field| {
                try self.keyvals.put(field.name, null);
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.args_iter.deinit();
            self.keyvals.deinit();
        }

        pub fn parse(self: *Self) !*const T {
            // skip executable
            _ = self.args_iter.next();

            // Load key/val splits.            
            while (self.args_iter.next()) |argval| {
                try self.cacheArgVal(argval);
            }

            inline for (@typeInfo(T).Struct.fields) |field| {
                // cache was prefilled with fields
                if (self.keyvals.get(field.name).?) |val| {
                    @field(self.args, field.name) = switch (field.type) {
                        []const u8 => val,

                        bool => {
                            if (std.mem.eql(u8, val, "true")) break true;
                            if (std.mem.eql(u8, val, "1")) break true;
                            if (std.mem.eql(u8, val, "false")) break false;
                            if (std.mem.eql(u8, val, "0")) break false;
                        },

                        // ints
                        usize, u128, u64, u32, u16, u8, isize, i128, i64, i32, i16, i8 
                            => |t| try std.fmt.parseInt(t, val, 10), 

                        // floats
                        f128, f80, f64, f32, f16 => |t| try std.fmt.parseFloat(t, val),

                        // types with custom parsing logic
                        else => |t| {
                            if (!@hasDecl(t, "parse")) {
                                return ParseArgsError.ParseTypeParseMethodMissing;
                            }
                            break t.parse(val);
                        },
                    };
                }
            }

            return &self.args;
        }

        /// Outputs the expected arguments and their types.
        pub fn printUsage(self: *const Self, writer: std.fs.File.Writer) anyerror!void {
            try writer.print("Usage:\n", .{});

            inline for (@typeInfo(T).Struct.fields) |field| {
                if (std.meta.hasMethod(field.type, "printUsage")) {
                    try @field(self.args, field.name).printUsage(writer);

                } else {
                    try writer.print("\t--{s}=<{any}>\n", .{field.name, field.type});
                }
            }
        }

        fn cacheArgVal(self: *Self, argval: []const u8) !void {
            var start_idx: usize = 0;
            while (start_idx < argval.len and argval[start_idx] == '-') 
                : (start_idx += 1) {}

            var split = std.mem.splitSequence(u8, argval[start_idx..], "=");
            const key = split.next() orelse return ParseArgsError.InvalidArgument;
            const val = split.next() orelse return ParseArgsError.InvalidArgument;

            if (!self.keyvals.contains(key)) return ParseArgsError.UnrecognizedArgument;
            self.keyvals.putAssumeCapacity(key, val);
        }
    };
}

const std = @import("std");

const ARG_PREFIX = '-';
const ARG_VAL_DELIMITER = "=";

pub const ParseArgsError = error{
    ParseIntFailed,
    ParseBoolFailed,
    ParseFloatFailed,
    ParseEnumFailed,
    ParseMethodMissingFromType,
    InvalidArgument,
    UnrecognizedArgument,
};

/// Passed in type must provide default values for all fields.
pub fn ArgParser(comptime T: type) type {
    return struct {
        const Self = @This();        

        keyvals: std.StringHashMap(?[]const u8),
        args: T = .{},

        /// Loads user args into parsing context.
        pub fn init(allocator: std.mem.Allocator) !Self {
            var self = Self{ .keyvals = std.StringHashMap(?[]const u8).init(allocator) };

            // preload so we can detect unknown user args
            inline for (@typeInfo(T).Struct.fields) |field| {
                try self.keyvals.put(field.name, null);
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.keyvals.deinit();
        }

        /// Parses loaded args into underlying struct. Default values with no user overrides will be preserved.
        pub fn parse(self: *Self, argvals: []const []const u8) !*const T {        
            if (argvals.len == 0) return &self.args;

            // Load key/val splits.            
            const skip_exe_arg = 1;
            for (argvals[skip_exe_arg..]) |argval| {
                try self.cacheArgVal(argval);
            }

            inline for (@typeInfo(T).Struct.fields) |field| {
                // cache was prefilled with fields
                if (self.keyvals.get(field.name).?) |val| {
                    @field(self.args, field.name) = try parseVal(field.type, val);
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
            const start_idx = getArgStartIndex(argval);

            var split = std.mem.splitSequence(u8, argval[start_idx..], ARG_VAL_DELIMITER);
            const key = split.next() orelse return ParseArgsError.InvalidArgument;
            const val = split.next() orelse return ParseArgsError.InvalidArgument;

            if (!self.keyvals.contains(key)) return ParseArgsError.UnrecognizedArgument;
            self.keyvals.putAssumeCapacity(key, val);
        }
    };
}

fn getArgStartIndex(argval: []const u8) usize {
    var start_idx: usize = 0;
    while (start_idx < argval.len and argval[start_idx] == ARG_PREFIX) 
        : (start_idx += 1) {}
    return start_idx;
}

/// Uses reflection to parse a string value into the specified type.
/// Non primitive types must implement a "parse" method.
fn parseVal(comptime T: type, val: []const u8) anyerror!T {
    // Unwrap optional types. Type coercion will handle assignment later.
    if (isOptionalType(T) and std.mem.eql(u8, val, "null")) {
        return null;
    }
    const type_underlying = unwrapOptionalType(T);

    // Reflect on enum values.
    if (isEnumType(type_underlying)) {
        return std.meta.stringToEnum(type_underlying, val)
            orelse return ParseArgsError.ParseEnumFailed;
    }

    return switch (type_underlying) {
        []const u8 => val,

        bool => 
            if (std.mem.eql(u8, val, "true")) 
                true
            else if (std.mem.eql(u8, val, "false")) 
                false
            else 
                return ParseArgsError.ParseBoolFailed,

        // ints
        usize, u128, u64, u32, u16, u8, isize, i128, i64, i32, i16, i8 => |t| 
            std.fmt.parseInt(t, val, 10)
                catch return ParseArgsError.ParseIntFailed, 

        // floats
        f128, f80, f64, f32, f16 => |t| 
            std.fmt.parseFloat(t, val)
                catch return ParseArgsError.ParseFloatFailed,

        // types with custom parsing logic
        else => |t| blk: {
            if (!std.meta.hasMethod(t, "parse")) {
                return ParseArgsError.ParseMethodMissingFromType;
            }
            break :blk try t.parse(val);
        },
    };
}

inline fn isEnumType(comptime T: type) bool {
    return (@typeInfo(T) == .Enum);
}

inline fn isOptionalType(comptime T: type) bool {
    return (@typeInfo(T) == .Optional);
}

inline fn unwrapOptionalType(comptime T: type) type {
    return 
        if (isOptionalType(T)) @typeInfo(T).Optional.child
        else T;
}

test "ArgParser - happy path" {
    const UserArgs = struct {
        arg1: usize = 0,
        arg2: f16 = 1.0,
        arg3: []const u8 = "arg3",
        arg4: bool = false,
        arg5_default: usize = 0,
        arg6: ?usize = null,
        arg7: ?usize = 0,
    };

    const argvals = [_][:0]const u8{
        "/EXE",
        "--arg4=true",
        "arg3=string-val",
        "--arg2=0.5",
        "-arg1=1",
        "--arg6=1",
        "--arg7=null",
    };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();
    const args = try parser.parse(&argvals);

    try std.testing.expectEqual(1, args.arg1);
    try std.testing.expectApproxEqRel(0.5, args.arg2, 1e-6);
    try std.testing.expectEqualStrings("string-val", args.arg3);
    try std.testing.expectEqual(true, args.arg4);
    // defaults with no user override should be preserved.
    try std.testing.expectEqual(0, args.arg5_default);
    try std.testing.expectEqual(1, args.arg6);
    try std.testing.expectEqual(null, args.arg7);
}

test "ArgParser - unknown arg" {
    const UserArgs = struct {};
    const argvals = [_][:0]const u8{ "/EXE", "--arg4=true" };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    try std.testing.expectError(ParseArgsError.UnrecognizedArgument, parser.parse(&argvals));
}

test "ArgParser - nested struct - catches missing parse method" {
    const UserArgs = struct {
        nested: struct {
            arg1: usize = 0,
        } = .{},
    };
    const argvals = [_][:0]const u8{ "/EXE", "--nested=1" };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    try std.testing.expectError(ParseArgsError.ParseMethodMissingFromType, parser.parse(&argvals));
}

test "ArgParser - nested struct" {
    const UserArgs = struct {
        nested: struct {
            arg1: usize = 0,

            pub fn parse(val: []const u8) std.fmt.ParseIntError!@This() {
                return .{ .arg1 = try std.fmt.parseInt(usize, val, 10) };
            }
        } = .{},
    };
    const argvals = [_][:0]const u8{ "/EXE", "--nested=1" };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    const args = try parser.parse(&argvals);
    try std.testing.expectEqual(1, args.nested.arg1);
}

test "ArgParser - enum values" {
    const UserEnum = enum {
        flag1,
        flag2,
    };
    const UserArgs = struct {
        flag: UserEnum = .flag1,
    };

    const argvals = [_][:0]const u8{ "/EXE", "--flag=flag2" };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    const args = try parser.parse(&argvals);
    try std.testing.expectEqual(UserEnum.flag2, args.flag);
}

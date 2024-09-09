const std = @import("std");

const ARG_PREFIX = '-';
const ARG_VAL_DELIMITER_DEFAULT = "=";
const ARG_HELP = "help";

pub const ParseArgsError = error{
    HelpPassedInArgs,
    ParseIntFailed,
    ParseBoolFailed,
    ParseFloatFailed,
    ParseEnumFailed,
    ParseMethodMissingFromType,
    InvalidArgument,
    ArgumentMissingValue,
    RequiredArgumentMissing,
    UnrecognizedArgument,
};

/// Passed in type must provide default values for all fields.
pub fn ArgParser(comptime T: type) type {
    return struct {
        const Self = @This();        

        allocator: std.mem.Allocator,
        argval_cache: std.StringHashMap(?[]const u8),
        argval_delimiter: []const u8,

        args_parsed: T = undefined,

        /// Loads user args into parsing context.
        pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return initDelimiter(allocator, ARG_VAL_DELIMITER_DEFAULT);
        }

        pub fn initDelimiter(allocator: std.mem.Allocator, argval_delimiter: []const u8) std.mem.Allocator.Error!Self {
            var self = Self{ 
                .allocator = allocator,
                .argval_cache = std.StringHashMap(?[]const u8).init(allocator),
                .argval_delimiter = argval_delimiter,
            };

            // preload so we can detect unknown user args
            inline for (@typeInfo(T).@"struct".fields) |field| {
                try self.argval_cache.put(field.name, null);
            }

            return self;
        }

        /// Clears parsing state from previous invocation.
        pub fn reset(self: *Self) void {
            inline for (@typeInfo(T).Struct.fields) |field| {
                self.argval_cache.putAssumeCapacity(field.name, null);
            }
            self.args_parsed = undefined;
        }

        pub fn deinit(self: *Self) void {
            self.argval_cache.deinit();
        }

        /// Parses loaded args into underlying struct. Default values with no user overrides will be preserved.
        pub fn parse(self: *Self, argvals: []const []const u8) anyerror!*const T {        
            // Load key/val splits.            
            for (argvals) |argval| {
                try self.cacheArgVal(argval);
            }

            inline for (@typeInfo(T).@"struct".fields) |field| {
                const maybe_val = self.argval_cache.get(field.name).?;  // all field keys were populated during init
                if (maybe_val) |val| {
                    @field(self.args_parsed, field.name) = try self.parseConcreteValue(field.type, val);

                } else if (isRequiredArg(field)) {
                    return ParseArgsError.RequiredArgumentMissing;

                } else if (isOptionalType(field.type)) {
                    // We can assume optional types without default values are null de facto.
                    @field(self.args_parsed, field.name) = null;

                } else {
                    std.debug.assert(field.default_value != null); // otherwise would be considered required arg

                    const default_ptr = field.default_value.?; 
                    const default = @as(*align(1) const field.type, @ptrCast(default_ptr)).*;
                    @field(self.args_parsed, field.name) = default;
                }
            }
            return &self.args_parsed;
        }        

        /// Outputs the expected arguments and their types.
        pub fn printUsage(self: *const Self, writer: std.fs.File.Writer) anyerror!void {
            try writer.print("Usage:\n", .{});

            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (std.meta.hasMethod(field.type, "printUsage")) {
                    try @field(self.args_parsed, field.name).printUsage(writer);

                } else {
                    try writer.print("\t--{s}=<{any}>\n", .{field.name, field.type});
                    switch (@typeInfo(field.type)) {
                        .@"enum" => {
                            inline for (comptime std.enums.values(field.type)) |e| {
                                try writer.print("\t\t{s}\n", .{@tagName(e)});
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        /// Split input into keys and values for later.
        fn cacheArgVal(self: *Self, argval: []const u8) ParseArgsError!void {
            const start_idx = getArgStartIndex(argval);

            var split = std.mem.splitSequence(u8, argval[start_idx..], self.argval_delimiter);
            const key = split.next() orelse return ParseArgsError.InvalidArgument;

            // Handle help flag passed among args.
            // We pass this back as an error so that it can be handled with other exceptional cases (commonly, usage is printed on other errors as well).
            if (std.mem.eql(u8, key, "help") or std.mem.eql(u8, key, "h")) {
                return ParseArgsError.HelpPassedInArgs;
            }
            if (!self.argval_cache.contains(key)) {
                return ParseArgsError.UnrecognizedArgument;
            }

            // Allow valueless keys to support flags.
            const val = split.rest();
            if (val.len == 0) return ParseArgsError.ArgumentMissingValue;

            self.argval_cache.putAssumeCapacity(key, val);
        }

        /// Uses reflection to parse a string value into the specified type.
        /// Non primitive types must implement a "parse" method.
        fn parseConcreteValue(self: *const Self, comptime ConcereteType: type, val: []const u8) anyerror!ConcereteType {
            // Unwrap optional types. Type coercion will handle assignment later.
            if (isOptionalType(ConcereteType) and std.mem.eql(u8, val, "null")) {
                return null;
            }
            const TypeUnderlying = unwrapOptionalType(ConcereteType);

            // Reflect on enum values.
            if (isEnumType(TypeUnderlying)) {
                return std.meta.stringToEnum(TypeUnderlying, val)
                    orelse return ParseArgsError.ParseEnumFailed;
            }

            return switch (TypeUnderlying) {
                []const u8 => val,

                bool => 
                    if (std.mem.eql(u8, val, "true")) 
                        true
                    else if (std.mem.eql(u8, val, "false")) 
                        false
                    else 
                        return ParseArgsError.ParseBoolFailed,

                // ints
                usize, u128, u64, u32, u16, u8, isize, i128, i64, i32, i16, i8 => |Int| 
                    std.fmt.parseInt(Int, val, 10)
                        catch return ParseArgsError.ParseIntFailed, 

                // floats
                f128, f80, f64, f32, f16 => |Float| 
                    std.fmt.parseFloat(Float, val)
                        catch return ParseArgsError.ParseFloatFailed,

                // types with custom parsing logic
                else => |Nested| blk: {
                    if (!std.meta.hasMethod(Nested, "parse")) {
                        return ParseArgsError.ParseMethodMissingFromType;
                    }
                    break :blk try Nested.parse(self.allocator, val);
                },
            };
        }
    };
}

fn getArgStartIndex(argval: []const u8) usize {
    var start_idx: usize = 0;
    while (start_idx < argval.len and argval[start_idx] == ARG_PREFIX) 
        : (start_idx += 1) {}
    return start_idx;
}

inline fn isRequiredArg(field: std.builtin.Type.StructField) bool {
    return (!isOptionalType(field.type) and (field.default_value == null));
}

inline fn isEnumType(comptime T: type) bool {
    return (@typeInfo(T) == .@"enum");
}

inline fn isOptionalType(comptime T: type) bool {
    return (@typeInfo(T) == .optional);
}

inline fn unwrapOptionalType(comptime T: type) type {
    return 
        if (isOptionalType(T)) @typeInfo(T).optional.child
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
        arg8_default_null: ?usize, // optionals are considered de facto null without explicit default values
        arg9_required: usize,      // non-optional, non-default fields are considered required
    };

    const argvals = [_][:0]const u8{
        "--arg4=true",
        "arg3=string-val",
        "--arg2=0.5",
        "-arg1=1",
        "--arg6=1",
        "--arg7=null",
        "--arg9_required=0",
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
    try std.testing.expectEqual(null, args.arg8_default_null);
    try std.testing.expectEqual(0, args.arg9_required);
}

test "ArgParser - argval delimiter" {
    const UserArgs = struct {
        required: usize,
    };

    const delimiter = "::";
    var parser = try ArgParser(UserArgs).initDelimiter(std.testing.allocator, delimiter);
    defer parser.deinit();

    const argvals = [_][:0]const u8{ "--required" ++ delimiter ++ "0" };
    const args = try parser.parse(&argvals);

    try std.testing.expectEqual(0, args.required);
}

test "ArgParser - required args" {
    const UserArgs = struct {
        required: usize,
    };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    {
        const argvals = [_][:0]const u8{};
        try std.testing.expectError(ParseArgsError.RequiredArgumentMissing, parser.parse(&argvals));
    }

    parser.reset();
    {
        const argvals = [_][:0]const u8{ "--required=0" };
        const args = try parser.parse(&argvals);
        try std.testing.expectEqual(0, args.required);
    }
}

test "ArgParser - unknown arg" {
    const UserArgs = struct {};
    const argvals = [_][:0]const u8{ "--arg4=true" };

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
    const argvals = [_][:0]const u8{ "--nested=1" };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    try std.testing.expectError(ParseArgsError.ParseMethodMissingFromType, parser.parse(&argvals));
}

test "ArgParser - nested struct" {
    const UserArgs = struct {
        nested: struct {
            arg1: usize = 0,

            // ArgParser can be invoked recursively like this.
            pub fn parse(allocator: std.mem.Allocator, argval: []const u8) !@This() {
                var parser = try ArgParser(@This()).init(allocator);
                defer parser.deinit();

                const this = try parser.parse(&.{argval});
                return this.*;
            }
        } = .{},
    };
    const argvals = [_][:0]const u8{ "--nested=arg1=1" };

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

    const argvals = [_][:0]const u8{ "--flag=flag2" };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    const args = try parser.parse(&argvals);
    try std.testing.expectEqual(UserEnum.flag2, args.flag);
}

test "ArgParser - boolean flags" {
    const UserArgs = struct {
        flag: bool = false,
        flag_default: bool = false,
    };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    {
        const argvals = [_][:0]const u8{ "--flag=true" };
        const args = try parser.parse(&argvals);
        try std.testing.expectEqual(true, args.flag);
        try std.testing.expectEqual(false, args.flag_default);
    }
    parser.reset();
    {
        const argvals = [_][:0]const u8{ "--flag=false" };
        const args = try parser.parse(&argvals);
        try std.testing.expectEqual(false, args.flag);
        try std.testing.expectEqual(false, args.flag_default);
    }
    parser.reset();
    {
        const argvals = [_][:0]const u8{ "--flag" };
        try std.testing.expectError(ParseArgsError.ArgumentMissingValue, parser.parse(&argvals));
    }
}

test "ArgParser - help" {
    const UserEnum = enum {
        flag1,
        flag2,
    };
    const UserArgs = struct {
        flag: UserEnum = .flag1,
    };

    var parser = try ArgParser(UserArgs).init(std.testing.allocator);
    defer parser.deinit();

    {
        defer parser.reset();
        const argvals = [_][:0]const u8{ "--help" };
        try std.testing.expectError(ParseArgsError.HelpPassedInArgs, parser.parse(&argvals));
    }
    {
        defer parser.reset();
        const argvals = [_][:0]const u8{ "-h" };
        try std.testing.expectError(ParseArgsError.HelpPassedInArgs, parser.parse(&argvals));
    }
    {
        defer parser.reset();
        const argvals = [_][:0]const u8{ "--flag=flag2", "--help", "--flag=flag1" };
        try std.testing.expectError(ParseArgsError.HelpPassedInArgs, parser.parse(&argvals));
    }
}
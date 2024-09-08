const std = @import("std");
 
const ztracy = @import("ztracy");

pub const rng = @import("rng.zig");

pub const Ray = @import("ray.zig").Ray;

pub const Interval = @import("interval.zig").Interval;
pub const INTERVAL_01 = Interval(Real){ .min = 0, .max = 1 };

pub const AABB = @import("aabb.zig").AABB;

/// Always pick a power of two for @Vector sizes.
fn suggestVectorSize(comptime T: type, min: usize) usize {
    const min2 = try std.math.ceilPowerOfTwo(usize, min);
    const suggested = std.simd.suggestVectorLength(T) orelse min2;
    return @max(min2, suggested);
}
fn Vec(comptime T: type, size: comptime_int) type {
    return @Vector(suggestVectorSize(T, size), T);
}

pub inline fn vecLen(comptime V: type) comptime_int {
    return switch (@typeInfo(V)) {
        .Vector => |info| info.len, 
        .Array => |info| info.len,
        inline else => @compileError("Invalid vector type " ++ @typeName(V)),
    };
}

pub inline fn vecCapacity(comptime V: type) comptime_int {
    return switch (V) {
        Vec3 => 3,
        Vec2 => 2,
        else => @compileError("Invalid type " ++ @typeName(V)),
    };
}

pub const Real = f64;

pub const Vec3 = Vec(Real, 3);
pub const Vec2 = Vec(Real, 2);
pub const Vecx = Vec(Real, 4);

pub const Point3 = Vec3;
pub const Color = Vec3;

pub const Axis = enum(u2) { 

    x, y, z,

    pub inline fn select(self: Axis, v: anytype) std.meta.Child(@TypeOf(v)) {
        return v[@intFromEnum(self)];
    }
};

pub const OrthoBasis = struct {
    const Self = @This();

    pub const OrthoAxis = enum { u, v, w };

    basis: std.enums.EnumArray(OrthoAxis, Vec3),

    pub fn init(n: Vec3) Self {
        const w = normalize(n);
        // pick a direction that isn't parallel to w
        const a = if (@abs(w[1]) > 0.9) vec3(1, 0, 0) else vec3(0, 1, 0);
        const u = normalize(cross(w, a));
        const v = cross(w, u);

        return initFromVectors(u, v, w);
    }

    pub fn initFromVectors(u: Vec3, v: Vec3, w: Vec3) Self {
        var self = Self{ .basis = std.enums.EnumArray(OrthoAxis, Vec3).initUndefined() };

        self.basis.set(.u, u);
        self.basis.set(.v, v);
        self.basis.set(.w, w);

        return self;
    }

    pub fn get(self: *const Self, axis: OrthoAxis) Vec3 {
        return self.basis.get(axis);
    }

    pub fn transform(self: *const Self, v: Vec3) Vec3 {
        return (
            self.get(.u) * vec3s(v[0]) 
            + self.get(.v) * vec3s(v[1]) 
            + self.get(.w) * vec3s(v[2])
        );
    }
};

/// For MaxMult method from listing 5 of robust BVH traversal paper: 
/// https://blogs.autodesk.com/media-and-entertainment/wp-content/uploads/sites/162/jcgt2013_robust_BVH-revised.pdf
/// This is a "crude" approximation that adds up to 4 ULPs, which can be excessive. If a tighter bound is required (e.g. 2 ULPs), use addUlpMagnitude below.
pub inline fn maxMultFactor(comptime T: type) T {
    return switch (T) {
        f32 => 1.00000024,
        f64 => 1.0000000000000004,
        else => @compileError("Invalid float type: " ++ @typeName(T)),
    };
}

/// Listing 3 of https://blogs.autodesk.com/media-and-entertainment/wp-content/uploads/sites/162/jcgt2013_robust_BVH-revised.pdf
pub fn addUlpMagnitude(
    x: anytype, 
    ulps: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(x)))
) @TypeOf(x) {
    const T = @TypeOf(x);
    if (@typeInfo(T) != .Float) {
        @compileError("Invalid float type: " ++ @typeName(T));
    }
    const UT = std.meta.Int(.unsigned, @bitSizeOf(T));

    if (!std.math.isFinite(x)) return x;
    const bits = @as(UT, @bitCast(x));
    return @as(T, @bitCast(bits + ulps));
}
test "addUlpMagnitude" {
    {
        const x: f32 = 0.0;
        try std.testing.expectEqual(x, addUlpMagnitude(x, 0));
        try std.testing.expect(x != addUlpMagnitude(x, 1));
        try std.testing.expectApproxEqAbs(x, addUlpMagnitude(x, 1), std.math.floatEps(@TypeOf(x)));
        try std.testing.expect(x != addUlpMagnitude(x, 2));
        try std.testing.expectApproxEqAbs(x, addUlpMagnitude(x, 2), std.math.floatEps(@TypeOf(x)));
    }
    {
        const x: f64 = 0.0;
        try std.testing.expectEqual(x, addUlpMagnitude(x, 0));
        try std.testing.expect(x != addUlpMagnitude(x, 1));
        try std.testing.expectApproxEqAbs(x, addUlpMagnitude(x, 1), std.math.floatEps(@TypeOf(x)));
        try std.testing.expect(x != addUlpMagnitude(x, 2));
        try std.testing.expectApproxEqAbs(x, addUlpMagnitude(x, 2), std.math.floatEps(@TypeOf(x)));
    }
}

/// Create a Vec3 filled with a scalar value. 
pub inline fn vec3s(x: Real) Vec3 {
    return @splat(x);
}
test "vec3s" {
    try expectVecEqual(vec3(1, 1, 1), vec3s(1));
}

pub inline fn vec2s(x: Real) Vec2 {
    return @splat(x);
}

/// Create a Vec3 type populated with specified values.
pub inline fn vec3(x: Real, y: Real, z: Real) Vec3 {
    var v = std.mem.zeroes(Vec3);
    v[@intFromEnum(Axis.x)] = x;
    v[@intFromEnum(Axis.y)] = y;
    v[@intFromEnum(Axis.z)] = z;
    return v;
}

pub inline fn vec2(x: Real, y: Real) Vec2 {
    var v = std.mem.zeroes(Vec2);
    v[@intFromEnum(Axis.x)] = x;
    v[@intFromEnum(Axis.y)] = y;
    return v;
}

/// Assumes gamma = 2
pub inline fn linearizeColorSpace(color: Vec3) Vec3 {
    return color * color;
}

/// Assumes gamma = 2
pub inline fn gammaCorrection(color: Vec3) Vec3 {
    return @sqrt(color);
}

pub inline fn lerp(x: Vec3, y: Vec3, alpha: Real) Vec3 {
    return x + vec3s(alpha) * (y - x);
}

/// Fill superfluous @Vector components with a given value.
pub inline fn rightPad(comptime V: type, v: *V, val: std.meta.Child(V)) void {
    inline for (vecCapacity(V) - 1 .. vecLen(V)) |i| {
        v[i] = val;
    }
}

pub inline fn swizzle(
    v: Vec3,
    comptime x: Axis,
    comptime y: Axis,
    comptime z: Axis,
) Vec3 {
    const mask = comptime blk: {
        var m = std.simd.iota(i32, vecLen(Vec3));
        m[@intFromEnum(Axis.x)] = @intFromEnum(x);
        m[@intFromEnum(Axis.y)] = @intFromEnum(y);
        m[@intFromEnum(Axis.z)] = @intFromEnum(z);
        break :blk m;
    };
    return @shuffle(Real, v, undefined, mask);
}
test "swizzle" {
    const v = vec3(1, 2, 3);
    try expectVecEqual(v, swizzle(v, .x, .y, .z));
    try expectVecEqual(vec3(3, 2, 1), swizzle(v, .z, .y, .x));
    try expectVecEqual(vec3(1, 1, 1), swizzle(v, .x, .x, .x));
}

pub inline fn cross(u: Vec3, v: Vec3) Vec3 {
    // return vec3(
    //     y.select(u)*z.select(v) - z.select(u)*y.select(v),
    //     z.select(u)*x.select(v) - x.select(u)*z.select(v),
    //     x.select(u)*y.select(v) - y.select(u)*x.select(v),
    // );
    var xu = swizzle(u, .y, .z, .x);
    var xv = swizzle(v, .z, .x, .y);
    var xmm = xu * xv;

    xu = swizzle(xu, .y, .z, .x);
    xv = swizzle(xv, .z, .x, .y);
    xmm -= xu * xv;

    return xmm;
}
test "cross" {
    {
        const u = vec3(1, 0, 0);
        const v = vec3(0, 1, 0);
        try expectVecApproxEqRel(vec3(0, 0, 1), cross(u, v), 1e-6);
    }
    {
        const u = vec3(1, 0, 0);
        const v = vec3(0, -1, 0);
        try expectVecApproxEqRel(vec3(0, 0, -1), cross(u, v), 1e-6);
    }
}

pub inline fn dot(u: Vec3, v: Vec3) Real {
    const xmm = u * v;
    return xmm[0] + xmm[1] + xmm[2];
}
test "dot" {
    const u = vec3(1, 1, 1);
    const v = vec3(2, 2, 2);
    const d = dot(u, v);
    try std.testing.expectApproxEqRel(6.0, d, 1e-8);
}

pub inline fn length(u: Vec3) Real {
    return @sqrt(dot(u, u));
} 
test "length" {
    const u = vec3(1, 1, 1);
    try std.testing.expectApproxEqRel(@sqrt(3.0), length(u), 1e-8);
}

pub inline fn normalize(u: Vec3) Vec3 {
    return u * vec3s(1.0 / length(u));
}
test "normalize" {
    const u = vec3(1, 2, 3);
    try std.testing.expectApproxEqRel(1.0, length(normalize(u)), 1e-6);
}

pub inline fn reflect(v: Vec3, n: Vec3) Vec3 {
    return v - vec3s(2.0 * dot(v, n)) * n;
}

pub fn refract(vn: Vec3, n: Vec3, index: Real) Vec3 {
    const cos_theta = @min(dot(-vn, n), 1.0);
    const r_out_perp = vec3s(index) * (vn + vec3s(cos_theta) * n);
    const r_out_parallel = vec3s(-@sqrt(@abs(1.0 - dot(r_out_perp, r_out_perp)))) * n;
    return r_out_perp + r_out_parallel;
}

pub inline fn isVec3NearZero(v: Vec3) bool {
    return isNearZero(v[0]) and isNearZero(v[1]) and isNearZero(v[2]); 
}

pub inline fn isNearZero(x: Real) bool {
    const tol = 1e-8;
    return @abs(x) < tol;
}
test "isVec3NearZero" {
    const v0 = vec3(0, 0, 0);
    try std.testing.expect(isVec3NearZero(v0));

    const v1 = vec3(0, 1, 0);
    try std.testing.expect(!isVec3NearZero(v1));
}

fn expectVecApproxEqRel(expected: anytype, actual: anytype, tol: anytype) !void {
    const V = @TypeOf(expected, actual);
    const size = switch(V) {
        Vec3 => 3,
        Vec2 => 2,
        else => return error.UnknownVectorType,
    };
    for (0..size) |i| {
        try std.testing.expectApproxEqRel(expected[i], actual[i], tol);
    }
}

fn expectVecEqual(expected: anytype, actual: anytype) !void {
    const V = @TypeOf(expected, actual);
    const size = switch(V) {
        Vec3 => 3,
        Vec2 => 2,
        else => return error.UnknownVectorType,
    };
    for (0..size) |i| {
        try std.testing.expectEqual(expected[i], actual[i]);
    }
}
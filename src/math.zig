const std = @import("std");
 
const ztracy = @import("ztracy");

const Ray = @import("ray.zig").Ray;

fn suggestVectorSize(comptime T: type, min: usize) usize {
    const min2 = try std.math.ceilPowerOfTwo(usize, min);
    const suggested = std.simd.suggestVectorLength(T) orelse min2;
    return @max(min2, suggested);
}
fn Vec(comptime T: type, size: comptime_int) type {
    return @Vector(suggestVectorSize(T, size), T);
}

pub const Real = f64;
pub const Vec3 = Vec(Real, 3);
    //@Vector(3, Real);
pub const Vec2 = Vec(Real, 2);
    //@Vector(2, Real);
pub const Vecx = Vec(Real, 4);

pub const Axis = enum(u2) { x, y, z };

pub inline fn vec3s(x: Real) Vec3 {
    return @splat(x);
}
test "vec3s" {
    try expectVecEqual(vec3(1, 1, 1), vec3s(1));
}

pub inline fn vec3(x: Real, y: Real, z: Real) Vec3 {
    var v: Vec3 = undefined;
    v[0] = x;
    v[1] = y;
    v[2] = z;
    return v;
}

pub inline fn vec2(x: Real, y: Real) Vec2 {
    var v: Vec2 = undefined;
    v[0] = x;
    v[1] = y;
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

fn vecLen(comptime V: type) comptime_int {
    return switch (@typeInfo(V)) {
        .Vector => |info| info.len, 
        .Array => |info| info.len,
        inline else => @compileError("Invalid vector type " ++ @typeName(V)),
    };
}

fn createMask(comptime V: type) @Vector(vecLen(V), i32) {
    const len = vecLen(V);
    const M = @Vector(len, i32);
    return comptime blk: {
        var mask: M = undefined;
        for (0..len) |i| mask[i] = i;
        break :blk mask;
    };
}
test "createMask" {
    const vec_types = [_]type{ Vec3, Vec2 };
    inline for (vec_types) |V| { // vec3
        const mask = createMask(V);
        for (0..vecLen(V)) |i| {
            try std.testing.expectEqual(@as(i32, @intCast(i)), mask[i]);
        }
    }
}

pub inline fn swizzle(
    v: Vec3,
    comptime x: Axis,
    comptime y: Axis,
    comptime z: Axis,
) Vec3 {
    const mask = comptime blk: {
        var m = createMask(Vec3);
        m[0] = @intFromEnum(x);
        m[1] = @intFromEnum(y);
        m[2] = @intFromEnum(z);
        break :blk m;
    };
    // var mask: [vecLen(Vec3)]i32 = undefined;
    // const mask = std.mem.zeroes(@Vector(vecLen(Vec3), i32));
    return @shuffle(Real, v, undefined, mask);
}
test "swizzle" {
    const v = vec3(1, 2, 3);
    try expectVecEqual(v, swizzle(v, .x, .y, .z));
    try expectVecEqual(vec3(3, 2, 1), swizzle(v, .z, .y, .x));
    try expectVecEqual(vec3(1, 1, 1), swizzle(v, .x, .x, .x));
}

pub inline fn cross(u: Vec3, v: Vec3) Vec3 {
    return vec3(
        u[1]*v[2] - u[2]*v[1],
        u[2]*v[0] - u[0]*v[2],
        u[0]*v[1] - u[1]*v[0],
    );
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
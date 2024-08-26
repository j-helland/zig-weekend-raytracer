const std = @import("std");

pub const Vec3 = @Vector(3, f32);


pub inline fn vec3s(x: f32) Vec3 {
    return @splat(x);
}

const Vec3Component = enum(i32) { x, y, z };

pub inline fn swizzle(
    v: Vec3, 
    comptime x: Vec3Component, 
    comptime y: Vec3Component,
    comptime z: Vec3Component
) Vec3 {
    return @shuffle(f32, v, undefined, [3]i32{ @intFromEnum(x), @intFromEnum(y), @intFromEnum(z) });
}

test "swizzle" {
    const v = Vec3{ 1, 2, 3 };

    const v1 = swizzle(v, .x, .y, .z);
    try std.testing.expectEqual(v, v1);

    const v2 = swizzle(v, .z, .y, .x);
    try std.testing.expectEqual(Vec3{3, 2, 1}, v2);
}

pub inline fn dot(u: Vec3, v: Vec3) f32 {
    const xmm = u * v;
    return xmm[0] + xmm[1] + xmm[2];
}

test "dot" {
    const u = Vec3{1, 1, 1};
    const v = Vec3{2, 2, 2};
    const d = dot(u, v);
    try std.testing.expectApproxEqRel(6.0, d, 1e-8);
}

pub inline fn length(u: Vec3) f32 {
    return @sqrt(dot(u, u));
} 

test "length" {
    const u = Vec3{1, 1, 1};
    try std.testing.expectApproxEqRel(@sqrt(3.0), length(u), 1e-8);
}

pub inline fn normalize(u: Vec3) Vec3 {
    return u / @as(Vec3, @splat(length(u)));
}

test "normalize" {
    const u = Vec3{1, 2, 3};
    try std.testing.expectApproxEqRel(1.0, length(normalize(u)), 1e-6);
}
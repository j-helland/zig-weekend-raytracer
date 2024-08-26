const std = @import("std");

pub const Vec3 = @Vector(3, f32);


pub inline fn vec3s(x: f32) Vec3 {
    return @splat(x);
}

const Vec3Component = enum(i32) { x, y, z };

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
    return u / vec3s(length(u));
}

test "normalize" {
    const u = Vec3{1, 2, 3};
    try std.testing.expectApproxEqRel(1.0, length(normalize(u)), 1e-6);
}
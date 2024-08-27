const std = @import("std");

pub const Real = f64;
pub const Vec3 = @Vector(3, Real);

pub const INTERVAL_EMPTY = Interval(Real){ .min = std.math.inf(Real), .max = -std.math.inf(Real) };
pub const INTERVAL_UNIVERSE = Interval(Real){ .min = -std.math.inf(Real), .max = std.math.inf(Real) };
pub const GAMMA = 2.2;
pub const INV_GAMMA = 1.0 / GAMMA;

pub fn Interval(comptime T: type) type {
    return struct {
        const Self = @This();

        min: T,
        max: T,

        pub inline fn size(self: *const Self) T {
            return self.max - self.min;
        }

        /// Containment including boundary.
        pub inline fn contains(self: *const Self, t: T) bool {
            return (self.min <= t) and (t <= self.max);
        }

        /// Containment excluding boundary.
        pub inline fn surrounds(self: *const Self, t: T) bool {
            return (self.min < t) and (t < self.max);
        }

        pub inline fn clamp(self: *const Self, t: T) T {
            return std.math.clamp(t, self.min, self.max);
        }
    };
}

pub inline fn gammaCorrection(v: Vec3) Vec3 {
    return Vec3{
        gammaCorrectionReal(v[0]),
        gammaCorrectionReal(v[1]),
        gammaCorrectionReal(v[2]),
    };
}

pub inline fn gammaCorrectionReal(x: Real) Real {
    return std.math.pow(Real, x, INV_GAMMA);
}

pub inline fn lerp(x: Vec3, y: Vec3, alpha: Real) Vec3 {
    return x + vec3s(alpha) * (y - x);
}

pub inline fn vec3s(x: Real) Vec3 {
    return @splat(x);
}

pub inline fn dot(u: Vec3, v: Vec3) Real {
    const xmm = u * v;
    return xmm[0] + xmm[1] + xmm[2];
}

test "dot" {
    const u = Vec3{1, 1, 1};
    const v = Vec3{2, 2, 2};
    const d = dot(u, v);
    try std.testing.expectApproxEqRel(6.0, d, 1e-8);
}

pub inline fn length(u: Vec3) Real {
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
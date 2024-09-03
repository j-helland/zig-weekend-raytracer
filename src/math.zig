const std = @import("std");
 
const ztracy = @import("ztracy");

const Ray = @import("ray.zig").Ray;

pub const Real = f64;
pub const Vec3 = @Vector(3, Real);
pub const Vec2 = @Vector(2, Real);

pub const INTERVAL_EMPTY = Interval(Real){ .min = std.math.inf(Real), .max = -std.math.inf(Real) };
pub const INTERVAL_UNIVERSE = Interval(Real){ .min = -std.math.inf(Real), .max = std.math.inf(Real) };
pub const GAMMA = 2.2;
pub const INV_GAMMA = 1.0 / GAMMA;

pub const Axis = enum(u2) { x, y, z };

pub fn Interval(comptime T: type) type {
    return struct {
        const Self = @This();

        min: T = 0,
        max: T = 0,

        pub fn unionWith(self: *const Self, other: Self) Self {
            return Self{
                .min = @min(self.min, other.min),
                .max = @max(self.max, other.max),
            };
        }

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

        pub inline fn expand(self: *const Self, delta: Real) Self {
            const padding = delta / 2;
            return Self{ .min = self.min - padding, .max = self.max + padding };
        }
    };
}

pub const AABB = struct {
    const Self = @This();

    x: Interval(Real) = .{},
    y: Interval(Real) = .{},
    z: Interval(Real) = .{},

    pub fn init(a: Vec3, b: Vec3) Self {
        var self = Self{
            .x = .{ .min = @min(a[0], b[0]), .max = @max(a[0], b[0]) },
            .y = .{ .min = @min(a[1], b[1]), .max = @max(a[1], b[1]) },
            .z = .{ .min = @min(a[2], b[2]), .max = @max(a[2], b[2]) },
        };
        // Avoid degenerate cases where AABB collapses to zero volume.
        self.padToMinimum();
        return self;
    }

    pub fn unionWith(self: *const Self, other: *const Self) Self {
        return Self{
            .x = self.x.unionWith(other.x),
            .y = self.y.unionWith(other.y),
            .z = self.z.unionWith(other.z),
        };
    }

    pub fn axisInterval(self: *const Self, axis: Axis) *const Interval(Real) {
        return switch (axis) {
            .x => &self.x,
            .y => &self.y,
            .z => &self.z,
        };
    }

    pub fn longestAxis(self: *const Self) Axis {
        const lx = self.x.size();
        const ly = self.y.size();
        const lz = self.z.size();
        if (lx > ly) {
            return if (lx > lz) .x else .z;
        }
        return if (ly > lz) .y else .z;
    }

    pub fn hit(self: *const Self, ray: *const Ray, ray_t: Interval(Real)) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "AABB::hit");
        defer tracy_zone.End();

        // Check intersection against AABB slabs. 
        inline for (comptime std.enums.values(Axis)) |axis| {
            const axis_idx = @as(u2, @intFromEnum(axis));
            const interval = self.axisInterval(axis);
            const axis_dir_inv = 1.0 / ray.direction[axis_idx];

            var t0: Real = (interval.min - ray.origin[axis_idx]) * axis_dir_inv;
            var t1: Real = (interval.max - ray.origin[axis_idx]) * axis_dir_inv;
            if (t0 > t1) std.mem.swap(Real, &t0, &t1);

            const tmin = @max(t0, ray_t.min);
            const tmax = @min(t1, ray_t.max);

            // No overlap in this axis necessarily means ray does not hit.
            if (tmax <= tmin) return false;
        }
        return true;
    }

    fn padToMinimum(self: *Self) void {
        const delta = 0.0001;
        if (self.x.size() < delta) self.x = self.x.expand(delta);
        if (self.y.size() < delta) self.y = self.y.expand(delta);
        if (self.z.size() < delta) self.z = self.z.expand(delta);
    }
};

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

pub inline fn swizzle(
    v: Vec3,
    comptime x: Axis,
    comptime y: Axis,
    comptime z: Axis,
) Vec3 {
    return @shuffle(Real, v, undefined, [3]i32{ @intFromEnum(x), @intFromEnum(y), @intFromEnum(z) });
}
test "swizzle" {
    const v = Vec3{1, 2, 3};
    try std.testing.expectEqual(v, swizzle(v, .x, .y, .z));
    try std.testing.expectEqual(Vec3{3, 2, 1}, swizzle(v, .z, .y, .x));
    try std.testing.expectEqual(Vec3{1, 1, 1}, swizzle(v, .x, .x, .x));
}

pub inline fn vec3s(x: Real) Vec3 {
    return @splat(x);
}
test "vec3s" {
    try std.testing.expectEqual(Vec3{1, 1, 1}, vec3s(1));
}

// pub inline fn cross(u: Vec3, v: Vec3) Vec3 {
//     var xmm0 = swizzle(u, .y, .z, .x);
//     var xmm1 = swizzle(v, .z, .x, .y);
//     var result = xmm0 * xmm1;
//     xmm0 = swizzle(xmm0, .y, .z, .x);
//     xmm1 = swizzle(xmm1, .z, .x, .y);
//     result -= xmm0 * xmm1;
//     return result;
// }
pub inline fn cross(u: Vec3, v: Vec3) Vec3 {
    return Vec3{
        u[1]*v[2] - u[2]*v[1],
        u[2]*v[0] - u[0]*v[2],
        u[0]*v[1] - u[1]*v[0],
    };
}
test "cross" {
    {
        const u = Vec3{1, 0, 0};
        const v = Vec3{0, 1, 0};
        try expectApproxEqualVec3(Vec3{0, 0, 1}, cross(u, v), 1e-6);
    }
    {
        const u = Vec3{1, 0, 0};
        const v = Vec3{0, -1, 0};
        try expectApproxEqualVec3(Vec3{0, 0, -1}, cross(u, v), 1e-6);
    }
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
    return u * vec3s(1.0 / length(u));
}
test "normalize" {
    const u = Vec3{1, 2, 3};
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
    const v0 = Vec3{0, 0, 0};
    try std.testing.expect(isVec3NearZero(v0));

    const v1 = Vec3{0, 1, 0};
    try std.testing.expect(!isVec3NearZero(v1));
}

fn expectApproxEqualVec3(expected: Vec3, actual: Vec3, tol: Real) !void {
    try std.testing.expectApproxEqRel(expected[0], actual[0], tol);
    try std.testing.expectApproxEqRel(expected[1], actual[1], tol);
    try std.testing.expectApproxEqRel(expected[2], actual[2], tol);
}
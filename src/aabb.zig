const std = @import("std");

const ztracy = @import("ztracy");

const Real = @import("math.zig").Real;
const Vec3 = @import("math.zig").Vec3;
const Axis = @import("math.zig").Axis;
const Ray = @import("ray.zig").Ray;
const Interval = @import("interval.zig").Interval;

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

    pub fn offset(self: *const Self, displacement: Vec3) Self {
        return Self{
            .x = self.x.offset(displacement[0]),
            .y = self.y.offset(displacement[1]),
            .z = self.z.offset(displacement[2]),
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
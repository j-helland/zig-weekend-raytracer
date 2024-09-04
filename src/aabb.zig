const std = @import("std");

const ztracy = @import("ztracy");

const math = @import("math.zig");
const Real = @import("math.zig").Real;
const Vec3 = @import("math.zig").Vec3;
const Axis = @import("math.zig").Axis;
const vec3 = @import("math.zig").vec3;
const vec3s = @import("math.zig").vec3s;

const Ray = @import("ray.zig").Ray;
const Interval = @import("interval.zig").Interval;

pub const AABB = struct {
    const Self = @This();

    x: Interval(Real) = .{},
    y: Interval(Real) = .{},
    z: Interval(Real) = .{},

    // cache the min/max bounds
    min: Vec3 = undefined,
    max: Vec3 = undefined,

    pub fn init(a: Vec3, b: Vec3) Self {
        const min = @min(a, b);
        const max = @max(a, b);
        var self = Self{
            .x = .{ .min = Axis.x.select(min), .max = Axis.x.select(max) },
            .y = .{ .min = Axis.y.select(min), .max = Axis.y.select(max) },
            .z = .{ .min = Axis.z.select(min), .max = Axis.z.select(max) },
            .min = min,
            .max = max,
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
            .min = @min(self.min, other.min),
            .max = @max(self.max, other.max),
        };
    }

    pub fn offset(self: *const Self, displacement: Vec3) Self {
        return Self{
            .x = self.x.offset(Axis.x.select(displacement)),
            .y = self.y.offset(Axis.y.select(displacement)),
            .z = self.z.offset(Axis.z.select(displacement)),
            .min = self.min - vec3s(displacement),
            .max = self.max + vec3s(displacement),
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

        const t0 = (self.min - ray.origin) / ray.direction;
        const t1 = (self.max - ray.origin) / ray.direction;

        var tmin = @max(@min(t0, t1), vec3s(ray_t.min));
        var tmax = @min(@max(t0, t1), vec3s(ray_t.max));

        // Make sure superfluous @Vector components will eval to "true" in @reduce expression.
        math.rightPad(Vec3, &tmin, 0);
        math.rightPad(Vec3, &tmax, 1);

        return @reduce(.And, tmax > tmin);
    }

    fn padToMinimum(self: *Self) void {
        const delta = 0.0001;
        var min_max_offset = vec3s(0);

        if (self.x.size() < delta) {
            self.x = self.x.expand(delta);
            min_max_offset[@intFromEnum(Axis.x)] = delta;
        }
        if (self.y.size() < delta) {
            self.y = self.y.expand(delta);
            min_max_offset[@intFromEnum(Axis.y)] = delta;
        }
        if (self.z.size() < delta) {
            self.z = self.z.expand(delta);
            min_max_offset[@intFromEnum(Axis.z)] = delta;
        }

        self.min -= min_max_offset;
        self.max += min_max_offset;
    }
};
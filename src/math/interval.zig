const std = @import("std");

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

        pub fn offset(self: *const Self, displacement: T) Self {
            return Self{ .min = self.min + displacement, .max = self.max + displacement };
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

        pub inline fn expand(self: *const Self, delta: T) Self {
            const padding = delta / 2;
            return Self{ .min = self.min - padding, .max = self.max + padding };
        }
    };
}
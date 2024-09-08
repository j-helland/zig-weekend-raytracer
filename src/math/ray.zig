const Vec3 = @import("math.zig").Vec3;
const Real = @import("math.zig").Real;
const vec3s = @import("math.zig").vec3s;

pub const Ray = struct {
    const Self = @This();

    origin: Vec3,
    direction: Vec3,
    time: Real = 0.0,

    pub fn at(self: *const Self, t: Real) Vec3 {
        return self.origin + vec3s(t) * self.direction;
    }
};
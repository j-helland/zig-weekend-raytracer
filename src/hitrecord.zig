const std = @import("std");

const math = @import("math/math.zig");
const mat = @import("material.zig");

pub const HitRecord = struct {
    const Self = @This();

    point: math.Point3 = math.vec3(0, 0, 0),
    normal: math.Vec3 = math.vec3(0, 0, 0),
    material: ?*const mat.IMaterial = null,
    t: math.Real = std.math.inf(math.Real),
    tex_uv: math.Vec2 = math.vec2(0, 0),
    b_front_face: bool = false,

    pub fn setFrontFaceNormal(self: *Self, ray: *const math.Ray, outward_normal: math.Vec3) void {
        self.b_front_face = (math.dot(ray.direction, outward_normal) < 0.0);
        self.normal = 
            if (self.b_front_face) outward_normal 
            else -outward_normal;
    } 
};

pub const HitContext = struct {
    ray: *const math.Ray,
    trange: math.Interval(math.Real),
};
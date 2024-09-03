const std = @import("std");

const math = @import("math.zig");
const Real = math.Real;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;
const Point3 = math.Vec3;
const Color = math.Vec3;
const Interval = math.Interval;

const mat = @import("material.zig");

pub const ScatterContext = struct {
    /// Keep all mutable fields here for clarity.
    mut: struct {
        attenuation: *Color, 
        ray_scattered: *Ray,
    },

    random: std.Random,
    ray_incoming: *const Ray, 
    hit_record: *const HitRecord,     
};

pub const HitRecord = struct {
    const Self = @This();

    point: Point3 = .{0, 0, 0},
    normal: Vec3 = .{0, 0, 0},
    material: ?*const mat.IMaterial = null,
    t: Real = std.math.inf(Real),
    tex_uv: Vec2 = .{0, 0},
    b_front_face: bool = false,

    pub fn setFrontFaceNormal(self: *Self, ray: *const Ray, outward_normal: Vec3) void {
        self.b_front_face = (math.dot(ray.direction, outward_normal) < 0.0);
        self.normal = 
            if (self.b_front_face) outward_normal 
            else -outward_normal;
    } 
};

pub const HitContext = struct {
    ray: *const Ray,
    trange: Interval(Real),
};

pub const Ray = struct {
    const Self = @This();

    origin: Vec3,
    direction: Vec3,
    time: Real = 0.0,

    pub fn at(self: *const Self, t: Real) Vec3 {
        return self.origin + math.vec3s(t) * self.direction;
    }
};
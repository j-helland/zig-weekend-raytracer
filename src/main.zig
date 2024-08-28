const std = @import("std");
const AllocatorError = std.mem.Allocator.Error;

const math = @import("math.zig");
const Real = math.Real;
const Vec3 = math.Vec3;
const Point3 = Vec3;
const Color = Vec3;
const vec3s = math.vec3s;
const Interval = math.Interval;

const ent = @import("entity.zig");
const Entity = ent.Entity;
const EntityCollection = ent.EntityCollection;
const SphereEntity = ent.SphereEntity;
const Ray = ent.Ray;
const HitContext = ent.HitContext;
const HitRecord = ent.HitRecord;
const Material = ent.Material;
const MetalMaterial = ent.MetalMaterial;
const LambertianMaterial = ent.LambertianMaterial;

const cam = @import("camera.zig");
const Camera = cam.Camera;

pub fn main() !void {    
    // ---- allocator ----
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ---- thread pool ----
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    // camera
    const img_width = 800;
    const img_height = 400;
    const focal_length = 1.0;
    const camera = Camera.init(&pool, img_width, img_height, focal_length);
    const stdout = std.io.getStdOut().writer();

    // ---- materials ----
    const mat_ground = Material{ .lambertian = LambertianMaterial{ .albedo = Color{0.8, 0.8, 0.0} } };
    const mat_sphere_diffuse = Material{ .lambertian = LambertianMaterial{ .albedo = Color{0.1, 0.2, 0.5} } };
    const mat_metal_left = Material{ .metal = MetalMaterial{ .albedo = Color{0.8, 0.8, 0.8} } };
    const mat_metal_right = Material{ .metal = MetalMaterial{ .albedo = Color{0.8, 0.6, 0.2} } };

    // ---- scene initialization ----
    var scene = EntityCollection.init(allocator);
    defer scene.deinit();
    try scene.add(Entity{ .sphere = SphereEntity{ .center = Point3{0, 0, -1.2}, .radius = 0.5, .material = &mat_sphere_diffuse } });
    try scene.add(Entity{ .sphere = SphereEntity{ .center = Point3{0, -100.5, -1}, .radius = 100.0, .material = &mat_ground } });
    try scene.add(Entity{ .sphere = SphereEntity{ .center = Point3{-1, 0, -1}, .radius = 0.5, .material = &mat_metal_left } });
    try scene.add(Entity{ .sphere = SphereEntity{ .center = Point3{1, 0, -1}, .radius = 0.5, .material = &mat_metal_right } });
    const world = Entity{ .collection = scene };

    // ---- render ----
    var framebuffer = try cam.Framebuffer.init(allocator, img_height, img_width);
    defer framebuffer.deinit();

    std.log.debug("Rendering image...", .{});
    try camera.render(&world, &framebuffer);

    // ---- write ----
    // TODO: create separate encoder struct
    std.log.debug("Writing image...", .{});
    try framebuffer.write(allocator, &stdout);

    std.log.info("DONE", .{});
}

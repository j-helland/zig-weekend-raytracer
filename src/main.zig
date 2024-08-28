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
const DielectricMaterial = ent.DielectricMaterial;

const rng = @import("rng.zig");

const cam = @import("camera.zig");
const Camera = cam.Camera;

const WriterPPM = @import("writer.zig").WriterPPM;

const Timer = @import("timer.zig").Timer;

/// Global log level configuration.
/// Will produce logs at this level in release mode.
pub const log_level: std.log.Level = .info;

pub fn main() !void {
    // ---- allocator ----
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ---- thread pool ----
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = 32 });
    defer pool.deinit();

    var timer = Timer.init();

    // ---- materials ----
    var scene = EntityCollection.init(allocator);
    defer scene.deinit();
    try scene.entities.ensureTotalCapacity(22*22 + 3);

    var materials = std.ArrayList(Material).init(allocator);
    defer materials.deinit();
    try materials.ensureTotalCapacity(22*22);

    const material_ground = LambertianMaterial.initMaterial(Color{0.5, 0.5, 0.5});
    try scene.add(SphereEntity.initEntity(Point3{0, -1000, 0}, 1000, &material_ground));

    const rand = rng.getThreadRng();
    var a: Real = -11.0;
    while (a < 11.0) : (a += 1.0) {
        var b: Real = -11.0;
        while (b < 11.0) : (b += 1.0) {
            const choose_mat = rand.float(Real); 
            const center = Point3{ a + 0.9*rand.float(Real), 0.2, b + 0.9*rand.float(Real) };

            if (math.length(center - Point3{4, 0.2, 0}) > 0.9) {
                if (choose_mat < 0.8) {
                    // diffuse
                    const albedo = rng.sampleVec3(rand);
                    try materials.append(LambertianMaterial.initMaterial(albedo));
                    try scene.add(SphereEntity.initEntity(center, 0.2, &materials.items[materials.items.len - 1]));
                } else if (choose_mat < 0.95) {
                    // metal
                    const albedo = rng.sampleVec3Interval(rand, .{ .min = 0.5, .max = 1.0 });
                    const fuzz = rand.float(Real) * 0.8;
                    try materials.append(MetalMaterial.initMaterial(albedo, fuzz));
                    try scene.add(SphereEntity.initEntity(center, 0.2, &materials.items[materials.items.len - 1]));
                } else {
                    // glass
                    try materials.append(DielectricMaterial.initMaterial(1.5));
                    try scene.add(SphereEntity.initEntity(center, 0.2, &materials.items[materials.items.len - 1]));
                }
            }
        }
    }

    const material1 = DielectricMaterial.initMaterial(1.5);
    try scene.add(SphereEntity.initEntity(Point3{0, 1, 0}, 1.0, &material1));

    const material2 = LambertianMaterial.initMaterial(Color{0.4, 0.2, 0.1});
    try scene.add(SphereEntity.initEntity(Point3{-4, 1, 0}, 1, &material2));

    const material3 = MetalMaterial.initMaterial(Color{0.7, 0.6, 0.5}, 0.0);
    try scene.add(SphereEntity.initEntity(Point3{4, 1, 0}, 1, &material3));

    timer.logInfoElapsed("scene setup");

    // camera
    const img_width = 1200;
    const aspect = 16.0 / 9.0;
    const fov_vertical = 20.0;
    const look_from = Point3{13, 2, 3};
    const look_at = Point3{0, 0, 0};
    const view_up = Vec3{ 0, 1, 0 };
    const focus_dist = 10.0;
    const defocus_angle = 0.6;
    var camera = Camera.init(
        &pool,
        aspect,
        img_width,
        fov_vertical,
        look_from,
        look_at,
        view_up,
        focus_dist,
        defocus_angle,
    );
    camera.samples_per_pixel = 10;
    camera.max_ray_bounce_depth = 20;

    // ---- render ----
    var framebuffer = try cam.Framebuffer.init(allocator, camera.image_height, img_width);
    defer framebuffer.deinit();

    timer.logInfoElapsed("renderer initialized");

    std.log.debug("Rendering image...", .{});
    const world = Entity{ .collection = scene };
    try camera.render(&world, &framebuffer);

    timer.logInfoElapsed("scene rendered");

    // ---- write ----
    std.log.debug("Writing image...", .{});
    const path = "hello.ppm";
    var writer = WriterPPM{
        .allocator = allocator,
        .thread_pool = &pool,
    };
    try writer.write(path, framebuffer.buffer, framebuffer.num_cols, framebuffer.num_rows);

    timer.logInfoElapsed("scene written to file");
}

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

const cam = @import("camera.zig");
const Camera = cam.Camera;

fn rayColor(ray: *const Ray, entity: *const Entity) Vec3 {
    const ctx = HitContext{ 
        .ray = ray, 
        .trange = Interval(Real){ .min = 0.0, .max = std.math.inf(Real) },
    };
    var record = HitRecord{};
    if (entity.hit(ctx, &record)) {
        return vec3s(0.5) * (record.normal + vec3s(1.0));
    }

    const d = math.normalize(ray.direction);
    const a = 0.5 * (d[1] + 1.0);
    return math.lerp(Color{1, 1, 1}, Color{0.5, 0.7, 1.0}, a);
}

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

    // ---- scene initialization ----
    var scene = EntityCollection.init(allocator);
    defer scene.deinit();
    try scene.add(Entity{ .sphere = SphereEntity{ .center = Point3{0, 0, -1}, .radius = 0.5 } });
    try scene.add(Entity{ .sphere = SphereEntity{ .center = Point3{0, -100.5, -1}, .radius = 100.0 } });
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

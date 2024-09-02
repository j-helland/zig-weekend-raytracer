const std = @import("std");
const AllocatorError = std.mem.Allocator.Error;

const ztracy = @import("ztracy");
const zstbi = @import("zstbi");

const math = @import("math.zig");
const Real = math.Real;
const Vec3 = math.Vec3;
const Point3 = Vec3;
const Color = Vec3;
const vec3s = math.vec3s;
const Interval = math.Interval;
const Ray = math.Ray;

const ent = @import("entity.zig");
const Entity = ent.Entity;
const EntityCollection = ent.EntityCollection;
const SphereEntity = ent.SphereEntity;
const HitContext = ent.HitContext;
const HitRecord = ent.HitRecord;
const Material = ent.Material;
const MetalMaterial = ent.MetalMaterial;
const LambertianMaterial = ent.LambertianMaterial;
const DielectricMaterial = ent.DielectricMaterial;

const img = @import("image.zig");
const tex = @import("texture.zig");
const rng = @import("rng.zig");
const cam = @import("camera.zig");
const Camera = cam.Camera;
const WriterPPM = @import("writer.zig").WriterPPM;
const Timer = @import("timer.zig").Timer;

const ArgParser = @import("argparser.zig").ArgParser;

/// Global log level configuration.
/// Will produce logs at this level in release mode.
pub const log_level: std.log.Level = .info;

const UserArgs = struct {
    image_width: usize = 800,
    image_out_path: []const u8 = "image.ppm",
    samples_per_pixel: usize = 10,
    ray_bounce_max_depth: usize = 20,
};

fn bigBountifulBodaciousBeautifulBouncingBalls(allocator: std.mem.Allocator, thread_pool: *std.Thread.Pool, timer: *Timer, args: *const UserArgs) !void {
    // ---- textures ----
    const texture_solid_brown = tex.SolidColorTexture.initTexture(Color{0.4, 0.2, 0.1});
    const texture_even = tex.SolidColorTexture.initTexture(Color{0.2, 0.3, 0.1});
    const texture_odd = tex.SolidColorTexture.initTexture(Color{0.9, 0.9, 0.9});
    const texture_ground = tex.CheckerboardTexture.initTexture(0.32, &texture_even, &texture_odd);

    // ---- materials ----
    // Use scene.deinit() to manage lifetime of all entities. We'll keep these in a contiguous memory block. 
    // Any acceleration structures will be built on top of this block and managed separately.
    var scene = EntityCollection.init(allocator);
    defer scene.deinit();
    try scene.entities.ensureTotalCapacity(22*22 + 4);

    var textures = std.ArrayList(tex.Texture).init(allocator);
    defer textures.deinit();
    try textures.ensureTotalCapacity(22*22);

    var materials = std.ArrayList(Material).init(allocator);
    defer materials.deinit();
    try materials.ensureTotalCapacity(22*22);

    const material_ground = LambertianMaterial.initMaterial(&texture_ground);
    scene.addAssumeCapacity(SphereEntity.initEntity(Point3{0, -1000, 0}, 1000, &material_ground));

    if (@import("builtin").mode != .Debug) {
        // This many entities is way too slow in debug builds. 
        // Also generates way too much profiling data.
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
                        textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(albedo));
                        materials.appendAssumeCapacity(LambertianMaterial.initMaterial(&textures.items[textures.items.len - 1]));

                        // Non-motion blurred entities.
                        // try scene.add(SphereEntity.initEntity(center, 0.2, &materials.items[materials.items.len - 1]));
                        
                        // Motion blurred entities.
                        scene.addAssumeCapacity(SphereEntity.initEntityAnimated(
                            center, 
                            center + Point3{0, rand.float(Real)*0.5, 0}, 
                            0.2, 
                            &materials.items[materials.items.len - 1],
                        ));

                    } else if (choose_mat < 0.95) {
                        // metal
                        const albedo = rng.sampleVec3Interval(rand, .{ .min = 0.5, .max = 1.0 });
                        const fuzz = rand.float(Real) * 0.8;
                        materials.appendAssumeCapacity(MetalMaterial.initMaterial(albedo, fuzz));
                        scene.addAssumeCapacity(SphereEntity.initEntity(center, 0.2, &materials.items[materials.items.len - 1]));

                    } else {
                        // glass
                        materials.appendAssumeCapacity(DielectricMaterial.initMaterial(1.5));
                        scene.addAssumeCapacity(SphereEntity.initEntity(center, 0.2, &materials.items[materials.items.len - 1]));
                    }
                }
            }
        }
    }

    const material1 = DielectricMaterial.initMaterial(1.5);
    scene.addAssumeCapacity(SphereEntity.initEntity(Point3{0, 1, 0}, 1.0, &material1));

    const material2 = LambertianMaterial.initMaterial(&texture_solid_brown);
    scene.addAssumeCapacity(SphereEntity.initEntity(Point3{-4, 1, 0}, 1, &material2));

    const material3 = MetalMaterial.initMaterial(Color{0.7, 0.6, 0.5}, 0.0);
    scene.addAssumeCapacity(SphereEntity.initEntity(Point3{4, 1, 0}, 1, &material3));

    var entity_refs = try std.ArrayList(*Entity).initCapacity(allocator, scene.entities.items.len);
    defer entity_refs.deinit();
    for (scene.entities.items) |*e| entity_refs.appendAssumeCapacity(e);

    // Use the following for BVH-tree (accelerated) rendering.
    var mem_pool = std.heap.MemoryPool(Entity).init(std.heap.page_allocator);
    defer mem_pool.deinit();
    var world = try ent.BVHNodeEntity.initEntity(&mem_pool, entity_refs.items, 0, scene.entities.items.len);
    
    // // Use the following for non-BVH tree (slow) rendering
    // var world = Entity{ .collection = scene };

    timer.logInfoElapsed("scene setup");

    // camera
    const aspect = 16.0 / 9.0;
    const fov_vertical = 20.0;
    const look_from = Point3{13, 2, 3};
    const look_at = Point3{0, 0, 0};
    const view_up = Vec3{ 0, 1, 0 };
    const focus_dist = 10.0;
    const defocus_angle = 0.6;
    var camera = Camera.init(
        thread_pool,
        aspect,
        args.image_width,
        fov_vertical,
        look_from,
        look_at,
        view_up,
        focus_dist,
        defocus_angle,
    );
    camera.samples_per_pixel = args.samples_per_pixel;
    camera.max_ray_bounce_depth = args.ray_bounce_max_depth;

    // ---- render ----
    var framebuffer = try cam.Framebuffer.init(allocator, camera.image_height, args.image_width);
    defer framebuffer.deinit();
    timer.logInfoElapsed("renderer initialized");

    try camera.render(&world, &framebuffer);
    timer.logInfoElapsed("scene rendered");

    // ---- write ----
    std.log.debug("Writing image...", .{});
    var writer = WriterPPM{
        .allocator = allocator,
        .thread_pool = thread_pool,
    };
    try writer.write(args.image_out_path, framebuffer.buffer, framebuffer.num_cols, framebuffer.num_rows);
    timer.logInfoElapsed("scene written to file");
}

fn checkeredSpheres(allocator: std.mem.Allocator, thread_pool: *std.Thread.Pool, timer: *Timer, args: *const UserArgs) !void {
    // ---- textures ----
    const texture_even = tex.SolidColorTexture.initTexture(Color{0.2, 0.3, 0.1});
    const texture_odd = tex.SolidColorTexture.initTexture(Color{0.9, 0.9, 0.9});
    const texture_checker = tex.CheckerboardTexture.initTexture(2.32, &texture_even, &texture_odd);

    // ---- materials ----
    const material = LambertianMaterial.initMaterial(&texture_checker);

    // ---- entities ----
    var scene = EntityCollection.init(allocator);
    defer scene.deinit();

    try scene.add(SphereEntity.initEntity(Point3{0, -10, 0}, 10, &material));
    try scene.add(SphereEntity.initEntity(Point3{0, 10, 0}, 10, &material));

    const world = Entity{ .collection = scene };

    // ---- camera ----
    const aspect = 16.0 / 9.0;
    const fov_vertical = 20.0;
    const look_from = Point3{13, 2, 3};
    const look_at = Point3{0, 0, 0};
    const view_up = Vec3{ 0, 1, 0 };
    const focus_dist = 10.0;
    const defocus_angle = 0.0;
    var camera = Camera.init(
        thread_pool,
        aspect,
        args.image_width,
        fov_vertical,
        look_from,
        look_at,
        view_up,
        focus_dist,
        defocus_angle,
    );
    camera.samples_per_pixel = args.samples_per_pixel;
    camera.max_ray_bounce_depth = args.ray_bounce_max_depth; 

    // ---- render ----
    var framebuffer = try cam.Framebuffer.init(allocator, camera.image_height, args.image_width);
    defer framebuffer.deinit();
    timer.logInfoElapsed("renderer initialized");

    try camera.render(&world, &framebuffer);
    timer.logInfoElapsed("scene rendered");

    // ---- write ----
    std.log.debug("Writing image...", .{});
    var writer = WriterPPM{
        .allocator = allocator,
        .thread_pool = thread_pool,
    };
    try writer.write(args.image_out_path, framebuffer.buffer, framebuffer.num_cols, framebuffer.num_rows);
    timer.logInfoElapsed("scene written to file");
}

fn earth(allocator: std.mem.Allocator, thread_pool: *std.Thread.Pool, timer: *Timer, args: *const UserArgs) !void {
    // ---- textures ----
    const earth_image_path: [:0]const u8 = @import("build_options").asset_dir ++ "earth.png";
    // const earth_image_path: [:0]const u8 = @import("build_options").asset_dir ++ "me.jpg";
    // const earth_image_path: [:0]const u8 = @import("build_options").asset_dir ++ "wap.jpg";
    var earth_image = try img.Image.initFromFile(earth_image_path);
    defer earth_image.deinit();
    std.log.debug("w:{d}, h:{d}", .{earth_image.image.?.width, earth_image.image.?.height});

    const texture_earth = tex.ImageTexture.initTexture(&earth_image);

    // ---- materials ----
    const material = LambertianMaterial.initMaterial(&texture_earth);

    // ---- entities ----
    var scene = EntityCollection.init(allocator);
    defer scene.deinit();

    try scene.add(SphereEntity.initEntity(Point3{0, 0, 0}, 1.5, &material));

    const world = Entity{ .collection = scene };

    // ---- camera ----
    const aspect = 16.0 / 9.0;
    const fov_vertical = 20.0;
    const look_from = Point3{0, 0, 12};
    const look_at = Point3{0, 0, 0};
    const view_up = Vec3{ 0, 1, 0 };
    const focus_dist = 10.0;
    const defocus_angle = 0.0;
    var camera = Camera.init(
        thread_pool,
        aspect,
        args.image_width,
        fov_vertical,
        look_from,
        look_at,
        view_up,
        focus_dist,
        defocus_angle,
    );
    camera.samples_per_pixel = args.samples_per_pixel;
    camera.max_ray_bounce_depth = args.ray_bounce_max_depth; 

    // ---- render ----
    var framebuffer = try cam.Framebuffer.init(allocator, camera.image_height, args.image_width);
    defer framebuffer.deinit();
    timer.logInfoElapsed("renderer initialized");

    try camera.render(&world, &framebuffer);
    timer.logInfoElapsed("scene rendered");

    // ---- write ----
    std.log.debug("Writing image...", .{});
    var writer = WriterPPM{
        .allocator = allocator,
        .thread_pool = thread_pool,
    };
    try writer.write(args.image_out_path, framebuffer.buffer, framebuffer.num_cols, framebuffer.num_rows);
    timer.logInfoElapsed("scene written to file");
}

pub fn main() !void {
    // ---- allocator ----
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // parse args
    var parser = try ArgParser(UserArgs).init(allocator);
    defer parser.deinit();
    const args = parser.parse() catch {
        try parser.printUsage(std.io.getStdOut().writer());
        return error.CouldNotParseUserArgs;
    };

    // ---- thread pool ----
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator, .n_jobs = 16 });
    defer thread_pool.deinit();

    var timer = Timer.init();


    // ---- ext lib init ----
    zstbi.init(allocator);
    defer zstbi.deinit();

    // Scene
    // try bigBountifulBodaciousBeautifulBouncingBalls(allocator, &thread_pool, &timer, args);
    // try checkeredSpheres(allocator, &thread_pool, &timer, args);
    try earth(allocator, &thread_pool, &timer, args);
}

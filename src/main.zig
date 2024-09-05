const std = @import("std");
const AllocatorError = std.mem.Allocator.Error;

const ztracy = @import("ztracy");
const zstbi = @import("zstbi");

const math = @import("math.zig");
const Real = math.Real;
const Vec3 = math.Vec3;
const Point3 = math.Vec3;
const Color = math.Vec3;
const Interval = math.Interval;
const vec3 = math.vec3;
const vec3s = math.vec3s;

const IMaterial = @import("material.zig").IMaterial;
const MetalMaterial = @import("material.zig").MetalMaterial;
const LambertianMaterial = @import("material.zig").LambertianMaterial;
const DielectricMaterial = @import("material.zig").DielectricMaterial;
const DiffuseLightEmissiveMaterial = @import("material.zig").DiffuseLightEmissiveMaterial;

const tex = @import("texture.zig");
const ITexture = @import("texture.zig").ITexture;
const ImageTexture = @import("texture.zig").ImageTexture;
const SolidColorTexture = @import("texture.zig").SolidColorTexture;
const CheckerboardTexture = @import("texture.zig").CheckerboardTexture;

const ent = @import("entity.zig");
const IEntity = ent.IEntity;
const EntityCollection = ent.EntityCollection;
const SphereEntity = ent.SphereEntity;
const QuadEntity = ent.QuadEntity;
const RotateY = ent.RotateY;
const Translate = ent.Translate;

const img = @import("image.zig");
const rng = @import("rng.zig");
const Renderer = @import("render.zig").Renderer;
const Camera = @import("camera.zig").Camera;
const Framebuffer = @import("camera.zig").Framebuffer;
const WriterPPM = @import("writer.zig").WriterPPM;
const Timer = @import("timer.zig").Timer;

const ArgParser = @import("argparser.zig").ArgParser;

const UserArgs = struct {
    thread_pool_size: usize = 128,
    image_width: usize = 800,
    image_height: usize = 800,
    image_out_path: []const u8 = "image.ppm",
    samples_per_pixel: usize = 10,
    ray_bounce_max_depth: usize = 20,
};

const EntityPool = std.heap.MemoryPool(IEntity);

pub const SceneContext = struct {
    allocator: std.mem.Allocator,
    entity_pool: *EntityPool,
    timer: *Timer,
    args: *const UserArgs,
};

const sceneRenderFunc = *const fn(*const SceneContext, *Renderer, *Camera) anyerror!void;

fn bigBountifulBodaciousBeautifulBouncingBalls(ctx: SceneContext, renderer: *Renderer, framebuffer: *Framebuffer) !void {
    // ---- textures ----
    const texture_solid_brown = tex.SolidColorTexture.initTexture(vec3( 0.4, 0.2, 0.1 ));
    const texture_even = tex.SolidColorTexture.initTexture(vec3( 0.2, 0.3, 0.1 ));
    const texture_odd = tex.SolidColorTexture.initTexture(vec3( 0.9, 0.9, 0.9 ));
    const texture_ground = tex.CheckerboardTexture.initTexture(0.32, &texture_even, &texture_odd);

    // ---- materials ----
    var scene = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    defer scene.deinit();
    try scene.collection.entities.ensureTotalCapacity(22 * 22 + 4);

    var textures = std.ArrayList(ITexture).init(ctx.allocator);
    defer textures.deinit();
    try textures.ensureTotalCapacity(22 * 22);

    var materials = std.ArrayList(IMaterial).init(ctx.allocator);
    defer materials.deinit();
    try materials.ensureTotalCapacity(22 * 22);

    const material_ground = LambertianMaterial.initMaterial(&texture_ground);
    scene.collection.addAssumeCapacity(try SphereEntity.initEntity(ctx.entity_pool, vec3( 0, -1000, 0 ), 1000, &material_ground));

    if (@import("builtin").mode != .Debug) {
        // This many entities is way too slow in debug builds.
        // Also generates way too much profiling data.
        const rand = rng.getThreadRng();
        var a: Real = -11.0;
        while (a < 11.0) : (a += 1.0) {
            var b: Real = -11.0;
            while (b < 11.0) : (b += 1.0) {
                const choose_mat = rand.float(Real);
                const center = vec3( a + 0.9 * rand.float(Real), 0.2, b + 0.9 * rand.float(Real) );

                if (math.length(center - vec3( 4, 0.2, 0 )) > 0.9) {
                    if (choose_mat < 0.8) {
                        // diffuse
                        const albedo = rng.sampleVec3(rand);
                        textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(albedo));
                        materials.appendAssumeCapacity(LambertianMaterial.initMaterial(&textures.items[textures.items.len - 1]));

                        // // Non-motion blurred entities.
                        // try scene.collection.add(try SphereEntity.initEntity(
                        //     &entity_pool, center, 0.2, &materials.items[materials.items.len - 1]));

                        // Motion blurred entities.
                        scene.collection.addAssumeCapacity(try SphereEntity.initEntityAnimated(
                            ctx.entity_pool,
                            center,
                            center + vec3( 0, rand.float(Real) * 0.5, 0 ),
                            0.2,
                            &materials.items[materials.items.len - 1],
                        ));

                    } else if (choose_mat < 0.95) {
                        // metal
                        const albedo = rng.sampleVec3Interval(rand, .{ .min = 0.5, .max = 1.0 });
                        const fuzz = rand.float(Real) * 0.8;
                        materials.appendAssumeCapacity(MetalMaterial.initMaterial(albedo, fuzz));
                        scene.collection.addAssumeCapacity(try SphereEntity.initEntity(
                            ctx.entity_pool, center, 0.2, &materials.items[materials.items.len - 1]));

                    } else {
                        // glass
                        materials.appendAssumeCapacity(DielectricMaterial.initMaterial(1.5));
                        scene.collection.addAssumeCapacity(try SphereEntity.initEntity(
                            ctx.entity_pool, center, 0.2, &materials.items[materials.items.len - 1]));
                    }
                }
            }
        }
    }

    const material1 = DielectricMaterial.initMaterial(1.5);
    scene.collection.addAssumeCapacity(try SphereEntity.initEntity(ctx.entity_pool, vec3( 0, 1, 0 ), 1.0, &material1));

    const material2 = LambertianMaterial.initMaterial(&texture_solid_brown);
    scene.collection.addAssumeCapacity(try SphereEntity.initEntity(ctx.entity_pool, vec3( -4, 1, 0 ), 1, &material2));

    const material3 = MetalMaterial.initMaterial(vec3( 0.7, 0.6, 0.5 ), 0.0);
    scene.collection.addAssumeCapacity(try SphereEntity.initEntity(ctx.entity_pool, vec3( 4, 1, 0 ), 1, &material3));

    try scene.collection.createBvhTree(ctx.entity_pool);

    // camera    
    var camera = Camera.init(
        vec3( 13, 2, 3 ),
        vec3( 0, 0, 0 ),
        vec3( 0, 1, 0 ),
        20.0,
        10.0,
        0.6,
    );
    renderer.background_color = vec3( 0.5, 0.7, 1.0 );

    ctx.timer.logInfoElapsed("scene initialized");

    // ---- render ----
    try renderer.render(&camera, scene, framebuffer);
    ctx.timer.logInfoElapsed("scene rendered");
}

fn checkeredSpheres(ctx: SceneContext, renderer: *Renderer, framebuffer: *Framebuffer) !void {
    // ---- textures ----
    const texture_even = tex.SolidColorTexture.initTexture(vec3( 0.2, 0.3, 0.1 ));
    const texture_odd = tex.SolidColorTexture.initTexture(vec3( 0.9, 0.9, 0.9 ));
    const texture_checker = tex.CheckerboardTexture.initTexture(2.32, &texture_even, &texture_odd);

    // ---- materials ----
    const material = LambertianMaterial.initMaterial(&texture_checker);

    // ---- entities ----
    var scene = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    defer scene.deinit();

    try scene.collection.add(try SphereEntity.initEntity(ctx.entity_pool, vec3( 0, -10, 0 ), 10, &material));
    try scene.collection.add(try SphereEntity.initEntity(ctx.entity_pool, vec3( 0, 10, 0 ), 10, &material));

    // ---- camera ----    
    var camera = Camera.init(
        vec3( 13, 2, 3 ),
        vec3( 0, 0, 0 ),
        vec3( 0, 1, 0 ),
        20.0,
        10.0,
        0.0,
    );
    renderer.background_color = vec3( 0.5, 0.7, 1.0 );

    ctx.timer.logInfoElapsed("scene initialized");

    // ---- render ----
    try renderer.render(&camera, scene, framebuffer);
    ctx.timer.logInfoElapsed("scene rendered");
}

fn earth(ctx: SceneContext, renderer: *Renderer, framebuffer: *Framebuffer) !void {
    // ---- textures ----
    const earth_image_path: [:0]const u8 = @import("build_options").asset_dir ++ "earth.png";
    var earth_image = try img.Image.initFromFile(earth_image_path);
    defer earth_image.deinit();

    // ---- materials ----
    const material = LambertianMaterial.initMaterial(&ImageTexture.initTexture(&earth_image));

    // ---- entities ----
    var scene = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    defer scene.deinit();

    try scene.collection.add(try SphereEntity.initEntity(ctx.entity_pool, vec3( 0, 0, 0 ), 1.5, &material));

    // ---- camera ----
    var camera = Camera.init(
        vec3( 0, 0, 12 ),
        vec3( 0, 0, 0 ),
        vec3( 0, 1, 0 ),
        20.0,
        10.0,
        0.0,
    );
    renderer.background_color = vec3( 0.5, 0.7, 1.0 );

    ctx.timer.logInfoElapsed("scene initialized");

    // ---- render ----
    try renderer.render(&camera, scene, framebuffer);
    ctx.timer.logInfoElapsed("scene rendered");
}

fn quads(ctx: SceneContext, renderer: *Renderer, framebuffer: *Framebuffer) !void {
    // ---- textures ----
    const image_path: [:0]const u8 = @import("build_options").asset_dir ++ "wap.jpg";
    var image = try img.Image.initFromFile(image_path);
    defer image.deinit();

    const texture_image = ImageTexture.initTexture(&image);

    // ---- materials ----
    const material_left = LambertianMaterial.initMaterial(&texture_image);
    const material_back = LambertianMaterial.initMaterial(&texture_image);
    const material_right = LambertianMaterial.initMaterial(&texture_image);
    const material_top = LambertianMaterial.initMaterial(&texture_image);
    const material_bottom = LambertianMaterial.initMaterial(&texture_image);

    // ---- entities ----
    var scene = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    defer scene.deinit();
    try scene.collection.entities.ensureTotalCapacity(5);

    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( -3, -2, 5 ), vec3( 0, 0, -4 ), vec3( 0, 4, 0 ), &material_left));
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( -2, -2, 0 ), vec3( 4, 0, 0 ), vec3( 0, 4, 0 ), &material_right));
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( 3, -2, 1 ), vec3( 0, 0, 4 ), vec3( 0, 4, 0 ), &material_back));
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( -2, 3, 1 ), vec3( 4, 0, 0 ), vec3( 0, 0, 4 ), &material_top));
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( -2, -3, 5 ), vec3( 4, 0, 0 ), vec3( 0, 0, -4 ), &material_bottom));

    var camera = Camera.init(
        vec3( 0, 0, 9 ),
        vec3( 0, 0, 0 ),
        vec3( 0, 1, 0 ),
        80.0,
        10.0,
        0.0,
    );
    renderer.background_color = vec3( 0.5, 0.7, 1.0 );

    ctx.timer.logInfoElapsed("scene initialized");

    // ---- render ----
    try renderer.render(&camera, scene, framebuffer);
    ctx.timer.logInfoElapsed("scene rendered");
}

fn emissive(ctx: SceneContext, renderer: *Renderer, framebuffer: *Framebuffer) !void {
    // ---- textures ----
    const texture_even = SolidColorTexture.initTexture(vec3( 0.2, 0.3, 0.1 ));
    const texture_odd = SolidColorTexture.initTexture(vec3( 0.9, 0.9, 0.9 ));
    const texture_ground = CheckerboardTexture.initTexture(0.32, &texture_even, &texture_odd);
    const texture_light = SolidColorTexture.initTexture(vec3( 4, 4, 4 ));

    // ---- materials ----
    const material_glass = DielectricMaterial.initMaterial(1.5);
    const material_ground = LambertianMaterial.initMaterial(&texture_ground);
    const material_light = DiffuseLightEmissiveMaterial.initMaterial(&texture_light);

    // ---- entities ----
    var scene = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    defer scene.deinit();
    try scene.collection.entities.ensureTotalCapacity(5);

    scene.collection.addAssumeCapacity(try SphereEntity.initEntity(ctx.entity_pool, vec3( 0, -1000, 0 ), 1000, &material_ground));
    scene.collection.addAssumeCapacity(try SphereEntity.initEntity(ctx.entity_pool, vec3( 0, 2, 0 ), 1.5, &material_glass));
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( 3, 1, -2 ), vec3( 2, 0, 0 ), vec3( 0, 2, 0 ), &material_light));
    scene.collection.addAssumeCapacity(try SphereEntity.initEntity(ctx.entity_pool, vec3( 0, 7, 0 ), 1, &material_light));

    try scene.collection.createBvhTree(ctx.entity_pool);

    // ---- camera ----
    var camera = Camera.init(
        vec3( 26, 3, 6 ),
        vec3( 0, 2, 0 ),
        vec3( 0, 1, 0 ),
        20.0,
        10.0,
        0.0,
    );

    ctx.timer.logInfoElapsed("scene initialized");

    // ---- render ----
    try renderer.render(&camera, scene, framebuffer);
    ctx.timer.logInfoElapsed("scene rendered");
}

fn cornellBox(ctx: SceneContext, renderer: *Renderer, framebuffer: *Framebuffer) !void {
    // ---- textures ----
    const texture_red = SolidColorTexture.initTexture(vec3( 0.65, 0.05, 0.05 ));
    const texture_white = SolidColorTexture.initTexture(vec3( 0.73, 0.73, 0.73 ));
    const texture_green = SolidColorTexture.initTexture(vec3( 0.12, 0.45, 0.15 ));
    const texture_light = SolidColorTexture.initTexture(vec3( 15, 15, 15 ));

    // ---- materials ----
    const material_red = LambertianMaterial.initMaterial(&texture_red);
    const material_white = LambertianMaterial.initMaterial(&texture_white);
    const material_green = LambertianMaterial.initMaterial(&texture_green);
    const material_light = DiffuseLightEmissiveMaterial.initMaterial(&texture_light);

    // ---- entities ----
    var scene = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    defer scene.deinit();
    try scene.collection.entities.ensureTotalCapacity(9);

    // left
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( 555, 0, 0 ), vec3( 0, 555, 0 ), vec3( 0, 0, 555 ), &material_green));
    // right
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( 0, 0, 0 ), vec3( 0, 555, 0 ), vec3( 0, 0, 555 ), &material_red));
    // bottom
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( 0, 0, 0 ), vec3( 555, 0, 0 ), vec3( 0, 0, 555 ), &material_white));
    // top
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( 555, 555, 555 ), vec3( -555, 0, 0 ), vec3( 0, 0, -555 ), &material_white));
    // back
    scene.collection.addAssumeCapacity(try QuadEntity.initEntity(ctx.entity_pool, vec3( 0, 0, 555 ), vec3( 555, 0, 0 ), vec3( 0, 555, 0 ), &material_white));

    // right mirror
    scene.collection.addAssumeCapacity(
        try Translate.initEntity(ctx.entity_pool, vec3(1, 104, 40), 
            try QuadEntity.initEntity(ctx.entity_pool, vec3(0, 0, 0), vec3( 0, 332, 0 ), vec3( 0, 0, 332 ), 
                &MetalMaterial.initMaterial(vec3(0.7, 0.6, 0.5), 0.0))));

    const box1 = try Translate.initEntity(ctx.entity_pool, vec3(130, 0, 65), 
        try RotateY.initEntity(ctx.entity_pool, -18.0, 
            try ent.createBoxEntity(ctx.allocator, ctx.entity_pool, vec3( 0, 0, 0 ), vec3( 165, 165, 165 ), &material_white)));
    scene.collection.addAssumeCapacity(box1);

    const box2 = try Translate.initEntity(ctx.entity_pool, vec3(265, 0, 295),
        try RotateY.initEntity(ctx.entity_pool, 15.0, 
            try ent.createBoxEntity(ctx.allocator, ctx.entity_pool, vec3( 0, 0, 0 ), vec3( 165, 330, 165 ), &material_white)));
    scene.collection.addAssumeCapacity(box2);

    // light
    scene.collection.addAssumeCapacity(
        try QuadEntity.initEntity(ctx.entity_pool, vec3( 353, 554, 312 ), vec3( -150, 0, 0 ), vec3( 0, 0, -125 ), &material_light));

    try scene.collection.createBvhTree(ctx.entity_pool);

    // ---- camera ----
    const fov_vertical = 40.0;
    const look_from = vec3( 278, 278, -800 );
    const look_at = vec3( 278, 278, 0 );
    const view_up = vec3( 0, 1, 0 );
    const focus_dist = 10.0;
    const defocus_angle = 0.0;
    var camera = Camera.init(
        look_from,
        look_at,
        view_up,
        fov_vertical,
        focus_dist,
        defocus_angle,
    );    

    ctx.timer.logInfoElapsed("scene initialized");

    // ---- render ----
    try renderer.render(&camera, scene, framebuffer);
    ctx.timer.logInfoElapsed("scene rendered");    
}

fn finalScene(ctx: SceneContext, renderer: *Renderer, framebuffer: *Framebuffer) !void {
    var rand = rng.getThreadRng();

    var scene = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    defer scene.deinit();

    // ---- ground ----
    const material_ground = LambertianMaterial.initMaterial(&SolidColorTexture.initTexture(vec3( 0.4, 0.83, 0.53 )));

    var ground_boxes = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    try scene.collection.add(ground_boxes);

    const num_boxes_per_side = 20;
    for (0..num_boxes_per_side) |i| {
        const fi = @as(Real, @floatFromInt(i));

        for (0..num_boxes_per_side) |j| {
            const fj = @as(Real, @floatFromInt(j));

            const w = 100.0;
            const x0 = -1000.0 + fi * w;
            const y0 = 0.0;
            const z0 = -1000.0 + fj * w;
            const x1 = x0 + w;
            const y1 = rand.float(Real) * 100.0 + 1.0;
            const z1 = z0 + w;

            try ground_boxes.collection.add(try ent.createBoxEntity(ctx.allocator, ctx.entity_pool, vec3( x0, y0, z0 ), vec3( x1, y1, z1 ), &material_ground));
        }
    }

    try ground_boxes.collection.createBvhTree(ctx.entity_pool);

    // ---- lights ----
    const material_light = DiffuseLightEmissiveMaterial.initMaterial(&SolidColorTexture.initTexture(vec3(7, 7, 7)));
    try scene.collection.add(
        try QuadEntity.initEntity(ctx.entity_pool, vec3(123,554,147), vec3(300, 0, 0), vec3(0, 0, 265), &material_light));

    // ---- spheres ----
    // glass
    try scene.collection.add(
        try SphereEntity.initEntity(ctx.entity_pool, vec3(260, 150, 45), 50.0, 
            &DielectricMaterial.initMaterial(1.5)));

    // metal
    try scene.collection.add(
        try SphereEntity.initEntity(ctx.entity_pool, vec3(0, 150, 145), 50,
            &MetalMaterial.initMaterial(vec3(0.8, 0.8, 0.9), 1.0)));

    const boundary = try SphereEntity.initEntity(ctx.entity_pool, vec3(360,150,145), 70, 
        &DielectricMaterial.initMaterial(1.5));
    try scene.collection.add(boundary);

    const image_path_shrek: [:0]const u8 = @import("build_options").asset_dir ++ "wap.jpg";
    var image_shrek = try img.Image.initFromFile(image_path_shrek);
    defer image_shrek.deinit();
    try scene.collection.add(
        try SphereEntity.initEntity(ctx.entity_pool, vec3(400,200,400), 100, 
            &LambertianMaterial.initMaterial(&ImageTexture.initTexture(&image_shrek))));

    const image_path: [:0]const u8 = @import("build_options").asset_dir ++ "me.jpg";
    var image = try img.Image.initFromFile(image_path);
    defer image.deinit();
    try scene.collection.add(
        try SphereEntity.initEntity(ctx.entity_pool, vec3(220,280,300), 80, 
            &LambertianMaterial.initMaterial(&ImageTexture.initTexture(&image))));

    var box_of_balls = try EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    const material_white = LambertianMaterial.initMaterial(&SolidColorTexture.initTexture(vec3(0.73, 0.73, 0.73)));
    for (0..1000) |_| {
        const center = rng.sampleVec3(rand) * vec3s(165.0);
        try box_of_balls.collection.add(
            try SphereEntity.initEntity(ctx.entity_pool, center, 10, &material_white));
    }
    try box_of_balls.collection.createBvhTree(ctx.entity_pool);

    try scene.collection.add(
        try Translate.initEntity(ctx.entity_pool, vec3(-100,270,395), 
            try RotateY.initEntity(ctx.entity_pool, 15.0,
                box_of_balls)));

    try scene.collection.createBvhTree(ctx.entity_pool);

    // ---- camera ----
    const fov_vertical = 40.0;
    const look_from = vec3( 478, 278, -600 );
    const look_at = vec3( 278, 278, 0 );
    const view_up = vec3( 0, 1, 0 );
    const focus_dist = 10.0;
    const defocus_angle = 0.0;
    var camera = Camera.init(
        look_from,
        look_at,
        view_up,
        fov_vertical,
        focus_dist,
        defocus_angle,
    );

    ctx.timer.logInfoElapsed("scene initialized");

    // ---- render ----
    try renderer.render(&camera, scene, framebuffer);
    ctx.timer.logInfoElapsed("scene rendered");
}

pub fn main() !void {
    // ---- allocator ----
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var entity_pool = std.heap.MemoryPool(IEntity).init(std.heap.page_allocator);
    defer entity_pool.deinit();

    // parse args
    var parser = try ArgParser(UserArgs).init(allocator);
    defer parser.deinit();

    const argvals = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argvals);

    const args = parser.parse(argvals) catch {
        try parser.printUsage(std.io.getStdErr().writer());
        return error.CouldNotParseUserArgs;
    };

    // ---- thread pool ----
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator, .n_jobs = args.thread_pool_size });
    defer thread_pool.deinit();

    var timer = Timer.init();

    // ---- ext lib init ----
    zstbi.init(allocator);
    defer zstbi.deinit();

    const ctx = SceneContext{
        .allocator = allocator,
        .entity_pool = &entity_pool,
        .timer = &timer,
        .args = args,
    };

    const sqrt_spp = @sqrt(@as(Real, @floatFromInt(args.samples_per_pixel)));
    var renderer = Renderer{
        .thread_pool = &thread_pool,
        .background_color = vec3(0, 0, 0),
        .clear_color = vec3(0, 0, 0),
        .samples_per_pixel = ctx.args.samples_per_pixel,
        .max_ray_bounce_depth = ctx.args.ray_bounce_max_depth,

        .sqrt_spp = @intFromFloat(sqrt_spp),
        .recip_sqrt_spp = 1.0 / sqrt_spp,
    };

    var framebuffer = try Framebuffer.init(allocator, args.image_height, args.image_width);
    defer framebuffer.deinit();

    // Scene
    // try bigBountifulBodaciousBeautifulBouncingBalls(ctx, &renderer, &framebuffer);
    // try checkeredSpheres(ctx, &renderer, &framebuffer);
    // try earth(ctx, &renderer, &framebuffer);
    // try quads(ctx, &renderer, &framebuffer);
    // try emissive(ctx, &renderer, &framebuffer);
    try cornellBox(ctx, &renderer, &framebuffer);
    // try finalScene(ctx, &renderer, &framebuffer);

    // ---- write ----
    std.log.debug("Writing image...", .{});
    var writer = WriterPPM{
        .allocator = allocator,
        .thread_pool = &thread_pool,
    };
    try writer.write(args.image_out_path, framebuffer.buffer, framebuffer.num_cols, framebuffer.num_rows);
    timer.logInfoElapsed("scene written to file");
}

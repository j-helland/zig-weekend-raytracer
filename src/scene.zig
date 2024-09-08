const std = @import("std");

const math = @import("math.zig");
const cam = @import("camera.zig");
const ent = @import("entity.zig");
const rdr = @import("render.zig");
const tex = @import("texture.zig");
const mat = @import("material.zig");
const img = @import("image.zig");
const rng = @import("rng.zig");
const time = @import("timer.zig");

pub const SceneLoadContext = struct {
    allocator: std.mem.Allocator,
    entity_pool: *std.heap.MemoryPool(ent.IEntity),
    rand: std.Random,
};

pub const SceneType = enum {
    balls,
    shrek_quads,
    emissive,
    cornell_box,
    rtw_final,
};

pub fn loadScene(scene_type: SceneType, ctx: SceneLoadContext) anyerror!Scene {
    return switch(scene_type) {
        .balls => loadSceneBalls(ctx),
        .shrek_quads => loadSceneShrekQuads(ctx),
        .emissive => loadSceneEmissive(ctx),
        .cornell_box => loadSceneCornellBox(ctx),
        .rtw_final => loadSceneRTWFinal(ctx),
    };
}

pub const Scene = struct {
    const Self = @This();

    textures: std.ArrayList(tex.ITexture),
    materials: std.ArrayList(mat.IMaterial),
    scene: *ent.IEntity,
    lights: ?*ent.IEntity = null,
    camera: cam.Camera,
    background_color: math.Vec3 = math.vec3(0, 0, 0),

    pub fn deinit(self: *Self) void {
        for (self.textures.items) |*texture| texture.deinit();
        self.textures.deinit();

        self.materials.deinit();

        self.scene.deinit();

        if (self.lights) |lights| lights.deinit();
    }

    pub fn draw(self: *const Self, renderer: *rdr.Renderer, framebuffer: *cam.Framebuffer) !void {
        renderer.background_color = self.background_color;
        renderer.light_entities = self.lights;
        try renderer.render(&self.camera, self.scene, framebuffer);
    }
};

inline fn getLastRef(items: anytype) *const std.meta.Child(@TypeOf(items)) {
    return &items[items.len - 1];
}

fn loadSceneBalls(ctx: SceneLoadContext) anyerror!Scene {
    // ---- textures ----
    const num_textures = 4 + 22 * 22;
    var textures = try std.ArrayList(tex.ITexture).initCapacity(ctx.allocator, num_textures);

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.4, 0.2, 0.1)));
    const texture_solid_brown = getLastRef(textures.items); 

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.2, 0.3, 0.1)));
    const texture_even        = getLastRef(textures.items); 

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.9, 0.9, 0.9)));
    const texture_odd         = getLastRef(textures.items); 

    textures.appendAssumeCapacity(tex.CheckerboardTexture.initTexture(0.32, texture_even, texture_odd));
    const texture_ground      = getLastRef(textures.items); 

    // ---- materials ----
    var scene = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    try scene.collection.entities.ensureTotalCapacity(22 * 22 + 4);

    const num_materials = 22 * 22 + 4;
    var materials = try std.ArrayList(mat.IMaterial).initCapacity(ctx.allocator, num_materials);

    // ground
    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_ground));
    scene.collection.addAssumeCapacity(try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(0, -1000, 0), 1000, getLastRef(materials.items)));

    if (@import("builtin").mode != .Debug) {
        // This many entities is way too slow in debug builds.
        // Also generates way too much profiling data.
        const rand = rng.getThreadRng();
        var a: math.Real = -11.0;
        while (a < 11.0) : (a += 1.0) {
            var b: math.Real = -11.0;
            while (b < 11.0) : (b += 1.0) {
                const choose_mat = rand.float(math.Real);
                const center = math.vec3(a + 0.9 * rand.float(math.Real), 0.2, b + 0.9 * rand.float(math.Real));

                if (math.length(center - math.vec3(4, 0.2, 0)) > 0.9) {
                    if (choose_mat < 0.8) {
                        // diffuse
                        const albedo = rng.sampleVec3(rand);
                        textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(albedo));
                        materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(getLastRef(textures.items)));

                        // Non-motion blurred entities.
                        try scene.collection.add(try ent.SphereEntity.initEntity(ctx.entity_pool, center, 0.2, getLastRef(materials.items)));

                        // // Motion blurred entities.
                        // scene.collection.addAssumeCapacity(try ent.SphereEntity.initEntityAnimated(
                        //     ctx.entity_pool,
                        //     center,
                        //     center + math.vec3(0, rand.float(math.Real) * 0.5, 0),
                        //     0.2,
                        //     materials.items[materials.items.len - 1],
                        // ));

                    } else if (choose_mat < 0.95) {
                        // metal
                        const albedo = rng.sampleVec3Interval(rand, .{ .min = 0.5, .max = 1.0 });
                        const fuzz = rand.float(math.Real) * 0.8;
                        materials.appendAssumeCapacity(mat.MetalMaterial.initMaterial(albedo, fuzz));
                        scene.collection.addAssumeCapacity(try ent.SphereEntity.initEntity(ctx.entity_pool, center, 0.2, getLastRef(materials.items)));

                    } else {
                        // glass
                        materials.appendAssumeCapacity(mat.DielectricMaterial.initMaterial(1.5));
                        const glass_sphere = try ent.SphereEntity.initEntity(ctx.entity_pool, center, 0.2, getLastRef(materials.items));
                        scene.collection.addAssumeCapacity(glass_sphere);
                    }
                }
            }
        }
    }

    materials.appendAssumeCapacity(mat.DielectricMaterial.initMaterial(1.5));
    const big_glass_sphere = try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(0, 1, 0), 1.0, getLastRef(materials.items));
    scene.collection.addAssumeCapacity(big_glass_sphere);

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_solid_brown));
    scene.collection.addAssumeCapacity(try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(-4, 1, 0), 1, getLastRef(materials.items)));

    materials.appendAssumeCapacity(mat.MetalMaterial.initMaterial(math.vec3(0.7, 0.6, 0.5), 0.0));
    scene.collection.addAssumeCapacity(try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(4, 1, 0), 1, getLastRef(materials.items)));

    // acceleration structure
    try scene.collection.createBvhTree(ctx.entity_pool);

    // camera
    const camera = cam.Camera.init(
        math.vec3(13, 2, 3),
        math.vec3(0, 0, 0),
        math.vec3(0, 1, 0),
        20.0,
        10.0,
        0.6,
    );

    return Scene{
        .textures = textures,
        .materials = materials,
        .scene = scene,
        .camera = camera,
        .background_color = math.vec3(0.5, 0.7, 1.0),
    };
}

fn loadSceneShrekQuads(ctx: SceneLoadContext) anyerror!Scene {
    // ---- textures ----
    const num_textures = 1;
    var textures = try std.ArrayList(tex.ITexture).initCapacity(ctx.allocator, num_textures);

    const image_path: [:0]const u8 = @import("build_options").asset_dir ++ "wap.jpg";
    textures.appendAssumeCapacity(try tex.ImageTexture.initTextureFromPath(image_path));
    const texture_image = getLastRef(textures.items);

    // ---- materials ----
    const num_materials = 5;
    var materials = try std.ArrayList(mat.IMaterial).initCapacity(ctx.allocator, num_materials);

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_image));
    const material_left   = getLastRef(materials.items);

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_image));
    const material_back   = getLastRef(materials.items);

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_image));
    const material_right  = getLastRef(materials.items);

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_image));
    const material_top    = getLastRef(materials.items);

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_image));
    const material_bottom = getLastRef(materials.items);

    // ---- entities ----
    var scene = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    try scene.collection.entities.ensureTotalCapacity(5);

    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(-3, -2, 5), math.vec3(0, 0, -4), math.vec3(0, 4, 0), material_left));
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(-2, -2, 0), math.vec3(4, 0, 0), math.vec3(0, 4, 0), material_right));
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(3, -2, 1), math.vec3(0, 0, 4), math.vec3(0, 4, 0), material_back));
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(-2, 3, 1), math.vec3(4, 0, 0), math.vec3(0, 0, 4), material_top));
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(-2, -3, 5), math.vec3(4, 0, 0), math.vec3(0, 0, -4), material_bottom));

    const camera = cam.Camera.init(
        math.vec3(0, 0, 9),
        math.vec3(0, 0, 0),
        math.vec3(0, 1, 0),
        80.0,
        10.0,
        0.0,
    );

    return Scene{
        .textures = textures,
        .materials = materials,
        .scene = scene,
        .camera = camera,
        .background_color = math.vec3(0.5, 0.7, 1.0),
    };
}

fn loadSceneEmissive(ctx: SceneLoadContext) anyerror!Scene {
    // ---- textures ----
    const num_textures = 5;
    var textures = try std.ArrayList(tex.ITexture).initCapacity(ctx.allocator, num_textures);

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.2, 0.3, 0.1)));
    const texture_even        = getLastRef(textures.items);

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.9, 0.9, 0.9)));
    const texture_odd         = getLastRef(textures.items);

    textures.appendAssumeCapacity(tex.CheckerboardTexture.initTexture(0.32, texture_even, texture_odd));
    const texture_ground      = getLastRef(textures.items);

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(1, 2, 4)));
    const texture_light_blue  = getLastRef(textures.items);

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(2.3, 4, 2.3)));
    const texture_light_green = getLastRef(textures.items);

    // ---- materials ----
    const num_materials = 4;
    var materials = try std.ArrayList(mat.IMaterial).initCapacity(ctx.allocator, num_materials);

    materials.appendAssumeCapacity(mat.DielectricMaterial.initMaterial(1.5));
    const material_glass       = getLastRef(materials.items);

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_ground));
    const material_ground      = getLastRef(materials.items);

    materials.appendAssumeCapacity(mat.DiffuseLightEmissiveMaterial.initMaterial(texture_light_blue));
    const material_light_blue  = getLastRef(materials.items); 

    materials.appendAssumeCapacity(mat.DiffuseLightEmissiveMaterial.initMaterial(texture_light_green));
    const material_light_green = getLastRef(materials.items); 

    // ---- entities ----
    const num_entities = 5;
    var scene = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    try scene.collection.entities.ensureTotalCapacity(num_entities);

    const ground_sphere = try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(0, -1000, 0), 1000, material_ground);
    scene.collection.addAssumeCapacity(ground_sphere);
    const glass_sphere = try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(0, 2, 0), 1.5, material_glass);
    scene.collection.addAssumeCapacity(glass_sphere);

    // lights
    const light_quad = try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(3, 1, -2), math.vec3(2, 0, 0), math.vec3(0, 2, 0), material_light_blue);
    scene.collection.addAssumeCapacity(light_quad);

    const light_sphere = try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(0, 7, 0), 1, material_light_green);
    scene.collection.addAssumeCapacity(light_sphere);

    // acceleration structure
    try scene.collection.createBvhTree(ctx.entity_pool);

    var scene_lights = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    try scene_lights.collection.add(light_quad);
    try scene_lights.collection.add(light_sphere);
    try scene_lights.collection.add(glass_sphere);

    // ---- camera ----
    const camera = cam.Camera.init(
        math.vec3(26, 3, 6),
        math.vec3(0, 2, 0),
        math.vec3(0, 1, 0),
        20.0,
        10.0,
        0.0,
    );

    return Scene{
        .textures = textures,
        .materials = materials,
        .camera = camera,
        .scene = scene,
        .lights = scene_lights,
    };
}

fn loadSceneCornellBox(ctx: SceneLoadContext) anyerror!Scene {
    // ---- textures ----
    const num_textures = 4;
    var textures = try std.ArrayList(tex.ITexture).initCapacity(ctx.allocator, num_textures);

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.65, 0.05, 0.05)));
    const texture_red   = getLastRef(textures.items); 

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.73, 0.73, 0.73)));
    const texture_white = getLastRef(textures.items); 

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.12, 0.45, 0.15)));
    const texture_green = getLastRef(textures.items); 

    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(15, 15, 15)));
    const texture_light = getLastRef(textures.items); 

    // ---- materials ----
    const num_materials = 6;
    var materials = try std.ArrayList(mat.IMaterial).initCapacity(ctx.allocator, num_materials);

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_red));
    const material_red   = getLastRef(materials.items); 

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_white));
    const material_white = getLastRef(materials.items); 

    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(texture_green));
    const material_green = getLastRef(materials.items); 

    materials.appendAssumeCapacity(mat.DiffuseLightEmissiveMaterial.initMaterial(texture_light));
    const material_light = getLastRef(materials.items); 

    materials.appendAssumeCapacity(mat.DielectricMaterial.initMaterial(1.5));
    const material_glass = getLastRef(materials.items); 

    materials.appendAssumeCapacity(mat.MetalMaterial.initMaterial(math.vec3(0.8, 0.85, 0.88), 0));
    const material_metal = getLastRef(materials.items); 

    // ---- entities ----
    var scene = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    try scene.collection.entities.ensureTotalCapacity(9);

    // box walls
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(555, 0, 0), math.vec3(0, 555, 0), math.vec3(0, 0, 555), material_green));
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(0, 0, 0), math.vec3(0, 555, 0), math.vec3(0, 0, 555), material_red));
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(0, 0, 0), math.vec3(555, 0, 0), math.vec3(0, 0, 555), material_white));
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(555, 555, 555), math.vec3(-555, 0, 0), math.vec3(0, 0, -555), material_white));
    scene.collection.addAssumeCapacity(try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(0, 0, 555), math.vec3(555, 0, 0), math.vec3(0, 555, 0), material_white));

    // interior boxes
    // const box1 = try Translate.initEntity(ctx.entity_pool, math.vec3(130, 0, 65), try RotateY.initEntity(ctx.entity_pool, -18.0, try ent.createBoxEntity(ctx.allocator, ctx.entity_pool, math.vec3(0, 0, 0), math.vec3(165, 165, 165), material_white)));
    // const box1 = try Translate.initEntity(ctx.entity_pool, math.vec3(130, 0, 65), try RotateY.initEntity(ctx.entity_pool, -18.0, try ent.createBoxEntity(ctx.allocator, ctx.entity_pool, math.vec3(0, 0, 0), math.vec3(165, 165, 165), material_white)));
    // scene.collection.addAssumeCapacity(box1);

    const glass_sphere = try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(190, 90, 190), 90, material_glass);
    scene.collection.addAssumeCapacity(glass_sphere);

    const box2 = try ent.Translate.initEntity(ctx.entity_pool, math.vec3(265, 0, 295), try ent.RotateY.initEntity(ctx.entity_pool, 15.0, try ent.createBoxEntity(ctx.allocator, ctx.entity_pool, math.vec3(0, 0, 0), math.vec3(165, 330, 165), material_metal)));
    scene.collection.addAssumeCapacity(box2);

    // light
    const light = try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(343, 554, 332), math.vec3(-150, 0, 0), math.vec3(0, 0, -125), material_light);
    scene.collection.addAssumeCapacity(light);

    // acceleration structure
    try scene.collection.createBvhTree(ctx.entity_pool);

    // importance sampled entities
    var scene_lights = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    try scene_lights.collection.add(glass_sphere);
    try scene_lights.collection.add(light);

    // ---- camera ----
    const look_from = math.vec3(278, 278, -800);
    const look_at = math.vec3(278, 278, 0);
    const view_up = math.vec3(0, 1, 0);
    const fov_vertical = 40.0;
    const focus_dist = 10.0;
    const defocus_angle = 0.0;
    const camera = cam.Camera.init(
        look_from,
        look_at,
        view_up,
        fov_vertical,
        focus_dist,
        defocus_angle,
    );

    return Scene{
        .textures = textures,
        .materials = materials,
        .scene = scene,
        .lights = scene_lights,
        .camera = camera,
    };
}

fn loadSceneRTWFinal(ctx: SceneLoadContext) anyerror!Scene {
    var scene = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    var scene_lights = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);

    const num_textures = 5;
    var textures = try std.ArrayList(tex.ITexture).initCapacity(ctx.allocator, num_textures);

    const num_materials = 8;
    var materials = try std.ArrayList(mat.IMaterial).initCapacity(ctx.allocator, num_materials);

    // ---- ground ----
    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.4, 0.83, 0.53)));
    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(getLastRef(textures.items)));
    const material_ground = getLastRef(materials.items);

    var ground_boxes = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    try scene.collection.add(ground_boxes);

    const num_boxes_per_side = 20;
    for (0..num_boxes_per_side) |i| {
        const fi = @as(math.Real, @floatFromInt(i));

        for (0..num_boxes_per_side) |j| {
            const fj = @as(math.Real, @floatFromInt(j));

            const w = 100.0;
            const x0 = -1000.0 + fi * w;
            const y0 = 0.0;
            const z0 = -1000.0 + fj * w;
            const x1 = x0 + w;
            const y1 = ctx.rand.float(math.Real) * 100.0 + 1.0;
            const z1 = z0 + w;

            try ground_boxes.collection.add(try ent.createBoxEntity(ctx.allocator, ctx.entity_pool, math.vec3(x0, y0, z0), math.vec3(x1, y1, z1), material_ground));
        }
    }

    // acceleration structure
    try ground_boxes.collection.createBvhTree(ctx.entity_pool);

    // ---- lights ----
    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(7, 7, 7)));
    materials.appendAssumeCapacity(mat.DiffuseLightEmissiveMaterial.initMaterial(getLastRef(textures.items)));
    const material_light = getLastRef(materials.items);
    const light = try ent.QuadEntity.initEntity(ctx.entity_pool, math.vec3(123, 554, 147), math.vec3(300, 0, 0), math.vec3(0, 0, 265), material_light);
    try scene.collection.add(light);
    try scene_lights.collection.add(light);

    // ---- spheres ----
    // glass
    materials.appendAssumeCapacity(mat.DielectricMaterial.initMaterial(1.5));
    try scene.collection.add(try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(260, 150, 45), 50.0, getLastRef(materials.items)));

    // metal
    materials.appendAssumeCapacity(mat.MetalMaterial.initMaterial(math.vec3(0.8, 0.8, 0.9), 1.0));
    try scene.collection.add(try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(0, 150, 145), 50, getLastRef(materials.items)));

    materials.appendAssumeCapacity(mat.DielectricMaterial.initMaterial(1.5));
    const boundary = try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(360, 150, 145), 70, getLastRef(materials.items));
    try scene.collection.add(boundary);

    const image_path_shrek: [:0]const u8 = @import("build_options").asset_dir ++ "wap.jpg";
    textures.appendAssumeCapacity(try tex.ImageTexture.initTextureFromPath(image_path_shrek));
    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(getLastRef(textures.items)));
    try scene.collection.add(try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(400, 200, 400), 100, getLastRef(materials.items)));

    const image_path: [:0]const u8 = @import("build_options").asset_dir ++ "me.jpg";
    textures.appendAssumeCapacity(try tex.ImageTexture.initTextureFromPath(image_path));
    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(getLastRef(textures.items)));
    try scene.collection.add(try ent.SphereEntity.initEntity(ctx.entity_pool, math.vec3(220, 280, 300), 80, getLastRef(materials.items)));

    var box_of_balls = try ent.EntityCollection.initEntity(ctx.entity_pool, ctx.allocator);
    textures.appendAssumeCapacity(tex.SolidColorTexture.initTexture(math.vec3(0.73, 0.73, 0.73)));
    materials.appendAssumeCapacity(mat.LambertianMaterial.initMaterial(getLastRef(textures.items)));
    const material_white = getLastRef(materials.items);
    for (0..1000) |_| {
        const center = rng.sampleVec3(ctx.rand) * math.vec3s(165.0);
        try box_of_balls.collection.add(try ent.SphereEntity.initEntity(ctx.entity_pool, center, 10, material_white));
    }
    try box_of_balls.collection.createBvhTree(ctx.entity_pool);

    try scene.collection.add(try ent.Translate.initEntity(ctx.entity_pool, math.vec3(-100, 270, 395), try ent.RotateY.initEntity(ctx.entity_pool, 15.0, box_of_balls)));
    try scene.collection.createBvhTree(ctx.entity_pool);

    // ---- camera ----
    const fov_vertical = 40.0;
    const look_from = math.vec3(478, 278, -600);
    const look_at = math.vec3(278, 278, 0);
    const view_up = math.vec3(0, 1, 0);
    const focus_dist = 10.0;
    const defocus_angle = 0.0;
    const camera = cam.Camera.init(
        look_from,
        look_at,
        view_up,
        fov_vertical,
        focus_dist,
        defocus_angle,
    );

    return Scene{
        .textures = textures,
        .materials = materials,
        .scene = scene,
        .lights = scene_lights,
        .camera = camera,
    };
}
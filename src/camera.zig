const std = @import("std");
const WriteError = std.fs.File.WriteError;

const math = @import("math.zig");
const Real = math.Real;
const Vec3 = math.Vec3;
const Color = math.Vec3;
const Point3 = math.Vec3;

const ent = @import("entity.zig");
const Entity = ent.Entity;
const Ray = ent.Ray;
const HitRecord = ent.HitRecord;
const HitContext = ent.HitContext;
const Material = ent.Material;
const MetalMaterial = ent.MetalMaterial;
const LambertiaMaterial = ent.LambertianMaterial;
const ScatterContext = ent.ScatterContext;

const rng = @import("rng.zig");

/// Render target abstraction that corresponds to a single frame.
pub const Framebuffer = struct {
    const Self = @This();

    const PPM_HEADER_FMT = "P3\n{} {}\n255\n";
    const PPM_PIXEL_FMT = "{d} {d} {d}\n";
    const PPM_PIXEL_NUM_BYTES = "255 255 255\n".len;

    allocator: std.mem.Allocator,
    buffer: []Color,
    num_rows: usize,
    num_cols: usize,

    pub fn init(allocator: std.mem.Allocator, height: usize, width: usize) !Self {
        return .{
            .allocator = allocator,
            .buffer = try allocator.alloc(Color, height * width),
            .num_rows = height,
            .num_cols = width,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.allocator.free(self.buffer);
    }
};

pub const Camera = struct {
    const Self = @This();

    fov_vertical: Real = 90.0,
    look_from: Point3 = .{0, 0, 0},
    look_at: Point3 = .{0, 0, -1},
    view_up: Vec3 = .{0, 1, 0},
    basis_u: Vec3,
    basis_v: Vec3,
    basis_w: Vec3,

    aspect_ratio: Real,
    image_width: usize,
    image_height: usize,
    center: Point3,
    pixel00_loc: Point3,
    pixel_delta_u: Vec3,
    pixel_delta_v: Vec3,

    defocus_angle: Real = 0,
    focus_dist: Real = 10,
    defocus_disk_u: Vec3,
    defocus_disk_v: Vec3,

    samples_per_pixel: usize = 100,
    max_ray_bounce_depth: usize = 50,

    thread_pool: *std.Thread.Pool,

    pub fn init(
        thread_pool: *std.Thread.Pool, 
        aspect: Real,
        img_width: usize, 
        fov_vertical: Real,
        look_from: Point3,
        look_at: Point3,
        view_up: Vec3,
        focus_dist: Real,
        defocus_angle: Real,
    ) Self {
        const img_height = @as(usize, @intFromFloat(@as(Real, @floatFromInt(img_width)) / aspect));

        // viewport dimensions
        const theta = std.math.degreesToRadians(fov_vertical);
        const h = @tan(theta / 2.0);
        const viewport_height = 2.0 * h * focus_dist;
        const viewport_width = viewport_height * aspect;

        // coordinate frame basis vectors
        const w = math.normalize(look_from - look_at);
        const u = math.normalize(math.cross(view_up, w));
        const v = math.cross(w, u);

        // vectors across horizontal and down vertical viewport edges
        const viewport_u = math.vec3s(viewport_width) * u; // across horizontal
        const viewport_v = math.vec3s(-viewport_height) * v; // down vertical

        const pixel_delta_u = viewport_u / math.vec3s(@floatFromInt(img_width));
        const pixel_delta_v = viewport_v / math.vec3s(@floatFromInt(img_height));

        // upper left pixel location
        const viewport_upper_left = look_from 
            - (math.vec3s(focus_dist) * w)
            - viewport_u / math.vec3s(2) 
            - viewport_v / math.vec3s(2);
        const pixel00_loc = viewport_upper_left + math.vec3s(0.5) * (pixel_delta_u + pixel_delta_v);        

        // calculate camera defocus disk basis vectors
        const defocus_radius = math.vec3s(focus_dist * @tan(std.math.degreesToRadians(defocus_angle / 2.0)));
        const defocus_disk_u = u * defocus_radius;
        const defocus_disk_v = v * defocus_radius;

        return .{
            .fov_vertical = fov_vertical,
            .center = look_from,
            .look_at = look_at,
            .look_from = look_from,
            .view_up = view_up,

            .basis_u = u,
            .basis_v = v,
            .basis_w = w,

            .pixel_delta_u = pixel_delta_u,
            .pixel_delta_v = pixel_delta_v,

            .aspect_ratio = aspect,
            .image_width = img_width, 
            .image_height = img_height,
            .pixel00_loc = pixel00_loc,

            .defocus_angle = defocus_angle,
            .focus_dist = focus_dist,
            .defocus_disk_u = defocus_disk_u,
            .defocus_disk_v = defocus_disk_v,

            .thread_pool = thread_pool,
        };
    }

    pub fn render(self: *const Self, entity: *const Entity, framebuffer: *Framebuffer) !void {
        var wg = std.Thread.WaitGroup{};

        // Similar to GPU 4x4 pixel shading work groups, except that here we use row-major order lines.
        const block_size = 32;
        std.debug.assert(self.image_width % block_size == 0);

        var render_thread_context = RenderThreadContext{
            .entity = entity,

            .framebuffer = framebuffer.buffer,
            .row_idx = 0,
            .col_range = .{ .min = 0, .max = 0 },
            .num_cols = self.image_width,

            .pixel00_loc = self.pixel00_loc,
            .delta_u = self.pixel_delta_u,
            .delta_v = self.pixel_delta_v,
            .center = self.center,

            .defocus_angle = self.defocus_angle,
            .defocus_disk_u = self.defocus_disk_u,
            .defocus_disk_v = self.defocus_disk_v,

            .samples_per_pixel = self.samples_per_pixel,
            .max_ray_bounce_depth = self.max_ray_bounce_depth,
        };

        // Write pixels into shared image. No need to lock since the image is partitioned into non-overlapping lines.
        for (0..self.image_height) |v| {
            render_thread_context.row_idx = v;

            var idx_u: usize = 0;
            while (idx_u < self.image_width) : (idx_u += block_size) {
                // Handle uneven chunking.
                render_thread_context.col_range = .{ .min = idx_u, .max = @min(self.image_width, idx_u + block_size) };
                self.thread_pool.spawnWg(&wg, rayColorLine, .{ render_thread_context });
            }
        }
        self.thread_pool.waitAndWork(&wg);
    }
};

/// Data required for each rendering thread to compute pixel color information.
const RenderThreadContext = struct {
    // Contains scene to raytrace.
    entity: *const Entity,

    // Shared mutable rendering surface parameters.
    framebuffer: []Color,
    row_idx: usize,
    col_range: math.Interval(usize),
    num_cols: usize,

    // Raytracing parameters.
    pixel00_loc: Point3,
    delta_u: Vec3,
    delta_v: Vec3,
    center: Point3,

    defocus_angle: Real,
    defocus_disk_u: Vec3,
    defocus_disk_v: Vec3,

    samples_per_pixel: usize,
    max_ray_bounce_depth: usize,
};

fn encodeColor(_color: Color) [3]u8 {
    const rgb_max = 256.0;
    const intensity = math.Interval(Real){ .min = 0.0, .max = 0.999 };

    const color = math.gammaCorrection(_color);

    const ir = @as(u8, @intFromFloat(rgb_max * intensity.clamp(color[0])));
    const ig = @as(u8, @intFromFloat(rgb_max * intensity.clamp(color[1])));
    const ib = @as(u8, @intFromFloat(rgb_max * intensity.clamp(color[2])));

    return .{ir, ig, ib};
}

/// Raytraces a pixel line and writes the result into the framebuffer.
/// Wrapper around rayColor function for use in multithreaded.
fn rayColorLine(ctx: RenderThreadContext) void {
    const pixel_color_scale = math.vec3s(1.0 / @as(Real, @floatFromInt(ctx.samples_per_pixel)));

    for (ctx.col_range.min..ctx.col_range.max) |col_idx| {
        var color = Vec3{0, 0, 0};
        for (0..ctx.samples_per_pixel) |_| {
            const ray = sampleRay(&ctx, col_idx);
            color += rayColor(ctx.entity, &ray, ctx.max_ray_bounce_depth);
        }
        ctx.framebuffer[ctx.row_idx * ctx.num_cols + col_idx] = color * pixel_color_scale;
    }
}

/// Generates a random ray in a box around the current pixel (halfway to adjacent pixels).
fn sampleRay(ctx: *const RenderThreadContext, col_idx: usize) Ray {
    const offset = 
        if (ctx.samples_per_pixel == 1) Vec3{0, 0, 0} 
        else rng.sampleSquareXY(rng.getThreadRng());
    const sample = ctx.pixel00_loc 
        + ctx.delta_u * math.vec3s(@as(Real, @floatFromInt(col_idx)) + offset[0])
        + ctx.delta_v * math.vec3s(@as(Real, @floatFromInt(ctx.row_idx)) + offset[1]);

    const origin = if (ctx.defocus_angle <= 0.0) ctx.center else sampleDefocusDisk(ctx);
    const direction = sample - origin;
    const ray = Ray{ .origin = origin, .direction = direction };
    return ray;
}

fn sampleDefocusDisk(ctx: *const RenderThreadContext) Vec3 {
    const p = rng.sampleUnitDiskXY(rng.getThreadRng(), 1.0);
    return ctx.center + math.vec3s(p[0]) * ctx.defocus_disk_u + math.vec3s(p[1]) * ctx.defocus_disk_v;
}

/// Computes the pixel color for the scene.
fn rayColor(entity: *const Entity, ray: *const Ray, depth: usize) Color {
    // Bounce recursion depth exceeded.
    if (depth == 0) return Color{0, 0, 0};

    // Correction factor to ignore spurious hits due to floating point precision issues when the ray is very close to the surface.
    // This helps reduce z-fighting / shadow-acne issues.
    const ray_correction_factor = 1e-4;

    var record = HitRecord{};
    const ctx = HitContext{
        .ray = ray,
        .trange = math.Interval(Real){ 
            .min = ray_correction_factor, 
            .max = std.math.inf(Real),
        },
    };

    // Hit recursion to simulate ray bouncing.
    if (entity.hit(ctx, &record)) {
        var ray_scattered: Ray = undefined;
        var attenuation_color: Color = .{1, 1, 1};
        const ctx_scatter = ScatterContext{ 
            .random = rng.getThreadRng(), 
            .ray_incoming = ray, 
            .hit_record = &record, 
            .ray_scattered = &ray_scattered,
            .attenuation = &attenuation_color, 
        };

        if (record.material) |material| {
            if (material.scatter(ctx_scatter)) { 
                return attenuation_color * rayColor(entity, &ray_scattered, depth - 1);
            }
        }
        return Color{0, 0, 0};
    } 

    const dn = math.normalize(ray.direction);
    const alpha = 0.5 * (dn[1] + 1.0);
    return math.lerp(Color{1, 1, 1}, Color{0.5, 0.7, 1.0}, alpha);
}

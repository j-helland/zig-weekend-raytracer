const std = @import("std");
const WriteError = std.fs.File.WriteError;

const ztracy = @import("ztracy");

const math = @import("math.zig");
const Real = math.Real;
const vec3 = math.vec3;
const Vec3 = math.Vec3;
const Color = math.Vec3;
const Point3 = math.Vec3;

const Interval = @import("interval.zig").Interval;

const Ray = @import("ray.zig").Ray;
const HitRecord = @import("ray.zig").HitRecord;
const HitContext = @import("ray.zig").HitContext;
const ScatterContext = @import("ray.zig").ScatterContext;

const ent = @import("entity.zig");
const IEntity = ent.IEntity;

const mat = @import("material.zig");
const IMaterial = mat.IMaterial;
const MetalMaterial = mat.MetalMaterial;
const LambertiaMaterial = mat.LambertianMaterial;

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
    look_from: Point3 = vec3( 0, 0, 0 ),
    look_at: Point3 = vec3( 0, 0, -1 ),
    view_up: Vec3 = vec3( 0, 1, 0 ),
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

    background_color: Color = vec3( 0, 0, 0 ),

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
        const viewport_upper_left = look_from - (math.vec3s(focus_dist) * w) - viewport_u / math.vec3s(2) - viewport_v / math.vec3s(2);
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

    pub fn render(self: *const Self, entity: *const IEntity, framebuffer: *Framebuffer) !void {
        const tracy_zone = ztracy.ZoneN(@src(), "Camera::render");
        defer tracy_zone.End();

        var wg = std.Thread.WaitGroup{};

        var render_thread_context = RenderThreadContext{
            .mut = .{
                .framebuffer = framebuffer.buffer,
            },

            // Rendering surface
            .row_idx = 0,
            .col_range = .{ .min = 0, .max = 0 },
            .num_cols = self.image_width,

            // Scene
            .entity = entity,

            // Raytracing parameters
            .pixel00_loc = self.pixel00_loc,
            .delta_u = self.pixel_delta_u,
            .delta_v = self.pixel_delta_v,
            .center = self.center,

            .background_color = self.background_color,

            .defocus_angle = self.defocus_angle,
            .defocus_disk_u = self.defocus_disk_u,
            .defocus_disk_v = self.defocus_disk_v,

            .samples_per_pixel = self.samples_per_pixel,
            .max_ray_bounce_depth = self.max_ray_bounce_depth,
        };

        // Similar to GPU 4x4 pixel shading work groups, except that here we use row-major order lines and use bigger chunks due to OS thread overhead.
        const block_size = 16;

        // Write pixels into shared image. No need to lock since the image is partitioned into non-overlapping lines.
        for (0..self.image_height) |v| {
            render_thread_context.row_idx = v;

            var idx_u: usize = 0;
            while (idx_u < self.image_width) : (idx_u += block_size) {
                // Handle uneven chunking.
                render_thread_context.col_range = .{ .min = idx_u, .max = @min(self.image_width, idx_u + block_size) };
                self.thread_pool.spawnWg(&wg, rayColorLine, .{render_thread_context});
            }
        }
        self.thread_pool.waitAndWork(&wg);
    }
};

/// Data required for each rendering thread to compute pixel color information.
const RenderThreadContext = struct {
    /// Keep mutable fields here for clarity.
    mut: struct {
        framebuffer: []Color,
    },

    // Rendering surface parameters.
    // These define a range that each thread can operate on without race conditions.
    row_idx: usize,
    col_range: Interval(usize),
    num_cols: usize,

    // Contains scene to raytrace.
    entity: *const IEntity,

    // Raytracing parameters.
    // These dictate parameters necessary to cast a ray through the scene and calculate an ensuing pixel color.
    pixel00_loc: Point3,
    delta_u: Vec3,
    delta_v: Vec3,
    center: Point3,

    background_color: Color,

    defocus_angle: Real,
    defocus_disk_u: Vec3,
    defocus_disk_v: Vec3,

    samples_per_pixel: usize,
    max_ray_bounce_depth: usize,
};

/// Raytraces a pixel line and writes the result into the framebuffer.
/// Wrapper around rayColor function for use in multithreaded.
fn rayColorLine(ctx: RenderThreadContext) void {
    const tracy_zone = ztracy.ZoneN(@src(), "rayColorLine");
    defer tracy_zone.End();

    const pixel_color_scale = math.vec3s(1.0 / @as(Real, @floatFromInt(ctx.samples_per_pixel)));

    for (ctx.col_range.min..ctx.col_range.max) |col_idx| {
        var color = vec3(0, 0, 0);
        for (0..ctx.samples_per_pixel) |_| {
            const ray = sampleRay(&ctx, col_idx);
            color += rayColor(ctx.entity, &ray, ctx.max_ray_bounce_depth, ctx.background_color);
        }
        ctx.mut.framebuffer[ctx.row_idx * ctx.num_cols + col_idx] = color * pixel_color_scale;
    }
}

/// Generates a random ray in a box around the current pixel (halfway to adjacent pixels).
fn sampleRay(ctx: *const RenderThreadContext, col_idx: usize) Ray {
    const tracy_zone = ztracy.ZoneN(@src(), "sampleRay");
    defer tracy_zone.End();

    const rand = rng.getThreadRng();

    // Create a ray originating from the defocus disk and directed at a randomly sampled point around the pixel.
    // - defocus disk sampling simulates depth of field
    // - sampling randomly around the pixel performs multisample antialiasing
    const offset =
        if (ctx.samples_per_pixel == 1) vec3(0, 0, 0) else rng.sampleSquareXY(rand);
    const sample = ctx.pixel00_loc + ctx.delta_u * math.vec3s(@as(Real, @floatFromInt(col_idx)) + offset[0]) + ctx.delta_v * math.vec3s(@as(Real, @floatFromInt(ctx.row_idx)) + offset[1]);

    const origin =
        if (ctx.defocus_angle <= 0.0) ctx.center else sampleDefocusDisk(ctx);
    const direction = sample - origin;
    const time = rand.float(Real);

    return Ray{
        .origin = origin,
        .direction = direction,
        .time = time,
    };
}

fn sampleDefocusDisk(ctx: *const RenderThreadContext) Vec3 {
    const p = rng.sampleUnitDiskXY(rng.getThreadRng(), 1.0);
    return ctx.center + math.vec3s(p[0]) * ctx.defocus_disk_u + math.vec3s(p[1]) * ctx.defocus_disk_v;
}

/// Computes the pixel color for the scene.
fn rayColor(entity: *const IEntity, ray: *const Ray, depth: usize, background_color: Color) Color {
    const tracy_zone = ztracy.ZoneN(@src(), "rayColor");
    defer tracy_zone.End();

    // Bounce recursion depth exceeded.
    if (depth == 0) return vec3( 0, 0, 0 );

    // Correction factor to ignore spurious hits due to floating point precision issues when the ray is very close to the surface.
    // This helps reduce z-fighting / shadow-acne issues.
    const ray_correction_factor = 1e-4;

    var record = HitRecord{};
    const ctx = HitContext{
        .ray = ray,
        .trange = Interval(Real){
            .min = ray_correction_factor,
            .max = std.math.inf(Real),
        },
    };

    // Ray hits nothing, return default
    if (!entity.hit(&ctx, &record)) {
        return background_color;
    }

    var ray_scattered: Ray = undefined;
    var attenuation_color = vec3( 1, 1, 1 );
    var ctx_scatter = ScatterContext{
        .random = rng.getThreadRng(),
        .ray_incoming = ray,
        .hit_record = &record,

        .mut = .{
            .ray_scattered = &ray_scattered,
            .attenuation = &attenuation_color,
        },
    };

    var emission_color = background_color;
    var scatter_color = vec3( 0, 0, 0 );
    if (record.material) |material| {
        // Emissive light sources.
        emission_color = material.emitted(record.tex_uv, &record.point);

        // Surface scattering.
        // Updates: hit_record, ray_scattered, attenuation
        if (!material.scatter(&ctx_scatter)) {
            return emission_color;
        }
        scatter_color = rayColor(entity, &ray_scattered, depth - 1, background_color) * attenuation_color;
    }

    return emission_color + scatter_color;
}

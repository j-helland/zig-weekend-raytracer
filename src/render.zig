const std = @import("std");

const ztracy = @import("ztracy");

const math = @import("math.zig");
const Real = @import("math.zig").Real;
const Color = @import("math.zig").Vec3;
const Point3 = @import("math.zig").Vec3;
const Vec3 = @import("math.zig").Vec3;

const Interval = @import("interval.zig").Interval;

const Ray = @import("ray.zig").Ray;
const HitRecord = @import("ray.zig").HitRecord;
const HitContext = @import("ray.zig").HitContext;
const ScatterContext = @import("ray.zig").ScatterContext;

const Camera = @import("camera.zig").Camera;
const Viewport = @import("camera.zig").Viewport;
const Framebuffer = @import("camera.zig").Framebuffer;
const IEntity = @import("entity.zig").IEntity;

const rng = @import("rng.zig");

pub const Renderer = struct {
    const Self = @This();

    thread_pool: *std.Thread.Pool,
    clear_color: Color,
    background_color: Color,
    samples_per_pixel: usize,
    max_ray_bounce_depth: usize,

    pub fn render(self: *const Self, camera: *const Camera, entity: *const IEntity, framebuffer: *Framebuffer) !void {
        const tracy_zone = ztracy.ZoneN(@src(), "Renderer::render");
        defer tracy_zone.End();

        framebuffer.clear(self.clear_color);

        var thread_wg = std.Thread.WaitGroup{};
        var render_thread_context = RenderThreadContext{
            .mut = .{
                .framebuffer = framebuffer,
            },

            .samples_per_pixel = self.samples_per_pixel,
            .max_ray_bounce_depth = self.max_ray_bounce_depth,
            .background_color = self.background_color,

            .entity = entity,
            .camera_position = camera.position,
            .viewport = &camera.getViewport(framebuffer),

            .b_is_depth_of_field = camera.b_is_depth_of_field,
            .defocus_disk_u = camera.defocus_disk_u,
            .defocus_disk_v = camera.defocus_disk_v,
        };

        const pixel_block_size = 32;

        // TODO: sample parallelism seems to have no performance impact
        const sample_partition_size = self.samples_per_pixel; 

        const image_width = framebuffer.num_cols;
        const image_height = framebuffer.num_rows;
        std.log.debug("w:{d} h:{d}", .{image_width, image_height});

        // var write_mutexes = std.ArrayList(std.Thread.Mutex).init(framebuffer.allocator);
        // defer write_mutexes.deinit();
        // try write_mutexes.ensureTotalCapacity((image_width * image_height) / pixel_block_size + 1);

        // Write pixels into shared image. No need to lock since the image is partitioned into non-overlapping lines.
        for (0..image_height) |v| {
            render_thread_context.row_idx = v;

            var idx_u: usize = 0;
            while (idx_u < image_width) : (idx_u += pixel_block_size) {

                // try write_mutexes.append(std.Thread.Mutex{});
                // render_thread_context.mut.mutex = &write_mutexes.items[write_mutexes.items.len - 1];

                var idx_sample: usize = 0;
                while (idx_sample < self.samples_per_pixel) : (idx_sample += sample_partition_size) {
                    // Handle uneven chunking.
                    render_thread_context.col_range = 
                        .{ .min = idx_u, .max = @min(image_width, idx_u + pixel_block_size) };
                    render_thread_context.sample_range = 
                        .{ .min = idx_sample, .max = @min(self.samples_per_pixel, idx_sample + sample_partition_size) };

                    self.thread_pool.spawnWg(&thread_wg, rayColorLine, .{render_thread_context});
                }
            }
        }
        self.thread_pool.waitAndWork(&thread_wg);
    }
};

/// Data required for each rendering thread to compute pixel color information.
const RenderThreadContext = struct {
    /// Keep mutable fields here for clarity.
    mut: struct {
        framebuffer: *Framebuffer,
        write_mutex: ?*std.Thread.Mutex = null,
    },

    // Rendering surface parameters.
    // These define a range that each thread can operate on without race conditions.
    row_idx: usize = 0,
    col_range: Interval(usize) = .{},
    sample_range: Interval(usize) = .{},

    // Raytracing parameters.
    max_ray_bounce_depth: usize,
    samples_per_pixel: usize,

    // View
    camera_position: Point3,
    viewport: *const Viewport,
    entity: *const IEntity,
    background_color: Color,

    b_is_depth_of_field: bool,
    defocus_disk_u: Vec3,
    defocus_disk_v: Vec3,
};

/// Raytraces a pixel line and writes the result into the framebuffer.
/// Wrapper around rayColor function for use in multithreaded.
fn rayColorLine(ctx: RenderThreadContext) void {
    const tracy_zone = ztracy.ZoneN(@src(), "rayColorLine");
    defer tracy_zone.End();

    const rand = rng.getThreadRng();

    const pixel_color_scale = math.vec3s(1.0 / @as(Real, @floatFromInt(ctx.samples_per_pixel)));

    for (ctx.col_range.min .. ctx.col_range.max) |col_idx| {
        var color = math.vec3(0, 0, 0);
        for (ctx.sample_range.min .. ctx.sample_range.max) |_| {
            const ray = sampleRay(rand, &ctx, col_idx);
            color += pixel_color_scale * rayColor(ctx.entity, &ray, ctx.max_ray_bounce_depth, ctx.background_color);
        }

        // framebuffer write
        if (ctx.mut.write_mutex) |mtx| mtx.lock();
        ctx.mut.framebuffer.buffer[ctx.row_idx * ctx.mut.framebuffer.num_cols + col_idx] += color;
        if (ctx.mut.write_mutex) |mtx| mtx.unlock();
    }
}

/// Generates a random ray in a box around the current pixel (halfway to adjacent pixels).
fn sampleRay(rand: std.Random, ctx: *const RenderThreadContext, col_idx: usize) Ray {
    const tracy_zone = ztracy.ZoneN(@src(), "sampleRay");
    defer tracy_zone.End();

    // Create a ray originating from the defocus disk and directed at a randomly sampled point around the pixel.
    // - defocus disk sampling simulates depth of field
    // - sampling randomly around the pixel performs multisample antialiasing
    const offset =
        if (ctx.samples_per_pixel == 1) 
            math.vec3(0, 0, 0) 
        else 
            rng.sampleSquareXY(rand);
    const sample = ctx.viewport.pixel00_loc 
        + ctx.viewport.pixel_delta_u * math.vec3s(@as(Real, @floatFromInt(col_idx)) + offset[0]) 
        + ctx.viewport.pixel_delta_v * math.vec3s(@as(Real, @floatFromInt(ctx.row_idx)) + offset[1]);

    const origin = 
        if (ctx.b_is_depth_of_field) 
            sampleDefocusDisk(rand, ctx)
        else 
            ctx.camera_position;
    const direction = sample - origin;
    const time = rand.float(Real);

    return Ray{
        .origin = origin,
        .direction = direction,
        .time = time,
    };
}

fn sampleDefocusDisk(rand: std.Random, ctx: *const RenderThreadContext) Vec3 {
    const p = rng.sampleUnitDiskXY(rand, 1.0);
    return ctx.camera_position 
        + math.vec3s(p[0]) * ctx.defocus_disk_u 
        + math.vec3s(p[1]) * ctx.defocus_disk_v;
}

/// Computes the pixel color for the scene.
fn rayColor(entity: *const IEntity, ray: *const Ray, depth: usize, background_color: Color) Color {
    const tracy_zone = ztracy.ZoneN(@src(), "rayColor");
    defer tracy_zone.End();

    // Bounce recursion depth exceeded.
    if (depth == 0) return math.vec3( 0, 0, 0 );

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
    var attenuation_color = math.vec3( 1, 1, 1 );
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
    var scatter_color = math.vec3( 0, 0, 0 );
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
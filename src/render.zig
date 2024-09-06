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

const ScatterContext = @import("material.zig").ScatterContext;

const Camera = @import("camera.zig").Camera;
const Viewport = @import("camera.zig").Viewport;
const Framebuffer = @import("camera.zig").Framebuffer;
const IEntity = @import("entity.zig").IEntity;

const rng = @import("rng.zig");

const smpl = @import("sampler.zig");
const pdf = @import("pdf.zig");

pub const Renderer = struct {
    const Self = @This();

    thread_pool: *std.Thread.Pool,
    clear_color: Color,
    background_color: Color,
    samples_per_pixel: usize,
    max_ray_bounce_depth: usize,
    important_entity: ?*const IEntity = null,

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
            .important_entity = self.important_entity,

            .entity = entity,
            .camera_position = camera.position,
            .viewport = &camera.getViewport(framebuffer),
            .background_color = self.background_color,

            .b_is_depth_of_field = camera.b_is_depth_of_field,
            .defocus_disk_u = camera.defocus_disk_u,
            .defocus_disk_v = camera.defocus_disk_v,
        };

        const pixel_block_size = 32;

        const image_width = framebuffer.num_cols;
        const image_height = framebuffer.num_rows;

        // Write pixels into shared image. No need to lock since the image is partitioned into non-overlapping lines.
        for (0..image_height) |v| {
            render_thread_context.row_idx = v;

            var idx_u: usize = 0;
            while (idx_u < image_width) : (idx_u += pixel_block_size) {
                // Handle uneven chunking.
                render_thread_context.col_range =
                    .{ .min = idx_u, .max = @min(image_width, idx_u + pixel_block_size) };

                self.thread_pool.spawnWg(&thread_wg, rayColorLine, .{render_thread_context});
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
    },

    // Rendering surface parameters.
    // These define a range that each thread can operate on without race conditions.
    row_idx: usize = 0,
    col_range: Interval(usize) = .{},

    // Raytracing parameters.
    samples_per_pixel: usize,
    max_ray_bounce_depth: usize,
    important_entity: ?*const IEntity,

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

    const seed = rand.int(u32);
    // const spp = std.math.ceilPowerOfTwo(usize, ctx.samples_per_pixel) 
    //     catch @panic("Failed to initialize sobol sampler");
    var sampler = smpl.SobolSampler(Real).initSampler(
        ctx.samples_per_pixel,
        @intCast(ctx.mut.framebuffer.num_cols),
        @intCast(ctx.mut.framebuffer.num_rows),
        .owen_fast,
        seed,
    ) catch @panic("Failed to initialized sobol sampler");
    // var sampler = smpl.StratifiedSampler(Real).initSampler(
    //     rand,
    //     ctx.sqrt_spp,
    //     ctx.recip_sqrt_spp,
    // );
    // var sampler = smpl.IndependentSampler(Real).initSampler(rand);

    const pixel_color_scale = math.vec3s(1.0 / @as(Real, @floatFromInt(ctx.samples_per_pixel)));
    for (ctx.col_range.min..ctx.col_range.max) |col_idx| {
        var color = math.vec3(0, 0, 0);

        for (0..ctx.samples_per_pixel) |sample_idx| {
            var ray = sampleRay(rand, &ctx, col_idx, sample_idx, &sampler);
            color += rayColor(
                ctx.entity, 
                &ray, 
                ctx.max_ray_bounce_depth, 
                ctx.background_color, 
                ctx.important_entity,
            ) * pixel_color_scale;
        }

        // framebuffer write
        ctx.mut.framebuffer.buffer[ctx.row_idx * ctx.mut.framebuffer.num_cols + col_idx] += color;
    }
}

/// Generates a random ray in a box around the current pixel (halfway to adjacent pixels).
fn sampleRay(
    rand: std.Random,
    ctx: *const RenderThreadContext,
    col_idx: usize,
    sample_idx: usize,
    sampler: *smpl.ISampler(Real),
) Ray {
    const tracy_zone = ztracy.ZoneN(@src(), "sampleRay");
    defer tracy_zone.End();

    // Create a ray originating from the defocus disk and directed at a randomly sampled point around the pixel.
    // - defocus disk sampling simulates depth of field
    // - sampling randomly around the pixel performs multisample antialiasing
    sampler.startPixelSample(.{ col_idx, ctx.row_idx }, sample_idx);
    const offset = sampler.getPixel2D();
    const sample = ctx.viewport.pixel00_loc + ctx.viewport.pixel_delta_u * math.vec3s(@as(Real, @floatFromInt(col_idx)) + offset[0]) + ctx.viewport.pixel_delta_v * math.vec3s(@as(Real, @floatFromInt(ctx.row_idx)) + offset[1]);

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

fn sampleSquareStratified(rand: std.Random, ctx: *const RenderThreadContext, si: usize, sj: usize) Vec3 {
    const px = (rand.float(Real) + @as(Real, @floatFromInt(si))) * ctx.recip_sqrt_spp - 0.5;
    const py = (rand.float(Real) + @as(Real, @floatFromInt(sj))) * ctx.recip_sqrt_spp - 0.5;
    return math.vec3(px, py, 0);
}

fn sampleDefocusDisk(rand: std.Random, ctx: *const RenderThreadContext) Vec3 {
    const p = rng.sampleUnitDiskXY(rand, 1.0);
    return ctx.camera_position + math.vec3s(p[0]) * ctx.defocus_disk_u + math.vec3s(p[1]) * ctx.defocus_disk_v;
}

/// Computes the pixel color for the scene.
fn rayColor(
    entity: *const IEntity,
    ray: *const Ray,
    depth: usize,
    background_color: Color,
    important_entity: ?*const IEntity,
) Color {
    const tracy_zone = ztracy.ZoneN(@src(), "rayColor");
    defer tracy_zone.End();

    // Bounce recursion depth exceeded.
    if (depth == 0) return math.vec3(0, 0, 0);

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
    var attenuation_color = math.vec3(1, 1, 1);
    var pdf_value: Real = 0.0;
    var ctx_scatter = ScatterContext{
        .random = rng.getThreadRng(),
        .ray_incoming = ray,
        .hit_record = &record,

        .mut = .{
            .ray_scattered = &ray_scattered,
            .attenuation = &attenuation_color,
            .pdf_value = &pdf_value,
        },
    };

    var emission_color = background_color;
    var scatter_color = math.vec3(0, 0, 0);
    if (record.material) |material| {
        // Emissive light sources.
        emission_color = material.emitted(&record, record.tex_uv);

        // Surface scattering.
        // Updates: hit_record, ray_scattered, attenuation
        if (!material.scatter(&ctx_scatter)) {
            return emission_color;
        }

        std.debug.assert(important_entity != null);
        const entity_pdf = pdf.EntityPdf.initPdf(ctx_scatter.random, important_entity.?, record.point);
        const cosine_pdf = pdf.CosinePdf.initPdf(ctx_scatter.random, record.normal);
        const surface_pdf = pdf.MixturePdf.initPdf(ctx_scatter.random, &entity_pdf, &cosine_pdf);

        ray_scattered = Ray{
            .origin = record.point,
            .direction = surface_pdf.generate(),
            .time = ray.time,
        };
        pdf_value = surface_pdf.value(ray_scattered.direction);

        // // TODO: hack in light importance sampling
        // const on_light = math.vec3(
        //     ctx_scatter.random.float(math.Real) * (343.0 - 213.0) + 213.0,
        //     554,
        //     ctx_scatter.random.float(math.Real) * (332.0 - 227.0) + 227.0,
        // );
        // var to_light = on_light - record.point;
        // const dist_sq = math.dot(to_light, to_light);
        // to_light = math.normalize(to_light);

        // if (math.dot(to_light, record.normal) < 0) {
        //     return emission_color;
        // }

        // const light_area = (343.0 - 213.0) * (332.0 - 227.0);
        // const light_cos = @abs(to_light[1]);
        // if (light_cos < 1e-6) {
        //     return emission_color;
        // }

        // pdf_value = dist_sq / (light_cos * light_area);
        // ray_scattered = Ray{
        //     .origin = record.point,
        //     .direction = to_light,
        //     .time = ray.time,
        // };

        // importance sampling density function
        const scattering_pdf = material.scatteringPdf(&ctx_scatter);
        // pdf_value = scattering_pdf;

        scatter_color = rayColor(entity, &ray_scattered, depth - 1, background_color, important_entity);
        scatter_color *= (attenuation_color * math.vec3s(scattering_pdf));
        scatter_color /= math.vec3s(pdf_value);
    }

    return emission_color + scatter_color;
}

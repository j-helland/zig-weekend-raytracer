const std = @import("std");

const ztracy = @import("ztracy");

const math = @import("math/math.zig");
const pdf = @import("pdf.zig");

const SobolSampler = math.rng.sampler.SobolSampler;

const HitRecord = @import("hitrecord.zig").HitRecord;
const HitContext = @import("hitrecord.zig").HitContext;
const ScatterRecord = @import("material.zig").ScatterRecord;

const Camera = @import("camera.zig").Camera;
const Viewport = @import("camera.zig").Viewport;
const Framebuffer = @import("camera.zig").Framebuffer;
const IEntity = @import("entity.zig").IEntity;

pub const Renderer = struct {
    const Self = @This();

    thread_pool: *std.Thread.Pool,
    clear_color: math.Color,
    background_color: math.Color,
    samples_per_pixel: usize,
    max_ray_bounce_depth: usize,
    light_entities: ?*const IEntity = null,

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
            .light_entities = self.light_entities,

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
    col_range: math.Interval(usize) = .{},

    // math.Raytracing parameters.
    samples_per_pixel: usize,
    max_ray_bounce_depth: usize,
    light_entities: ?*const IEntity,

    // View
    camera_position: math.Point3,
    viewport: *const Viewport,
    entity: *const IEntity,
    background_color: math.Color,

    b_is_depth_of_field: bool,
    defocus_disk_u: math.Vec3,
    defocus_disk_v: math.Vec3,
};

/// math.Raytraces a pixel line and writes the result into the framebuffer.
/// Wrapper around raymath.Color function for use in multithreaded.
fn rayColorLine(ctx: RenderThreadContext) void {
    const tracy_zone = ztracy.ZoneN(@src(), "raymath.ColorLine");
    defer tracy_zone.End();

    const rand = math.rng.getThreadRng();
    const seed = rand.int(u32);
    // const spp = std.math.ceilPowerOfTwo(usize, ctx.samples_per_pixel)
    //     catch @panic("Failed to initialize sobol sampler");
    var sampler = SobolSampler(math.Real).initSampler(
        ctx.samples_per_pixel,
        @intCast(ctx.mut.framebuffer.num_cols),
        @intCast(ctx.mut.framebuffer.num_rows),
        .owen_fast,
        seed,
    ) catch @panic("Failed to initialized sobol sampler");

    const pixel_color_scale = math.vec3s(1.0 / @as(math.Real, @floatFromInt(ctx.samples_per_pixel)));
    for (ctx.col_range.min..ctx.col_range.max) |col_idx| {
        var color = math.vec3(0, 0, 0);

        for (0..ctx.samples_per_pixel) |sample_idx| {
            var ray = sampleRay(rand, &ctx, col_idx, sample_idx, &sampler);
            color += rayColor(
                ctx.entity,
                &ray,
                ctx.max_ray_bounce_depth,
                ctx.background_color,
                ctx.light_entities,
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
    sampler: *math.rng.sampler.ISampler(math.Real),
) math.Ray {
    const tracy_zone = ztracy.ZoneN(@src(), "samplemath.Ray");
    defer tracy_zone.End();

    // Create a ray originating from the defocus disk and directed at a randomly sampled point around the pixel.
    // - defocus disk sampling simulates depth of field
    // - sampling randomly around the pixel performs multisample antialiasing
    sampler.startPixelSample(.{ col_idx, ctx.row_idx }, sample_idx);
    const offset = sampler.getPixel2D();
    const sample = ctx.viewport.pixel00_loc + ctx.viewport.pixel_delta_u * math.vec3s(@as(math.Real, @floatFromInt(col_idx)) + offset[0]) + ctx.viewport.pixel_delta_v * math.vec3s(@as(math.Real, @floatFromInt(ctx.row_idx)) + offset[1]);

    const origin =
        if (ctx.b_is_depth_of_field)
        sampleDefocusDisk(rand, ctx)
    else
        ctx.camera_position;
    const direction = sample - origin;
    const time = rand.float(math.Real);

    return math.Ray{
        .origin = origin,
        .direction = direction,
        .time = time,
    };
}

fn sampleSquareStratified(rand: std.Random, ctx: *const RenderThreadContext, si: usize, sj: usize) math.Vec3 {
    const px = (rand.float(math.Real) + @as(math.Real, @floatFromInt(si))) * ctx.recip_sqrt_spp - 0.5;
    const py = (rand.float(math.Real) + @as(math.Real, @floatFromInt(sj))) * ctx.recip_sqrt_spp - 0.5;
    return math.vec3(px, py, 0);
}

fn sampleDefocusDisk(rand: std.Random, ctx: *const RenderThreadContext) math.Vec3 {
    const p = math.rng.sampleUnitDiskXY(rand, 1.0);
    return ctx.camera_position + math.vec3s(p[0]) * ctx.defocus_disk_u + math.vec3s(p[1]) * ctx.defocus_disk_v;
}

/// Computes the pixel color for the scene.
fn rayColor(
    entity: *const IEntity,
    ray: *const math.Ray,
    depth: usize,
    background_color: math.Color,
    light_entities: ?*const IEntity,
) math.Color {
    const tracy_zone = ztracy.ZoneN(@src(), "raymath.Color");
    defer tracy_zone.End();

    // Bounce recursion depth exceeded.
    if (depth == 0) return math.vec3(0, 0, 0);

    // Correction factor to ignore spurious hits due to floating point precision issues when the ray is very close to the surface.
    // This helps reduce z-fighting / shadow-acne issues.
    const ray_correction_factor = 1e-4;

    var record = HitRecord{};
    const ctx = HitContext{
        .ray = ray,
        .trange = math.Interval(math.Real){
            .min = ray_correction_factor,
            .max = std.math.inf(math.Real),
        },
    };

    // math.Ray hits nothing, return default
    if (!entity.hit(&ctx, &record)) {
        return background_color;
    }

    var attenuation_color = math.vec3(1, 1, 1);
    var ctx_scatter = ScatterRecord{
        .random = math.rng.getThreadRng(),
        .ray_incoming = ray,
        .hit_record = &record,

        .mut = .{
            .attenuation = &attenuation_color,
        },
    };

    var emission_color = background_color;
    var scatter_color = math.vec3(0, 0, 0);
    if (record.material) |material| {
        // Emissive light sources.
        emission_color = material.emitted(&record, record.tex_uv);

        // No scattering (e.g. emissive surface hit).
        // This can modify the ctx_scatter.mut fields.
        if (!material.scatter(&ctx_scatter)) {
            return emission_color;
        }

        // Material specifies no importance sampling (e.g. specular materials like mirrors).
        if (ctx_scatter.mut.ray_specular) |*ray_specular| {
            std.debug.assert(material.isSpecular());
            return attenuation_color * rayColor(entity, ray_specular, depth - 1, background_color, light_entities);
        }

        // If no objects in the scene provide importance sampling PDFs, default to a cosine distribution oriented by the surface normal.
        var ray_scattered = math.Ray{
            .origin = record.point,
            .direction = undefined,
            .time = ray.time,
        };
        const scatter_direction_pdf_value = if (light_entities) |lights| blk: {
            std.debug.assert(ctx_scatter.mut.pdf != null);
            std.debug.assert(ctx_scatter.mut.ray_specular == null);

            const light_pdf = pdf.EntityPdf.initPdf(ctx_scatter.random, lights, record.point);
            const surface_pdf = pdf.MixturePdf.initPdf(ctx_scatter.random, &light_pdf, &ctx_scatter.mut.pdf.?);

            ray_scattered.direction = surface_pdf.generate();
            break :blk surface_pdf.value(ray_scattered.direction);

        } else blk: {
            const surface_pdf = pdf.CosinePdf.initPdf(ctx_scatter.random, record.normal);

            ray_scattered.direction = surface_pdf.generate();
            break :blk surface_pdf.value(ray_scattered.direction);
        };

        // importance sampled monte carlo estimate of rendering equation:
        // color = emittance + \int_hemisphere BRDF * radiance_color * cos(theta)
        //    where BRDF = (albedo * material_scatter_pdf) / cos(theta)
        // => color = emittance + \int_hemisphere (albedo * material_scatter_pdf * radiance_color) / sampling_pdf
        //
        // - The hemisphere is oriented by the surface normal.
        // - Emittance is directly taken from the material emittance function.
        // - Radiance color is computed by the ray bouncing through the scene and collecting color.
        // - Albedo is the attenuation color, which represents the probability of light being absorbed vs reflected.
        scatter_color = rayColor(entity, &ray_scattered, depth - 1, background_color, light_entities);

        const scatter_position_pdf_value = material.scatteringPdf(&ctx_scatter, &ray_scattered);
        scatter_color *= (attenuation_color * math.vec3s(scatter_position_pdf_value));

        scatter_color /= math.vec3s(scatter_direction_pdf_value);
    }

    return emission_color + scatter_color;
}

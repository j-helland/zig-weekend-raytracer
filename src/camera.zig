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

const rng = @import("rng.zig");

threadlocal var g_RNG: ?std.Random.DefaultPrng = null;
fn getThreadRng() std.Random {
    if (g_RNG == null) {
        g_RNG = rng.createRng(null) 
            catch @panic("Could not get threadlocal RNG");
    }
    return g_RNG.?.random();
}

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

    pub fn write(self: *const Self, allocator: std.mem.Allocator, writer: *const std.fs.File.Writer) !void {
        // PPM header.
        try writer.print(PPM_HEADER_FMT, .{self.num_cols, self.num_rows});        

        // Write image to buffer and print to file all at once to minimize system calls.
        // This speeds up image writing to near-instant.
        var buf = try allocator.alloc(u8, self.buffer.len * PPM_PIXEL_NUM_BYTES);
        defer allocator.free(buf);

        var buf_idx: usize = 0;
        for (0..self.num_rows) |v| {
            for (0..self.num_cols) |u| {
                const color = encodeColor(self.buffer[self.num_cols * v + u]);
                const result = try std.fmt.bufPrint(buf[buf_idx..], "{d} {d} {d}\n", .{color[0], color[1], color[2]});
                buf_idx += result.len;
            }
        }

        try writer.writeAll(buf);
    }
};

pub const Camera = struct {
    const Self = @This();

    aspect_ratio: Real = 1.0,
    image_width: usize = 200,
    image_height: usize = 100,
    samples_per_pixel: usize = 100,
    max_ray_bounce_depth: usize = 50,
    center: Point3,
    pixel00_loc: Point3,
    pixel_delta_u: Vec3,
    pixel_delta_v: Vec3,
    thread_pool: *std.Thread.Pool,

    pub fn init(thread_pool: *std.Thread.Pool, img_width: usize, img_height: usize, focal_length: Real) Self {
        const aspect_ratio = (@as(Real, @floatFromInt(img_width)) / @as(Real, @floatFromInt(img_height)));
        const viewport_height = 2.0;
        const viewport_width = viewport_height * aspect_ratio;
        const camera_center = Point3{0, 0, 0};

        const viewport_u = Vec3{viewport_width, 0, 0}; // horizontal right
        const viewport_v = Vec3{0, -viewport_height, 0}; // vertical downwards

        const pixel_delta_u = viewport_u / math.vec3s(@floatFromInt(img_width));
        const pixel_delta_v = viewport_v / math.vec3s(@floatFromInt(img_height));

        // upper left pixel location
        const viewport_upper_left = camera_center 
            - Vec3{0, 0, focal_length} 
            - viewport_u / math.vec3s(2) 
            - viewport_v / math.vec3s(2);
        const pixel00_loc = viewport_upper_left + math.vec3s(0.5) * (pixel_delta_u + pixel_delta_v);        

        return .{
            .aspect_ratio = aspect_ratio,
            .image_width = img_width, 
            .image_height = img_height,
            .center = camera_center,
            .pixel00_loc = pixel00_loc,
            .pixel_delta_u = pixel_delta_u,
            .pixel_delta_v = pixel_delta_v,
            .thread_pool = thread_pool,
        };
    }

    pub fn render(self: *const Self, entity: *const Entity, framebuffer: *Framebuffer) !void {
        // const framebuffer = try self.thread_pool.allocator.alloc(Color, self.image_height * self.image_width);
        // defer self.thread_pool.allocator.free(framebuffer);
        var wg = std.Thread.WaitGroup{};

        // Similar to GPU 4x4 pixel shading work groups, except that here we use row-major order lines.
        const block_size = 16;
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
            .samples_per_pixel = self.samples_per_pixel,
            .max_ray_bounce_depth = self.max_ray_bounce_depth,
        };

        // Write pixels into shared image. No need to lock since the image is partitioned into non-overlapping lines.
        for (0..self.image_height) |v| {
            render_thread_context.row_idx = v;

            var idx_u: usize = 0;
            while (idx_u < self.image_width) : (idx_u += block_size) {
                render_thread_context.col_range = .{ .min = idx_u, .max = idx_u + block_size };
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
        else rng.sampleSquareXY(getThreadRng());
    const sample = ctx.pixel00_loc 
        + ctx.delta_u * Vec3{@as(Real, @floatFromInt(col_idx)) + offset[0], 0, 0}
        + ctx.delta_v * Vec3{0, @as(Real, @floatFromInt(ctx.row_idx)) + offset[1], 0};

    const origin = ctx.center;
    const direction = sample - origin;
    const ray = Ray{ .origin = origin, .direction = direction };
    return ray;
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
        // Lambertian diffusion: spherical lobe biases reflection directions to be proportional to cos(theta), 
        // theta = angle between surface normal and light direction (incoming ray!).
        const bounce_direction = record.normal + rng.sampleUnitSphere(getThreadRng());
        const origin = record.point;
        const bounce_ray = Ray{ .origin = origin, .direction = bounce_direction };
        return math.vec3s(0.5) * rayColor(entity, &bounce_ray, depth - 1);
    } 

    const dn = math.normalize(ray.direction);
    const alpha = 0.5 * (dn[1] + 1.0);
    return math.lerp(Color{1, 1, 1}, Color{0.5, 0.7, 1.0}, alpha);
}

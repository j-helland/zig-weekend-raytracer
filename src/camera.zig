const std = @import("std");
const WriteError = std.fs.File.WriteError;

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Color = math.Vec3;
const Point3 = math.Vec3;

const ent = @import("entity.zig");
const Entity = ent.Entity;
const Ray = ent.Ray;
const HitRecord = ent.HitRecord;
const HitContext = ent.HitContext;

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

    aspect_ratio: f32 = 1.0,
    image_width: usize = 200,
    image_height: usize = 100,
    center: Point3,
    pixel00_loc: Point3,
    pixel_delta_u: Vec3,
    pixel_delta_v: Vec3,
    thread_pool: *std.Thread.Pool,

    pub fn init(thread_pool: *std.Thread.Pool, img_width: usize, img_height: usize, focal_length: f32) Self {
        const aspect_ratio = (@as(f32, @floatFromInt(img_width)) / @as(f32, @floatFromInt(img_height)));
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
        std.debug.assert(self.image_height % block_size == 0);

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
        };

        // Write pixels into shared image. No need to lock since the image is partitioned into non-overlapping lines.
        for (0..self.image_height) |v| {
            std.log.debug("Scanlines remaining: {}", .{self.image_height - v});
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
};

fn encodeColor(color: Color) [3]u8 {
    const rgb_factor = 255.999;
    const ir = @as(u8, @intFromFloat(color[0] * rgb_factor));
    const ig = @as(u8, @intFromFloat(color[1] * rgb_factor));
    const ib = @as(u8, @intFromFloat(color[2] * rgb_factor));
    return .{ir, ig, ib};
}

/// Raytraces a pixel line and writes the result into the framebuffer.
/// Wrapper around rayColor function for use in multithreaded.
fn rayColorLine(ctx: RenderThreadContext) void {
    for (ctx.col_range.min..ctx.col_range.max) |u| {
        const pixel_center = ctx.pixel00_loc 
            + ctx.delta_u * math.vec3s(@floatFromInt(u)) 
            + ctx.delta_v * math.vec3s(@floatFromInt(ctx.row_idx));
        const ray_direction = pixel_center - ctx.center;
        const ray = Ray{ .origin = ctx.center, .direction = ray_direction };

        rayColor(&ray, ctx.entity, ctx.framebuffer, ctx.row_idx, u, ctx.num_cols);
    }
}

/// Does the actual raytracing work.
fn rayColor(ray: *const Ray, entity: *const Entity, image: []Color, row_idx: usize, col_idx: usize, num_cols: usize) void {
    var record = HitRecord{};
    const ctx = HitContext{
        .ray = ray,
        .trange = math.Interval(f32){ .min = 0, .max = std.math.inf(f32) },
    };

    var color: Color = undefined;
    if (entity.hit(ctx, &record)) {
        color = math.vec3s(0.5) * (record.normal + math.vec3s(1.0));

    } else {
        const dn = math.normalize(ray.direction);
        const alpha = 0.5 * (dn[1] + 1.0);
        color = math.lerp(Color{1, 1, 1}, Color{0.5, 0.7, 1.0}, alpha);
    }

    image[row_idx * num_cols + col_idx] = color;
}

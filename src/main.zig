const std = @import("std");
const AllocatorError = std.mem.Allocator.Error;

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Point3 = Vec3;
const Color = Vec3;
const vec3s = math.vec3s;

pub const HitRecord = struct {
    const Self = @This();

    point: Point3 = .{0, 0, 0},
    normal: Vec3 = .{0, 0, 0},
    t: f32 = std.math.inf(f32),
    b_front_face: bool = false,

    pub fn setFrontFaceNormal(self: *Self, ray: *const Ray, outward_normal: Vec3) void {
        self.b_front_face = (math.dot(ray.direction, outward_normal) < 0.0);
        self.normal = 
            if (self.b_front_face) outward_normal 
            else -outward_normal;
    } 
};

pub const HitContext = struct {
    ray: *const Ray,
    tmin: f32,
    tmax: f32,
};

pub const Entity = union(enum) {
    const Self = @This();

    sphere: SphereEntity,
    collection: EntityCollection,

    pub fn hit(self: Self, ctx: HitContext, hit_record: *HitRecord) bool {
        return switch (self) {
            .sphere => |e| e.hit(ctx, hit_record),
            .collection => |e| e.hit(ctx, hit_record)
        };
    }
};

pub const EntityCollection = struct {
    const Self = @This();

    entities: std.ArrayList(Entity),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .entities = std.ArrayList(Entity).init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.entities.deinit();
    }

    pub fn add(self: *Self, entity: Entity) AllocatorError!void {
        try self.entities.append(entity);
    }

    pub fn hit(self: *const Self, _ctx: HitContext, hit_record: *HitRecord) bool {
        var ctx = _ctx;
        var hit_record_tmp  = HitRecord{};
        var b_hit_anything = false;
        var closest_t = ctx.tmax;

        for (self.entities.items) |*entity| {
            if (entity.hit(ctx, &hit_record_tmp)) {
                b_hit_anything = true;
                closest_t = hit_record_tmp.t;
                ctx.tmax = closest_t;

                // We know this hit is closest because we already reduced the search range bound tmax.
                hit_record.* = hit_record_tmp;
            }
        }

        return b_hit_anything;
    }
};

pub const SphereEntity = struct {
    const Self = @This();

    center: Point3,
    radius: f32,

    pub fn hit(self: *const Self, ctx: HitContext, hit_record: *HitRecord) bool {
        // direction from ray to sphere center
        const oc = self.center - ctx.ray.origin;
        // Detect polynomial roots for ray / sphere intersection equation (cx-x)^2 + (cy-y)^2 + (cz-z)^2 = r^2 = (c - p(t)) . (c - p(t))
        const a = math.dot(ctx.ray.direction, ctx.ray.direction);
        const h = math.dot(ctx.ray.direction, oc);
        const c = math.dot(oc, oc) - self.radius * self.radius;
        const discriminant = h*h - a*c;

        if (discriminant < 0.0) return false;

        const disc_sqrt = @sqrt(discriminant);
        var root = (h - disc_sqrt) / a;
        if ((root <= ctx.tmin) or (ctx.tmax <= root)) {
            root = (h + disc_sqrt) / a;
            if ((root <= ctx.tmin) or (ctx.tmax <= root)) {
                return false;
            }
        }

        hit_record.t = root;
        hit_record.point = ctx.ray.at(hit_record.t);
        const outward_normal = (hit_record.point - self.center) / vec3s(self.radius);
        hit_record.setFrontFaceNormal(ctx.ray, outward_normal);

        return true;
    }
};

pub const Ray = struct {
    const Self = @This();

    origin: Point3,
    direction: Vec3,

    pub fn at(self: *const Self, t: f32) Point3 {
        return self.origin + vec3s(t) * self.direction;
    }
};

fn writeColor(writer: *const std.fs.File.Writer, color: *const Vec3) !void {
    const rgb_factor = 255.999;
    const ir = @as(u8, @intFromFloat(color[0] * rgb_factor));
    const ig = @as(u8, @intFromFloat(color[1] * rgb_factor));
    const ib = @as(u8, @intFromFloat(color[2] * rgb_factor));
    try writer.print("{} {} {}\n", .{ir, ig, ib}); 
}

fn rayColor(ray: *const Ray, entity: *const Entity) Vec3 {
    const ctx = HitContext{ 
        .ray = ray, 
        .tmin = 0.0, 
        .tmax = std.math.inf(f32),
    };
    var record = HitRecord{};
    if (entity.hit(ctx, &record)) {
        return vec3s(0.5) * (record.normal + vec3s(1.0));
    }

    const d = math.normalize(ray.direction);
    const a = 0.5 * (d[1] + 1.0);
    return vec3s(1.0 - a) * Color{1, 1, 1} + vec3s(a) * Color{0.5, 0.7, 1.0}; 
}

pub fn main() !void {
    const img_width = 800;
    const img_height = 400;

    // camera
    const focal_length = 1.0;
    const viewport_height = 2.0;
    const viewport_width = viewport_height * (@as(f32, @floatFromInt(img_width)) / @as(f32, @floatFromInt(img_height)));
    const camera_center = Point3{0, 0, 0};

    const viewport_u = Vec3{viewport_width, 0, 0}; // horizontal right
    const viewport_v = Vec3{0, -viewport_height, 0}; // vertical downwards

    const pixel_delta_u = viewport_u / vec3s(img_width);
    const pixel_delta_v = viewport_v / vec3s(img_height);

    // upper left pixel location
    const viewport_upper_left = camera_center 
        - Vec3{0, 0, focal_length} 
        - viewport_u / vec3s(2) 
        - viewport_v / vec3s(2);
    const pixel00_loc = viewport_upper_left + vec3s(0.5) * (pixel_delta_u + pixel_delta_v);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("P3\n{} {}\n255\n", .{img_width, img_height});

    // ---- allocator ----
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ---- scene initialization ----
    var scene = EntityCollection.init(allocator);
    defer scene.deinit();

    try scene.add(Entity{ .sphere = SphereEntity{ .center = Point3{0, 0, -1}, .radius = 0.5 } });
    try scene.add(Entity{ .sphere = SphereEntity{ .center = Point3{0, -100.5, -1}, .radius = 100.0 } });

    const world = Entity{ .collection = scene };

    // ---- rendering pass ----
    for (0..img_height) |v| {
        std.log.info("Scanlines remaining: {}", .{img_height - v});

        for (0..img_width) |u| {
            const pixel_center = pixel00_loc + pixel_delta_u * vec3s(@floatFromInt(u)) + pixel_delta_v * vec3s(@floatFromInt(v));
            const ray_direction = pixel_center - camera_center;
            const ray = Ray{ .origin = camera_center, .direction = ray_direction };
            const color = rayColor(&ray, &world);

            try writeColor(&stdout, &color);
        }
    }

    std.log.info("DONE", .{});
}


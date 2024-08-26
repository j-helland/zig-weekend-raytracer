const std = @import("std");

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Point3 = Vec3;
const Color = Vec3;
const vec3s = math.vec3s;

pub const HitRecord = struct {
    point: Point3 = .{0, 0, 0},
    normal: Vec3 = .{0, 0, 0},
    t: f32 = 0.0,
};

pub const Entity = union(enum) {
    const Self = @This();

    sphere: SphereEntity,

    pub fn hit(self: Self, ray: *const Ray, tmin: f32, tmax: f32, hit_record: *HitRecord) bool {
        return switch (self) {
            .sphere => |e| e.hit(ray, tmin, tmax, hit_record),
        };
    }
};

pub const SphereEntity = struct {
    const Self = @This();

    center: Point3,
    radius: f32,

    pub fn hit(self: *const Self, ray: *const Ray, tmin: f32, tmax: f32, hit_record: *HitRecord) bool {
        // direction from ray to sphere center
        const oc = self.center - ray.origin;
        // Detect polynomial roots for ray / sphere intersection equation (cx-x)^2 + (cy-y)^2 + (cz-z)^2 = r^2 = (c - p(t)) . (c - p(t))
        const a = math.dot(ray.direction, ray.direction);
        const h = math.dot(ray.direction, oc);
        const c = math.dot(oc, oc) - self.radius * self.radius;
        const discriminant = h*h - a*c;

        if (discriminant < 0.0) return false;

        const disc_sqrt = @sqrt(discriminant);
        var root = (h - disc_sqrt) / a;
        if ((root <= tmin) or (root >= tmax)) {
            root = (h + disc_sqrt) / a;
            if ((root <= tmin) or (root >= tmax)) {
                return false;
            }
        }

        hit_record.t = root;
        hit_record.point = ray.at(hit_record.t);
        hit_record.normal = (hit_record.point - self.center) / vec3s(self.radius);

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

fn rayColor(ray: *const Ray) Vec3 {
    const sphere = Entity{ .sphere = SphereEntity{ .center = .{0, 0, -1}, .radius = 0.5 } };

    var hit_record = HitRecord{};
    if (sphere.hit(ray, 0.0, 1.0, &hit_record)) {
        return vec3s(0.5) * (hit_record.normal + vec3s(1.0));
    }

    const d = math.normalize(ray.direction);
    const a = 0.5 * (d[1] + 1.0);
    return vec3s(1.0 - a) * Color{1, 1, 1} + vec3s(a) * Color{0.5, 0.7, 1.0}; 
}

fn sphereHit(ray: *const Ray, center: Point3, radius: f32) f32 {
    // direction from ray to sphere center
    const oc = center - ray.origin;
    // Detect polynomial roots for ray / sphere intersection equation (cx-x)^2 + (cy-y)^2 + (cz-z)^2 = r^2 = (c - p(t)) . (c - p(t))
    const a = math.dot(ray.direction, ray.direction);
    const h = math.dot(ray.direction, oc);
    const c = math.dot(oc, oc) - radius * radius;
    const discriminant = h*h - a*c;

    if (discriminant < 0) {
        return -1.0;
    } else {
        return (h - @sqrt(discriminant)) / a;
    }
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

    for (0..img_height) |v| {
        std.log.info("Scanlines remaining: {}", .{img_height - v});

        for (0..img_width) |u| {
            const pixel_center = pixel00_loc + pixel_delta_u * vec3s(@floatFromInt(u)) + pixel_delta_v * vec3s(@floatFromInt(v));
            const ray_direction = pixel_center - camera_center;
            const ray = Ray{ .origin = camera_center, .direction = ray_direction };
            const color = rayColor(&ray);

            try writeColor(&stdout, &color);
        }
    }

    std.log.info("DONE", .{});
}


const std = @import("std");

const math = @import("math.zig");
const Real = @import("math.zig").Real;
const Vec3 = @import("math.zig").Vec3;
const Color = @import("math.zig").Vec3;
const Point3 = @import("math.zig").Vec3;

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

    pub fn clear(self: *Self, clear_color: Color) void {
        for (self.buffer) |*c| c.* = clear_color;
    }

    pub fn getAspectRatio(self: *const Self) Real {
        const numerator = @as(Real, @floatFromInt(self.num_cols));
        const denominator = @as(Real, @floatFromInt(self.num_rows));
        return numerator / denominator;
    }
};

pub const CoordinateBasis = struct {
    u: Vec3,
    v: Vec3,
    w: Vec3,
};

pub const Camera = struct {
    const Self = @This();

    coordinate_basis: CoordinateBasis,
    position: Point3,
    fov_vertical: Real,

    b_is_depth_of_field: bool,
    lens_focus_dist: Real,
    defocus_radius: Vec3,
    defocus_disk_u: Vec3,
    defocus_disk_v: Vec3,

    pub fn init(
        look_from: Point3, 
        look_at: Point3, 
        view_up: Vec3,
        fov_vertical: Real,
        lens_focus_dist: Real,
        defocus_angle_degrees: Real,
    ) Self {
        // coordinate frame basis vectors
        const w = math.normalize(look_from - look_at);
        const u = math.normalize(math.cross(view_up, w));
        const v = math.cross(w, u);

        // calculate camera defocus disk basis vectors
        const defocus_radius = math.vec3s(lens_focus_dist * @tan(std.math.degreesToRadians(defocus_angle_degrees / 2.0)));
        const defocus_disk_u = u * defocus_radius;
        const defocus_disk_v = v * defocus_radius; 

        return Self{
            .coordinate_basis = CoordinateBasis{ .u = u, .v = v, .w = w },
            .position = look_from,
            .fov_vertical = fov_vertical,

            .b_is_depth_of_field = (defocus_angle_degrees > 0.0),
            .lens_focus_dist = lens_focus_dist,
            .defocus_radius = defocus_radius,
            .defocus_disk_u = defocus_disk_u,
            .defocus_disk_v = defocus_disk_v,
        };
    }

    pub fn getViewport(self: *const Self, framebuffer: *const Framebuffer) Viewport {
        return Viewport.init(
            framebuffer.num_cols,
            framebuffer.num_rows,
            framebuffer.getAspectRatio(),
            self.fov_vertical,
            self.lens_focus_dist,
            self.position,
            &self.coordinate_basis,
        );
    }
};

pub const Viewport = struct {
    const Self = @This();

    width: Real,
    height: Real,
    upper_left_corner: Point3,
    u: Vec3,
    v: Vec3,
    pixel_delta_u: Vec3,
    pixel_delta_v: Vec3,
    pixel00_loc: Point3,

    pub fn init(
        image_width: usize,
        image_height: usize,
        aspect_ratio: Real,
        fov_vertical: Real,
        lens_focus_distance: Real,
        look_from: Point3,
        coordinate_basis: *const CoordinateBasis,
    ) Viewport {
        // viewport dimensions
        const theta = std.math.degreesToRadians(fov_vertical);
        const h = @tan(theta / 2.0);
        const viewport_height = 2.0 * h * lens_focus_distance;
        const viewport_width = viewport_height * aspect_ratio;

        // vectors across horizontal and down vertical viewport edges
        const viewport_u = math.vec3s(viewport_width) * coordinate_basis.u; // across horizontal
        const viewport_v = math.vec3s(-viewport_height) * coordinate_basis.v; // down vertical

        // upper left pixel location
        const viewport_upper_left = look_from 
            - (math.vec3s(lens_focus_distance) * coordinate_basis.w) 
            - viewport_u / math.vec3s(2) 
            - viewport_v / math.vec3s(2);

        // rasterization
        const pixel_delta_u = viewport_u / math.vec3s(@floatFromInt(image_width));
        const pixel_delta_v = viewport_v / math.vec3s(@floatFromInt(image_height));
        const pixel00_loc = viewport_upper_left + math.vec3s(0.5) * (pixel_delta_u + pixel_delta_v);

        return Self{
            .width = viewport_width,
            .height = viewport_height,
            .upper_left_corner = viewport_upper_left,
            .u = viewport_u,
            .v = viewport_v,
            .pixel_delta_u = pixel_delta_u,
            .pixel_delta_v = pixel_delta_v,
            .pixel00_loc = pixel00_loc,
        };
    }
};
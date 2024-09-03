const std = @import("std");

const ztracy = @import("ztracy");

const math = @import("math.zig");
const Color = math.Vec3;
const Point = math.Vec3;
const Vec2 = math.Vec2;

const img = @import("image.zig");

const DEBUG_IMAGE = img.Image{};

/// INTERFACE
pub const ITexture = union(enum) {
    const Self = @This();

    solid_color: SolidColorTexture,
    checkerboard: CheckerboardTexture,
    image: ImageTexture,

    pub fn value(self: Self, uv: Vec2, point: *const Point) Color {
        return switch (self) {
            inline else => |t| t.value(uv, point),
        };
    }
};

pub const ImageTexture = struct {
    const Self = @This();

    image: *const img.Image,

    pub fn initTexture(image: *const img.Image) ITexture {
        return ITexture{ .image = Self{ .image = image } };
    }

    /// Samples the image pixel given a UV coordinate. Colors are returned in linear colorspace.
    pub fn value(self: *const Self, uv: Vec2, _: *const Point) Color {
        const tracy_zone = ztracy.ZoneN(@src(), "ImageTexture::value");
        defer tracy_zone.End();

        if (self.image.getHeight() <= 0) {
            return pixelToColor(DEBUG_IMAGE.getPixel(0, 0));
        }

        const int = math.Interval(math.Real){ .min = 0, .max = 1 };
        const u = int.clamp(uv[0]);
        const v = 1.0 - int.clamp(uv[1]); // flip to image coordinates

        const fwidth = @as(math.Real, @floatFromInt(self.image.getWidth()));
        const fheight = @as(math.Real, @floatFromInt(self.image.getHeight()));
        const pixel = self.image.getPixel(
            @intFromFloat(u * fwidth),
            @intFromFloat(v * fheight),
        );

        return pixelToColor(pixel);
    }

    fn pixelToColor(pixel: []const u8) Color {
        const color_scale = 1.0 / 255.0;
        return Color{
            linearizeColorspace(color_scale * @as(math.Real, @floatFromInt(pixel[0]))),
            linearizeColorspace(color_scale * @as(math.Real, @floatFromInt(pixel[1]))),
            linearizeColorspace(color_scale * @as(math.Real, @floatFromInt(pixel[2]))),
        };
    }

    inline fn linearizeColorspace(x: math.Real) math.Real {
        return std.math.pow(math.Real, x, math.GAMMA);
    }
};

pub const SolidColorTexture = struct {
    const Self = @This();

    color: Color,

    pub fn initTexture(color: Color) ITexture {
        return ITexture{ .solid_color = Self{ .color = color } };
    }

    pub fn value(self: *const Self, uv: Vec2, point: *const Point) Color {
        _ = uv;
        _ = point;
        return self.color;
    }
};

pub const CheckerboardTexture = struct {
    const Self = @This();

    inv_scale: math.Real,
    tex_even: *const ITexture,
    tex_odd: *const ITexture,

    pub fn initTexture(inv_scale: math.Real, tex_even: *const ITexture, tex_odd: *const ITexture) ITexture {
        return ITexture{ .checkerboard = CheckerboardTexture{
            .inv_scale = inv_scale,
            .tex_even = tex_even,
            .tex_odd = tex_odd,
        } };
    }

    pub fn value(self: *const Self, uv: Vec2, point: *const Point) Color {
        const x_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[0]))));
        const y_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[1]))));
        const z_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[2]))));

        const is_even = @mod(x_int + y_int + z_int, 2) == 0;
        return if (is_even) self.tex_even.value(uv, point) else self.tex_odd.value(uv, point);
    }
};

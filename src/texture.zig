const std = @import("std");

const ztracy = @import("ztracy");

const math = @import("math/math.zig");
const img = @import("image.zig");

const DEBUG_IMAGE = img.Image{};

/// INTERFACE
pub const ITexture = union(enum) {
    const Self = @This();

    solid_color: SolidColorTexture,
    checkerboard: CheckerboardTexture,
    image: ImageTexture,

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            inline else => |*t|
                if (std.meta.hasMethod(@TypeOf(t.*), "deinit"))
                    t.deinit(),
        }
    }

    pub fn value(self: *const Self, uv: math.Vec2, point: *const math.Point3) math.Color {
        return switch (self.*) {
            inline else => |*t| t.value(uv, point),
        };
    }
};

pub const ImageTexture = struct {
    const Self = @This();

    image: img.Image,

    pub fn initTextureFromPath(path: [:0]const u8) !ITexture {
        return ITexture{ .image = Self{ 
            .image = try img.Image.initFromFile(path),
        }};
    }

    pub fn deinit(self: *Self) void {
        self.image.deinit();
    }

    /// Samples the image pixel given a UV coordinate. Colors are returned in linear colorspace.
    pub fn value(self: *const Self, uv: math.Vec2, _: *const math.Point3) math.Color {
        const tracy_zone = ztracy.ZoneN(@src(), "ImageTexture::value");
        defer tracy_zone.End();

        if (self.image.getHeight() <= 0) {
            return pixelToColor(DEBUG_IMAGE.getPixel(0, 0));
        }

        const u = math.INTERVAL_01.clamp(uv[0]);
        const v = 1.0 - math.INTERVAL_01.clamp(uv[1]); // flip to image coordinates

        const fwidth = @as(math.Real, @floatFromInt(self.image.getWidth()));
        const fheight = @as(math.Real, @floatFromInt(self.image.getHeight()));
        const pixel = self.image.getPixel(
            @intFromFloat(u * fwidth),
            @intFromFloat(v * fheight),
        );

        return pixelToColor(pixel);
    }

    fn pixelToColor(pixel: []const u8) math.Color {
        const color_scale = math.vec3s(1.0 / 255.0);
        return math.linearizeColorSpace(color_scale * math.vec3(
            @as(math.Real, @floatFromInt(pixel[0])),
            @as(math.Real, @floatFromInt(pixel[1])),
            @as(math.Real, @floatFromInt(pixel[2])),
        ));
    }
};

pub const SolidColorTexture = struct {
    const Self = @This();

    color: math.Color,

    pub fn initTexture(color: math.Color) ITexture {
        return ITexture{ .solid_color = Self{ .color = color } };
    }

    pub fn value(self: *const Self, uv: math.Vec2, point: *const math.Point3) math.Color {
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

    pub fn value(self: *const Self, uv: math.Vec2, point: *const math.Point3) math.Color {
        const x_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[0]))));
        const y_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[1]))));
        const z_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[2]))));

        const is_even = @mod(x_int + y_int + z_int, 2) == 0;
        return if (is_even) self.tex_even.value(uv, point) else self.tex_odd.value(uv, point);
    }
};

const std = @import("std");

const math = @import("math.zig");
const Color = math.Vec3;
const Point = math.Vec3;
const Vec2 = math.Vec2;

pub const Texture = union(enum) {
    const Self = @This();

    solid_color: SolidColorTexture,
    checkerboard: CheckerboardTexture,

    pub fn value(self: Self, uv: Vec2, point: *const Point) Color {
        return switch (self) {
            .solid_color => |t| t.value(uv, point),
            .checkerboard => |t| t.value(uv, point),
        };
    } 
};

pub const SolidColorTexture = struct {
    const Self = @This();

    color: Color,

    pub fn initTexture(color: Color) Texture {
        return Texture{ .solid_color = Self{ .color = color } };
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
    tex_even: *const Texture,
    tex_odd: *const Texture,

    pub fn initTexture(inv_scale: math.Real, tex_even: *const Texture, tex_odd: *const Texture) Texture {
        return Texture{ .checkerboard = CheckerboardTexture{
            .inv_scale = inv_scale,
            .tex_even = tex_even,
            .tex_odd = tex_odd,
        }};
    }

    pub fn value(self: *const Self, uv: Vec2, point: *const Point) Color {
        const x_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[0]))));
        const y_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[1]))));
        const z_int = @as(i32, @intFromFloat((@floor(self.inv_scale * point[2]))));

        const is_even = @mod(x_int + y_int + z_int, 2) == 0;
        return
            if (is_even) self.tex_even.value(uv, point)
            else self.tex_odd.value(uv, point);
    }
};
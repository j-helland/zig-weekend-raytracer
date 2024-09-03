const std = @import("std");

const ztracy = @import("ztracy");

const Texture = @import("texture.zig").Texture;

const Ray            = @import("ray.zig").Ray;
const HitRecord      = @import("ray.zig").HitRecord;
const ScatterContext = @import("ray.zig").ScatterContext;

const math  = @import("math.zig");
const Real  = math.Real;
const Color = math.Vec3;

const rng = @import("rng.zig");

/// INTERFACE
pub const Material = union(enum) {
    const Self = @This();
    
    lambertian: LambertianMaterial,
    metal: MetalMaterial,
    dielectric: DielectricMaterial,

    pub fn scatter(self: Self, ctx: ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Material::scatter");
        defer tracy_zone.End();

        return switch (self) {
            inline else => |m| m.scatter(ctx),
        };
    }
};

pub const LambertianMaterial = struct {
    const Self = @This();

    texture: *const Texture,

    pub fn initMaterial(texture: *const Texture) Material {
        return Material{ .lambertian = Self{ .texture = texture } };
    }

    pub fn scatter(self: *const Self, ctx: ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Lambertian::scatter");
        defer tracy_zone.End();

        var scatter_direction = ctx.hit_record.normal + rng.sampleUnitSphere(ctx.random);

        // handle degenerate scattering direction
        if (math.isVec3NearZero(scatter_direction)) {
            scatter_direction = ctx.hit_record.normal;
        }

        const origin = ctx.hit_record.point;
        ctx.ray_scattered.* = Ray{ 
            .origin = origin, 
            .direction = scatter_direction, 
            .time = ctx.ray_incoming.time,
        };
        ctx.attenuation.* = self.texture.value(ctx.hit_record.tex_uv, &origin);
        return true;
    }
};

pub const MetalMaterial = struct {
    const Self = @This();

    albedo: Color,
    fuzz: Real,

    pub fn initMaterial(albedo: Color, fuzz: Real) Material {
        return Material{ .metal = Self{ .albedo = albedo, .fuzz = fuzz } };
    }

    pub fn scatter(self: *const Self, ctx: ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Metal::scatter");
        defer tracy_zone.End();

        const blur = math.vec3s(std.math.clamp(self.fuzz, 0, 1));
        const scatter_direction = math.reflect(ctx.ray_incoming.direction, ctx.hit_record.normal) 
            + blur * rng.sampleUnitSphere(ctx.random);
        const origin = ctx.hit_record.point;
        ctx.ray_scattered.* = Ray{ 
            .origin = origin, 
            .direction = scatter_direction, 
            .time = ctx.ray_incoming.time,
        };
        ctx.attenuation.* = self.albedo;
        return (math.dot(scatter_direction, ctx.hit_record.normal) > 0.0);
    }
};

pub const DielectricMaterial = struct {
    const Self = @This();

    refraction_index: Real,

    pub fn initMaterial(refraction_index: Real) Material {
        return Material{ .dielectric = Self{ .refraction_index = refraction_index } };
    }

    pub fn scatter(self: *const Self, ctx: ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Dielectric::scatter");
        defer tracy_zone.End();

        const index = 
            if (ctx.hit_record.b_front_face) 1.0 / self.refraction_index 
            else self.refraction_index;
        const in_unit_direction = math.normalize(ctx.ray_incoming.direction);

        const cos_theta = @min(math.dot(-in_unit_direction, ctx.hit_record.normal), 1.0);
        const sin_theta = @sqrt(1 - cos_theta * cos_theta);

        const scatter_direction = 
            if (index * sin_theta > 1.0 or self.reflectance(cos_theta) > ctx.random.float(Real)) 
                // must reflect
                math.reflect(in_unit_direction, ctx.hit_record.normal)
            else 
                // can refract
                math.refract(in_unit_direction, ctx.hit_record.normal, index);

        const origin = ctx.hit_record.point;
        ctx.ray_scattered.* = Ray{ 
            .origin = origin, 
            .direction = scatter_direction, 
            .time = ctx.ray_incoming.time,
        };
        return true;
    }

    /// Schlick Fresnel approximation for dielectric reflectance.
    fn reflectance(self: *const Self, cosine: Real) Real {
        var r0 = (1 - self.refraction_index) / (1 + self.refraction_index);
        r0 *= r0;
        return r0 + (1 - r0) * std.math.pow(Real, (1 - cosine), 5);
    }
};
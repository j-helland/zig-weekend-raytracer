const std = @import("std");

const ztracy = @import("ztracy");

const ITexture = @import("texture.zig").ITexture;

const Ray = @import("ray.zig").Ray;
const HitRecord = @import("ray.zig").HitRecord;

const math = @import("math.zig");
const Real = math.Real;
const Vec2 = math.Vec2;
const Point3 = math.Vec3;
const Color = math.Vec3;
const vec3 = math.vec3;

const rng = @import("rng.zig");

pub const ScatterContext = struct {
    /// Keep all mutable fields here for clarity.
    mut: struct {
        attenuation: *Color, 
        ray_scattered: *Ray,
        pdf_value: *Real,
    },

    random: std.Random,
    ray_incoming: *const Ray, 
    hit_record: *const HitRecord,     
};

/// INTERFACE
pub const IMaterial = union(enum) {
    const Self = @This();

    lambertian: LambertianMaterial,
    isotropic: IsotropicMaterial,
    metal: MetalMaterial,
    dielectric: DielectricMaterial,
    diffuse_emissive: DiffuseLightEmissiveMaterial,

    pub fn emitted(self: *const Self, hit_record: *const HitRecord, uv: Vec2) Color {
        const tracy_zone = ztracy.ZoneN(@src(), "Material::emitted");
        defer tracy_zone.End();

        return switch (self.*) {
            inline else => |*m| 
                if (std.meta.hasMethod(@TypeOf(m.*), "emitted"))
                    m.emitted(hit_record, uv)
                else
                    // Default no light emitted.
                    vec3( 0, 0, 0 ),
        };
    }

    pub fn scatter(self: *const Self, ctx: *ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Material::scatter");
        defer tracy_zone.End();

        return switch (self.*) {
            inline else => |*m| 
                if (std.meta.hasMethod(@TypeOf(m.*), "scatter"))
                    m.scatter(ctx)
                else
                    false,
        };
    }

    pub fn scatteringPdf(self: *const Self, ctx: *ScatterContext) Real {
        const tracy_zone = ztracy.ZoneN(@src(), "Material::scatteringPdf");
        defer tracy_zone.End();

        return switch (self.*) {
            inline else => |*m| 
                if (std.meta.hasMethod(@TypeOf(m.*), "scatteringPdf"))
                    m.scatteringPdf(ctx)
                else
                    0.0,
        };
    }
};

pub const DiffuseLightEmissiveMaterial = struct {
    const Self = @This();

    texture: *const ITexture,

    pub fn initMaterial(texture: *const ITexture) IMaterial {
        return IMaterial{ .diffuse_emissive = Self{ .texture = texture } };
    }

    pub fn emitted(self: *const Self, hit_record: *const HitRecord, uv: Vec2) Color {
        const tracy_zone = ztracy.ZoneN(@src(), "DiffuseLightEmissiveMaterial::emitted");
        defer tracy_zone.End();

        // Backface of lights do not emit into scene
        if (!hit_record.b_front_face) return vec3(0, 0, 0);

        return self.texture.value(uv, &hit_record.point);
    }
};

pub const LambertianMaterial = struct {
    const Self = @This();

    texture: *const ITexture,

    pub fn initMaterial(texture: *const ITexture) IMaterial {
        return IMaterial{ .lambertian = Self{ .texture = texture } };
    }

    pub fn scatter(self: *const Self, ctx: *ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Lambertian::scatter");
        defer tracy_zone.End();

        const basis = math.OrthoBasis.init(ctx.hit_record.normal);
        const scatter_direction = basis.transform(rng.sampleCosineDirectionZ(ctx.random));

        const origin = ctx.hit_record.point;
        ctx.mut.ray_scattered.* = Ray{
            .origin = origin,
            .direction = math.normalize(scatter_direction),
            .time = ctx.ray_incoming.time,
        };
        ctx.mut.attenuation.* = self.texture.value(ctx.hit_record.tex_uv, &origin);
        ctx.mut.pdf_value.* = math.dot(basis.get(.w), ctx.mut.ray_scattered.direction) / std.math.pi;
        return true;
    }

    pub inline fn scatteringPdf(_: *const Self, ctx: *const ScatterContext) Real {
        const light_dir = math.normalize(ctx.mut.ray_scattered.direction);
        const cos_theta = math.dot(ctx.hit_record.normal, light_dir);
        return @max(0.0, cos_theta / std.math.pi);
    }
};

pub const IsotropicMaterial = struct {
    const Self = @This();

    texture: *const ITexture,

    pub fn initMaterial(texture: *const ITexture) IMaterial {
        return IMaterial{ .isotropic = Self{ .texture = texture } };
    }

    pub fn scatter(self: *const Self, ctx: *ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Isotropic::scatter");
        defer tracy_zone.End();

        const origin = ctx.hit_record.point;
        ctx.mut.ray_scattered.* = Ray{
            .origin = origin,
            .direction = rng.sampleUnitSphere(ctx.random),
            .time = ctx.ray_incoming.time,
        };
        ctx.mut.attenuation.* = self.texture.value(ctx.hit_record.tex_uv, &origin);
        ctx.mut.pdf_value.* = 1.0 / (4.0 * std.math.pi);
        return true;
    }

    pub inline fn scatteringPdf(_: *const Self, _: *const ScatterContext) Real {
        return 1.0 / (4.0 * std.math.pi);
    }
};

pub const MetalMaterial = struct {
    const Self = @This();

    albedo: Color,
    fuzz: Real,

    pub fn initMaterial(albedo: Color, fuzz: Real) IMaterial {
        return IMaterial{ .metal = Self{ .albedo = albedo, .fuzz = fuzz } };
    }

    pub fn scatter(self: *const Self, ctx: *ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Metal::scatter");
        defer tracy_zone.End();

        const blur = math.vec3s(std.math.clamp(self.fuzz, 0, 1));
        const scatter_direction = math.reflect(ctx.ray_incoming.direction, ctx.hit_record.normal) + blur * rng.sampleUnitSphere(ctx.random);
        const origin = ctx.hit_record.point;
        ctx.mut.ray_scattered.* = Ray{
            .origin = origin,
            .direction = scatter_direction,
            .time = ctx.ray_incoming.time,
        };
        ctx.mut.attenuation.* = self.albedo;
        return (math.dot(scatter_direction, ctx.hit_record.normal) > 0.0);
    }
};

pub const DielectricMaterial = struct {
    const Self = @This();

    refraction_index: Real,

    pub fn initMaterial(refraction_index: Real) IMaterial {
        return IMaterial{ .dielectric = Self{ .refraction_index = refraction_index } };
    }

    pub fn scatter(self: *const Self, ctx: *ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Dielectric::scatter");
        defer tracy_zone.End();

        const index =
            if (ctx.hit_record.b_front_face) 1.0 / self.refraction_index else self.refraction_index;
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
        ctx.mut.ray_scattered.* = Ray{
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

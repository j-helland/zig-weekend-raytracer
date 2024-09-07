const std = @import("std");

const math = @import("math.zig");
const Vec3 = @import("math.zig").Vec3;
const Real = @import("math.zig").Real;

const ent = @import("entity.zig");
const rng = @import("rng.zig");

pub const IPdf = union(enum) {
    const Self = @This();

    sphere: SpherePdf,
    cosine: CosinePdf,
    entity: EntityPdf,
    mixture: MixturePdf,

    pub fn value(self: *const Self, direction: Vec3) Real {
        return switch(self.*) {
            inline else => |*p| p.value(direction),
        };
    }

    pub fn generate(self: *const Self) Vec3 {
        return switch (self.*) {
            inline else => |*p| p.generate(),
        };
    }
};

pub const SpherePdf = struct {
    const Self = @This();

    rand: std.Random,

    pub fn initPdf(rand: std.Random) IPdf {
        return IPdf{ .sphere = Self{ .rand = rand } };
    }

    pub inline fn value(_: *const Self, _: Vec3) Real {
        return 1.0 / (4.0 * std.math.pi);
    }

    pub inline fn generate(self: *const Self) Vec3 {
        return rng.sampleUnitSphere(self.rand);
    }
};

pub const CosinePdf = struct {
    const Self = @This();

    rand: std.Random,
    basis: math.OrthoBasis,

    pub fn initPdf(rand: std.Random, direction: Vec3) IPdf {
        return IPdf{ .cosine = Self{ 
            .rand = rand,
            .basis = math.OrthoBasis.init(direction),
        }};
    }

    pub inline fn value(self: *const Self, direction: Vec3) Real {
        const cos_theta = math.dot(math.normalize(direction), self.basis.get(.w));
        return @max(0, cos_theta / std.math.pi);
    }

    pub inline fn generate(self: *const Self) Vec3 {
        return self.basis.transform(rng.sampleCosineDirectionZ(self.rand));
    }
};

pub const EntityPdf = struct {
    const Self = @This();

    rand: std.Random,
    entity: *const ent.IEntity,
    origin: Vec3,

    pub fn initPdf(rand: std.Random, entity: *const ent.IEntity, origin: Vec3) IPdf {
        return IPdf{ .entity = Self{
            .rand = rand,
            .entity = entity,
            .origin = origin,
        }};
    }

    pub inline fn value(self: *const Self, direction: Vec3) Real {
        return self.entity.pdfValue(self.origin, direction);
    }

    pub inline fn generate(self: *const Self) Vec3 {
        return self.entity.sampleDirectionToSurface(self.rand, self.origin);
    }
};

pub const MixturePdf = struct {
    const Self = @This();

    rand: std.Random,
    pdf1: *const IPdf,
    pdf2: *const IPdf,

    pub fn initPdf(rand: std.Random, pdf1: *const IPdf, pdf2: *const IPdf) IPdf {
        return IPdf{ .mixture = Self{
            .rand = rand,
            .pdf1 = pdf1,
            .pdf2 = pdf2,
        }};
    }

    pub fn value(self: *const Self, direction: Vec3) Real {
        return @reduce(.Add, math.vec2s(0.5) * math.vec2(
            self.pdf1.value(direction),
            self.pdf2.value(direction),
        ));
    }

    pub fn generate(self: *const Self) Vec3 {
        const p = self.rand.float(math.Real);
        if (p < 0.5) return self.pdf1.generate();
        return self.pdf2.generate();
    }
};
const std = @import("std");
const AllocatorError = std.mem.Allocator.Error;

const ztracy = @import("ztracy");

const math = @import("math.zig");
const Real = math.Real;
const Vec3 = math.Vec3;
const Point3 = Vec3;
const Color = Vec3;
const vec3s = math.vec3s;
const Interval = math.Interval;
const Ray = math.Ray;
const AABB = math.AABB;

const rng = @import("rng.zig");

pub const ScatterContext = struct {
    random: std.Random,
    ray_incoming: *const Ray, 
    hit_record: *const HitRecord, 
    attenuation: *Color, 
    ray_scattered: *Ray,
};

pub const Material = union(enum) {
    const Self = @This();
    
    lambertian: LambertianMaterial,
    metal: MetalMaterial,
    dielectric: DielectricMaterial,

    pub fn scatter(self: Self, ctx: ScatterContext) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Material::scatter");
        defer tracy_zone.End();

        return switch (self) {
            .lambertian => |m| m.scatter(ctx),
            .metal => |m| m.scatter(ctx),
            .dielectric => |m| m.scatter(ctx),
        };
    }
};

pub const LambertianMaterial = struct {
    const Self = @This();

    albedo: Color,

    pub fn initMaterial(albedo: Color) Material {
        return Material{ .lambertian = Self{ .albedo = albedo } };
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
        ctx.attenuation.* = self.albedo;
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

pub const HitRecord = struct {
    const Self = @This();

    point: Point3 = .{0, 0, 0},
    normal: Vec3 = .{0, 0, 0},
    material: ?*const Material = null,
    t: Real = std.math.inf(Real),
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
    trange: Interval(Real),
};

pub const Entity = union(enum) {
    const Self = @This();

    sphere: SphereEntity,
    collection: EntityCollection,
    bvh_node: BVHNodeEntity,

    pub fn deinit(self: *Self) void {
        switch(self.*) {
            .sphere => |*e| e.deinit(),
            .collection => |*e| e.deinit(),
            .bvh_node => {},
            // .bvh_node => |*e| e.deinit(),
        }
    }

    pub fn hit(self: Self, ctx: HitContext, hit_record: *HitRecord) bool {
        return switch (self) {
            .sphere => |e| e.hit(ctx, hit_record),
            .collection => |e| e.hit(ctx, hit_record),
            .bvh_node => |e| e.hit(ctx, hit_record),
        };
    }

    pub fn boundingBox(self: Self) AABB {
        return switch(self) {
            .sphere => |e| e.aabb,
            .collection => |e| e.aabb,
            .bvh_node => |e| e.aabb,
        };
    }
}; 

const BoxCmpContext = struct {
    axis: math.Axis,
};
fn boxCmp(ctx: BoxCmpContext, a: *const Entity, b: *const Entity) bool {
    const a_axis_interval = a.boundingBox().axisInterval(ctx.axis);
    const b_axis_interval = b.boundingBox().axisInterval(ctx.axis);
    return (a_axis_interval.min < b_axis_interval.min);
}

/// Caller is responsible for freeing the memory pool on which the BVH tree is allocated.
pub const BVHNodeEntity = struct {
    const Self = @This();

    const _mat = LambertianMaterial.initMaterial(Color{1, 0, 0});

    left: ?*Entity,
    right: ?*Entity,
    aabb: AABB, 

    pub fn init(allocator: *std.heap.MemoryPool(Entity), entities: []*Entity, start: usize, end: usize) !Self {
        var self: BVHNodeEntity = undefined;

        // Populate left/right children.
        const span = end - start;
        if (span == 1) {
            self.left = entities[start];
            self.right = entities[start];

        } else if (span == 2) {
            self.left = entities[start];
            self.right = entities[start + 1];

        } else {
            // node splitting
            // choose axis aligned with longest bbox face
            var bbox = AABB{};
            for (entities[start..end]) |entity| {
                bbox = bbox.unionWith(entity.boundingBox());
            }
            const axis = bbox.longestAxis();

            std.sort.pdq(*Entity, entities[start..end], BoxCmpContext{ .axis = axis }, boxCmp);
            const mid = start + span / 2;

            self.left = try allocator.create();
            self.left.?.* = Entity{ .bvh_node = try Self.init(allocator, entities, start, mid) };

            self.right = try allocator.create();
            self.right.?.* = Entity{ .bvh_node = try Self.init(allocator, entities, mid, end) };
        }

        self.aabb = self.left.?.boundingBox().unionWith(self.right.?.boundingBox());

        return self;
    }

    pub fn initEntity(allocator: *std.heap.MemoryPool(Entity), entities: []*Entity, start: usize, end: usize) !Entity {
        return Entity{ .bvh_node = try init(allocator, entities, start, end) };
    }

    pub fn hit(self: *const Self, ctx: HitContext, hit_record: *HitRecord) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "BVH::hit");
        defer tracy_zone.End();

        if (!self.aabb.hit(ctx.ray, ctx.trange)) {
            return false;
        }

        const hit_left = 
            if (self.left) |left| left.hit(ctx, hit_record) 
            else false;
        
        var ctx_right = ctx;
        if (hit_left) ctx_right.trange.max = hit_record.t;
        const hit_right = 
            if (self.right) |right| right.hit(ctx_right, hit_record)
            else false;

        return hit_left or hit_right;
    }
};

pub const EntityCollection = struct {
    const Self = @This();

    entities: std.ArrayList(Entity),
    aabb: AABB = .{},

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .entities = std.ArrayList(Entity).init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        for (self.entities.items) |*e| e.deinit();
        self.entities.deinit();
    }

    pub fn add(self: *Self, entity: Entity) AllocatorError!void {
        try self.entities.append(entity);
        self.aabb = self.aabb.unionWith(entity.boundingBox());
    }

    pub fn hit(self: *const Self, _ctx: HitContext, hit_record: *HitRecord) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "EntityCollection::hit");
        defer tracy_zone.End();

        var ctx = _ctx;
        var hit_record_tmp  = HitRecord{};
        var b_hit_anything = false;
        var closest_t = ctx.trange.max;

        for (self.entities.items) |*entity| {
            if (entity.hit(ctx, &hit_record_tmp)) {
                b_hit_anything = true;
                closest_t = hit_record_tmp.t;
                ctx.trange.max = closest_t;

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
    radius: Real,
    material: *const Material,
    aabb: AABB,

    b_is_moving: bool = false,
    movement_direction: Vec3 = .{0, 0, 0},

    /// noop to satisfy interface
    pub fn deinit(_: *const Self) void {}

    pub fn initEntity(center: Point3, radius: Real, material: *const Material) Entity {
        const rvec = math.vec3s(radius);

        return Entity{ .sphere = Self{ 
            .center = center, 
            .radius = radius, 
            .material = material, 
            .aabb = AABB.init(center - rvec, center + rvec),
        }};
    }

    pub fn initEntityAnimated(center_start: Point3, center_end: Point3, radius: Real, material: *const Material) Entity {
        const rvec = math.vec3s(radius);

        return Entity{ .sphere = Self{
            .center = center_start,
            .radius = radius,
            .material = material,
            .b_is_moving = true,
            .movement_direction = center_end - center_start,
            .aabb = AABB
                .init(center_start - rvec, center_start + rvec)
                .unionWith(AABB.init(center_end - rvec, center_end + rvec)),
        }};
    }

    pub fn hit(self: *const Self, ctx: HitContext, hit_record: *HitRecord) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Sphere::hit");
        defer tracy_zone.End();

        // animation
        const center = 
            if (self.b_is_moving) self.move(ctx.ray.time) 
            else self.center;

        // direction from ray to sphere center
        const oc = center - ctx.ray.origin;
        // Detect polynomial roots for ray / sphere intersection equation (cx-x)^2 + (cy-y)^2 + (cz-z)^2 = r^2 = (c - p(t)) . (c - p(t))
        const a = math.dot(ctx.ray.direction, ctx.ray.direction);
        const h = math.dot(ctx.ray.direction, oc);
        const c = math.dot(oc, oc) - self.radius * self.radius;
        const discriminant = h*h - a*c;

        if (discriminant < 0.0) return false;

        const disc_sqrt = @sqrt(discriminant);
        var root = (h - disc_sqrt) / a;
        if (!ctx.trange.surrounds(root)) {
            root = (h + disc_sqrt) / a;
            if (!ctx.trange.surrounds(root)) {
                return false;
            }
        }

        hit_record.t = root;
        hit_record.point = ctx.ray.at(hit_record.t);
        const outward_normal = (hit_record.point - center) / vec3s(self.radius);
        hit_record.setFrontFaceNormal(ctx.ray, outward_normal);
        hit_record.material = self.material;

        return true;
    }

    fn move(self: *const Self, time: Real) Point3 {
        // lerp towards target; assume time is in [0,1]
        return self.center + math.vec3s(time) * self.movement_direction;
    }
};
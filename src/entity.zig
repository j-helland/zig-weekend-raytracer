const std = @import("std");
const AllocatorError = std.mem.Allocator.Error;

const ztracy = @import("ztracy");

const math = @import("math.zig");
const Real = math.Real;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;
const Point3 = Vec3;
const vec3 = math.vec3;
const vec2 = math.vec2;
const vec3s = math.vec3s;

const Interval = @import("interval.zig").Interval;
const AABB = @import("aabb.zig").AABB;

const Ray = @import("ray.zig").Ray;

const ITexture = @import("texture.zig").ITexture;
const IMaterial = @import("material.zig").IMaterial;
const HitContext = @import("ray.zig").HitContext;
const HitRecord = @import("ray.zig").HitRecord;

const rng = @import("rng.zig");

const EntityPool = std.heap.MemoryPool(IEntity);
const EntityPoolError = error{OutOfMemory};

/// INTERFACE
pub const IEntity = union(enum) {
    const Self = @This();

    sphere: SphereEntity,
    quad: QuadEntity,
    collection: EntityCollection,
    bvh_node: BVHNodeEntity,
    translate: Translate,
    rotate_y: RotateY,

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            inline else => |*e| 
                if (std.meta.hasMethod(@TypeOf(e.*), "deinit")) 
                    e.deinit(),
        }
    }

    pub fn hit(self: *const Self, ctx: *const HitContext, hit_record: *HitRecord) bool {
        return switch (self.*) {
            inline else => |e| e.hit(ctx, hit_record),
        };
    }

    pub fn boundingBox(self: *const Self) *const AABB {
        return switch (self.*) {
            inline else => |*e| &e.aabb,
        };
    }

    pub fn pdfValue(self: *const Self, origin: Vec3, direction: Vec3) Real {
        return switch (self.*) {
            inline else => |*e| 
                if (std.meta.hasMethod(@TypeOf(e.*), "pdfValue"))
                    e.pdfValue(origin, direction)
                else
                    0.0,
        };
    }

    pub fn sampleDirectionToSurface(self: *const Self, rand: std.Random, origin: Vec3) Vec3 {
        return switch (self.*) {
            inline else => |*e|
                if (std.meta.hasMethod(@TypeOf(e.*), "sampleDirectionToSurface"))
                    e.sampleDirectionToSurface(rand, origin)
                else
                    vec3(1, 0, 0),
        };
    }
};

pub const Translate = struct {
    const Self = @This();

    offset: Vec3,
    entity: *IEntity,
    aabb: AABB,

    pub fn initEntity(
        entity_pool: *EntityPool,
        offset: Vec3, 
        entity_to_transform: *IEntity,
    ) EntityPoolError!*IEntity {
        const entity = try entity_pool.create();
        entity.* = IEntity{ .translate = Self{ 
            .offset = offset, 
            .entity = entity_to_transform,
            .aabb = entity_to_transform.boundingBox().offset(offset),
        }};
        return entity;
    }

    pub fn deinit(self: *Self) void {
        self.entity.deinit();
    }

    pub fn hit(self: *const Self, ctx: *const HitContext, hit_record: *HitRecord) bool {
        // Offset ray backwards
        var ray_trans = ctx.ray.*;
        ray_trans.origin -= self.offset;

        var ctx_trans = ctx.*;
        ctx_trans.ray = &ray_trans;

        if (!self.entity.hit(&ctx_trans, hit_record)) {
            return false;
        }

        // Offset hit point forwards to account for inital ray offset.
        hit_record.point += self.offset;

        return true;
    }
};

pub const RotateY = struct {
    const Self = @This();

    sin_theta: Real,
    cos_theta: Real,
    entity: *IEntity,
    aabb: AABB,

    pub fn initEntity(
        entity_pool: *EntityPool,
        angle_degrees: Real, 
        entity_to_transform: *IEntity,
    ) EntityPoolError!*IEntity {
        const theta = std.math.degreesToRadians(angle_degrees);
        const sin_theta = @sin(theta);
        const cos_theta = @cos(theta);
        const bbox = entity_to_transform.boundingBox();

        var min = math.vec3s(std.math.inf(Real));
        var max = math.vec3s(-std.math.inf(Real));

        for (0..2) |i| {
            const fi = @as(Real, @floatFromInt(i));
            const x = fi * bbox.x.max + (1.0 - fi) * bbox.x.min;

            for (0..2) |j| {
                const fj = @as(Real, @floatFromInt(j));
                const y = fj * bbox.x.max + (1.0 - fj) * bbox.y.min;

                for (0..2) |k| {
                    const fk = @as(Real, @floatFromInt(k));
                    const z = fk * bbox.x.max + (1.0 - fk) * bbox.z.min;

                    const newx = cos_theta * x + sin_theta * z;
                    const newz = -sin_theta * x + cos_theta * z;
                    const tester = vec3(newx, y, newz);

                    min = @min(min, tester);
                    max = @max(max, tester);
                }
            }
        }

        const entity = try entity_pool.create();
        entity.* = IEntity{ .rotate_y = Self{ 
            .sin_theta = sin_theta,
            .cos_theta = cos_theta,
            .entity = entity_to_transform,
            .aabb = AABB.init(min, max),
        }};
        return entity;
    }

    pub fn deinit(self: *Self) void {
        self.entity.deinit();
    }

    pub fn hit(self: *const Self, ctx: *const HitContext, hit_record: *HitRecord) bool {
        // ray from world space into object space
        const ray_rotated = Ray{
            .origin = self.worldToObjectSpace(&ctx.ray.origin),
            .direction = self.worldToObjectSpace(&ctx.ray.direction),
            .time = ctx.ray.time,
        };
        const ctx_rotated = HitContext{
            .ray = &ray_rotated,
            .trange = ctx.trange,
        };

        if (!self.entity.hit(&ctx_rotated, hit_record)) {
            return false;
        }

        hit_record.point = self.objectToWorldSpace(&hit_record.point);
        hit_record.normal = self.objectToWorldSpace(&hit_record.normal);

        return true;
    }

    inline fn worldToObjectSpace(self: *const Self, v: *const Vec3) Vec3 {
        return vec3(
            self.cos_theta * v[0] - self.sin_theta * v[2],
            v[1],
            self.sin_theta * v[0] + self.cos_theta * v[2],
        );
    }

    inline fn objectToWorldSpace(self: *const Self, v: *const Vec3) Vec3 {
        return vec3(
            self.cos_theta * v[0] + self.sin_theta * v[2],
            v[1],
            -self.sin_theta * v[0] + self.cos_theta * v[2],
        );
    }
};

/// Sorting for BVH splitting
const BoxCmpContext = struct {
    axis: math.Axis,
};
fn boxCmp(ctx: BoxCmpContext, a: *const IEntity, b: *const IEntity) bool {
    const a_axis_interval = a.boundingBox().axisInterval(ctx.axis);
    const b_axis_interval = b.boundingBox().axisInterval(ctx.axis);
    return (a_axis_interval.min < b_axis_interval.min);
}

/// Caller is responsible for freeing the memory pool on which the BVH tree is allocated.
pub const BVHNodeEntity = struct {
    const Self = @This();

    left: ?*IEntity,
    right: ?*IEntity,
    aabb: AABB,

    pub fn init(entity_pool: *EntityPool, entities: []*IEntity, start: usize, end: usize) !Self {
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

            std.sort.pdq(*IEntity, entities[start..end], BoxCmpContext{ .axis = axis }, boxCmp);
            const mid = start + span / 2;

            self.left = try entity_pool.create();
            self.left.?.* = IEntity{ .bvh_node = try Self.init(entity_pool, entities, start, mid) };

            self.right = try entity_pool.create();
            self.right.?.* = IEntity{ .bvh_node = try Self.init(entity_pool, entities, mid, end) };
        }

        self.aabb = self.left.?.boundingBox().unionWith(self.right.?.boundingBox());

        return self;
    }

    pub fn initEntity(entity_pool: *EntityPool, entities: []*IEntity, start: usize, end: usize) EntityPoolError!*IEntity {
        const entity = try entity_pool.create();
        entity.* = IEntity{ 
            .bvh_node = try init(entity_pool, entities, start, end), 
        };
        return entity;
    }

    // fn hitAABB2(box1: *const AABB, box2: *const AABB, ray: *const Ray, ray_t: Interval(Real)) @Vector(8, bool) {
    //     const min = std.simd.join(box1.min, box2.min);
    //     const max = std.simd.join(box1.max, box2.max);
    //     const origin = std.simd.join(ray.origin, ray.origin);
    //     const direction = std.simd.join(ray.direction, ray.direction);
    //     const ray_t_min = std.simd.join(vec3s(ray_t.min), vec3s(ray_t.min));
    //     const ray_t_max = std.simd.join(vec3s(ray_t.max), vec3s(ray_t.max));

    //     const t0 = (min - origin) / direction;
    //     const t1 = (max - origin) / direction;

    //     const tmin = @max(@min(t0, t1), ray_t_min);
    //     const tmax = @min(@max(t0, t1), ray_t_max);

    //     return tmax > tmin;
    // }

    pub fn hit(self: *const Self, ctx: *const HitContext, hit_record: *HitRecord) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "BVH::hit");
        defer tracy_zone.End();

        if (!self.aabb.hit(ctx.ray, ctx.trange)) {
            return false;
        }

        const hit_left =
            if (self.left) |left| left.hit(ctx, hit_record) else false;

        var ctx_right = ctx.*;
        if (hit_left) ctx_right.trange.max = hit_record.t;
        const hit_right =
            if (self.right) |right| right.hit(&ctx_right, hit_record) else false;

        return hit_left or hit_right;
    }
};

pub const EntityCollection = struct {
    const Self = @This();

    entities: std.ArrayList(*IEntity),
    aabb: AABB = .{},
    bvh_root: ?*IEntity = null,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .entities = std.ArrayList(*IEntity).init(allocator) };
    }

    pub fn initEntity(entity_pool: *EntityPool, allocator: std.mem.Allocator) EntityPoolError!*IEntity {
        const entity = try entity_pool.create();
        entity.* = IEntity{ .collection = Self.init(allocator) };
        return entity;
    }

    pub fn deinit(self: *Self) void {
        for (self.entities.items) |e| e.deinit();
        self.entities.deinit();
    }

    pub fn add(self: *Self, entity: *IEntity) AllocatorError!void {
        try self.entities.append(entity);
        self.aabb = self.aabb.unionWith(entity.boundingBox());
    }

    pub fn addAssumeCapacity(self: *Self, entity: *IEntity) void {
        self.entities.appendAssumeCapacity(entity);
        self.aabb = self.aabb.unionWith(entity.boundingBox());
    }

    pub fn createBvhTree(self: *Self, entity_pool: *EntityPool) !void {
        self.bvh_root = try BVHNodeEntity.initEntity(entity_pool, self.entities.items, 0, self.entities.items.len);
    }

    pub fn hit(self: *const Self, _ctx: *const HitContext, hit_record: *HitRecord) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "EntityCollection::hit");
        defer tracy_zone.End();

        // Prefer BVH hierarchy if one exists.
        if (self.bvh_root) |bvh| {
            return bvh.hit(_ctx, hit_record);
        }

        var ctx = _ctx.*;
        var hit_record_tmp = HitRecord{};
        var b_hit_anything = false;
        var closest_t = ctx.trange.max;

        for (self.entities.items) |entity| {
            if (entity.hit(&ctx, &hit_record_tmp)) {
                b_hit_anything = true;
                closest_t = hit_record_tmp.t;
                ctx.trange.max = closest_t;

                // We know this hit is closest because we already reduced the search range bound tmax.
                hit_record.* = hit_record_tmp;
            }
        }

        return b_hit_anything;
    }

    /// Evenly weighted sum of surface PDFs.
    pub fn pdfValue(self: *const Self, origin: Vec3, direction: Vec3) Real {
        const weight = 1.0 / @as(Real, @floatFromInt(self.entities.items.len));
        var sum: Real = 0.0;
        for (self.entities.items) |entity| {
            sum += weight * entity.pdfValue(origin, direction);
        }
        return sum;
    }

    /// Pick a random entity.
    pub fn sampleDirectionToSurface(self: *const Self, rand: std.Random, origin: Vec3) Vec3 {
        std.debug.assert(self.entities.items.len > 0);

        const idx = rand.intRangeAtMost(usize, 0, self.entities.items.len - 1);
        return self.entities.items[idx].sampleDirectionToSurface(rand, origin);
    }
};

/// composite of quads arranged in a box; contained in EntityCollection
pub fn createBoxEntity(
    allocator: std.mem.Allocator, 
    entity_pool: *EntityPool, 
    point_a: Point3, 
    point_b: Point3, 
    material: *const IMaterial,
) EntityPoolError!*IEntity {
    var sides = try EntityCollection.initEntity(entity_pool, allocator);
    try sides.collection.entities.ensureTotalCapacity(6);

    // two opposite vertices with min/max coords
    const min = @min(point_a, point_b);
    const max = @max(point_a, point_b);

    const diff = max - min;
    const dx = vec3( diff[0], 0, 0 );
    const dy = vec3( 0, diff[1], 0 );
    const dz = vec3( 0, 0, diff[2] );

    const init_data = [_][3]Point3{
        .{ vec3(min[0], min[1], max[2]),  dx,  dy }, // front
        .{ vec3(max[0], min[1], max[2]), -dz,  dy }, // right
        .{ vec3(max[0], min[1], min[2]), -dx,  dy }, // back
        .{ vec3(min[0], min[1], min[2]),  dz,  dy }, // left
        .{ vec3(min[0], max[1], max[2]),  dx, -dz }, // top
        .{ vec3(min[0], min[1], min[2]),  dx,  dz }, // bottom
    };
    for (init_data) |data| {
        const p0 = data[0];
        const u = data[1];
        const v = data[2];
        sides.collection.addAssumeCapacity(
            try QuadEntity.initEntity(entity_pool, p0, u, v, material));
    }

    return sides;
}

pub const QuadEntity = struct {
    const Self = @This();

    // Parallelogram parameterization.
    start_point: Point3,
    basis: math.OrthoBasis,
    // axis1: Vec3,
    // axis2: Vec3,
    // axis3: Vec3,

    // containing plane
    normal: Vec3,
    offset: Real,
    area: Real,

    // Misc.
    material: *const IMaterial,
    aabb: AABB,

    pub fn initEntity(
        entity_pool: *EntityPool,
        start: Point3, 
        axis1: Vec3, 
        axis2: Vec3, 
        material: *const IMaterial,
    ) EntityPoolError!*IEntity {
        // Calculate the plane containing this quad.
        const normal = math.cross(axis1, axis2);
        const axis3 = normal / math.vec3s(math.dot(normal, normal));

        const normal_unit = math.normalize(normal);
        const offset = math.dot(normal_unit, start);

        const bbox_diag1 = AABB.init(start, start + axis1 + axis2);
        const bbox_diag2 = AABB.init(start + axis1, start + axis2);
        const bbox = bbox_diag1.unionWith(&bbox_diag2);

        const entity = try entity_pool.create();
        entity.* = IEntity{ .quad = Self{
            .start_point = start,
            .basis = math.OrthoBasis.initFromVectors(axis1, axis2, axis3),
            // .axis1 = axis1,
            // .axis2 = axis2,
            // .axis3 = axis3,

            .normal = normal_unit,
            .offset = offset,            
            .area = math.length(normal),  // recall: ||a x b|| is area of parallelogram spanned by a and b

            .material = material,
            .aabb = bbox,
        }};
        return entity;
    }

    pub fn hit(self: *const Self, ctx: *const HitContext, hit_record: *HitRecord) bool {
        const denom = math.dot(self.normal, ctx.ray.direction);

        // No hit if ray is parallel to plane.
        if (@abs(denom) < 1e-8) return false;

        // No hit if hit point is outside ray check interval.
        const t = (self.offset - math.dot(self.normal, ctx.ray.origin)) / denom;
        if (!ctx.trange.contains(t)) return false;

        const hit_point = ctx.ray.at(t);
        const planar_hit_point = hit_point - self.start_point;
        const alpha = math.dot(self.basis.get(.w), math.cross(planar_hit_point, self.basis.get(.v)));
        const beta = math.dot(self.basis.get(.w), math.cross(self.basis.get(.u), planar_hit_point));

        if (!isInteriorPoint(alpha, beta)) return false;

        hit_record.t = t;
        hit_record.point = hit_point;
        hit_record.material = self.material;
        hit_record.setFrontFaceNormal(ctx.ray, self.normal);
        hit_record.tex_uv = vec2(alpha, beta);

        return true;
    }

    pub fn pdfValue(self: *const Self, origin: Vec3, direction: Vec3) Real {
        const ctx = HitContext{
            .ray = &Ray{ .origin = origin, .direction = direction },
            .trange = Interval(Real){ .min = 1e-3, .max = std.math.inf(Real) },
        };
        var record = HitRecord{};
        if (!self.hit(&ctx, &record)) {
            return 0.0;
        }

        const dir_length_sq = math.dot(direction, direction);
        const dist_sq = record.t * record.t * dir_length_sq;
        const cos = @abs(math.dot(direction, record.normal)) / @sqrt(dir_length_sq);

        return dist_sq / (cos * self.area);
    }

    pub fn sampleDirectionToSurface(self: *const Self, rand: std.Random, origin: Vec3) Vec3 {
        const u = math.vec3s(rand.float(Real)) * self.basis.get(.u);
        const v = math.vec3s(rand.float(Real)) * self.basis.get(.v);
        const p = self.start_point + u + v;
        return p - origin;
    }

    inline fn isInteriorPoint(alpha: Real, beta: Real) bool {
        const unit = Interval(Real){ .min = 0, .max = 1 };
        return (unit.contains(alpha) and unit.contains(beta));
    }
};

pub const SphereEntity = struct {
    const Self = @This();

    center: Point3,
    radius: Real,
    material: *const IMaterial,
    aabb: AABB,

    b_is_moving: bool = false,
    movement_direction: Vec3 = vec3(0, 0, 0),

    pub fn initEntity(
        entity_pool: *EntityPool, 
        center: Point3, 
        radius: Real, 
        material: *const IMaterial,
    ) EntityPoolError!*IEntity {
        const rvec = math.vec3s(radius);

        const entity = try entity_pool.create();
        entity.* = IEntity{ .sphere = Self{
            .center = center,
            .radius = radius,
            .material = material,
            .aabb = AABB.init(center - rvec, center + rvec),
        }};
        return entity;
    }

    pub fn initEntityAnimated(
        entity_pool: *EntityPool, 
        center_start: Point3, 
        center_end: Point3, 
        radius: Real, 
        material: *const IMaterial,
    ) EntityPoolError!*IEntity {
        const rvec = math.vec3s(radius);

        const entity = try entity_pool.create();
        entity.* = IEntity{ .sphere = Self{
            .center = center_start,
            .radius = radius,
            .material = material,
            .b_is_moving = true,
            .movement_direction = center_end - center_start,
            .aabb = AABB
                .init(center_start - rvec, center_start + rvec)
                .unionWith(&AABB.init(center_end - rvec, center_end + rvec)),
        }};
        return entity;
    }

    pub fn hit(self: *const Self, ctx: *const HitContext, hit_record: *HitRecord) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Sphere::hit");
        defer tracy_zone.End();

        // animation
        const center =
            if (self.b_is_moving) 
                self.move(ctx.ray.time) 
            else 
                self.center;

        // direction from ray to sphere center
        const oc = center - ctx.ray.origin;
        // Detect polynomial roots for ray / sphere intersection equation (cx-x)^2 + (cy-y)^2 + (cz-z)^2 = r^2 = (c - p(t)) . (c - p(t))
        const a = math.dot(ctx.ray.direction, ctx.ray.direction);
        const h = math.dot(ctx.ray.direction, oc);
        const c = math.dot(oc, oc) - self.radius * self.radius;
        const discriminant = h * h - a * c;

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
        hit_record.tex_uv = getSphereUv(&outward_normal);
        hit_record.material = self.material;

        return true;
    }

    /// NOTE: sphere assumed to be stationary
    pub fn pdfValue(self: *const Self, origin: Vec3, direction: Vec3) Real {
        std.debug.assert(!self.b_is_moving);

        const ctx = HitContext{
            .ray = &Ray{ .origin = origin, .direction = direction },
            .trange = Interval(Real){ .min = 1e-3, .max = std.math.inf(Real) },
        };
        var hit_record = HitRecord{};
        if (!self.hit(&ctx, &hit_record)) {
            return 0.0;
        }

        const diff = self.center - origin;
        const dist_sq = math.dot(diff, diff);
        const cos_theta_max = @sqrt(1.0 - self.radius * self.radius / dist_sq);
        const solid_angle = 2.0 * std.math.pi * (1.0 - cos_theta_max);

        return 1.0 / solid_angle;
    }

    pub fn sampleDirectionToSurface(self: *const Self, rand: std.Random, origin: Vec3) Vec3 {
        const direction = self.center - origin;
        const dist_sq = math.dot(direction, direction);
        const basis = math.OrthoBasis.init(direction);
        return basis.transform(randomToSphere(rand, self.radius, dist_sq));
    }

    fn move(self: *const Self, time: Real) Point3 {
        // lerp towards target; assume time is in [0,1]
        return self.center + math.vec3s(time) * self.movement_direction;
    }

    /// Returns UV coordinates for the sphere.
    fn getSphereUv(v: *const Vec3) Vec2 {
        const theta = std.math.acos(-v[1]);
        const phi = std.math.atan2(-v[2], v[0]) + std.math.pi;
        return vec2(
            phi / (2 * std.math.pi),
            theta / std.math.pi,
        );
    }

    fn randomToSphere(rand: std.Random, radius: Real, dist_sq: Real) Vec3 {
        const r1 = rand.float(Real);
        const r2 = rand.float(Real);
        const z = 1.0 + r2 * (@sqrt(1.0 - radius * radius / dist_sq) - 1.0);

        const phi = 2.0 * std.math.pi * r1;
        const sz2 = @sqrt(1.0 - z*z);
        const x = @cos(phi) * sz2;
        const y = @sin(phi) * sz2;

        return math.vec3(x, y, z);
    }
};

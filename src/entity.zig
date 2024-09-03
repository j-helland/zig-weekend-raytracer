const std = @import("std");
const AllocatorError = std.mem.Allocator.Error;

const ztracy = @import("ztracy");

const math = @import("math.zig");
const Real = math.Real;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;
const Point3 = Vec3;
const Color = Vec3;
const vec3s = math.vec3s;
const Interval = math.Interval;
const Ray = math.Ray;
const AABB = math.AABB;

const ITexture = @import("texture.zig").ITexture;
const IMaterial = @import("material.zig").IMaterial;
const HitContext = @import("ray.zig").HitContext;
const HitRecord = @import("ray.zig").HitRecord;

const rng = @import("rng.zig");

/// INTERFACE
pub const IEntity = union(enum) {
    const Self = @This();

    sphere: SphereEntity,
    quad: QuadEntity,
    collection: EntityCollection,
    bvh_node: BVHNodeEntity,
    translate: Translate,

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
};

pub const Translate = struct {
    const Self = @This();

    offset: Vec3,
    entity: *const IEntity,
    aabb: AABB,

    pub fn transform(entity: *const IEntity, offset: Vec3) IEntity {
        return IEntity{ .translate = Self{ 
            .offset = offset, 
            .entity = entity,
            .aabb = entity.boundingBox().offset(offset),
        }};
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

    pub fn init(allocator: *std.heap.MemoryPool(IEntity), entities: []*IEntity, start: usize, end: usize) !Self {
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

            self.left = try allocator.create();
            self.left.?.* = IEntity{ .bvh_node = try Self.init(allocator, entities, start, mid) };

            self.right = try allocator.create();
            self.right.?.* = IEntity{ .bvh_node = try Self.init(allocator, entities, mid, end) };
        }

        self.aabb = self.left.?.boundingBox().unionWith(self.right.?.boundingBox());

        return self;
    }

    pub fn initEntity(allocator: *std.heap.MemoryPool(IEntity), entities: []*IEntity, start: usize, end: usize) !IEntity {
        return IEntity{ .bvh_node = try init(allocator, entities, start, end) };
    }

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

    entities: std.ArrayList(IEntity),
    aabb: AABB = .{},

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .entities = std.ArrayList(IEntity).init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        for (self.entities.items) |*e| e.deinit();
        self.entities.deinit();
    }

    pub fn add(self: *Self, entity: IEntity) AllocatorError!void {
        try self.entities.append(entity);
        self.aabb = self.aabb.unionWith(entity.boundingBox());
    }

    pub fn addAssumeCapacity(self: *Self, entity: IEntity) void {
        self.entities.appendAssumeCapacity(entity);
        self.aabb = self.aabb.unionWith(entity.boundingBox());
    }

    pub fn hit(self: *const Self, _ctx: *const HitContext, hit_record: *HitRecord) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "EntityCollection::hit");
        defer tracy_zone.End();

        var ctx = _ctx.*;
        var hit_record_tmp = HitRecord{};
        var b_hit_anything = false;
        var closest_t = ctx.trange.max;

        for (self.entities.items) |*entity| {
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
};

/// composite of quads arranged in a box; contained in EntityCollection
pub fn createBoxEntity(allocator: std.mem.Allocator, point_a: Point3, point_b: Point3, material: *const IMaterial) !IEntity {
    var sides = EntityCollection.init(allocator);
    try sides.entities.ensureTotalCapacity(6);

    // two opposite vertices with min/max coords
    const min = Point3{
        @min(point_a[0], point_b[0]),
        @min(point_a[1], point_b[1]),
        @min(point_a[2], point_b[2]),
    };
    const max = Point3{
        @max(point_a[0], point_b[0]),
        @max(point_a[1], point_b[1]),
        @max(point_a[2], point_b[2]),
    };

    const diff = max - min;
    const dx = Vec3{ diff[0], 0, 0 };
    const dy = Vec3{ 0, diff[1], 0 };
    const dz = Vec3{ 0, 0, diff[2] };

    sides.addAssumeCapacity(QuadEntity.initEntity(Point3{ min[0], min[1], max[2] }, dx, dy, material)); // front
    sides.addAssumeCapacity(QuadEntity.initEntity(Point3{ max[0], min[1], max[2] }, -dz, dy, material)); // right
    sides.addAssumeCapacity(QuadEntity.initEntity(Point3{ max[0], min[1], min[2] }, -dx, dy, material)); // back
    sides.addAssumeCapacity(QuadEntity.initEntity(Point3{ min[0], min[1], min[2] }, dz, dy, material)); // left
    sides.addAssumeCapacity(QuadEntity.initEntity(Point3{ min[0], max[1], max[2] }, dx, -dz, material)); // top
    sides.addAssumeCapacity(QuadEntity.initEntity(Point3{ min[0], min[1], min[2] }, dx, dz, material)); // bottom

    return IEntity{ .collection = sides };
}

pub const QuadEntity = struct {
    const Self = @This();

    // Parallelogram parameterization.
    start_point: Point3,
    axis1: Vec3,
    axis2: Vec3,
    axis3: Vec3,

    // containing plane
    normal: Vec3,
    offset: Real,

    // Misc.
    material: *const IMaterial,
    aabb: AABB,

    pub fn initEntity(start: Point3, axis1: Vec3, axis2: Vec3, material: *const IMaterial) IEntity {
        // Calculate the plane containing this quad.
        const normal = math.cross(axis1, axis2);
        const axis3 = normal / math.vec3s(math.dot(normal, normal));

        const normal_unit = math.normalize(normal);
        const offset = math.dot(normal_unit, start);

        const bbox_diag1 = AABB.init(start, start + axis1 + axis2);
        const bbox_diag2 = AABB.init(start + axis1, start + axis2);
        const bbox = bbox_diag1.unionWith(&bbox_diag2);

        return IEntity{ .quad = Self{
            .start_point = start,
            .axis1 = axis1,
            .axis2 = axis2,
            .axis3 = axis3,

            .normal = normal_unit,
            .offset = offset,

            .material = material,
            .aabb = bbox,
        } };
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
        const alpha = math.dot(self.axis3, math.cross(planar_hit_point, self.axis2));
        const beta = math.dot(self.axis3, math.cross(self.axis1, planar_hit_point));

        if (!isInteriorPoint(alpha, beta)) return false;

        hit_record.t = t;
        hit_record.point = hit_point;
        hit_record.material = self.material;
        hit_record.setFrontFaceNormal(ctx.ray, self.normal);
        hit_record.tex_uv = Vec2{ alpha, beta };

        return true;
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
    movement_direction: Vec3 = .{ 0, 0, 0 },

    pub fn initEntity(center: Point3, radius: Real, material: *const IMaterial) IEntity {
        const rvec = math.vec3s(radius);

        return IEntity{ .sphere = Self{
            .center = center,
            .radius = radius,
            .material = material,
            .aabb = AABB.init(center - rvec, center + rvec),
        } };
    }

    pub fn initEntityAnimated(center_start: Point3, center_end: Point3, radius: Real, material: *const IMaterial) IEntity {
        const rvec = math.vec3s(radius);

        return IEntity{ .sphere = Self{
            .center = center_start,
            .radius = radius,
            .material = material,
            .b_is_moving = true,
            .movement_direction = center_end - center_start,
            .aabb = AABB
                .init(center_start - rvec, center_start + rvec)
                .unionWith(AABB.init(center_end - rvec, center_end + rvec)),
        } };
    }

    pub fn hit(self: *const Self, ctx: *const HitContext, hit_record: *HitRecord) bool {
        const tracy_zone = ztracy.ZoneN(@src(), "Sphere::hit");
        defer tracy_zone.End();

        // animation
        const center =
            if (self.b_is_moving) self.move(ctx.ray.time) else self.center;

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

    fn move(self: *const Self, time: Real) Point3 {
        // lerp towards target; assume time is in [0,1]
        return self.center + math.vec3s(time) * self.movement_direction;
    }

    /// Returns UV coordinates for the sphere.
    fn getSphereUv(v: *const Vec3) Vec2 {
        const theta = std.math.acos(-v[1]);
        const phi = std.math.atan2(-v[2], v[0]) + std.math.pi;
        return Vec2{
            phi / (2 * std.math.pi),
            theta / std.math.pi,
        };
    }
};

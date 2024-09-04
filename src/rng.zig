const std = @import("std");

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Point3 = math.Vec3;

const Interval = @import("interval.zig").Interval;

threadlocal var g_RNG: ?std.Random.DefaultPrng = null;

/// Thread-safe retrieval of random number generator. Works by implicitly creating a threadlocal singleton RNG. 
pub fn getThreadRng() std.Random {
    if (g_RNG == null) {
        g_RNG = createRng(null) 
            catch @panic("Could not get threadlocal RNG");
    }
    return g_RNG.?.random();
}
fn createRng(rng_seed: ?u64) std.posix.GetRandomError!std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(
        if (rng_seed) |seed| 
            seed
        else blk: {
            var seed: u64 = 0;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            std.log.debug("[thread {d}]\t\tSimulation RNG seed: {d}", .{std.Thread.getCurrentId(), seed});
            break :blk seed;
        }
    );
}

/// Sample a random enum value from the type.
pub fn sampleEnum(comptime E: type, rand: std.Random) E {
    const vals = comptime std.enums.values(E);
    return vals[rand.intRangeAtMost(usize, 0, vals.len - 1)];
}

pub fn sampleVec3(rng: std.Random) Vec3 {
    return Vec3{ 
        rng.float(math.Real), 
        rng.float(math.Real), 
        rng.float(math.Real),
    };
}

pub fn sampleVec3Interval(rng: std.Random, int: Interval(math.Real)) Vec3 {
    return Vec3{
        rng.float(math.Real) * int.size() + int.min,
        rng.float(math.Real) * int.size() + int.min,
        rng.float(math.Real) * int.size() + int.min,
    };
}

test "sampleVec3Interval" {
    var rng = try createRng(@intCast(std.testing.random_seed));
    for (0..128) |_| {
        const int = Interval(math.Real){ .min = 1.5, .max = 2.25 };
        const v = sampleVec3Interval(rng.random(), int);
        try std.testing.expect(int.min <= v[0] and v[0] <= int.max);
        try std.testing.expect(int.min <= v[1] and v[1] <= int.max);
        try std.testing.expect(int.min <= v[2] and v[2] <= int.max);
    }
}

/// Returns random point in the set [-0.5, 0.5] x [-0.5, 0.5].
pub fn sampleSquareXY(rng: std.Random) Point3 {
    return Vec3{
        rng.float(math.Real) - 0.5,
        rng.float(math.Real) - 0.5,
        0.0,
    };
}

pub inline fn sampleUnitCircleXY(rng: std.Random) Point3 {
    return math.normalize(Point3{ rng.floatNorm(math.Real), rng.floatNorm(math.Real), 0 });
}

/// Returns random point in disc of radius centered at (0, 0).
pub fn sampleUnitDiskXY(rng: std.Random, radius: math.Real) Point3 {
    return math.vec3s(radius * rng.float(math.Real)) * sampleUnitCircleXY(rng);
}

/// Returns random point in unit ball. Direct sampling i.e. no rejection sampling.
pub fn sampleUnitBall(rng: std.Random) Point3 {
    const radius = math.vec3s(rng.float(math.Real));
    return radius * sampleUnitSphere(rng);
}

/// Returns random point on surface of unit sphere. Direct sampling i.e. no rejection sampling.
pub fn sampleUnitSphere(rng: std.Random) Point3 {
    // Sample gaussian vector ~ N(0,I) and project it onto the sphere.
    const p = Point3{ 
        rng.floatNorm(math.Real), 
        rng.floatNorm(math.Real), 
        rng.floatNorm(math.Real), 
    };
    return math.normalize(p);
}

// Samples a point within a unit hemisphere defined via a normal vector. Direct sampling i.e. no rejection sampling.
pub fn sampleUnitHemisphere(rng: std.Random, normal: Vec3) Vec3 {
    const v = sampleUnitSphere(rng);
    return if (math.dot(normal, v) > 0.0) v else -v;
}

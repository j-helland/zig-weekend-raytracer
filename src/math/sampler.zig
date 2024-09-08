const std = @import("std");

const sm = @import("sobolmatrices.zig");
const rng = @import("rng.zig");

const FLOAT64_ONE_MINUS_EPSILON = 0x1.fffffffffffffp-1;
const FLOAT32_ONE_MINUS_EPSILON = 0x1.fffffep-1;

pub const RandomizerStrategy = enum {
    noop,
    owen_fast,
};

pub const IRandomizer = union(RandomizerStrategy) {
    const Self = @This();

    noop,
    owen_fast: OwenFastRandomizer,

    pub fn apply(self: *const Self, v: u32) u32 {
        return switch (self.*) {
            .noop => v,
            inline else => |*s| s.apply(v),
        };
    }
};

pub const OwenFastRandomizer = struct {
    const Self = @This();

    seed: u32,

    pub fn initRandomizer(seed: u32) IRandomizer {
        return IRandomizer{ .owen_fast = Self{ .seed = seed } };
    }

    /// Borrowed from: https://psychopath.io/post/2021_01_30_building_a_better_lk_hash
    /// NOTE: This algorithm is used in PBRT-v4 https://github.com/mmp/pbrt-v4/blob/39e01e61f8de07b99859df04b271a02a53d9aeb2/src/pbrt/util/lowdiscrepancy.h#L227-L233
    pub inline fn apply(self: *const Self, _v: u32) u32 {
        var v = _v;

        // zig fmt: off
        // Original algorithm (C/C++) seemingly doesn't care about overflow. 
        // If we don't handle this explicitly in Zig, we'll get runtime failures while sampling.
        v  = @bitReverse(v);
        v ^= @mulWithOverflow(v, 0x3d20adea)[0];            // v ^= v * 0x3d20adea
        v  = @addWithOverflow(v, self.seed)[0];             // v += seed;
        v  = @mulWithOverflow(v, (self.seed >> 16) | 1)[0]; // v *= (seed >> 16) | 1;
        v ^= @mulWithOverflow(v, 0x05526c56)[0];            // v ^= v * 0x05526c56;
        v ^= @mulWithOverflow(v, 0x53a22864)[0];            // v ^= v * 0x53a22864;
        // zig fmt: on
        return @bitReverse(v);
    }
};

pub fn ISampler(comptime T: type) type {
    requireFloat(T);

    return union(enum) {
        const Self = @This();

        independent: IndependentSampler(T),
        stratified: StratifiedSampler(T),
        sobol: SobolSampler(T),

        pub fn startPixelSample(self: *Self, pixel: [2]usize, sample_idx: usize) void {
            return switch (self.*) {
                inline else => |*s| s.startPixelSample(pixel, sample_idx),
            };
        }

        pub fn get2D(self: *Self) [2]T {
            return switch (self.*) {
                inline else => |*s| s.get2D(),
            };
        }

        pub fn getPixel2D(self: *Self) [2]T {
            return switch (self.*) {
                inline else => |*s| s.getPixel2D(),
            };
        }
    };
}

fn requireFloat(comptime T: type) void {
    if (@typeInfo(T) != .Float) {
        @compileError("Type is not a float: " ++ @typeName(T));
    }
}

pub fn IndependentSampler(comptime T: type) type {
    requireFloat(T);

    return struct {
        const Self = @This();

        rand: std.Random,

        pub fn initSampler(rand: std.Random) ISampler(T) {
            return ISampler(T){ .independent = Self{ .rand = rand } };
        }

        pub fn startPixelSample(_: *const Self, _: [2]usize, _: usize) void {}

        pub fn get2D(self: *Self) [2]T {
            const sample = rng.sampleSquareXY(self.rand);
            return .{ sample[0], sample[1] };
        }

        pub inline fn getPixel2D(self: *Self) [2]T {
            return self.get2D();
        }
    };
}

pub fn StratifiedSampler(comptime T: type) type {
    requireFloat(T);

    return struct {
        const Self = @This();

        rand: std.Random,
        sqrt_spp: usize,
        recip_sqrt_spp: T,

        px: T = 0,
        py: T = 0,
        si: T = 0,
        sj: T = 0,

        pub fn initSampler(
            rand: std.Random,
            sqrt_spp: usize,
            recip_sqrt_spp: T,
        ) ISampler(T) {
            return ISampler(T){ .stratified = Self{
                .rand = rand,
                .sqrt_spp = sqrt_spp,
                .recip_sqrt_spp = recip_sqrt_spp,
            } };
        }

        pub fn startPixelSample(self: *Self, _: [2]usize, sample_idx: usize) void {
            // Assuming evenly distributed sampled horizontally and vertically.
            self.si = @as(T, @floatFromInt(sample_idx / self.sqrt_spp));
            self.sj = @as(T, @floatFromInt(sample_idx % self.sqrt_spp));
        }

        pub fn get2D(self: *Self) [2]T {
            const px = (self.rand.float(T) + self.si) * self.recip_sqrt_spp - 0.5;
            const py = (self.rand.float(T) + self.sj) * self.recip_sqrt_spp - 0.5;
            return .{ px, py };
        }

        pub inline fn getPixel2D(self: *Self) [2]T {
            return self.get2D();
        }
    };
}

pub fn SobolSampler(comptime T: type) type {
    requireFloat(T);

    return struct {
        const Self = @This();

        samples_per_pixel: usize,
        scale: u32,
        randomizer_strategy: RandomizerStrategy,
        seed: u32,

        pixel: [2]usize = .{ 0, 0 },
        dimension: usize = 0,
        sobol_idx: u64 = 0,

        pub fn initSampler(
            samples_per_pixel: usize,
            image_width: u32,
            image_height: u32,
            randomizer_strategy: RandomizerStrategy,
            seed: u32,
        ) error{Overflow}!ISampler(T) {
            std.debug.assert(@typeInfo(T) == .Float);

            if (!std.math.isPowerOfTwo(samples_per_pixel)) {
                std.log.warn("Non power of two samples per pixel will perform poorly with sobol sampling: {d}", .{samples_per_pixel});
            }

            const scale = try std.math.ceilPowerOfTwo(u32, @max(image_width, image_height));
            return ISampler(T){ .sobol = Self{
                .samples_per_pixel = samples_per_pixel,
                .scale = scale,
                .randomizer_strategy = randomizer_strategy,
                .seed = seed,
            } };
        }

        pub fn startPixelSample(self: *Self, pixel: [2]usize, sample_idx: usize) void {
            self.pixel = pixel;
            self.dimension = 2;
            self.sobol_idx = sobolIntervalToIndex(std.math.log2_int(u32, self.scale), sample_idx, self.pixel);
        }

        pub fn get1D(self: *Self) T {
            defer self.dimension += 1;
            if (self.dimension >= sm.NSobolDimensions) {
                self.dimension = 2;
            }
            return @floatCast(self.sampleDimension(self.dimension));
        }

        pub fn get2D(self: *Self) [2]T {
            defer self.dimension += 2;
            if (self.dimension + 1 >= sm.NSobolDimensions) {
                self.dimension = 2;
            }
            return .{
                @floatCast(self.sampleDimension(self.dimension)),
                @floatCast(self.sampleDimension(self.dimension + 1)),
            };
        }

        pub fn getPixel2D(self: *Self) [2]T {
            var result = [2]T{
                @floatCast(sobolSample(self.sobol_idx, 0, .noop)),
                @floatCast(sobolSample(self.sobol_idx, 1, .noop)),
            };

            // remap sobol dimensions used for pixel samples
            for (0..2) |dim| {
                result[dim] = std.math.clamp(result[dim] * @as(T, @floatFromInt(self.scale)) - @as(T, @floatFromInt(self.pixel[dim])), 0, FLOAT32_ONE_MINUS_EPSILON);
            }

            return result;
        }

        fn sampleDimension(self: *const Self, dimension: usize) f32 {
            if (self.randomizer_strategy == .noop) {
                return sobolSample(self.sobol_idx, dimension, .noop);
            }

            const hash = std.hash.Murmur2_32.hashUint32WithSeed(@intCast(dimension), self.seed);
            const randomizer = switch (self.randomizer_strategy) {
                .owen_fast => OwenFastRandomizer.initRandomizer(hash),
                .noop => unreachable, // handled above
            };
            return sobolSample(self.sobol_idx, dimension, randomizer);
        }

        pub fn sobolSample(_a: u64, dimension: usize, randomizer: IRandomizer) f32 {
            var a = _a;

            var v: u32 = 0;
            var i: usize = dimension * sm.SobolMatrixSize;
            while (a != 0) : ({
                a >>= 1;
                i += 1;
            }) {
                if (a & 1 != 0) v ^= sm.SobolMatrices32[i];
            }

            v = randomizer.apply(v);
            const vf = @as(f32, @floatFromInt(v));
            return @min(vf * 0x1p-32, FLOAT32_ONE_MINUS_EPSILON);
        }

        /// Returns the index of the sample_idx'th sample in the pixel assuming that the sampling domain has been scaled by 2^log2_scale.
        fn sobolIntervalToIndex(log2_scale: std.math.Log2Int(u32), _sample_idx: u64, pixel: [2]usize) u64 {
            var sample_idx = _sample_idx;

            if (log2_scale == 0) return sample_idx;

            const scale2 = log2_scale << 1;
            var index: u64 = sample_idx << scale2;

            var delta: u64 = 0;
            var c: usize = 0;
            while (sample_idx > 0) : ({
                sample_idx >>= 1;
                c += 1;
            }) {
                // add flipped column: scale + c + 1
                if (sample_idx & 1 != 0) delta ^= sm.VdCSobolMatrices[log2_scale - 1][c];
            }

            // flipped b
            var b: u64 = ((pixel[0] << log2_scale) | pixel[1]) ^ delta;

            c = 0;
            while (b > 0) : ({
                b >>= 1;
                c += 1;
            }) {
                // add column: 2 * scale - c
                if (b & 1 != 0) index ^= sm.VdCSobolMatricesInv[log2_scale - 1][c];
            }

            return index;
        }
    };
}

// pub fn SobolBlueNoiseSampler(comptime T: type) type {
//     requireFloat(T);

//     return struct {
//         const Self = @This();

//         log2_samples_per_pixel: std.math.Log2Int(usize),
//         num_base4_digits: std.math.Log2Int(usize),
//         randomizer_strategy: RandomizerStrategy,
//         seed: u32,

//         pub fn initSampler(
//             samples_per_pixel: u32,
//             image_width: u32,
//             image_height: u32,
//             randomizer_strategy: RandomizerStrategy,
//             seed: u32,
//         ) error{Overflow}!ISampler(T) {
//             const resolution = try std.math.ceilPowerOfTwo(u32, @max(image_width, image_height));
//             const log2_samples_per_pixel = std.math.log2_int(u32, samples_per_pixel);
//             const log4_samples_per_pixel = (log2_samples_per_pixel + 1) / 2;
//             const num_base4_digits = std.math.log2_int(u32, resolution) + log4_samples_per_pixel;

//             return ISampler(T){ .sobol_blue_noise = Self{
//                 .log2_samples_per_pixel = log2_samples_per_pixel,
//                 .num_base4_digits = num_base4_digits,
//                 .randomizer_strategy = randomizer_strategy,
//                 .seed = seed,
//             }};
//         }

//         pub fn startPixelSample(self: *Self, pixel: [2]usize, sample_idx: usize) void {
//         }

//         pub fn get2D(self: *Self) [2]T {

//         }

//         pub fn getPixel2D(self: *Self) [2]T {

//         }

//         fn samplesPerPixel(self: *const Self) u32 {
//             return 1 << self.log2_samples_per_pixel;
//         }
//     };
// }

// test "SobolSampler" {
//     const math = @import("math.zig");

//     inline for (2 .. 10 + 1) |log_samples| {
//         const samples_per_pixel = 1 << log_samples;

//         var sampler = try SobolSampler(math.Real)
//             .init(samples_per_pixel, 1, 1, 0);

//         for (0..1) |px| {
//             for (0..1) |py| {
//                 for (0..samples_per_pixel) |sample_idx| {
//                     sampler.startPixelSample(.{px, py}, sample_idx, 0);
//                     const sample = sampler.get2D();
//                     std.debug.print("({d},{d}),\n", .{sample[0], sample[1]});
//                 }
//             }
//         }
//     }
// }

// fn checkSampler(comptime T: type, log_num_samples: comptime_int, sampler: Sampler(T), resolution: usize) !void {
//     var samples = std.ArrayList([2]T).init(std.testing.allocator);
//     defer samples.deinit();

//     inline for (2 .. log_num_samples + 1) |log_samples| {
//         const samples_per_pixel = 1 << log_samples;
//         samples.clearRetainingCapacity();

//         for (0..resolution) |px| {
//             for (0..resolution) |py| {
//                 for (0..samples_per_pixel) |sample_idx| {
//                     sampler.startPixelSample(.{px, py}, sample_idx);
//                     try samples.append(sampler.getPixel2D());
//                 }
//             }
//         }

//         try checkSamples(T, log_samples, samples);
//     }
// }

// fn checkSamples(comptime T: type, log_samples: comptime_int, samples: std.ArrayList([2]T)) !void {
//     inline for (0 .. log_samples + 1) |i| {
//         const nx =
//     }
// }

const std = @import("std");
const AllocatorError = std.mem.Allocator.Error;

const ztracy = @import("ztracy");
const zstbi = @import("zstbi");

const math = @import("math.zig");
const scn = @import("scene.zig");
const rng = @import("rng.zig");
const IEntity = @import("entity.zig").IEntity;
const Renderer = @import("render.zig").Renderer;
const Camera = @import("camera.zig").Camera;
const Framebuffer = @import("camera.zig").Framebuffer;
const WriterPPM = @import("writer.zig").WriterPPM;
const Timer = @import("timer.zig").Timer;

const ArgParser = @import("argparser.zig").ArgParser;
const ParseArgsError = @import("argparser.zig").ParseArgsError;

const UserArgs = struct {
    image_width: usize,
    image_height: usize,
    image_out_path: []const u8 = "image.ppm",
    thread_pool_size: usize = 8,
    scene: scn.SceneType = .emissive,
    samples_per_pixel: usize = 10,
    ray_bounce_max_depth: usize = 20,
};

/// Parse args passed via stdin.
fn parseUserArgs(allocator: std.mem.Allocator) !UserArgs {
    var parser = try ArgParser(UserArgs).init(allocator);
    defer parser.deinit();

    const input = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, input);
    
    const skip_exe_arg = 1;
    const argvals = input[skip_exe_arg..];

    const args = parser.parse(argvals) catch |err| {
        // print usage on any failure here for convenience
        try parser.printUsage(std.io.getStdErr().writer());
        return err;
    };
    return args.*;
}

pub fn main() !void {
    var timer = Timer.init();

    // ---- allocators ----
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var entity_pool = std.heap.MemoryPool(IEntity).init(std.heap.page_allocator);
    defer entity_pool.deinit();

    // ---- user args ----
    const args = parseUserArgs(allocator) catch |err| switch (err) {
        // help flag passed is okay terminal state
        ParseArgsError.HelpPassedInArgs => return,
        else => return err,
    };

    // ---- thread pool ----
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator, .n_jobs = args.thread_pool_size });
    defer thread_pool.deinit();

    // ---- ext lib init ----
    zstbi.init(allocator);
    defer zstbi.deinit();

    // ---- rendering ----
    var renderer = Renderer{
        .thread_pool = &thread_pool,
        .background_color = math.vec3(0, 0, 0),
        .clear_color = math.vec3(0, 0, 0),
        .samples_per_pixel = args.samples_per_pixel,
        .max_ray_bounce_depth = args.ray_bounce_max_depth,
    };

    var framebuffer = try Framebuffer.init(allocator, args.image_height, args.image_width);
    defer framebuffer.deinit();

    var scene = try scn.loadScene(args.scene, scn.SceneLoadContext{
        .allocator = allocator,
        .entity_pool = &entity_pool,
        .rand = rng.getThreadRng(),
    });
    defer scene.deinit();
    timer.logInfoElapsed("scene initialized");

    try scene.draw(&renderer, &framebuffer);
    timer.logInfoElapsed("scene rendered");

    // ---- write ----
    var writer = WriterPPM{
        .allocator = allocator,
        .thread_pool = &thread_pool,
    };
    try writer.write(args.image_out_path, framebuffer.buffer, framebuffer.num_cols, framebuffer.num_rows);
    timer.logInfoElapsed("scene written to file");
}

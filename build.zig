const std = @import("std");

const ASSET_DIR = "assets/";

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    enable_tracy: bool = false,
};

/// construct build graph
pub fn build(b: *std.Build) void {
    const opts = addOptions(b);

    const exe = b.addExecutable(.{
        .name = "weekend-raytracer",
        .root_source_file = b.path("src/main.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });    
    addDependencies(b, opts, exe);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // run step in build graph. 
    const run_cmd = b.addRunArtifact(exe);
    // run from installation directory
    run_cmd.step.dependOn(b.getInstallStep());
    // allow user args "zig build run -- arg1 arg2..."
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // expose "zig build run" to run run_cmd instead of default install step
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    addTests(b, opts);    
}

fn addOptions(b: *std.Build) Options {
    return Options{
        // User specified target.
        .target = b.standardTargetOptions(.{}),
        // User specified release mode.
        .optimize = b.standardOptimizeOption(.{}),

        // custom build flags
        .enable_tracy = b.option(bool, "enable-tracy", "Enable tracy profiling") 
            orelse false,
    };
}

fn addDependencies(b: *std.Build, opts: Options, exe: *std.Build.Step.Compile) void {
    // ---- 3P libs ----
    @import("system_sdk").addLibraryPathsTo(exe);

    // stbi_image
    {
        const zstbi = b.dependency("zstbi", .{});
        exe.root_module.addImport("zstbi", zstbi.module("root"));
        exe.linkLibrary(zstbi.artifact("zstbi"));
    }

    // tracy profiler
    {
        const ztracy = b.dependency("ztracy", .{
            .enable_ztracy = opts.enable_tracy,
            .enable_fibers = opts.enable_tracy,
        });
        exe.root_module.addImport("ztracy", ztracy.module("root"));
        exe.linkLibrary(ztracy.artifact("tracy"));
    }

    // ---- assets ----
    {
        const exe_options = b.addOptions();
        exe.root_module.addOptions("build_options", exe_options);

        exe_options.addOption([]const u8, "asset_dir", ASSET_DIR);
        const asset_path = b.pathJoin(&.{ASSET_DIR});
        const install_assets_step = b.addInstallDirectory(.{
            .source_dir = b.path(asset_path),
            .install_dir = .bin,
            .install_subdir = ASSET_DIR,
        });
        exe.step.dependOn(&install_assets_step.step);
    }
}

fn addTests(b: *std.Build, opts: Options) void {
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    addDependencies(b, opts, exe_unit_tests);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // expose "zig build test" to run test suite.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
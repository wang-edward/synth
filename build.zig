const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = std.builtin.OptimizeMode.Debug;

    // raylib
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    // soundio
    const soundio_dep = b.dependency("libsoundio", .{
        .target = target,
        .optimize = optimize,
    });
    const soundio_mod = soundio_dep.module("SoundIo");
    const soundio_artifact = soundio_dep.artifact("soundio");

    // exe
    const exe = b.addExecutable(.{
        .name = "synth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib },
                .{ .name = "raygui", .module = raygui },
                .{ .name = "soundio", .module = soundio_mod },
            },
        }),
    });
    exe.linkLibrary(raylib_artifact);
    exe.linkLibrary(soundio_artifact);
    exe.linkLibC();
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // graphics
    const graphics_demo = b.addExecutable(.{
        .name = "graphics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/graphics_demo/graphics_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib },
            },
        }),
    });
    graphics_demo.linkLibrary(raylib_artifact);
    graphics_demo.linkLibC();
    b.installArtifact(graphics_demo);
    const run_cmd_demo = b.addRunArtifact(graphics_demo);
    if (b.args) |args| run_cmd_demo.addArgs(args);
    const run_step_demo = b.step("demo", "Run emulated graphics");
    run_step_demo.dependOn(&run_cmd_demo.step);

    // double buffered audio graph demo
    const double_graph = b.addExecutable(.{
        .name = "double_graph",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/double_graph/double_graph.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib },
                .{ .name = "soundio", .module = soundio_mod },
            },
        }),
    });
    double_graph.linkLibrary(raylib_artifact);
    double_graph.linkLibrary(soundio_artifact);
    double_graph.linkLibC();
    b.installArtifact(double_graph);
    const run_cmd_double_graph = b.addRunArtifact(double_graph);
    if (b.args) |args| run_cmd_double_graph.addArgs(args);
    const run_step_double_graph = b.step("double", "Run double buffered graph demo");
    run_step_double_graph.dependOn(&run_cmd_double_graph.step);

    // test
    const queue_mod = b.createModule(.{
        .root_source_file = b.path("src/queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_queue.zig"),
            .imports = &.{
                .{ .name = "queue", .module = queue_mod },
            },
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_exe_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

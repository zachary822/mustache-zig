const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module. Other packages import it as "mustache_zig".
    const mod = b.addModule("mustache_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // The command-line tool: `zig build run -- TEMPLATE [DATA.json] [PARTIALS.json]`.
    const exe = b.addExecutable(.{
        .name = "mustache_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mustache_zig", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    // Generate one Zig test for each case in the Mustache spec.
    const spec_dir = b.dependency("mustache_spec", .{}).path("specs");
    const gen = b.addExecutable(.{
        .name = "gen_spec_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_spec_tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const gen_run = b.addRunArtifact(gen);
    gen_run.addDirectoryArg(spec_dir);
    const spec_tests_zig = gen_run.addOutputFileArg("spec_tests.zig");

    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose names contain this text") orelse &.{};

    const spec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = spec_tests_zig,
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mustache_zig", .module = mod }},
        }),
        .filters = test_filters,
    });
    const mod_tests = b.addTest(.{ .root_module = mod, .filters = test_filters });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_tests).step);
    // main.zig has no tests. Compile it, so `zig build test` finds errors in it.
    test_step.dependOn(&exe.step);
}

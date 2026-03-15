const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const cbor_dep = b.dependency("cbor", .{ .target = target, .optimize = optimize });
    const zqlite_dep = b.dependency("zqlite", .{ .target = target, .optimize = optimize });

    const superhtml_dep = b.dependency("superhtml", .{ .target = target, .optimize = optimize });

    // Library module (for consumption by other packages)
    const zigweb_mod = b.addModule("zigweb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigweb_mod.addImport("cbor", cbor_dep.module("cbor"));
    zigweb_mod.addImport("zqlite", zqlite_dep.module("zqlite"));
    zigweb_mod.addImport("superhtml", superhtml_dep.module("superhtml"));

    // zig build check -- verify all library code compiles
    const lib = b.addObject(.{
        .name = "zigweb",
        .root_module = zigweb_mod,
    });
    b.step("check", "Check compilation").dependOn(&lib.step);

    // zig build test
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/Database/migrate_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zqlite", zqlite_dep.module("zqlite"));

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);
}

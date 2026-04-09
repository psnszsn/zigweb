const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const cbor_dep = b.dependency("cbor", .{ .target = target, .optimize = optimize });

    const sqlite3_cflags = &[_][]const u8{
        "-std=c99",
        "-DSQLITE_ENABLE_FTS5",
    };
    const zqlite_dep = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
        .sqlite3 =  sqlite3_cflags,
    });

    // Library module (for consumption by other packages)
    const zigweb_mod = b.addModule("zigweb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigweb_mod.addImport("cbor", cbor_dep.module("cbor"));
    zigweb_mod.addImport("zqlite", zqlite_dep.module("zqlite"));

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

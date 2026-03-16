const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const zigweb_dep = b.dependency("zigweb", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption(bool, "bypass_login", b.option(bool, "bypass_login", "Bypass login for development") orelse false);

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addOptions("build_options", options);
    server_mod.addImport("zigweb", zigweb_dep.module("zigweb"));

    const server = b.addExecutable(.{
        .name = "demo",
        .root_module = server_mod,
    });
    b.installArtifact(server);

    // Install web assets
    b.installFile("web/style.css", "web/style.css");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(zigweb_dep.path("web/auth.js"), .prefix, "web/auth.js").step);

    // zig build run
    const run = b.addRunArtifact(server);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Start the demo server").dependOn(&run.step);
}

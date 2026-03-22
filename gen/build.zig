const std = @import("std");

pub fn build(b: *std.Build) void {
    const superhtml_dep = b.dependency("superhtml", .{});

    const gen_mod = b.createModule(.{
        .root_source_file = b.path("gen_attrs.zig"),
        .target = b.graph.host,
    });
    gen_mod.addImport("superhtml", superhtml_dep.module("superhtml"));

    const gen_attrs = b.addExecutable(.{
        .name = "gen_attrs",
        .root_module = gen_mod,
    });

    const gen_run = b.addRunArtifact(gen_attrs);
    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(gen_run.captureStdOut(.{}), "../src/generated_attrs.zig");

    b.getInstallStep().dependOn(&usf.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const superhtml_dep = b.dependency("superhtml", .{});
    const superhtml_mod = superhtml_dep.module("superhtml");

    const overlay = b.addWriteFiles();
    _ = overlay.addCopyDirectory(superhtml_dep.path("src"), "src", .{});
    const shim = overlay.add("src/superhtml_attrs.zig",
        \\pub const Ast = @import("html/Ast.zig");
        \\pub const Attribute = @import("html/Attribute.zig");
        \\
    );

    const attrs_mod = b.createModule(.{
        .root_source_file = shim,
        .target = b.graph.host,
    });
    for (superhtml_mod.import_table.keys(), superhtml_mod.import_table.values()) |name, mod| {
        attrs_mod.addImport(name, mod);
    }

    const gen_mod = b.createModule(.{
        .root_source_file = b.path("gen_attrs.zig"),
        .target = b.graph.host,
    });
    gen_mod.addImport("superhtml_attrs", attrs_mod);

    const gen_attrs = b.addExecutable(.{
        .name = "gen_attrs",
        .root_module = gen_mod,
    });

    const gen_run = b.addRunArtifact(gen_attrs);
    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(gen_run.captureStdOut(.{}), "../src/generated_attrs.zig");

    b.getInstallStep().dependOn(&usf.step);
}

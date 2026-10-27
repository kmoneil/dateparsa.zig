const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("dateparsa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src") },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check source formatting");
    fmt_step.dependOn(&fmt.step);

    // zigvet (github.com/kmoneil/zigvet) must be on PATH. Run from the build
    // root with relative paths so its findings print as src/x.zig:line:col.
    const vet = b.addSystemCommand(&.{ "zigvet", "src", "build.zig" });
    vet.setCwd(b.path("."));
    const vet_step = b.step("vet", "Check sources with zigvet");
    vet_step.dependOn(&vet.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("dateparsa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Which locales' words are compiled in. English always is.
    const locales = b.option(
        []const u8,
        "locales",
        "Comma-separated locale tags to compile in (default: all 20; en is always in)",
    ) orelse "all";
    const options = b.addOptions();
    options.addOption([]const u8, "locales", locales);
    mod.addOptions("build_options", options);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tools") },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check source formatting");
    fmt_step.dependOn(&fmt.step);

    // zigvet (github.com/kmoneil/zigvet) must be on PATH. Run from the build
    // root with relative paths so its findings print as src/x.zig:line:col.
    const vet = b.addSystemCommand(&.{ "zigvet", "src", "tools", "build.zig" });
    vet.setCwd(b.path("."));
    const vet_step = b.step("vet", "Check sources with zigvet");
    vet_step.dependOn(&vet.step);

    // Regenerates src/locale/*.zig from the Go dateparsa's locale tables.
    // A developer step: the generated files are committed, and the normal
    // build never runs it.
    const go_locale_dir = b.option(
        []const u8,
        "go-locale-dir",
        "The Go dateparsa's internal/locale/data, for the locales step",
    ) orelse "../../golang/go-dateparser/internal/locale/data";
    const gen = b.addExecutable(.{
        .name = "locale_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/locale_gen.zig"),
            .target = b.graph.host,
        }),
    });
    const run_gen = b.addRunArtifact(gen);
    run_gen.setCwd(b.path("."));
    run_gen.addArgs(&.{ go_locale_dir, "src/locale" });
    const locales_step = b.step("locales", "Regenerate src/locale/*.zig from the Go locale data");
    locales_step.dependOn(&run_gen.step);
}

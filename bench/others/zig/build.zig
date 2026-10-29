//! A build of its own, so that the library's build.zig.zon names no
//! dependency: zeit is fetched only here. tools/bench_others.sh runs it
//! with its package and cache directories under _bench/.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Always ReleaseFast, as bench/main.zig is.
    const dateparsa = b.dependency("dateparsa", .{ .target = target, .optimize = .ReleaseFast });
    const zeit = b.dependency("zeit", .{ .target = target, .optimize = .ReleaseFast });
    const exe = b.addExecutable(.{
        .name = "bench-zeit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "dateparsa", .module = dateparsa.module("dateparsa") },
                .{ .name = "zeit", .module = zeit.module("zeit") },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    // A measurement, not a build product: never served from the cache.
    run.has_side_effects = true;
    b.step("run", "Run the benchmark (-- -count N -benchtime MS)").dependOn(&run.step);
}

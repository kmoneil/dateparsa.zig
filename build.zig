const std = @import("std");
const zon = @import("build.zig.zon");

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
    options.addOption([]const u8, "version", zon.version);
    mod.addOptions("build_options", options);

    // The dateparsa command, cli/main.zig. `zig build` installs it into
    // zig-out/bin, and `zig build run -- detect data.csv --col 3` runs it.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "dateparsa", .module = mod }},
    });
    // Its own options, the version alone: the library's are the library
    // module's, and one file cannot be the root of two modules in a build.
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", zon.version);
    cli_mod.addOptions("build_options", cli_options);
    const cli = b.addExecutable(.{ .name = "dateparsa", .root_module = cli_mod });
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run", "Run the dateparsa command (-- detect FILE --col N)").dependOn(&run_cli.step);

    // The C ABI: src/c_api.zig behind include/dateparsa.h. Position
    // independent, static library too: most C toolchains link executables
    // as PIE, and gcc on Ubuntu refused the library without it.
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    c_mod.addOptions("build_options", options);

    // The tests are the library plus test data the package does not ship:
    // the golden corpus vendored from the Go original, and the C header as
    // Zig reads it, which src/c_api_test.zig checks the exports against.
    const header = b.addTranslateC(.{
        .root_source_file = b.path("include/dateparsa.h"),
        .target = target,
        .optimize = optimize,
        // The header needs only the compiler's own stdbool, stddef and
        // stdint, and the tests stay off libc.
        .link_libc = false,
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "golden_corpus",
                .module = b.createModule(.{ .root_source_file = b.path("testdata/golden.zig") }),
            },
            .{ .name = "dateparsa_h", .module = header.createModule() },
        },
    });
    test_mod.addOptions("build_options", options);
    const mod_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // The command's tests, then the command itself on a few inputs, for what
    // its tests cannot see from inside: arguments, files, standard input and
    // the exit status.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_mod })).step);
    for (cli_checks) |check| {
        const run = b.addRunArtifact(cli);
        run.setCwd(b.path("."));
        run.addArgs(check.args);
        run.addFileInput(b.path("testdata/cli/orders.csv"));
        if (check.stdin) |bytes| run.setStdIn(.{ .bytes = bytes });
        run.expectStdOutEqual(check.stdout);
        run.expectStdErrEqual(check.stderr);
        run.expectExitCode(check.code);
        test_step.dependOn(&run.step);
    }

    // libdateparsa for other languages, static unless -Dlinkage=dynamic,
    // installed with its header by `zig build lib`. A static library
    // carries the compiler runtime, so a C toolchain links it alone.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "libdateparsa's linkage for the lib step (default: static)",
    ) orelse .static;
    const lib = b.addLibrary(.{
        .linkage = linkage,
        .name = "dateparsa",
        .root_module = c_mod,
        .version = std.SemanticVersion.parse(zon.version) catch unreachable,
    });
    lib.bundle_compiler_rt = true;
    lib.installHeader(b.path("include/dateparsa.h"), "dateparsa.h");
    const lib_step = b.step("lib", "Build libdateparsa and install it with include/dateparsa.h");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

    // The libraries a release attaches: every dist target, static and
    // shared, ReleaseFast, each under zig-out/dist/dateparsa-<version>-<name>
    // with the header, the licences and the dateparsa command.
    // tools/dist.sh archives them. On Windows the static library is
    // dateparsa_static.lib, since the DLL's import library is dateparsa.lib.
    const dist_step = b.step("dist", "Build the release libraries and command into zig-out/dist (tools/dist.sh archives them)");
    for (dist_targets) |dt| {
        const dist_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = dt.query }) catch unreachable);
        const windows = dist_target.result.os.tag == .windows;
        const dir = b.fmt("dist/dateparsa-{s}-{s}", .{ zon.version, dt.name });
        const dist_mod = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = dist_target,
            .optimize = .ReleaseFast,
            .pic = true,
            .strip = true,
        });
        dist_mod.addOptions("build_options", options);
        const dist_static = b.addLibrary(.{
            .linkage = .static,
            .name = if (windows) "dateparsa_static" else "dateparsa",
            .root_module = dist_mod,
        });
        dist_static.bundle_compiler_rt = true;
        const dist_shared = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "dateparsa",
            .root_module = dist_mod,
            .version = std.SemanticVersion.parse(zon.version) catch unreachable,
        });
        // The command, in bin: its own code with safety checks, as the newer
        // and less exercised part, and the library as fast as the libraries
        // beside it.
        const dist_root = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = dist_target,
            .optimize = .ReleaseFast,
            .strip = true,
        });
        dist_root.addOptions("build_options", options);
        const dist_cli = b.addExecutable(.{
            .name = "dateparsa",
            .root_module = b.createModule(.{
                .root_source_file = b.path("cli/main.zig"),
                .target = dist_target,
                .optimize = .ReleaseSafe,
                .strip = true,
                .imports = &.{.{ .name = "dateparsa", .module = dist_root }},
            }),
        });
        dist_cli.root_module.addOptions("build_options", cli_options);
        dist_step.dependOn(&b.addInstallArtifact(dist_cli, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/bin", .{dir}) } },
            .implib_dir = .disabled,
            .pdb_dir = .disabled,
        }).step);
        const lib_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}/lib", .{dir}) };
        for ([_]*std.Build.Step.Compile{ dist_static, dist_shared }) |artifact| {
            dist_step.dependOn(&b.addInstallArtifact(artifact, .{
                .dest_dir = .{ .override = if (artifact.isDll()) .{ .custom = b.fmt("{s}/bin", .{dir}) } else lib_dir },
                .implib_dir = if (artifact.isDll()) .{ .override = lib_dir } else .disabled,
                .pdb_dir = .disabled,
                .h_dir = .disabled,
            }).step);
        }
        for ([_][2][]const u8{
            .{ "include/dateparsa.h", "include/dateparsa.h" },
            .{ "LICENSE", "LICENSE" },
            .{ "NOTICE", "NOTICE" },
        }) |file| {
            dist_step.dependOn(&b.addInstallFileWithDir(b.path(file[0]), .{ .custom = dir }, file[1]).step);
        }
    }

    // test/c_api.c, a C program, against the static library and the
    // header; and the header compiled as C++, which only has to compile.
    const static_lib = if (linkage == .static) lib else b.addLibrary(.{
        .name = "dateparsa",
        .root_module = c_mod,
    });
    static_lib.bundle_compiler_rt = true;
    const c_flags: []const []const u8 = &.{ "-Wall", "-Wextra", "-Werror", "-pedantic" };
    const c_test = b.addExecutable(.{
        .name = "c_api_test",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_test.root_module.addCSourceFile(.{
        .file = b.path("test/c_api.c"),
        .flags = c_flags ++ &[_][]const u8{"-std=c11"},
    });
    c_test.root_module.addIncludePath(b.path("include"));
    c_test.root_module.linkLibrary(static_lib);
    test_step.dependOn(&b.addRunArtifact(c_test).step);
    const cpp_header = b.addObject(.{
        .name = "header_cpp",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    cpp_header.root_module.addCSourceFile(.{
        .file = b.path("test/header.cpp"),
        .flags = c_flags ++ &[_][]const u8{"-std=c++11"},
    });
    cpp_header.root_module.addIncludePath(b.path("include"));
    test_step.dependOn(&cpp_header.step);

    // The fuzz targets alone. `zig build fuzz` replays their seeds, and
    // tools/fuzz.sh runs them under the fuzzer with --fuzz. Always the LLVM
    // backend: the self-hosted x86_64 one, the Debug default there, emits no
    // coverage instrumentation, and the fuzzer refuses to run blind
    // ("corrupted coverage file ...: pcs_len was zero").
    const fuzz_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = &.{"fuzz:"},
        .use_llvm = true,
    });
    const fuzz_step = b.step("fuzz", "Replay the fuzz seeds (tools/fuzz.sh to fuzz)");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // The Go library's benchmark matrix on this port, always ReleaseFast;
    // tools/bench.sh runs it against the Go benchmarks.
    const bench_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_lib.addOptions("build_options", options);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "dateparsa", .module = bench_lib }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    // A measurement, not a build product: never served from the cache.
    run_bench.has_side_effects = true;
    const bench_step = b.step("bench", "Run the benchmarks (-- -count N -benchtime MS -bench NAME)");
    bench_step.dependOn(&run_bench.step);
    const install_bench = b.step("bench-install", "Install the benchmark binary, for tools/bench.sh");
    install_bench.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);

    // API documentation, from the doc comments, into zig-out/docs.
    const docs_obj = b.addObject(.{ .name = "dateparsa", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src"), b.path("cli"), b.path("tools"), b.path("bench") },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check source formatting");
    fmt_step.dependOn(&fmt.step);

    // zigvet (github.com/kmoneil/zigvet) must be on PATH. Run from the build
    // root with relative paths so its findings print as src/x.zig:line:col.
    const vet = b.addSystemCommand(&.{ "zigvet", "src", "cli", "tools", "bench", "build.zig" });
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

    // Regenerates src/unicode_data.zig from Go's unicode package, so that
    // natural-language lowercasing and word boundaries match the Go original.
    // A developer step needing `go` on PATH; the output is committed.
    const unicode_gen = b.addSystemCommand(&.{
        "go",
        "run",
        "tools/unicode_gen.go",
        "src/unicode_data.zig",
    });
    unicode_gen.setCwd(b.path("."));
    const unicode_step = b.step("unicode", "Regenerate src/unicode_data.zig from Go's tables");
    unicode_step.dependOn(&unicode_gen.step);

    // Answer a Go oracle file with this port; tools/oracle.sh runs them.
    // The natural-language one drives src/natural.zig as its own module,
    // which is why the two are separate programs: a file belongs to one
    // module.
    const natural_mod = b.createModule(.{
        .root_source_file = b.path("src/natural.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    natural_mod.addOptions("build_options", options);
    const oracles = [_]struct { []const u8, []const u8, []const u8, *std.Build.Module }{
        .{ "oracle-api", "tools/oracle_api.zig", "dateparsa", mod },
        .{ "oracle-natural", "tools/oracle_natural.zig", "natural", natural_mod },
    };
    for (oracles) |o| {
        const exe = b.addExecutable(.{
            .name = o[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(o[1]),
                .target = target,
                .optimize = .ReleaseSafe,
                .imports = &.{.{ .name = o[2], .module = o[3] }},
            }),
        });
        const run_exe = b.addRunArtifact(exe);
        run_exe.addPassthruArgs();
        const step = b.step(o[0], "Answer a Go oracle file with this port (see tools/oracle.sh)");
        step.dependOn(&run_exe.step);
    }

    // The format strings layouts give, for tools/format_check.sh to try in
    // Python, Go and Java.
    const format_strings = b.addExecutable(.{
        .name = "format-strings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/format_strings.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "dateparsa", .module = mod }},
        }),
    });
    const run_format_strings = b.addRunArtifact(format_strings);
    run_format_strings.has_side_effects = true;
    b.step("format-strings", "Print each example's format string in every dialect (tools/format_check.sh)").dependOn(&run_format_strings.step);
}

/// The platforms a release carries libdateparsa for. macOS from 13, the
/// oldest the hosted runners and Apple still support; Linux and Windows
/// libraries link no libc, so any glibc, musl or C runtime takes them.
const dist_targets = [_]struct { name: []const u8, query: []const u8 }{
    .{ .name = "x86_64-linux", .query = "x86_64-linux-gnu" },
    .{ .name = "aarch64-linux", .query = "aarch64-linux-gnu" },
    .{ .name = "x86_64-macos", .query = "x86_64-macos.13.0" },
    .{ .name = "aarch64-macos", .query = "aarch64-macos.13.0" },
    .{ .name = "x86_64-windows", .query = "x86_64-windows-msvc" },
    .{ .name = "aarch64-windows", .query = "aarch64-windows-msvc" },
};

/// What `zig build test` runs the command with, and what it must write and
/// exit with. A file is read twice, from its start; standard input is held
/// for the second pass, or streamed when --order leaves only one.
const cli_checks = [_]struct {
    args: []const []const u8,
    stdin: ?[]const u8 = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    code: u8 = 0,
}{
    .{ .args = &.{"--version"}, .stdout = "dateparsa " ++ zon.version ++ "\n" },
    .{
        .args = &.{ "detect", "testdata/cli/orders.csv", "--col", "date" },
        .stdout =
        \\values     3, and 1 empty
        \\read       3
        \\order      day first, settled by line 3: "13/02/2024"
        \\ambiguous  2, read day first as the column settles
        \\
        \\values  example     strftime  go          java
        \\     3  01/02/2024  %d/%m/%Y  02/01/2006  dd/MM/yyyy
        \\
        ,
    },
    .{
        .args = &.{ "normalize", "testdata/cli/orders.csv", "--col", "date" },
        .stdout = "id,date,amount\n1,2024-02-01T00:00:00Z,10.00\n2,2024-02-13T00:00:00Z,12.50\n3,,7.25\n4,2024-03-05T00:00:00Z,3.10\n",
    },
    .{
        .args = &.{"normalize"},
        .stdin = "01/02/2024\n13/02/2024\n",
        .stdout = "2024-02-01T00:00:00Z\n2024-02-13T00:00:00Z\n",
    },
    .{
        .args = &.{ "normalize", "-", "--order", "month-first" },
        .stdin = "01/02/2024\n",
        .stdout = "2024-01-02T00:00:00Z\n",
    },
    .{
        .args = &.{ "normalize", "-" },
        .stdin = "01/02/2024\n",
        .stderr = "dateparsa: the column's date order is not settled: month first or day first each read every value\n" ++
            "Pass --order to choose one, or run dateparsa detect to see the values.\n",
        .code = 1,
    },
    .{
        .args = &.{ "detect", "testdata/cli/orders.csv", "--col", "when" },
        .stderr = "dateparsa: no column when in the header of testdata/cli/orders.csv: \"id\", \"date\", \"amount\"\n",
        .code = 2,
    },
    .{
        .args = &.{ "detect", "testdata/cli/none.csv" },
        .stderr = "dateparsa: cannot read testdata/cli/none.csv: no such file\n",
        .code = 2,
    },
    .{
        .args = &.{ "detect", "--colour" },
        .stderr = "dateparsa: no option --colour\nRun dateparsa --help for the options.\n",
        .code = 2,
    },
};

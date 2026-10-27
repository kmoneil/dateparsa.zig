//! The Go dateparsa's benchmark matrix (bench_test.go and phase2_test.go to
//! phase4_test.go there), on this port, under the same names. It prints Go's
//! benchmark format, one line per run, so tools/bench.sh and benchstat read
//! both libraries' results alike.
//!
//!   zig build bench -- [-count N] [-benchtime MS] [-bench NAME] [-list]
//!
//! -bench runs the benchmarks whose name holds NAME, or, written ^NAME$,
//! the one named NAME, as the same pattern does for go test.
//!
//! Built ReleaseFast, whatever -Doptimize says. B/op and allocs/op are 0 by
//! construction: no API takes an allocator, and no file under src/ outside
//! the tests names one.
//!
//! Left out: BenchmarkVsStdlib and the Compile benchmarks (no Go layout
//! strings here), and flextime's (std.json glue is t18).

const std = @import("std");
const builtin = @import("builtin");
const dp = @import("dateparsa");

const Io = std.Io;

/// The base time of the Go natural-language and locale benchmarks.
const base: dp.DateTime = .{ .year = 2024, .month = 3, .day = 15, .hour = 12 };

const Bench = struct {
    name: []const u8,
    /// Runs the operation n times.
    run: *const fn (n: u64) void,
    /// Input bytes per operation, reported as MB/s too, as Go's SetBytes.
    bytes: usize = 0,
};

/// s, reloaded from memory, so that the compiler cannot hoist a parse of a
/// constant out of the loop.
inline fn opaqueInput(s: *[]const u8) []const u8 {
    std.mem.doNotOptimizeAway(s);
    return s.*;
}

fn parseWith(comptime s: []const u8, comptime opts: dp.Options) *const fn (u64) void {
    return struct {
        fn run(n: u64) void {
            var in: []const u8 = s;
            for (0..n) |_| std.mem.doNotOptimizeAway(dp.parseWith(opaqueInput(&in), opts));
        }
    }.run;
}

fn parse(comptime s: []const u8) *const fn (u64) void {
    return parseWith(s, .{});
}

fn detect(comptime s: []const u8) *const fn (u64) void {
    return struct {
        fn run(n: u64) void {
            var in: []const u8 = s;
            for (0..n) |_| std.mem.doNotOptimizeAway(dp.detect(opaqueInput(&in), .{}));
        }
    }.run;
}

/// The layout detected from first, re-parsing row, rows times per operation.
fn layoutRows(comptime first: []const u8, comptime row: []const u8, comptime rows: u64) *const fn (u64) void {
    return struct {
        fn run(n: u64) void {
            var l = (dp.parse(first) catch unreachable).layout;
            std.mem.doNotOptimizeAway(&l);
            var in: []const u8 = row;
            for (0..n * rows) |_| std.mem.doNotOptimizeAway(l.parse(opaqueInput(&in)));
        }
    }.run;
}

fn layout(comptime first: []const u8, comptime row: []const u8) *const fn (u64) void {
    return layoutRows(first, row, 1);
}

/// A Parser primed with first once, then parsing row.
fn parserCached(comptime first: []const u8, comptime row: []const u8) *const fn (u64) void {
    return struct {
        fn run(n: u64) void {
            var p = dp.Parser.init(.{});
            _ = p.parse(first) catch unreachable;
            var in: []const u8 = row;
            for (0..n) |_| std.mem.doNotOptimizeAway(p.parse(opaqueInput(&in)));
        }
    }.run;
}

/// A fresh Parser per operation through a column of rows copies of row, as
/// Go's ParseColumn: the first row detects. ParseColumn also allocates the
/// results, where this keeps none.
fn parserColumn(comptime row: []const u8, comptime rows: u64) *const fn (u64) void {
    return struct {
        fn run(n: u64) void {
            var in: []const u8 = row;
            for (0..n) |_| {
                var p = dp.Parser.init(.{});
                for (0..rows) |_| std.mem.doNotOptimizeAway(p.parse(opaqueInput(&in)));
            }
        }
    }.run;
}

const miss_short = "N/A";
const miss_text = "not a date at all";
const miss_long = "the quick brown fox jumps over the lazy dog and then some more text ";

const fr_de_es: dp.LocaleSet = .{ .fr = true, .de = true, .es = true };

const benches = [_]Bench{
    // bench_test.go
    .{ .name = "Parse_ISO8601", .run = parse("2024-03-15") },
    .{ .name = "Parse_ISO8601_DateTime", .run = parse("2024-03-15T10:30:00Z") },
    .{ .name = "Parse_RFC3339", .run = parse("2024-03-15T10:30:00+05:30") },
    .{ .name = "Parse_SQLDatetime", .run = parse("2024-03-15 10:30:00") },
    .{ .name = "Parse_TextualMonth", .run = parse("March 15, 2024") },
    .{ .name = "Parse_RFC2822_Locales", .run = parseWith("Fri, 15 Mar 2024 10:30:00 +0000", .{ .locales = fr_de_es }) },
    .{ .name = "Parse_AmbiguousSlash", .run = parse("03/15/2024") },
    .{ .name = "Parse_Miss_Short", .run = parse(miss_short) },
    .{ .name = "Parse_Miss_Text", .run = parse(miss_text) },
    .{ .name = "Parse_Miss_Long", .run = parse(miss_long), .bytes = miss_long.len },
    .{ .name = "Parse_Miss_Locales", .run = parseWith(miss_text, .{ .locales = fr_de_es }) },
    .{ .name = "Parse_Miss_Locales_NonLatin", .run = parseWith(miss_text, .{ .locales = .{ .ru = true, .zh = true, .ja = true } }) },
    .{ .name = "Layout_Parse", .run = layout("2024-03-15T10:30:00Z", "2025-01-01T00:00:00Z") },
    .{ .name = "Layout_Parse_ISODate", .run = layout("2024-03-15", "2025-06-15") },
    .{ .name = "Layout_Parse_TextualMonth", .run = layout("March 15, 2024", "March 16, 2025") },
    .{ .name = "Detect_Only", .run = detect("2024-03-15T10:30:00Z") },
    .{ .name = "Detect_TrieMiss_Fallback", .run = detect("March 15, 2024") },
    .{ .name = "Detect_NoMatch", .run = detect(miss_text) },
    .{ .name = "Parser_Cached", .run = parserCached("2024-03-15T10:30:00Z", "2025-01-01T00:00:00Z") },
    .{ .name = "10M_Layout_Parse", .run = layoutRows("2024-03-15T10:30:00Z", "2025-01-15T08:30:00Z", 10_000_000) },
    .{ .name = "10M_Parser_ParseColumn", .run = parserColumn("2024-06-15T12:00:00Z", 10_000_000) },
    .{ .name = "Layout_Parse_TZName_CET", .run = layout("2024-03-15 10:30:00 CET", "2024-03-15 10:30:00 CET") },
    .{ .name = "Layout_Parse_TZOffset_OffGrid", .run = layout("2024-03-15T10:30:00+05:53", "2024-03-15T10:30:00+05:53") },
    .{ .name = "Layout_Parse_TZOffset_OnGrid", .run = layout("2024-03-15T10:30:00+05:30", "2024-03-15T10:30:00+05:30") },
    // phase2_test.go. Go's Parse reads the clock for a year-less input;
    // this port takes the base time instead.
    .{ .name = "Parse_Compact", .run = parse("20240315") },
    .{ .name = "Parse_CompactDateTime", .run = parse("20240315T103000") },
    .{ .name = "Parse_UnixTimestamp", .run = parse("1710504800") },
    .{ .name = "Parse_ISOWeekDate", .run = parse("2024-W11-5") },
    .{ .name = "Parse_ISOOrdinal", .run = parse("2024-074") },
    .{ .name = "Parse_TimeAMPM", .run = parseWith("10:30 PM", .{ .base_time = base }) },
    .{ .name = "Parse_SQLFrac6", .run = parse("2024-03-15 10:30:00.000000") },
    .{ .name = "Layout_Parse_Compact", .run = layout("20240315", "20250101") },
    // phase3_test.go
    .{ .name = "Parse_NL_Yesterday", .run = parseWith("yesterday", .{ .base_time = base }) },
    .{ .name = "Parse_NL_3DaysAgo", .run = parseWith("3 days ago", .{ .base_time = base }) },
    .{ .name = "Parse_NL_NextFriday", .run = parseWith("next friday", .{ .base_time = base }) },
    .{ .name = "Parse_NL_YesterdayAt5pm", .run = parseWith("yesterday at 5pm", .{ .base_time = base }) },
    .{ .name = "Parse_NL_BeginningOfMonth", .run = parseWith("beginning of month", .{ .base_time = base }) },
    .{ .name = "Parse_NL_In10Minutes", .run = parseWith("in 10 minutes", .{ .base_time = base }) },
    // phase4_test.go
    .{ .name = "Parse_Locale_FrenchMonth", .run = parseWith("15 mars 2024", .{ .locales = .{ .fr = true } }) },
    .{ .name = "Parse_Locale_FrenchNL", .run = parseWith("hier", .{ .locales = .{ .fr = true }, .base_time = base }) },
    .{ .name = "Parse_Locale_GermanMonth", .run = parseWith("15 März 2024", .{ .locales = .{ .de = true } }) },
    .{ .name = "Parse_Locale_RussianNL", .run = parseWith("3 дня назад", .{ .locales = .{ .ru = true }, .base_time = base }) },
};

fn elapsed(io: Io, b: Bench, n: u64) u64 {
    const start = Io.Timestamp.now(io, .awake);
    b.run(n);
    const ns = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@max(ns, 1));
}

/// The iteration count whose run takes at least goal_ns, grown as Go's
/// testing package grows b.N: from a prediction, by at most 100x a step.
fn calibrate(io: Io, b: Bench, goal_ns: u64) u64 {
    var n: u64 = 1;
    var ns = elapsed(io, b, n);
    while (ns < goal_ns and n < 1_000_000_000) {
        const predicted = goal_ns * n / ns * 6 / 5;
        n = @max(@min(predicted, n * 100), n + 1);
        ns = elapsed(io, b, n);
    }
    return n;
}

fn usage() noreturn {
    std.debug.print("usage: bench [-count N] [-benchtime MS] [-bench NAME] [-list]\n", .{});
    std.process.exit(2);
}

/// Whether name holds pattern, or is it, for a pattern written ^NAME$.
fn matches(name: []const u8, pattern: []const u8) bool {
    if (pattern.len >= 2 and pattern[0] == '^' and pattern[pattern.len - 1] == '$') {
        return std.mem.eql(u8, name, pattern[1 .. pattern.len - 1]);
    }
    return std.mem.indexOf(u8, name, pattern) != null;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var count: u32 = 1;
    var benchtime_ms: u64 = 1000;
    var filter: []const u8 = "";
    var list = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "-list")) {
            list = true;
            continue;
        }
        if (i + 1 == args.len) usage();
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, flag, "-count")) {
            count = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "-benchtime")) {
            benchtime_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, flag, "-bench")) {
            filter = value;
        } else usage();
    }

    var buf: [4096]u8 = undefined;
    // Streaming, not positional: a positional writer on stdout redirected to
    // a file writes from offset 0, over what an earlier run appended.
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;
    const procs = std.Thread.getCpuCount() catch 1;
    if (list) {
        for (benches) |b| if (matches(b.name, filter)) try w.print("{s}\n", .{b.name});
        return w.flush();
    }
    try w.print("goos: {t}\ngoarch: {t}\npkg: dateparsa.zig\n", .{ builtin.os.tag, builtin.cpu.arch });
    try w.flush();
    for (benches) |b| {
        if (!matches(b.name, filter)) continue;
        const n = calibrate(io, b, benchtime_ms * std.time.ns_per_ms);
        for (0..count) |_| {
            const ns = elapsed(io, b, n);
            const per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
            try w.print("Benchmark{s}-{d}\t{d}\t{d:.2} ns/op", .{ b.name, procs, n, per_op });
            if (b.bytes > 0) try w.print("\t{d:.2} MB/s", .{@as(f64, @floatFromInt(b.bytes)) * 1000 / per_op});
            try w.writeAll("\t0 B/op\t0 allocs/op\n");
            try w.flush();
        }
    }
}

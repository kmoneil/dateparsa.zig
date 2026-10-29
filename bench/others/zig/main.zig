//! dateparsa against zeit (github.com/rockorager/zeit), the Zig date and
//! time library, on the formats zeit reads: ISO 8601 and RFC 3339, and RFC
//! 5322. tools/bench_others.sh builds and runs it.
//!
//!   zig build run -- [-count N] [-benchtime MS]
//!
//! Prints a Markdown table of the time per parse, the median of -count
//! rounds. A round times every parser on every input, in an order that
//! turns by one each round. Before timing, each parser reads each input
//! once, and an answer that is not the instant the input names is reported
//! instead of timed.
//!
//! dateparsa runs twice: detecting the format on every call, as parse does,
//! and reusing the layout detected from the input, as a column's rows do.
//! zeit is told the format.

const std = @import("std");
const dp = @import("dateparsa");
const zeit = @import("zeit");

const Io = std.Io;

const Case = struct {
    input: []const u8,
    /// Nanoseconds since 1970-01-01T00:00:00Z, or null when the input is no
    /// date and every parser should refuse it.
    want: ?i128,
    /// The parser zeit is given, or null for a format it has none for.
    zeit: ?ZeitFormat,
};

const ZeitFormat = enum { iso8601, rfc5322 };

const s = std.time.ns_per_s;

const cases = [_]Case{
    .{ .input = "2024-03-15T10:30:00Z", .want = 1710498600 * s, .zeit = .iso8601 },
    .{ .input = "2024-03-15T10:30:00+05:30", .want = 1710478800 * s, .zeit = .iso8601 },
    .{ .input = "2024-03-15T10:30:00.123456789Z", .want = 1710498600 * s + 123456789, .zeit = .iso8601 },
    .{ .input = "2024-03-15 10:30:00", .want = 1710498600 * s, .zeit = .iso8601 },
    .{ .input = "2024-03-15", .want = 1710460800 * s, .zeit = .iso8601 },
    .{ .input = "20240315T103000Z", .want = 1710498600 * s, .zeit = .iso8601 },
    .{ .input = "Fri, 15 Mar 2024 10:30:00 +0000", .want = 1710498600 * s, .zeit = .rfc5322 },
    .{ .input = "03/15/2024", .want = 1710460800 * s, .zeit = null },
    .{ .input = "March 15, 2024", .want = 1710460800 * s, .zeit = null },
    .{ .input = "not a date at all", .want = null, .zeit = .iso8601 },
};

/// What a parser made of an input.
const Answer = union(enum) {
    time: i128,
    refused,
    /// The parser has no way to read this input's format.
    unsupported,
};

const Impl = struct {
    name: []const u8,
    answer: *const fn (c: Case) Answer,
    /// Parses c.input n times.
    run: *const fn (c: Case, n: u64) void,
};

/// in, reloaded from memory, so that the compiler cannot hoist a parse of a
/// constant out of the loop.
inline fn opaqueInput(in: *[]const u8) []const u8 {
    std.mem.doNotOptimizeAway(in);
    return in.*;
}

fn nanos(e: dp.DateTime.Epoch) i128 {
    return @as(i128, e.seconds) * s + e.nanosecond;
}

const impls = [_]Impl{
    .{
        .name = "dateparsa parse",
        .answer = struct {
            fn f(c: Case) Answer {
                const r = dp.parse(c.input) catch return .refused;
                return .{ .time = nanos(r.time.toEpoch()) };
            }
        }.f,
        .run = struct {
            fn f(c: Case, n: u64) void {
                var in = c.input;
                for (0..n) |_| std.mem.doNotOptimizeAway(dp.parse(opaqueInput(&in)));
            }
        }.f,
    },
    .{
        .name = "dateparsa layout",
        .answer = struct {
            fn f(c: Case) Answer {
                const r = dp.parse(c.input) catch return .unsupported;
                if (!r.layout.reusable()) return .unsupported;
                const t = r.layout.parse(c.input) catch return .refused;
                return .{ .time = nanos(t.toEpoch()) };
            }
        }.f,
        .run = struct {
            fn f(c: Case, n: u64) void {
                var l = (dp.parse(c.input) catch unreachable).layout;
                std.mem.doNotOptimizeAway(&l);
                var in = c.input;
                for (0..n) |_| std.mem.doNotOptimizeAway(l.parse(opaqueInput(&in)));
            }
        }.f,
    },
    .{
        .name = "zeit",
        .answer = struct {
            fn f(c: Case) Answer {
                const format = c.zeit orelse return .unsupported;
                const t = zeitParse(format, c.input) catch return .refused;
                return .{ .time = t.instant().timestamp };
            }
        }.f,
        .run = struct {
            fn f(c: Case, n: u64) void {
                var in = c.input;
                switch (c.zeit.?) {
                    inline else => |format| for (0..n) |_| {
                        std.mem.doNotOptimizeAway(zeitParse(format, opaqueInput(&in)));
                    },
                }
            }
        }.f,
    },
};

fn zeitParse(format: ZeitFormat, in: []const u8) !zeit.Time {
    return switch (format) {
        .iso8601 => zeit.Time.fromISO8601(in),
        .rfc5322 => zeit.Time.fromRFC5322(in),
    };
}

const Cell = union(enum) {
    /// Nanoseconds a parse, the median of the rounds.
    ns: f64,
    unsupported,
    /// Refused an input it should read.
    refused,
    /// Read the input as another instant.
    wrong: Answer,
};

fn elapsed(io: Io, impl: Impl, c: Case, n: u64) u64 {
    const start = Io.Timestamp.now(io, .awake);
    impl.run(c, n);
    const ns = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@max(ns, 1));
}

/// The iteration count whose run takes at least goal_ns, grown as Go's
/// testing package grows b.N: from a prediction, by at most 100x a step.
fn calibrate(io: Io, impl: Impl, c: Case, goal_ns: u64) u64 {
    var n: u64 = 1;
    var ns = elapsed(io, impl, c, n);
    while (ns < goal_ns and n < 1_000_000_000) {
        const predicted = goal_ns * n / ns * 6 / 5;
        n = @max(@min(predicted, n * 100), n + 1);
        ns = elapsed(io, impl, c, n);
    }
    return n;
}

/// What a parser should be timed on: an input it reads as the instant the
/// input names, or a non-date it refuses.
fn check(c: Case, a: Answer) ?Cell {
    switch (a) {
        .unsupported => return .unsupported,
        .refused => return if (c.want == null) null else .refused,
        .time => |t| return if (c.want != null and c.want.? == t) null else .{ .wrong = a },
    }
}

fn usage() noreturn {
    std.debug.print("usage: bench-zeit [-count N] [-benchtime MS]\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var count: usize = 10;
    var benchtime_ms: u64 = 200;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) usage();
        const value = args[i + 1];
        if (std.mem.eql(u8, args[i], "-count")) {
            count = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, args[i], "-benchtime")) {
            benchtime_ms = try std.fmt.parseInt(u64, value, 10);
        } else usage();
    }
    if (count == 0) usage();

    var cells: [cases.len][impls.len]Cell = undefined;
    var iters: [cases.len][impls.len]u64 = @splat(@splat(0));
    for (cases, 0..) |c, ci| for (impls, 0..) |impl, ii| {
        cells[ci][ii] = check(c, impl.answer(c)) orelse .{ .ns = 0 };
        if (cells[ci][ii] == .ns) iters[ci][ii] = calibrate(io, impl, c, benchtime_ms * std.time.ns_per_ms);
    };

    const runs = try arena.alloc([cases.len][impls.len]f64, count);
    for (runs, 0..) |*round, r| {
        std.debug.print("round {d} of {d}\n", .{ r + 1, count });
        for (cases, 0..) |c, ci| for (0..impls.len) |k| {
            const ii = (k + r) % impls.len;
            const n = iters[ci][ii];
            if (n == 0) continue;
            const ns = elapsed(io, impls[ii], c, n);
            round[ci][ii] = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
        };
    }
    var samples = try arena.alloc(f64, count);
    for (0..cases.len) |ci| for (0..impls.len) |ii| {
        if (iters[ci][ii] == 0) continue;
        for (runs, 0..) |round, r| samples[r] = round[ci][ii];
        std.mem.sort(f64, samples, {}, std.sort.asc(f64));
        const mid = samples.len / 2;
        cells[ci][ii] = .{ .ns = if (samples.len % 2 == 1) samples[mid] else (samples[mid - 1] + samples[mid]) / 2 };
    };

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;
    try w.writeAll("| Input |");
    for (impls) |impl| try w.print(" {s} |", .{impl.name});
    try w.writeAll("\n|---|");
    for (impls) |_| try w.writeAll("--:|");
    try w.writeByte('\n');
    for (cases, cells) |c, row| {
        try w.print("| `{s}` |", .{c.input});
        for (row) |cell| {
            try w.writeByte(' ');
            try writeCell(w, cell);
            try w.writeAll(" |");
        }
        try w.writeByte('\n');
    }
    // What a wrong answer was, under the table.
    for (cases, cells) |c, row| for (impls, row) |impl, cell| switch (cell) {
        .wrong => |a| switch (a) {
            .time => |t| try w.print("\n{s} read `{s}` as {d} ns since the epoch.\n", .{ impl.name, c.input, t }),
            else => unreachable,
        },
        else => {},
    };
    try w.flush();
}

/// ns as bench.sh writes it, in ns below a microsecond and µs or ms above.
fn writeCell(w: *Io.Writer, cell: Cell) !void {
    switch (cell) {
        .ns => |ns| if (ns >= 1e6)
            try w.print("{d:.2} ms", .{ns / 1e6})
        else if (ns >= 1e3)
            try w.print("{d:.2} µs", .{ns / 1e3})
        else if (ns >= 100)
            try w.print("{d:.0} ns", .{ns})
        else
            try w.print("{d:.1} ns", .{ns}),
        .unsupported => try w.writeAll("no"),
        .refused => try w.writeAll("refuses"),
        .wrong => try w.writeAll("wrong"),
    }
}

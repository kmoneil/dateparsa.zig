//! The Zig side of the public-API oracle: reads what the Go dateparsa
//! answered (tools/oracle/api_oracle_test.go.txt, run by tools/oracle.sh),
//! answers the same inputs and layout-reuse pairs with this port, and
//! writes its answers in the same format so the two files can be diffed.
//!
//!   zig build oracle-api -- <go output> <zig output>
//!
//! It also checks the no-base-time rule, which has no Go counterpart: with
//! no base time an input fails with error.NoBaseTime exactly where Go's
//! answer changed between the two base times it was given, and gives Go's
//! answer everywhere else. It exits 1 on a mismatch there.

const std = @import("std");
const dp = @import("dateparsa");

const Io = std.Io;

const base_a: dp.DateTime = .{ .year = 2026, .month = 8, .day = 20, .hour = 12 };
const base_b: dp.DateTime = .{
    .year = 2031,
    .month = 2,
    .day = 3,
    .hour = 4,
    .minute = 5,
    .second = 6,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: oracle-api <go output> <zig output>\n", .{});
        std.process.exit(2);
    }
    const input = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    var file = try Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    var buf: [1 << 16]u8 = undefined;
    var fw = file.writer(io, &buf);
    const mismatches = try run(input, &fw.interface);
    try fw.interface.flush();
    if (mismatches > 0) {
        std.debug.print("{d} no-base-time mismatches\n", .{mismatches});
        std.process.exit(1);
    }
}

/// Every compiled-in locale: the set's backing integer has one bit each.
fn allLocales() dp.LocaleSet {
    const Backing = @typeInfo(dp.LocaleSet).@"struct".backing_integer.?;
    return @bitCast(~@as(Backing, 0));
}

fn options(ci: usize, diag: *dp.Diagnostics) dp.Options {
    return switch (ci) {
        0 => .{ .base_time = base_a, .diagnostics = diag },
        1 => .{ .base_time = base_a, .prefer_day_first = true, .diagnostics = diag },
        2 => .{ .base_time = base_a, .prefer_year_first = true, .diagnostics = diag },
        3 => .{ .base_time = base_a, .strict = true, .diagnostics = diag },
        4 => .{ .base_time = base_a, .timezone_offset = 19800, .diagnostics = diag },
        5 => .{ .base_time = base_a, .locales = allLocales(), .diagnostics = diag },
        6 => .{ .base_time = base_a, .prefer_future = true, .diagnostics = diag },
        7 => .{ .base_time = base_b, .diagnostics = diag },
        8 => .{ .base_time = base_a, .strict = true, .locales = allLocales(), .diagnostics = diag },
        else => unreachable,
    };
}

fn fmtTime(w: *Io.Writer, t: dp.DateTime) !void {
    const sign = if (t.offset_seconds >= 0) "+" else "";
    try w.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}{s}{d}", .{
        t.year, t.month, t.day, t.hour, t.minute, t.second, t.nanosecond, sign, t.offset_seconds,
    });
}

fn fmtResult(w: *Io.Writer, res: dp.ParseError!dp.Result, diag: *const dp.Diagnostics) !void {
    const r = res catch |err| switch (err) {
        error.NoMatch => return w.writeAll("err nomatch"),
        error.NoBaseTime => return w.writeAll("err nobase"),
        error.Ambiguous => {
            try w.print("err ambiguous n={d}", .{diag.interpretation_count});
            for (diag.slice()) |in| {
                try w.print(" {s}@", .{in.label});
                try fmtTime(w, in.time);
            }
            return;
        },
    };
    try w.writeAll("ok ");
    try fmtTime(w, r.time);
    try w.print(" kind={s} label={s} amb={} reusable={}", .{
        @tagName(r.kind), r.layout.label, r.ambiguous, r.layout.reusable(),
    });
}

fn run(input: []const u8, w: *Io.Writer) !usize {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var in_buf: [4096]u8 = undefined;
    var row_buf: [4096]u8 = undefined;
    var go: [9][]const u8 = undefined;
    var mismatches: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, ' ');
        const tag = it.next().?;
        if (std.mem.eql(u8, tag, "R")) {
            // The first row's layout on another row of its format.
            const first_hex = it.next().?;
            const row_hex = it.next().?;
            const first = try std.fmt.hexToBytes(&in_buf, first_hex);
            const row = try std.fmt.hexToBytes(&row_buf, row_hex);
            try w.print("R {s} {s} ", .{ first_hex, row_hex });
            var diag: dp.Diagnostics = .{};
            const r = try dp.parseWith(first, options(0, &diag));
            if (r.layout.parse(row)) |t| {
                try w.writeAll("ok ");
                try fmtTime(w, t);
            } else |_| try w.writeAll("err");
            try w.writeAll("\n");
            continue;
        }
        const ci = try std.fmt.parseInt(usize, tag, 10);
        const hex = it.next().?;
        go[ci] = it.rest();
        const s = try std.fmt.hexToBytes(&in_buf, hex);
        var diag: dp.Diagnostics = .{};
        try w.print("{d} {s} ", .{ ci, hex });
        try fmtResult(w, dp.parseWith(s, options(ci, &diag)), &diag);
        try w.writeAll("\n");
        if (ci != 8) continue;
        const want = if (std.mem.eql(u8, go[0], go[7])) go[0] else "err nobase";
        var nd: dp.Diagnostics = .{};
        var got_buf: [1024]u8 = undefined;
        var gw: Io.Writer = .fixed(&got_buf);
        try fmtResult(&gw, dp.parseWith(s, .{ .diagnostics = &nd }), &nd);
        if (!std.mem.eql(u8, want, gw.buffered())) {
            mismatches += 1;
            const got = gw.buffered();
            std.debug.print("no base time, {s}:\n  want {s}\n  got  {s}\n", .{ hex, want, got });
        }
    }
    return mismatches;
}

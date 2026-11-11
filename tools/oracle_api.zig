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
//!
//! Where this port answers differently from Go on purpose (isDeliberate),
//! Go's answer is written in place of this port's and the row is counted,
//! so the diff shows only differences nobody decided on.

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
    const counts = try run(input, &fw.interface);
    try fw.interface.flush();
    if (counts.deliberate > 0) {
        std.debug.print("{d} answers differ from Go's on purpose (isDeliberate in tools/oracle_api.zig)\n", .{counts.deliberate});
    }
    if (counts.mismatches > 0) {
        std.debug.print("{d} no-base-time mismatches\n", .{counts.mismatches});
        std.process.exit(1);
    }
}

/// The layouts this port reads with where Go has no format, each listed in
/// the README's "Differences from the Go original".
const deliberate = [_][]const u8{
    "ISO8601_DATETIME_HM", // kmoneil/dateparsa#37
};

/// Whether this port's answer differs from Go's on purpose, as the README's
/// "Differences from the Go original" lists: it reads an input Go refuses,
/// with a layout in `deliberate`, or it reads a time alone on the base
/// time's day where Go reads 1 January (kmoneil/dateparsa#40).
fn isDeliberate(input: []const u8, go_answer: []const u8, zig_answer: []const u8) bool {
    if (std.mem.indexOf(u8, zig_answer, " label=TIME_") != null and onlyDayDiffers(go_answer, zig_answer)) return true;
    if (!std.mem.eql(u8, go_answer, "err nomatch")) return false;
    // A one-digit hour, which Go has no format for (kmoneil/dateparsa#38):
    // read here, or refused as its zero-padded form would be.
    if (hasShortHour(input)) return std.mem.startsWith(u8, zig_answer, "ok ") or
        std.mem.eql(u8, zig_answer, "err nobase") or std.mem.startsWith(u8, zig_answer, "err ambiguous");
    if (!std.mem.startsWith(u8, zig_answer, "ok ")) return false;
    for (deliberate) |label| {
        var buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, " label={s} ", .{label}) catch unreachable;
        if (std.mem.indexOf(u8, zig_answer, needle) != null) return true;
    }
    return false;
}

/// Whether s's first clock time has a one-digit hour: a digit with no
/// digit before it, a colon, two digits. Letters before it are allowed
/// (textual dates read one too); ISO 8601's 'T' is not, as there the hour
/// takes two digits.
fn hasShortHour(s: []const u8) bool {
    var i: usize = 0;
    while (i + 3 < s.len) : (i += 1) {
        if (!std.ascii.isDigit(s[i])) continue;
        const one = s[i + 1] == ':' and std.ascii.isDigit(s[i + 2]) and std.ascii.isDigit(s[i + 3]);
        const two = i + 4 < s.len and std.ascii.isDigit(s[i + 1]) and s[i + 2] == ':' and
            std.ascii.isDigit(s[i + 3]) and std.ascii.isDigit(s[i + 4]);
        if (two) return false;
        if (one) return i == 0 or !(std.ascii.isDigit(s[i - 1]) or s[i - 1] == 'T');
    }
    return false;
}

/// Whether both answers read a time, Go's on 1 January, and agree on
/// everything after the date.
fn onlyDayDiffers(go_answer: []const u8, zig_answer: []const u8) bool {
    if (!std.mem.startsWith(u8, go_answer, "ok ") or !std.mem.startsWith(u8, zig_answer, "ok ")) return false;
    const g = std.mem.indexOfScalarPos(u8, go_answer, 3, 'T') orelse return false;
    const z = std.mem.indexOfScalarPos(u8, zig_answer, 3, 'T') orelse return false;
    return std.mem.endsWith(u8, go_answer[0..g], "-01-01") and std.mem.eql(u8, go_answer[g..], zig_answer[z..]);
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

/// This port's answer to s under option set ci, in Go's place when it is a
/// deliberate reading of an input Go refuses (counted in deliberate_count).
fn answer(buf: []u8, s: []const u8, ci: usize, go_answer: []const u8, deliberate_count: *usize) ![]const u8 {
    var diag: dp.Diagnostics = .{};
    var aw: Io.Writer = .fixed(buf);
    try fmtResult(&aw, dp.parseWith(s, options(ci, &diag)), &diag);
    if (!isDeliberate(s, go_answer, aw.buffered())) return aw.buffered();
    deliberate_count.* += 1;
    return go_answer;
}

const Counts = struct { mismatches: usize = 0, deliberate: usize = 0 };

fn run(input: []const u8, w: *Io.Writer) !Counts {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var in_buf: [4096]u8 = undefined;
    var row_buf: [4096]u8 = undefined;
    var answer_buf: [4096]u8 = undefined;
    var go: [9][]const u8 = undefined;
    var counts: Counts = .{};
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
            const go_reused = it.rest();
            try w.print("R {s} {s} ", .{ first_hex, row_hex });
            var diag: dp.Diagnostics = .{};
            const r = try dp.parseWith(first, options(0, &diag));
            var rw: Io.Writer = .fixed(&answer_buf);
            if (r.layout.parse(row)) |t| {
                try rw.writeAll("ok ");
                try fmtTime(&rw, t);
            } else |_| try rw.writeAll("err");
            const reused = rw.buffered();
            // A time's layout reads on its base day, as its first row did.
            if (std.mem.startsWith(u8, r.layout.label, "TIME_") and onlyDayDiffers(go_reused, reused)) {
                counts.deliberate += 1;
                try w.print("{s}\n", .{go_reused});
            } else try w.print("{s}\n", .{reused});
            continue;
        }
        const ci = try std.fmt.parseInt(usize, tag, 10);
        const hex = it.next().?;
        go[ci] = it.rest();
        const s = try std.fmt.hexToBytes(&in_buf, hex);
        try w.print("{d} {s} {s}\n", .{ ci, hex, try answer(&answer_buf, s, ci, go[ci], &counts.deliberate) });
        if (ci != 8) continue;
        const want = if (std.mem.eql(u8, go[0], go[7])) go[0] else "err nobase";
        var nd: dp.Diagnostics = .{};
        var got_buf: [1024]u8 = undefined;
        var gw: Io.Writer = .fixed(&got_buf);
        try fmtResult(&gw, dp.parseWith(s, .{ .diagnostics = &nd }), &nd);
        const got = gw.buffered();
        if (!std.mem.eql(u8, want, got) and !isDeliberate(s, want, got)) {
            counts.mismatches += 1;
            std.debug.print("no base time, {s}:\n  want {s}\n  got  {s}\n", .{ hex, want, got });
        }
    }
    return counts;
}

//! Unix timestamps: a run of digits whose count says its precision.
//!
//!   10 to 12 digits  seconds        1710504800
//!   13               milliseconds   1710504800123
//!   16               microseconds
//!   19               nanoseconds
//!   9 to 12 . digits fractional seconds   1710504800.123
//!
//! Any other count names no precision and is refused, and so is anything
//! shorter than ten digits: that is compact-date and bare-year territory.
//! The instant must lie within max_seconds of the epoch. The result is UTC.

const std = @import("std");
const DateTime = @import("DateTime.zig");

pub const Kind = enum { seconds, milliseconds, microseconds, nanoseconds, fraction };

pub const Result = struct { time: DateTime, kind: Kind };

/// Seconds either side of the epoch a timestamp may name: about 3168 years
/// each way. Twelve digits of seconds reach past it, so the gate is on the
/// instant, not the digit count.
pub const max_seconds: i64 = 100_000_000_000;

/// The timestamp s spells, or null.
pub fn detect(s: []const u8) ?Result {
    if (s.len == 0) return null;
    const neg = s[0] == '-';
    const start: usize = if (neg) 1 else 0;
    if (start == s.len) return null;
    var dot: ?usize = null;
    for (s[start..], start..) |c, i| {
        if (c == '.') {
            if (dot != null) return null; // two dots
            dot = i;
        } else if (!std.ascii.isDigit(c)) return null;
    }
    if (dot) |at| return fractional(s, start, at, neg);
    const kind = precisionFor(s.len - start) orelse return null;
    var v = parseInt(s[start..]) orelse return null;
    if (neg) v = -v;
    const parts = split(v, kind);
    return .{ .time = withinRange(parts.sec, parts.nsec) orelse return null, .kind = kind };
}

fn precisionFor(digits: usize) ?Kind {
    return switch (digits) {
        10, 11, 12 => .seconds,
        13 => .milliseconds,
        16 => .microseconds,
        19 => .nanoseconds,
        else => null,
    };
}

/// Seconds and nanoseconds, floored, so a negative sub-second value lands
/// before the second it is in: -1500 ms is 1.5 s before the epoch.
fn split(v: i64, kind: Kind) struct { sec: i64, nsec: i64 } {
    return switch (kind) {
        .milliseconds => .{ .sec = @divFloor(v, 1_000), .nsec = @mod(v, 1_000) * 1_000_000 },
        .microseconds => .{ .sec = @divFloor(v, 1_000_000), .nsec = @mod(v, 1_000_000) * 1_000 },
        .nanoseconds => .{ .sec = @divFloor(v, 1_000_000_000), .nsec = @mod(v, 1_000_000_000) },
        .seconds, .fraction => .{ .sec = v, .nsec = 0 },
    };
}

/// The UTC reading of sec seconds plus nsec nanoseconds (|nsec| < 1e9,
/// either sign), or null past max_seconds.
fn withinRange(sec: i64, nsec: i64) ?DateTime {
    std.debug.assert(nsec > -1_000_000_000 and nsec < 1_000_000_000);
    const s = sec + @divFloor(nsec, 1_000_000_000);
    if (s > max_seconds or s < -max_seconds) return null;
    const ns: u32 = @intCast(@mod(nsec, 1_000_000_000));
    return DateTime.fromEpoch(.{ .seconds = s, .nanosecond = ns }, 0);
}

/// 9 to 12 digits, a dot, and at least one digit. Digits past the ninth
/// are dropped, since a nanosecond holds nine.
fn fractional(s: []const u8, start: usize, dot: usize, neg: bool) ?Result {
    const int_digits = dot - start;
    if (int_digits < 9 or int_digits > 12) return null;
    var sec = parseInt(s[start..dot]) orelse return null;
    const frac = s[dot + 1 ..];
    if (frac.len == 0) return null;
    const digits = frac[0..@min(frac.len, 9)];
    var nsec = parseInt(digits) orelse return null;
    for (digits.len..9) |_| nsec *= 10;
    if (neg) {
        sec = -sec;
        nsec = -nsec;
    }
    return .{ .time = withinRange(sec, nsec) orelse return null, .kind = .fraction };
}

/// Decimal digits as an i64, or null when they do not fit.
fn parseInt(s: []const u8) ?i64 {
    var v: i64 = 0;
    for (s) |c| {
        v = std.math.mul(i64, v, 10) catch return null;
        v = std.math.add(i64, v, c - '0') catch return null;
    }
    return v;
}

fn digitCount(v: i64) usize {
    var u = @abs(v);
    var n: usize = 1;
    while (u >= 10) : (u /= 10) n += 1;
    return n;
}

/// An integer timestamp from a typed number (a JSON number, a database
/// integer). The digit count picks the precision as for strings, and a
/// value under ten digits is seconds: a typed number is not a compact date.
pub fn fromInt(v: i64) ?DateTime {
    if (v == std.math.minInt(i64)) return null;
    const digits = digitCount(v);
    const kind = precisionFor(digits) orelse if (digits >= 10) return null else Kind.seconds;
    const parts = split(v, kind);
    return withinRange(parts.sec, parts.nsec);
}

/// Seconds as a float, rounded to the nearest nanosecond.
pub fn fromSeconds(f: f64) ?DateTime {
    const convertible: f64 = 1 << 62;
    if (std.math.isNan(f) or f > convertible or f < -convertible) return null;
    const sec: i64 = @trunc(f);
    var ns = (f - @as(f64, @floatFromInt(sec))) * 1e9;
    ns += if (ns >= 0) 0.5 else -0.5;
    const nsec: i64 = @trunc(ns);
    if (nsec <= -1_000_000_000 or nsec >= 1_000_000_000) return null;
    return withinRange(sec, nsec);
}

/// Go's time.Unix(sec, nsec).UTC(), for expected values.
fn unix(sec: i64, nsec: i64) DateTime {
    return DateTime.fromEpoch(.{
        .seconds = sec + @divFloor(nsec, 1_000_000_000),
        .nanosecond = @intCast(@mod(nsec, 1_000_000_000)),
    }, 0);
}

test "each digit count is its precision" {
    const Case = struct { []const u8, Kind, DateTime };
    for ([_]Case{
        .{ "1710504800", .seconds, unix(1710504800, 0) },
        .{ "1710504800000", .milliseconds, unix(1710504800, 0) },
        .{ "1710504800123", .milliseconds, unix(1710504800, 123_000_000) },
        .{ "1710504800000000", .microseconds, unix(1710504800, 0) },
        .{ "1710504800000000000", .nanoseconds, unix(1710504800, 0) },
        .{ "1710504800.123", .fraction, unix(1710504800, 123_000_000) },
    }) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        const r = detect(c[0]).?;
        try std.testing.expectEqual(c[1], r.kind);
        try std.testing.expectEqual(c[2], r.time);
    }
    try std.testing.expect(detect("-1710504800").?.time.year < 1970);
}

test "what is not a timestamp is refused" {
    for ([_][]const u8{
        "",                   "2024",     "20240315",
        "abc",                "12:30:00", "2024-03-15",
        "1710504800.123.456", "-",
        "17105048001234",    "171050480012345", // 14 and 15 digits name no precision
        // Zero-padded to counts that name no precision, though the value
        // would be in range as seconds.
        "00001710504800",    "000001710504800",
        "00000001710504800", "000000001710504800",
        "1710504800.", // a dot and no fraction
        "17105048.5", // eight integer digits
        ".5",
    }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expectEqual(null, detect(s));
    }
}

test "digits that do not fit an i64 are refused" {
    for ([_][]const u8{
        "9999999999999999999",
        "9223372036854775808",
        "-9999999999999999999",
        "-9223372036854775808",
    }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expectEqual(null, detect(s));
    }
    const r = detect("9223372036854775807").?;
    try std.testing.expectEqual(unix(9223372036, 854775807), r.time);
}

test "a long fraction is truncated to nanoseconds" {
    try std.testing.expectEqual(999_999_999, detect("1710500000.99999999999999999999999").?.time.nanosecond);
}

test "the range gate is on the instant" {
    for ([_][]const u8{ "-100000000000.1", "-100000000001", "100000000001" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expectEqual(null, detect(s));
    }
    // Nine integer digits are enough for a fraction, as in Go.
    for ([_][]const u8{ "100000000000", "-100000000000", "100000000000.1", "171050480.0" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expect(detect(s) != null);
    }
}

test "a negative sub-second value lands before its second" {
    const Case = struct { []const u8, DateTime };
    for ([_]Case{
        .{ "-1710500000123", unix(0, -1710500000123 * 1_000_000) },
        .{ "-1710500000123456", unix(-1710500000, -123456000) },
        .{ "-1710500000123456789", unix(-1710500000, -123456789) },
        .{ "-1710500000.5", unix(-1710500000, -500_000_000) },
        .{ "-1500000000000", unix(-1500000000, 0) },
    }) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        try std.testing.expectEqual(c[1], detect(c[0]).?.time);
    }
}

test "fromInt agrees with detect on the digits it would see" {
    for ([_]i64{
        1710500000,          1710500000000,   1710500000000000,  1710500000000000000,
        99999999999,         999999999999,    9999999999999,     9999999999999999,
        -1710500000,         -1710500000000,  -1710500000000000, -1710500000000000000,
        17105000000000,      171050000000000, 17105000000000000, 171050000000000000,
        9223372036854775807, 100000000000,    -100000000000,
    }) |v| {
        var buf: [24]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
        errdefer std.debug.print("{d}\n", .{v});
        const want = detect(s);
        const got = fromInt(v);
        try std.testing.expectEqual(want == null, got == null);
        if (want) |w| try std.testing.expectEqual(w.time, got.?);
    }
}

test "fromInt takes small values as seconds, which detect refuses as strings" {
    const Case = struct { i64, DateTime };
    for ([_]Case{
        .{ 0, unix(0, 0) },
        .{ 1, unix(1, 0) },
        .{ 86400, .{ .year = 1970, .month = 1, .day = 2 } },
        .{ -86400, .{ .year = 1969, .month = 12, .day = 31 } },
        .{ 999999999, unix(999999999, 0) },
    }) |c| {
        try std.testing.expectEqual(c[1], fromInt(c[0]).?);
        var buf: [24]u8 = undefined;
        try std.testing.expectEqual(null, detect(try std.fmt.bufPrint(&buf, "{d}", .{c[0]})));
    }
    try std.testing.expectEqual(null, fromInt(std.math.minInt(i64)));
}

test "fromSeconds" {
    for ([_]f64{
        std.math.nan(f64),      std.math.inf(f64),       -std.math.inf(f64),
        std.math.floatMax(f64), -std.math.floatMax(f64), 1e300,
        -1e300,                 1e15,                    -1e15,
    }) |f| {
        errdefer std.debug.print("{d}\n", .{f});
        try std.testing.expectEqual(null, fromSeconds(f));
    }
    const Case = struct { f64, DateTime };
    for ([_]Case{
        .{ 0, unix(0, 0) },
        .{ 1710500000, unix(1710500000, 0) },
        .{ 1710500000.5, unix(1710500000, 500_000_000) },
        .{ -1710500000.5, unix(-1710500000, -500_000_000) },
    }) |c| {
        try std.testing.expectEqual(c[1], fromSeconds(c[0]).?);
    }
    // Within a microsecond of the string reading, as Go's test allows.
    for ([_][]const u8{ "1710500000.123", "1710500000.5", "-1710500000.5", "999999999999.5", "100000000000.5" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        const want = detect(s);
        const got = fromSeconds(try std.fmt.parseFloat(f64, s));
        try std.testing.expectEqual(want == null, got == null);
        if (want) |w| {
            const a = w.time.toEpoch();
            const b = got.?.toEpoch();
            const apart = (a.seconds - b.seconds) * 1_000_000_000 + @as(i64, a.nanosecond) - b.nanosecond;
            try std.testing.expect(@abs(apart) <= 1000);
        }
    }
}

test "digitCount" {
    var buf: [24]u8 = undefined;
    var p: i64 = 1;
    while (true) : (p *= 10) {
        for ([_]i64{ p, p - 1, -p, -(p - 1) }) |v| {
            const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
            try std.testing.expectEqual(s.len - @intFromBool(v < 0), digitCount(v));
        }
        if (p > std.math.maxInt(i64) / 10) break;
    }
    try std.testing.expectEqual(19, digitCount(std.math.maxInt(i64)));
    try std.testing.expectEqual(19, digitCount(std.math.minInt(i64)));
}

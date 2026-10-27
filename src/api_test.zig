//! Tests of the public API, ported from the Go dateparsa's root-package
//! tests. Expected values in the first table are the Go library's own
//! answers on the same inputs and options.

const std = @import("std");
const dp = @import("root.zig");
const locale = @import("locale.zig");

const DateTime = dp.DateTime;

/// The Go tests' base time.
const base: DateTime = .{ .year = 2026, .month = 8, .day = 20, .hour = 12 };
const base_b: DateTime = .{ .year = 2031, .month = 2, .day = 3, .hour = 4, .minute = 5, .second = 6 };

fn allLocales() dp.LocaleSet {
    const Backing = @typeInfo(dp.LocaleSet).@"struct".backing_integer.?;
    var bits: Backing = 0;
    for (0..locale.compiled.len) |i| bits |= @as(Backing, @bitCast(locale.only(i)));
    return @bitCast(bits);
}

fn options(ci: usize, diag: *dp.Diagnostics) dp.Options {
    return switch (ci) {
        0 => .{ .base_time = base, .diagnostics = diag },
        1 => .{ .base_time = base, .prefer_day_first = true, .diagnostics = diag },
        2 => .{ .base_time = base, .prefer_year_first = true, .diagnostics = diag },
        3 => .{ .base_time = base, .strict = true, .diagnostics = diag },
        4 => .{ .base_time = base, .timezone_offset = 19800, .diagnostics = diag },
        5 => .{ .base_time = base, .locales = allLocales(), .diagnostics = diag },
        6 => .{ .base_time = base, .prefer_future = true, .diagnostics = diag },
        7 => .{ .base_time = base_b, .diagnostics = diag },
        8 => .{ .base_time = base, .strict = true, .locales = allLocales(), .diagnostics = diag },
        else => unreachable,
    };
}

fn fmtTime(w: *std.Io.Writer, t: DateTime) !void {
    try w.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}{s}{d}", .{
        t.year,                                 t.month,          t.day, t.hour, t.minute, t.second, t.nanosecond,
        if (t.offset_seconds >= 0) "+" else "", t.offset_seconds,
    });
}

/// A result as one line, in the Go oracle's spelling.
fn fmtResult(w: *std.Io.Writer, res: dp.ParseError!dp.Result, diag: *const dp.Diagnostics) !void {
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

test "parse answers what the Go original answers" {
    // Taken from the Go dateparsa's ParseWith under the same options. The
    // full comparison, 3,299 inputs under these nine option sets and with no
    // base time at all, agreed on every one when this was written.
    const Case = struct { usize, []const u8, []const u8 };
    const cases = [_]Case{
        .{ 0, "2024-03-15", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=ISO8601_DATE amb=false reusable=true" },
        .{ 0, "2024-03-15T10:30:00Z", "ok 2024-03-15T10:30:00.000000000+0 kind=absolute label=ISO8601_DATETIME_Z amb=false reusable=true" },
        .{ 0, "2024-03-15T10:30:00+05:30", "ok 2024-03-15T10:30:00.000000000+19800 kind=absolute label=RFC3339 amb=false reusable=true" },
        .{ 0, "2024-03-15T10:30:00.123456789Z", "ok 2024-03-15T10:30:00.123456789+0 kind=absolute label=RFC3339_NANO amb=false reusable=true" },
        .{ 0, "2024-03-15 10:30:00", "ok 2024-03-15T10:30:00.000000000+0 kind=absolute label=SQL_DATETIME amb=false reusable=true" },
        .{ 0, "20240315", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=COMPACT_DATE amb=false reusable=true" },
        .{ 0, "03/15/2024", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=NUMERIC_MDY amb=false reusable=false" },
        .{ 0, "01/02/2024", "ok 2024-01-02T00:00:00.000000000+0 kind=absolute label=NUMERIC_AMBIG amb=true reusable=false" },
        .{ 0, "13/01/2024", "ok 2024-01-13T00:00:00.000000000+0 kind=absolute label=NUMERIC_MDY amb=false reusable=false" },
        .{ 0, "15.03.2024", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=NUMERIC_DMY amb=false reusable=false" },
        .{ 0, "3/15/2024 10:30 PM", "ok 2024-03-15T22:30:00.000000000+0 kind=absolute label=NUMERIC_MDY_TIME amb=false reusable=false" },
        .{ 0, "March 15, 2024", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=MONTH_DAY_YEAR amb=false reusable=true" },
        .{ 0, "15 Mar 2024", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=DAY_MONTH_YEAR amb=false reusable=true" },
        .{ 0, "Fri, 15 Mar 2024 10:30:00 +0000", "ok 2024-03-15T10:30:00.000000000+0 kind=absolute label=DAY_MONTH_YEAR amb=false reusable=true" },
        .{ 0, "March 15", "ok 2026-03-15T00:00:00.000000000+0 kind=absolute label=MONTH_DAY amb=true reusable=false" },
        .{ 0, "December 23rd", "ok 2026-12-23T00:00:00.000000000+0 kind=absolute label=MONTH_DAY amb=false reusable=true" },
        .{ 0, "10:30:00", "ok 2026-01-01T10:30:00.000000000+0 kind=absolute label=TIME_HMS amb=false reusable=true" },
        .{ 0, "1710504800", "ok 2024-03-15T12:13:20.000000000+0 kind=absolute label=UNIX_TIMESTAMP amb=false reusable=false" },
        .{ 0, "1710504800123", "ok 2024-03-15T12:13:20.123000000+0 kind=absolute label=UNIX_TIMESTAMP amb=false reusable=false" },
        .{ 0, "3 days ago", "ok 2026-08-17T12:00:00.000000000+0 kind=relative label=NATURAL_LANGUAGE amb=false reusable=false" },
        .{ 0, "yesterday at 5pm", "ok 2026-08-19T17:00:00.000000000+0 kind=relative label=NATURAL_LANGUAGE amb=false reusable=false" },
        .{ 0, "now", "ok 2026-08-20T12:00:00.000000000+0 kind=now label=NATURAL_LANGUAGE amb=false reusable=false" },
        .{ 0, "today", "ok 2026-08-20T00:00:00.000000000+0 kind=now label=NATURAL_LANGUAGE amb=false reusable=false" },
        .{ 0, "2024-W11-5", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=ISO_WEEK_DATE amb=false reusable=true" },
        .{ 0, "2014年04月08日", "ok 2014-04-08T00:00:00.000000000+0 kind=absolute label=CJK_DATE amb=false reusable=true" },
        .{ 0, "2015-02-08 03:02:00 +0300 MSK", "ok 2015-02-08T03:02:00.000000000+10800 kind=absolute label=GO_TIME_STRING amb=false reusable=true" },
        .{ 0, "not a date", "err nomatch" },
        .{ 0, "2024-02-30", "err nomatch" },
        .{ 0, "first monday of march 2024", "err nomatch" },
        .{ 1, "01/02/2024", "ok 2024-02-01T00:00:00.000000000+0 kind=absolute label=NUMERIC_AMBIG amb=true reusable=false" },
        .{ 1, "13/01/2024", "ok 2024-01-13T00:00:00.000000000+0 kind=absolute label=NUMERIC_DMY amb=false reusable=false" },
        .{ 2, "01/02/03", "ok 2001-02-03T00:00:00.000000000+0 kind=absolute label=NUMERIC_AMBIG amb=true reusable=false" },
        .{ 3, "01/02/2024", "err ambiguous n=2 MM/DD/YYYY@2024-01-02T00:00:00.000000000+0 DD/MM/YYYY@2024-02-01T00:00:00.000000000+0" },
        .{ 3, "01/02/03", "err ambiguous n=3 MM/DD/YY@2003-01-02T00:00:00.000000000+0 DD/MM/YY@2003-02-01T00:00:00.000000000+0 YY/MM/DD@2001-02-03T00:00:00.000000000+0" },
        .{ 3, "31/12/24", "err ambiguous n=2 DD/MM/YY@2024-12-31T00:00:00.000000000+0 YY/MM/DD@2031-12-24T00:00:00.000000000+0" },
        .{ 3, "March 15", "err ambiguous n=2 MONTH_DAY@2026-03-15T00:00:00.000000000+0 MONTH_YEAR@2015-03-01T00:00:00.000000000+0" },
        .{ 3, "2024-03-15", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=ISO8601_DATE amb=false reusable=true" },
        .{ 4, "2024-03-15", "ok 2024-03-15T00:00:00.000000000+19800 kind=absolute label=ISO8601_DATE amb=false reusable=true" },
        .{ 4, "2024-03-15T10:30:00Z", "ok 2024-03-15T10:30:00.000000000+0 kind=absolute label=ISO8601_DATETIME_Z amb=false reusable=true" },
        .{ 4, "10:30:00", "ok 2026-01-01T10:30:00.000000000+19800 kind=absolute label=TIME_HMS amb=false reusable=true" },
        .{ 4, "1710504800", "ok 2024-03-15T12:13:20.000000000+0 kind=absolute label=UNIX_TIMESTAMP amb=false reusable=false" },
        .{ 5, "15 mars 2024", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=DAY_MONTH_YEAR amb=false reusable=true" },
        .{ 5, "hace 3 días", "ok 2026-08-17T12:00:00.000000000+0 kind=relative label=NATURAL_LANGUAGE amb=false reusable=false" },
        .{ 5, "15 марта 2024", "ok 2024-03-15T00:00:00.000000000+0 kind=absolute label=DAY_MONTH_YEAR amb=false reusable=true" },
        .{ 6, "monday", "ok 2026-08-24T00:00:00.000000000+0 kind=relative label=NATURAL_LANGUAGE amb=false reusable=false" },
        .{ 7, "10:30:00", "ok 2031-01-01T10:30:00.000000000+0 kind=absolute label=TIME_HMS amb=false reusable=true" },
        .{ 7, "3 days ago", "ok 2031-01-31T04:05:06.000000000+0 kind=relative label=NATURAL_LANGUAGE amb=false reusable=false" },
        .{ 8, "कल", "err ambiguous n=2 NATURAL_LANGUAGE@2026-08-19T00:00:00.000000000+0 NATURAL_LANGUAGE@2026-08-21T00:00:00.000000000+0" },
    };
    for (cases) |c| {
        errdefer std.debug.print("config {d}: \"{s}\"\n", .{ c[0], c[1] });
        if (c[0] == 5 or c[0] == 8) if (locale.compiled.len < 20) continue;
        var diag: dp.Diagnostics = .{};
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try fmtResult(&w, dp.parseWith(c[1], options(c[0], &diag)), &diag);
        try std.testing.expectEqualStrings(c[2], w.buffered());
    }
}

test "surrounding ASCII whitespace is padding on every path" {
    const Case = struct { []const u8, DateTime };
    const values = [_]Case{
        .{ "2024-03-15", .{ .year = 2024, .month = 3, .day = 15 } },
        .{ "2024-03-15T10:30:00Z", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30 } },
        .{ "2024-03-15 10:30:00", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30 } },
        .{ "10:30:00", .{ .year = 2026, .month = 1, .day = 1, .hour = 10, .minute = 30 } },
        .{ "03/15/2024", .{ .year = 2024, .month = 3, .day = 15 } },
        .{ "3/15/2024", .{ .year = 2024, .month = 3, .day = 15 } },
        .{ "March 15, 2024", .{ .year = 2024, .month = 3, .day = 15 } },
        .{ "15 Mar 2024", .{ .year = 2024, .month = 3, .day = 15 } },
        .{ "Fri, 15 Mar 2024 10:30:00 +0000", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30 } },
        .{ "1710504800", .{ .year = 2024, .month = 3, .day = 15, .hour = 12, .minute = 13, .second = 20 } },
        .{ "1710504800000", .{ .year = 2024, .month = 3, .day = 15, .hour = 12, .minute = 13, .second = 20 } },
        .{ "3 days ago", .{ .year = 2026, .month = 8, .day = 17, .hour = 12 } },
    };
    var buf: [64]u8 = undefined;
    for (values) |v| {
        for (" \t\n\r\x0b\x0c") |pad| {
            const n = v[0].len;
            const shapes = [_]struct { usize, usize }{ .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 3, 2 } };
            for (shapes) |shape| {
                @memset(buf[0..shape[0]], pad);
                @memcpy(buf[shape[0]..][0..n], v[0]);
                @memset(buf[shape[0] + n ..][0..shape[1]], pad);
                const in = buf[0 .. shape[0] + n + shape[1]];
                errdefer std.debug.print("\"{s}\" padded with {d}\n", .{ v[0], pad });
                const got = try dp.parseWith(in, .{ .base_time = base });
                try std.testing.expect(got.time.eqlInstant(v[1]));
            }
        }
    }
}

test "padding does not change the answer, its label, its guess or its kind" {
    for ([_][]const u8{
        "2024-03-15",     "2024-03-15T10:30:00+05:30",      "03/15/2024", "01/02/2024",
        "March 15, 2024", "15 Mar 2024",                    "March 15",   "01MAY10",
        "MAY70",          "10:30:00",                       "1710504800", "3 days ago",
        "20240315",       "Friday, 15-Mar-24 10:30:00 UTC",
    }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        const want = try dp.parseWith(s, .{ .base_time = base });
        for ([_][]const u8{ " ", "\t\n", "  \r\n" }) |pad| {
            var buf: [96]u8 = undefined;
            const padded = try std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ pad, s, pad });
            const got = try dp.parseWith(padded, .{ .base_time = base });
            try std.testing.expectEqual(want.time, got.time);
            try std.testing.expectEqualStrings(want.layout.label, got.layout.label);
            try std.testing.expectEqual(want.ambiguous, got.ambiguous);
            try std.testing.expectEqual(want.kind, got.kind);
        }
    }
}

test "a padded row reuses the layout, alone and in a Parser column" {
    for ([_][]const u8{ "2024-03-15", " 2024-03-15", "2024-03-15\r\n" }) |seed| {
        const r = try dp.parse(seed);
        try std.testing.expect(r.layout.reusable());
        for ([_][]const u8{ "2024-03-16", " 2024-03-16", "2024-03-16 ", "\t2024-03-16\r\n" }) |row| {
            const t = try r.layout.parse(row);
            try std.testing.expectEqual(DateTime{ .year = 2024, .month = 3, .day = 16 }, t);
        }
    }
    var p = dp.Parser.init(.{});
    for ([_][]const u8{ "2024-03-15", "2024-03-16 ", " 2024-03-17", "2024-03-18\r\n", "2024-03-19" }) |row| {
        const got = try p.parse(row);
        const fresh = try dp.parse(row);
        try std.testing.expectEqual(fresh.time, got.time);
    }
}

test "Unicode space is not padding, and whitespace alone is no date" {
    for ([_][]const u8{
        "\u{a0}2024-03-15",
        "2024-03-15\u{a0}",
        "\u{a0}March 15, 2024\u{a0}",
        "\u{2007}2024-03-15",
        "\u{202f}2024-03-15",
        "\u{3000}2024-03-15",
    }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expectError(error.NoMatch, dp.parseWith(s, .{ .base_time = base }));
    }
    const long: [1000]u8 = @splat(' ');
    for ([_][]const u8{ "", " ", "  ", "\t", "\n", "\r\n", " \t\r\n\x0b\x0c ", &long }) |s| {
        try std.testing.expectError(error.NoMatch, dp.parseWith(s, .{ .base_time = base }));
    }
}

test "an input that needs a base time fails without one, and only then" {
    var diag: dp.Diagnostics = .{};
    for ([_][]const u8{ "10:30:00", "March 15", "3 days ago", "now", "next friday", "December 23rd" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expectError(error.NoBaseTime, dp.parseWith(s, .{ .diagnostics = &diag }));
        try std.testing.expect(diag.message.len > 0);
    }
    // No year makes these dates, so a base time would not help.
    for ([_][]const u8{ "February 30", "March 00", "not a date" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expectError(error.NoMatch, dp.parseWith(s, .{ .diagnostics = &diag }));
        try std.testing.expectEqualStrings("no matching format found", diag.message);
    }
    // February 29 exists in some year, so it waits for one.
    try std.testing.expectError(error.NoBaseTime, dp.parse("February 29"));
    // Absolute inputs need none.
    _ = try dp.parse("2024-03-15");
    _ = try dp.parse("1710504800");
    _ = try dp.parse("March 15, 2024");
}

test "strict mode returns every reading in Diagnostics" {
    var diag: dp.Diagnostics = .{};
    try std.testing.expectError(error.Ambiguous, dp.parseWith("01/02/2024", .{ .strict = true, .diagnostics = &diag }));
    try std.testing.expectEqual(2, diag.interpretation_count);
    try std.testing.expectEqualStrings("MM/DD/YYYY", diag.slice()[0].label);
    try std.testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 2 }, diag.slice()[0].time);
    try std.testing.expectEqual(DateTime{ .year = 2024, .month = 2, .day = 1 }, diag.slice()[1].time);
    // Each interpretation's layout re-parses its reading.
    try std.testing.expectEqual(DateTime{ .year = 2025, .month = 3, .day = 4 }, try diag.slice()[1].layout.parse("04/03/2025"));
    // Unambiguous input passes strict mode, and the error carries no input.
    _ = try dp.parseWith("13/01/2024", .{ .strict = true });
    try std.testing.expectError(error.Ambiguous, dp.parseWith("01/02/2024", .{ .strict = true }));
}

test "Parser re-detects what its cached layout cannot answer" {
    var p = dp.Parser.init(.{ .base_time = base });
    // A format resolved per value: the cache would read the second row
    // day-first, as the first row was.
    _ = try p.parse("25/12/2024");
    try std.testing.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 2 }, (try p.parse("01/02/2024")).time);
    // A format change.
    _ = try p.parse("2024-03-15");
    try std.testing.expectEqualStrings("MONTH_DAY_YEAR", (try p.parse("March 16, 2024")).layout.label);
    // A sentinel cached by a relative row.
    _ = try p.parse("3 days ago");
    try std.testing.expectEqual(DateTime{ .year = 2024, .month = 3, .day = 15 }, (try p.parse("2024-03-15")).time);
    // Errors pass through, and reset forgets.
    try std.testing.expectError(error.NoMatch, p.parse("not a date"));
    p.reset();
    try std.testing.expectEqual(null, p.cache);
}

test "detect gives the layout, and locales are named by tag" {
    try std.testing.expectEqualStrings("ISO8601_DATE", (try dp.detect("2024-03-15", .{})).label);
    try std.testing.expect(!(try dp.detect("1710504800", .{})).reusable());
    if (dp.localeSet("fr-CA")) |fr| {
        const r = try dp.parseWith("15 mars 2024", .{ .locales = fr });
        try std.testing.expectEqual(DateTime{ .year = 2024, .month = 3, .day = 15 }, r.time);
    }
    try std.testing.expectEqual(null, dp.localeSet("xx"));
}

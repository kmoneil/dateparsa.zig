//! The examples in README.md, kept here so that an example which stops
//! compiling or stops being true fails `zig build test`. Each test body is
//! the README snippet with its comments turned into assertions.

const std = @import("std");
const dateparsa = @import("root.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "quick start" {
    const r = try dateparsa.parse("2024-03-15T10:30:00Z");

    try expectEqual(2024, r.time.year);
    try expectEqual(10, r.time.hour);
    try expectEqualStrings("ISO8601_DATETIME_Z", r.layout.label);
    try expect(r.kind == .absolute and !r.ambiguous);
}

test "reuse the detected layout" {
    const rows = [_][]const u8{ "2024-03-15", "2024-03-16 ", "\t2024-03-17" };

    const first = try dateparsa.parse(rows[0]);
    if (first.layout.reusable()) {
        for (rows[1..]) |row| {
            const t = try first.layout.parse(row); // no detection, no allocation
            try expectEqual(2024, t.year);
        }
    }
}

test "parse a column" {
    var p = dateparsa.Parser.init(.{});
    const column = [_][]const u8{ "2024-01-01", "2024-06-15", "March 3, 2024", "2024-12-31" };
    for (column) |value| {
        const r = try p.parse(value); // detects once, re-detects when the format changes
        try expectEqual(2024, r.time.year);
    }
}

test "ambiguity is reported, never hidden" {
    const r = try dateparsa.parse("01/02/2024");
    try expect(r.ambiguous); // read as January 2nd, and that was a guess
    try expectEqual(1, r.time.month);

    const eu = try dateparsa.parseWith("01/02/2024", .{ .prefer_day_first = true });
    try expectEqual(2, eu.time.month); // February 1st

    var diag: dateparsa.Diagnostics = .{};
    const strict = dateparsa.parseWith("01/02/2024", .{ .strict = true, .diagnostics = &diag });
    try std.testing.expectError(error.Ambiguous, strict);
    for (diag.slice()) |in| {
        // "MM/DD/YYYY" 2024-01-02, then "DD/MM/YYYY" 2024-02-01
        try expect(in.time.year == 2024 and in.label.len == 10);
    }
    try expectEqualStrings("DD/MM/YYYY", diag.slice()[1].label);
}

test "natural language, against an explicit base time" {
    const base: dateparsa.DateTime = .{ .year = 2024, .month = 3, .day = 15, .hour = 12 };

    const r = try dateparsa.parseWith("next friday at 5pm", .{ .base_time = base });
    try expectEqual(dateparsa.DateTime{ .year = 2024, .month = 3, .day = 22, .hour = 17 }, r.time);
    try expect(r.kind == .relative);

    // No base time means no guess at "now": the library never reads a clock.
    try std.testing.expectError(error.NoBaseTime, dateparsa.parse("3 days ago"));
}

test "locales" {
    const base: dateparsa.DateTime = .{ .year = 2024, .month = 3, .day = 15, .hour = 12 };
    if (!@hasField(dateparsa.LocaleSet, "fr") or !@hasField(dateparsa.LocaleSet, "de")) return error.SkipZigTest;

    const opts: dateparsa.Options = .{ .base_time = base, .locales = .{ .fr = true, .de = true } };
    const fr = try dateparsa.parseWith("15 mars 2024", opts);
    const de = try dateparsa.parseWith("vor 3 Tagen", opts);
    try expectEqual(3, fr.time.month);
    try expectEqual(12, de.time.day);

    // Or by BCP 47 tag, when the tag arrives at run time.
    const es = dateparsa.localeSet("es-MX") orelse return error.SkipZigTest;
    const r = try dateparsa.parseWith("hace 2 horas", .{ .base_time = base, .locales = es });
    try expectEqual(10, r.time.hour);
}

test "zones and timestamps" {
    // An input that writes no zone is read at timezone_offset.
    const ist = try dateparsa.parseWith("2024-03-15 10:30:00", .{ .timezone_offset = 5 * 3600 + 30 * 60 });
    try expectEqual(19800, ist.time.offset_seconds);
    const instant = ist.time.toEpoch(); // seconds since 1970-01-01T00:00:00Z
    try expectEqual(1710478800, instant.seconds);

    // Unix timestamps: the digit count is the precision.
    const ms = try dateparsa.parse("1710504800123");
    try expectEqual(123_000_000, ms.time.nanosecond);
    try expect(!ms.layout.reusable()); // a timestamp has no format to reuse
}

test "json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Event = struct { name: []const u8, at: dateparsa.FlexTime };

    const events = try std.json.parseFromSliceLeaky([]Event, arena,
        \\[{"name": "a", "at": "March 15, 2024"},
        \\ {"name": "b", "at": 1710505800123},
        \\ {"name": "c", "at": null}]
    , .{});
    try expectEqual(dateparsa.DateTime{ .year = 2024, .month = 3, .day = 15 }, events[0].at.time.?);
    try expectEqual(
        dateparsa.DateTime{ .year = 2024, .month = 3, .day = 15, .hour = 12, .minute = 30, .nanosecond = 123_000_000 },
        events[1].at.time.?,
    );
    try expect(events[2].at.time == null);

    const out = try std.json.Stringify.valueAlloc(arena, events[1], .{});
    try expectEqualStrings(
        \\{"name":"b","at":"2024-03-15T12:30:00.123Z"}
    , out);

    // The numeric rule: a number under ten digits is seconds, the string
    // of its digits is refused.
    const day = try dateparsa.FlexTime.fromValue(.{ .integer = 86400 });
    try expectEqual(dateparsa.DateTime{ .year = 1970, .month = 1, .day = 2 }, day.time.?);
    try std.testing.expectError(error.NoMatch, dateparsa.FlexTime.fromValue(.{ .string = "86400" }));

    var strict = dateparsa.Parser.init(.{ .strict = true });
    try std.testing.expectError(error.Ambiguous, dateparsa.FlexTime.fromValueWith(&strict, .{ .string = "01/02/2024" }));
}

test "every example in the README's format table parses" {
    const base: dateparsa.DateTime = .{ .year = 2024, .month = 3, .day = 15, .hour = 12 };
    for ([_][]const u8{
        "2024-03-15",                      "2024-03-15T10:30:00Z",              "2024-03-15T10:30:00.123456+05:30",
        "2024-W11-5",                      "2024-074",                          "2020-07-20+08:00",
        "2024-03-15 10:30:00",             "2024-03-15 10:30:00.000000",        "2024-03-15 10:30:00+00",
        "2014-12-16 06:20:00 UTC",         "2014-05-11 08:20:13,787",           "20240315",
        "20240315T103000Z",                "20240315103000",                    "171113",
        "03/15/2024",                      "15.03.2024",                        "3/15/24",
        "3/15/2024 10:30 PM",              "March 15, 2024",                    "15 Mar 2024",
        "December 23rd",                   "March 2024",                        "the 15th of March 2024",
        "Fri, 15 Mar 2024 10:30:00 +0000", "Friday, 15-Mar-24 10:30:00 UTC",    "Mon Jan 2 15:04:05 2006",
        "15/Mar/2024:10:30:00 +0000",      "Fri Jul 03 2015 18:04:07 GMT+0100", "2015-02-08 03:02:00 +0300 MSK",
        "2014:04:08 22:05:13",
        "2014年04月08日",
        "10:30",                           "10:30:00",                          "10:30 PM",
        "10:30:00.123",                    "1710504800",                        "1710504800123",
        "1710504800123456",                "1710504800.123",
    }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        const r = try dateparsa.parseWith(s, .{ .base_time = base });
        try expect(r.kind == .absolute);
    }
}

test "every natural-language phrase the README lists parses" {
    const base: dateparsa.DateTime = .{ .year = 2024, .month = 3, .day = 15, .hour = 12 };
    for ([_][]const u8{
        "now",        "today",           "tonight",                "yesterday at 5pm",  "3 days ago",
        "in 2 hours", "a week from now", "2 days and 3 hours ago", "half an hour ago",  "next friday",
        "last month", "this morning",    "end of month",           "beginning of year", "March 5",
    }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        _ = try dateparsa.parseWith(s, .{ .base_time = base });
    }
    // The README's other claims: a time alone takes 1 January of the base
    // year, and validation refuses rather than normalises.
    const t = try dateparsa.parseWith("10:30", .{ .base_time = base });
    try expectEqual(dateparsa.DateTime{ .year = 2024, .month = 1, .day = 1, .hour = 10, .minute = 30 }, t.time);
    try std.testing.expectError(error.NoMatch, dateparsa.parse("2024-02-30"));
}

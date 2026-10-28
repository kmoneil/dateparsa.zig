//! The C ABI through include/dateparsa.h as Zig's translate-c reads it: the
//! header's types laid out exactly as src/c_api.zig's, and its functions,
//! called through the header's own declarations, agreeing with the Zig API.

const std = @import("std");
const h = @import("dateparsa_h");
const c = @import("c_api.zig");
const dp = @import("root.zig");
const locale = @import("locale.zig");
const golden = @import("golden_test.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn upper(comptime s: []const u8) []const u8 {
    comptime {
        var buf: [s.len]u8 = undefined;
        _ = std.ascii.upperString(&buf, s);
        const out = buf;
        return &out;
    }
}

fn status(s: anytype) c_int {
    return @intCast(s);
}

test "the header lays out every type as the library does" {
    inline for (.{
        .{ c.DateTime, h.dateparsa_datetime },
        .{ c.Interpretation, h.dateparsa_interpretation },
        .{ c.Diagnostics, h.dateparsa_diagnostics },
        .{ c.Options, h.dateparsa_options },
        .{ c.Result, h.dateparsa_result },
        .{ c.LayoutBlob, h.dateparsa_layout },
        .{ c.ParserBlob, h.dateparsa_parser },
        .{ c.ColumnBlob, h.dateparsa_column },
        .{ c.ColumnReport, h.dateparsa_column_report },
    }) |pair| {
        const Z = pair[0];
        const H = pair[1];
        try expectEqual(@sizeOf(H), @sizeOf(Z));
        try expectEqual(@alignOf(H), @alignOf(Z));
        switch (@typeInfo(Z)) {
            .@"struct" => |s| inline for (s.field_names, s.field_types) |name, T| {
                try expectEqual(@offsetOf(H, name), @offsetOf(Z, name));
                try expectEqual(@sizeOf(@FieldType(H, name)), @sizeOf(T));
            },
            .@"union" => |u| inline for (u.field_names, u.field_types) |name, T| {
                try expectEqual(@sizeOf(@FieldType(H, name)), @sizeOf(T));
            },
            else => comptime unreachable,
        }
    }
    try expectEqual(c.layout_size, h.DATEPARSA_LAYOUT_SIZE);
    try expectEqual(c.parser_size, h.DATEPARSA_PARSER_SIZE);
    try expectEqual(c.column_size, h.DATEPARSA_COLUMN_SIZE);
    try expectEqual(-1, h.DATEPARSA_ORDER_NONE);
    inline for (comptime std.enums.values(dp.Layout.Order)) |o| {
        try expectEqual(@backingInt(o), @field(h, "DATEPARSA_ORDER_" ++ upper(@tagName(o))));
    }
    try expectEqual(c.rfc3339_max, h.DATEPARSA_RFC3339_MAX);
    inline for (comptime std.enums.values(c.Status)) |v| {
        try expectEqual(@backingInt(v), @field(h, "DATEPARSA_" ++ upper(@tagName(v))));
    }
    try expectEqual(0, h.DATEPARSA_KIND_ABSOLUTE);
    try expectEqual(1, h.DATEPARSA_KIND_RELATIVE);
    try expectEqual(2, h.DATEPARSA_KIND_NOW);
    inline for (locale.every_tag, 0..) |tag, i| {
        try expectEqual(@as(u32, 1) << i, @field(h, "DATEPARSA_LOCALE_" ++ upper(tag)));
    }
}

/// The golden corpus's base time, in the header's type.
const golden_base: h.dateparsa_datetime = .{
    .year = 2024,
    .month = 6,
    .day = 15,
    .hour = 12,
    .minute = 0,
    .second = 0,
    .nanosecond = 0,
    .offset_seconds = 0,
};

fn goldenInputs(a: std.mem.Allocator) ![]const []const u8 {
    var inputs: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, @import("golden_corpus").text, '\n');
    var buf: [4096]u8 = undefined;
    while (lines.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        const quoted = row[0 .. std.mem.indexOfScalar(u8, row, '\t') orelse row.len];
        try inputs.append(a, try a.dupe(u8, try golden.unquote(&buf, quoted)));
    }
    return inputs.items;
}

fn toZig(t: h.dateparsa_datetime) dp.DateTime {
    return .{
        .year = t.year,
        .month = t.month,
        .day = t.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
        .offset_seconds = t.offset_seconds,
    };
}

/// What the header's call answered, against what parseWith answers.
fn expectAgrees(s: []const u8, got_status: c_int, got: *const h.dateparsa_result, opts: dp.Options) !void {
    errdefer std.debug.print("input \"{f}\" options {any}\n", .{ std.zig.fmtString(s), opts });
    const want = dp.parseWith(s, opts) catch |err| {
        try expectEqual(status(switch (err) {
            error.NoMatch => h.DATEPARSA_NO_MATCH,
            error.Ambiguous => h.DATEPARSA_AMBIGUOUS,
            error.NoBaseTime => h.DATEPARSA_NO_BASE_TIME,
        }), got_status);
        return;
    };
    try expectEqual(status(h.DATEPARSA_OK), got_status);
    try expectEqual(want.time, toZig(got.time));
    try expectEqual(want.time.toEpoch().seconds, got.unix_seconds);
    try expectEqual(@backingInt(want.kind), got.kind);
    try expectEqual(want.ambiguous, got.ambiguous);
    try expectEqual(want.layout.reusable(), got.reusable);
    try expectEqualStrings(want.layout.label, got.label[0..got.label_len]);
    try expect(h.dateparsa_layout_reusable(&got.layout) == got.reusable);
    var n: usize = 0;
    try expectEqualStrings(want.layout.label, h.dateparsa_layout_label(&got.layout, &n)[0..n]);
    if (want.layout.source == .program) {
        var t: h.dateparsa_datetime = undefined;
        try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_layout_parse(&got.layout, s.ptr, s.len, &t)));
        try expectEqual(want.time, toZig(t));
    }
}

test "through the header, parse agrees with parseWith on every golden row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const inputs = try goldenInputs(arena.allocator());
    try expect(inputs.len > 1000);

    const zig_base: dp.DateTime = toZig(golden_base);
    const all = h.dateparsa_locales_compiled();
    const sets = [_]struct { h.dateparsa_options, dp.Options }{
        .{ .{}, .{} },
        .{ .{ .base_time = &golden_base }, .{ .base_time = zig_base } },
        .{
            .{ .base_time = &golden_base, .prefer_day_first = true, .timezone_offset = 19800 },
            .{ .base_time = zig_base, .prefer_day_first = true, .timezone_offset = 19800 },
        },
        .{ .{ .base_time = &golden_base, .strict = true }, .{ .base_time = zig_base, .strict = true } },
        .{
            .{ .base_time = &golden_base, .locales = all, .prefer_future = true },
            .{ .base_time = zig_base, .locales = (try c.toZig(&.{ .locales = all })).locales, .prefer_future = true },
        },
    };
    for (inputs) |s| for (sets) |set| {
        var r: h.dateparsa_result = undefined;
        const got = status(h.dateparsa_parse(s.ptr, s.len, &set[0], &r));
        try expectAgrees(s, got, &r, set[1]);
    };
}

test "through the header, a parser agrees with parse down the golden corpus" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const inputs = try goldenInputs(arena.allocator());

    var p: h.dateparsa_parser = undefined;
    const o: h.dateparsa_options = .{ .base_time = &golden_base };
    try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_parser_init(&p, &o)));
    for (inputs) |s| {
        var r: h.dateparsa_result = undefined;
        const got = status(h.dateparsa_parser_parse(&p, s.ptr, s.len, &r));
        try expectAgrees(s, got, &r, .{ .base_time = toZig(golden_base) });
    }
}

/// A column through the header, against Column over the same values.
fn expectColumnAgrees(values: []const []const u8, o: h.dateparsa_options, zo: dp.Options) !void {
    var col: h.dateparsa_column = undefined;
    try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_column_init(&col, &o)));
    for (values) |v| try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_column_add(&col, v.ptr, v.len)));
    var got: h.dateparsa_column_report = undefined;
    try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_column_summarize(&col, &got)));
    const want = dp.detectColumn(values, zo);
    try expectEqual(if (want.order) |w| @as(i32, @backingInt(w)) else -1, got.order);
    try expectEqual(@as(u32, @as(u3, @bitCast(want.fits))), got.fits);
    try expectEqual(want.order != null and want.options.prefer_day_first, got.prefer_day_first);
    try expectEqual(want.order != null and want.options.prefer_year_first, got.prefer_year_first);
    try expectEqual(want.values, got.values);
    try expectEqual(want.voted, got.voted);
    try expectEqual(want.failed, got.failed);
    try expectEqual(want.conflicts, got.conflicts);
    try expectEqual(if (want.settled_by) |i| @as(i64, @intCast(i)) else -1, got.settled_by);
    try expectEqual(if (want.first_conflict) |i| @as(i64, @intCast(i)) else -1, got.first_conflict);
}

test "through the header, a column reports what Column does" {
    const columns = [_][]const []const u8{
        &.{ "01/02/2024", "05/06/2024", "13/02/2024" },
        &.{ "01/02/2024", "02/13/2024" },
        &.{ "01/02/2024", "03/04/2024" },
        &.{ "13/02/03", "05/06/31" },
        &.{ "32/01/02", "01/02/03" },
        &.{ "13/02/2024", "02/13/2024", "14/02/2024" },
        &.{ "13/02/2024", "02/13/2024" },
        &.{ "2024-03-15", "nonsense", "yesterday" },
        &.{},
    };
    for (columns) |col| try expectColumnAgrees(col, .{}, .{});

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const inputs = try goldenInputs(arena.allocator());
    try expectColumnAgrees(inputs, .{ .base_time = &golden_base }, .{ .base_time = toZig(golden_base) });

    // A column the library never set up is refused, not read.
    var zeroed = std.mem.zeroes(h.dateparsa_column);
    var report: h.dateparsa_column_report = undefined;
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_column_add(&zeroed, "x", 1)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_column_summarize(&zeroed, &report)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_column_init(null, null)));
    const bad: h.dateparsa_options = .{ .timezone_offset = 86_400 };
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_column_init(&zeroed, &bad)));
}

test "what crosses in is checked, and a refusal says why" {
    var diag: h.dateparsa_diagnostics = undefined;
    var r: h.dateparsa_result = undefined;
    const refusals = [_]struct { h.dateparsa_datetime, i32, u32, []const u8 }{
        .{ golden_base, 86_400, 0, "timezone_offset is a day or more" },
        .{ golden_base, -86_400, 0, "timezone_offset is a day or more" },
        .{ golden_base, 0, 1 << 20, "locales has a bit for a locale this build did not compile in" },
        .{ .{ .year = 2023, .month = 2, .day = 29, .hour = 0, .minute = 0, .second = 0, .nanosecond = 0, .offset_seconds = 0 }, 0, 0, "base_time is not a valid date and time" },
        .{ .{ .year = 2024, .month = 1, .day = 1, .hour = 24, .minute = 0, .second = 0, .nanosecond = 0, .offset_seconds = 0 }, 0, 0, "base_time is not a valid date and time" },
        .{ .{ .year = 2024, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .nanosecond = 1_000_000_000, .offset_seconds = 0 }, 0, 0, "base_time is not a valid date and time" },
        .{ .{ .year = 2024, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .nanosecond = 0, .offset_seconds = 86_400 }, 0, 0, "base_time is not a valid date and time" },
        .{ .{ .year = 1_000_000_000, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .nanosecond = 0, .offset_seconds = 0 }, 0, 0, "base_time's year is more than 999999999 from year 0" },
        .{ .{ .year = -1_000_000_000, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .nanosecond = 0, .offset_seconds = 0 }, 0, 0, "base_time's year is more than 999999999 from year 0" },
    };
    for (refusals) |bad| {
        const o: h.dateparsa_options = .{ .base_time = &bad[0], .timezone_offset = bad[1], .locales = bad[2], .diagnostics = &diag };
        try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_parse("today", 5, &o, &r)));
        try expectEqualStrings(bad[3], diag.message[0..diag.message_len]);
        try expectEqual(0, diag.interpretation_count);
        var p: h.dateparsa_parser = undefined;
        try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_parser_init(&p, &o)));
        try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_parser_parse(&p, "today", 5, &r)));
    }

    // The edges that are allowed.
    const edge: h.dateparsa_datetime = .{ .year = 999_999_999, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .nanosecond = 999_999_999, .offset_seconds = -86_399 };
    const o: h.dateparsa_options = .{ .base_time = &edge, .timezone_offset = 86_399, .locales = h.dateparsa_locales_compiled() };
    try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_parse("in 999999 years", 15, &o, &r)));
    try expectEqual(1_000_999_998, r.time.year);

    const no_diag: h.dateparsa_options = .{};
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_parse("x", 1, &no_diag, null)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_parse(null, 1, null, &r)));
    try expectEqual(status(h.DATEPARSA_NO_MATCH), status(h.dateparsa_parse(null, 0, null, &r)));
    var l: h.dateparsa_layout = std.mem.zeroes(h.dateparsa_layout);
    var t: h.dateparsa_datetime = undefined;
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_layout_parse(&l, "2024-03-15", 10, &t)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_layout_parse(null, "2024-03-15", 10, &t)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_detect("2024-03-15", 10, null, null)));
    try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_detect("2024-03-15", 10, null, &l)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_layout_parse(&l, "2024-03-15", 10, null)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_parser_init(null, null)));
    h.dateparsa_parser_reset(null);
}

test "a failed parse says why through the diagnostics" {
    var diag: h.dateparsa_diagnostics = undefined;
    var r: h.dateparsa_result = undefined;

    const strict: h.dateparsa_options = .{ .strict = true, .diagnostics = &diag };
    try expectEqual(status(h.DATEPARSA_AMBIGUOUS), status(h.dateparsa_parse("01/02/03", 8, &strict, &r)));
    var zig_diag: dp.Diagnostics = .{};
    try std.testing.expectError(error.Ambiguous, dp.parseWith("01/02/03", .{ .strict = true, .diagnostics = &zig_diag }));
    try expectEqual(zig_diag.interpretation_count, diag.interpretation_count);
    try expectEqual(3, diag.interpretation_count);
    for (zig_diag.slice(), diag.interpretations[0..diag.interpretation_count]) |want, got| {
        try expectEqual(want.time, toZig(got.time));
        try expectEqualStrings(want.label, got.label[0..got.label_len]);
    }

    const plain: h.dateparsa_options = .{ .diagnostics = &diag };
    try expectEqual(status(h.DATEPARSA_NO_BASE_TIME), status(h.dateparsa_parse("3 days ago", 10, &plain, &r)));
    try expect(diag.message_len > 0 and diag.interpretation_count == 0);
    try expectEqual(status(h.DATEPARSA_NO_MATCH), status(h.dateparsa_parse("nonsense", 8, &plain, &r)));
    try expect(diag.message_len > 0);
}

test "RFC 3339 and Unix seconds" {
    var buf: [h.DATEPARSA_RFC3339_MAX]u8 = undefined;
    var n: usize = 0;
    var seconds: i64 = 0;
    const cases = [_]struct { h.dateparsa_datetime, []const u8 }{
        .{ golden_base, "2024-06-15T12:00:00Z" },
        .{ .{ .year = -1, .month = 12, .day = 31, .hour = 23, .minute = 0, .second = 0, .nanosecond = 500, .offset_seconds = -90 }, "-0001-12-31T23:00:00.0000005-00:01" },
        .{ .{ .year = std.math.minInt(i32), .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .nanosecond = 999_999_999, .offset_seconds = -86_399 }, "-2147483648-12-31T23:59:59.999999999-23:59" },
    };
    for (cases) |case| {
        try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_format_rfc3339(&case[0], &buf, buf.len, &n)));
        try expectEqualStrings(case[1], buf[0..n]);
        try expectEqual(0, buf[n]);
        try expectEqual(status(h.DATEPARSA_BUFFER_TOO_SMALL), status(h.dateparsa_format_rfc3339(&case[0], &buf, n, &n)));
        try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_to_unix(&case[0], &seconds)));
        try expectEqual(toZig(case[0]).toEpoch().seconds, seconds);
    }
    try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_format_rfc3339(&golden_base, &buf, buf.len, null)));
    const bad: h.dateparsa_datetime = .{ .year = 2024, .month = 13, .day = 1, .hour = 0, .minute = 0, .second = 0, .nanosecond = 0, .offset_seconds = 0 };
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_format_rfc3339(&bad, &buf, buf.len, &n)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_to_unix(&bad, &seconds)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_format_rfc3339(&golden_base, null, 64, &n)));
}

test "locale bits, the version" {
    const compiled = h.dateparsa_locales_compiled();
    try expect(compiled & h.DATEPARSA_LOCALE_EN != 0);
    try expectEqual(locale.compiled.len, @popCount(compiled));
    var bit: u32 = 0;
    for (locale.compiled) |d| {
        try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_locale_lookup(d.tag.ptr, d.tag.len, &bit)));
        try expect(bit & compiled != 0 and @popCount(bit) == 1);
    }
    try expectEqual(status(h.DATEPARSA_NO_MATCH), status(h.dateparsa_locale_lookup("xx", 2, &bit)));
    try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_locale_lookup("en", 2, null)));
    if (compiled & h.DATEPARSA_LOCALE_FR != 0) {
        try expectEqual(status(h.DATEPARSA_OK), status(h.dateparsa_locale_lookup("FR-ca", 5, &bit)));
        try expectEqual(h.DATEPARSA_LOCALE_FR, bit);
    } else {
        var r: h.dateparsa_result = undefined;
        const o: h.dateparsa_options = .{ .locales = h.DATEPARSA_LOCALE_FR };
        try expectEqual(status(h.DATEPARSA_INVALID_ARGUMENT), status(h.dateparsa_parse("15 mars 2024", 12, &o, &r)));
    }
    _ = try std.SemanticVersion.parse(std.mem.span(h.dateparsa_version()));
}

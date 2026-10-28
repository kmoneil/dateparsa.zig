//! Fuzz targets, after the Go dateparsa's fuzz_test.go. Under zig build test
//! each replays its seeds once; under tools/fuzz.sh the fuzzer mutates them.
//! Each holds a property, not only "does not crash":
//!
//! - parseWith on any bytes trips no safety check and answers a valid time;
//!   its layout re-reads the input it came from to that time, the time
//!   written as RFC 3339 parses back to itself, and the layout's format
//!   string in every dialect is spelled or refused, never misaligned.
//! - A layout detected from one input either refuses another or agrees with
//!   detecting that input afresh: the property Parser depends on.
//! - A Parser primed with one input agrees with parseWith on the next.
//! - The fixed-slot fast path agrees with the interpreter.
//! - A JSON value FlexTime reads is a valid time, and the RFC 3339 it
//!   writes reads back to that time.
//! - What FlexTime reads, through std.json or fromValue, does not depend on
//!   what it read before: its per-thread cache agrees with a cold one.
//! - Each field order Column says a value fits is the order its preferences
//!   read it in, and a column's options read every value that fits the
//!   column's order in it.
//! - The C API refuses exactly the options it must, whatever a C caller's
//!   struct holds, and otherwise answers as parseWith does; a base time at
//!   the edge of what it allows trips no safety check inside.
//!
//! The seeds are the Go targets' seeds and committed crashers, every format's
//! example and every row of the golden corpus.

const std = @import("std");
const dp = @import("root.zig");
const formats = @import("formats.zig");
const golden = @import("golden_test.zig");
const c = @import("c_api.zig");
const locale = @import("locale.zig");

const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Longer than any input a format or an expression can address, so the
/// bounds are fuzzed too.
const max_input = 600;

/// The golden corpus's base time, so its rows read as they do there.
const base: dp.DateTime = .{ .year = 2024, .month = 6, .day = 15, .hour = 12 };

/// Every compiled-in locale: the set's backing integer has one bit each.
const all_locales: dp.LocaleSet = blk: {
    const Backing = @typeInfo(dp.LocaleSet).@"struct".backing_integer.?;
    break :blk @bitCast(~@as(Backing, 0));
};

/// The options an input asks for: one byte of switches after its strings. A
/// seed ends before it, and reads as zero: the base time and every default.
fn options(smith: *Smith) dp.Options {
    const bits = smith.value(u8);
    return .{
        .base_time = if (bits & 1 == 0) base else null,
        .prefer_day_first = bits & 2 != 0,
        .prefer_year_first = bits & 4 != 0,
        .prefer_future = bits & 8 != 0,
        .strict = bits & 16 != 0,
        .locales = if (bits & 32 != 0) all_locales else .{},
        .timezone_offset = switch (bits >> 6) {
            0 => 0,
            1 => 5 * 3600 + 30 * 60,
            2 => -8 * 3600,
            else => 14 * 3600,
        },
    };
}

fn input(smith: *Smith, buf: *[max_input]u8) []const u8 {
    return buf[0..smith.slice(buf)];
}

fn report(a: []const u8, b: ?[]const u8, opts: dp.Options) void {
    std.debug.print("input \"{f}\"", .{std.zig.fmtString(a)});
    if (b) |s| std.debug.print(", then \"{f}\"", .{std.zig.fmtString(s)});
    std.debug.print("\noptions {any}\n", .{opts});
}

/// t written as RFC 3339 with nanoseconds parses back to t, offset and all.
/// A year outside 0000-9999 or an offset in seconds has no such form.
fn roundTrip(t: dp.DateTime) !void {
    if (t.year < 0 or t.year > 9999 or @rem(t.offset_seconds, 60) != 0) return;
    const sign: u8 = if (t.offset_seconds < 0) '-' else '+';
    const off = @abs(t.offset_seconds);
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}{c}{d:0>2}:{d:0>2}", .{
        @abs(t.year), t.month, t.day, t.hour, t.minute, t.second, t.nanosecond, sign, off / 3600, off % 3600 / 60,
    });
    errdefer std.debug.print("canonical form \"{s}\"\n", .{text});
    try expectEqual(t, (try dp.parse(text)).time);
}

fn parseOne(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const s = input(smith, &buf);
    var opts = options(smith);
    errdefer report(s, null, opts);

    _ = dp.detect(s, opts) catch {};
    var diag: dp.Diagnostics = .{};
    opts.diagnostics = &diag;
    const r = dp.parseWith(s, opts) catch |err| {
        if (err == error.Ambiguous) for (diag.slice()) |in| try expect(in.time.isValid());
        return;
    };
    try expect(r.time.isValid());
    try expect(@abs(r.time.offset_seconds) < 24 * 3600);
    if (r.layout.source == .program) try expectEqual(r.time, try r.layout.parse(s));
    try roundTrip(r.time);
    // Its format string, in every dialect, is spelled or refused: the value
    // a layout came from always lines up with its fields.
    for ([_]dp.Layout.Dialect{ .strftime, .go, .java }) |d| {
        var fmt_buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&fmt_buf);
        r.layout.formatString(d, s, &w) catch |err| switch (err) {
            error.Unsupported => {},
            else => return err,
        };
    }
}

fn reuseOne(_: void, smith: *Smith) anyerror!void {
    var buf_a: [max_input]u8 = undefined;
    var buf_b: [max_input]u8 = undefined;
    const a = input(smith, &buf_a);
    const b = input(smith, &buf_b);
    const opts = options(smith);
    errdefer report(a, b, opts);

    // Gated on having a program, not on reusable(): a layout that is not
    // reusable still parses, and one accepting a row it does not describe is
    // what this target hunts.
    const cached = dp.parseWith(a, opts) catch return;
    if (cached.layout.source != .program) return;
    const fresh = dp.parseWith(b, opts) catch return;
    if (fresh.layout.source != .program) return;
    const got = cached.layout.parse(b) catch return; // refusing is always allowed
    // A reported guess may differ: the cached layout made the other choice,
    // and both calls said a choice was made.
    if (cached.ambiguous or fresh.ambiguous) return;
    try expectEqual(fresh.time, got);
}

fn parserOne(_: void, smith: *Smith) anyerror!void {
    var buf_a: [max_input]u8 = undefined;
    var buf_b: [max_input]u8 = undefined;
    const a = input(smith, &buf_a);
    const b = input(smith, &buf_b);
    const opts = options(smith);
    errdefer report(a, b, opts);

    var p = dp.Parser.init(opts);
    _ = p.parse(a) catch {};
    const got = p.parse(b);
    // One direction: where detection parses an input, a primed Parser must
    // too, and agree. The other is allowed, because a skipped weekday takes
    // any letters, so a cached layout can accept bytes detection refuses.
    const want = dp.parseWith(b, opts) catch return;
    const g = try got;
    try expectEqual(want.time, g.time);
    try expectEqual(want.ambiguous, g.ambiguous);
    try expectEqual(want.kind, g.kind);
}

fn fastOne(_: void, smith: *Smith) anyerror!void {
    var buf_a: [max_input]u8 = undefined;
    var buf_b: [max_input]u8 = undefined;
    const a = input(smith, &buf_a);
    const b = input(smith, &buf_b);
    const opts = options(smith);
    errdefer report(a, b, opts);

    const r = dp.parseWith(a, opts) catch return;
    if (r.layout.source != .program or !r.layout.program.isFast()) return;
    var slow = r.layout.program;
    slow.width = 0;
    slow.width_alt = 0;
    try expectEqual(slow.execute(b), r.layout.program.execute(b));
}

/// A JSON document read as a FlexTime. The buffer holds the scanner's
/// nesting bits and a copy of an escaped string, which are all std.json
/// allocates for one.
fn readJson(doc: []const u8) !dp.FlexTime {
    var mem: [4 * max_input]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    return std.json.parseFromSliceLeaky(dp.FlexTime, fba.allocator(), doc, .{});
}

fn jsonOne(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const doc = input(smith, &buf);
    errdefer report(doc, null, .{});

    const ft = readJson(doc) catch return;
    const t = ft.time orelse return;
    try expect(t.isValid());
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try std.json.Stringify.value(ft, .{}, &w);
    errdefer std.debug.print("written as {s}\n", .{w.buffered()});
    // Outside 0000-9999, or with an offset in seconds, what is written is
    // Go's form and not RFC 3339, and need not read back.
    if (t.year < 0 or t.year > 9999 or @rem(t.offset_seconds, 60) != 0) return;
    try expectEqual(dp.FlexTime{ .time = t }, try readJson(w.buffered()));
}

fn flexJsonOne(_: void, smith: *Smith) anyerror!void {
    var buf_a: [max_input]u8 = undefined;
    var buf_b: [max_input]u8 = undefined;
    const a = input(smith, &buf_a);
    const b = input(smith, &buf_b);
    errdefer report(a, b, .{});

    // Cleared first, so the cache holds a's layout or none, whatever ran
    // before: a failing input then fails again when replayed alone.
    dp.FlexTime.forgetLayouts();
    _ = readJson(a) catch {};
    const warm = readJson(b);
    dp.FlexTime.forgetLayouts();
    // One direction, as for Parser: a primed cache may accept bytes
    // detection refuses, never refuse or change what it reads.
    const cold = readJson(b) catch return;
    try expectEqual(cold, try warm);
}

fn flexValueOne(_: void, smith: *Smith) anyerror!void {
    var buf_a: [max_input]u8 = undefined;
    var buf_b: [max_input]u8 = undefined;
    const a = input(smith, &buf_a);
    const b = input(smith, &buf_b);
    errdefer report(a, b, .{});

    dp.FlexTime.forgetLayouts();
    _ = dp.FlexTime.fromValue(.{ .string = a }) catch {};
    const warm = dp.FlexTime.fromValue(.{ .string = b });
    dp.FlexTime.forgetLayouts();
    const cold = dp.FlexTime.fromValue(.{ .string = b }) catch return;
    try expectEqual(cold, try warm);
}

fn columnOne(_: void, smith: *Smith) anyerror!void {
    var buf_a: [max_input]u8 = undefined;
    var buf_b: [max_input]u8 = undefined;
    const a = input(smith, &buf_a);
    const b = input(smith, &buf_b);
    const opts = options(smith);
    errdefer report(a, b, opts);
    // Column sets strict mode aside, so its checks here do too.
    var plain = opts;
    plain.strict = false;

    // Each order a value is said to fit is the order its preferences read.
    for ([_][]const u8{ a, b }) |s| {
        const say = dp.Column.orders(s, opts) orelse continue;
        for (std.enums.values(dp.Layout.Order)) |o| {
            if (!say.has(o)) continue;
            const r = try dp.parseWith(s, dp.Column.readIn(plain, o));
            try expectEqual(o, r.layout.dateOrder().?);
        }
    }
    // The column's options read every value that fits its order in it.
    const rep = dp.detectColumn(&.{ a, b }, opts);
    const order = rep.order orelse return;
    for ([_][]const u8{ a, b }) |s| {
        const say = dp.Column.orders(s, opts) orelse continue;
        if (!say.has(order)) continue;
        var o = rep.options;
        o.strict = false;
        try expectEqual(order, (try dp.parseWith(s, o)).layout.dateOrder().?);
    }
}

/// The C options a params string asks for, as raw as a C caller's struct.
/// Its bytes overwrite, from the front, a little-endian record whose
/// default is the golden base time and every other default: a switches
/// byte (1 no base time, 2 day first, 4 year first, 8 future, 16 strict),
/// the base year, timezone_offset, the locale bits, the base offset, then
/// the base month, day, hour, minute, second and nanosecond.
const c_record_len = 26;

const c_record_default: [c_record_len]u8 = blk: {
    var r: [c_record_len]u8 = @splat(0);
    std.mem.writeInt(i32, r[1..5], base.year, .little);
    r[17] = base.month;
    r[18] = base.day;
    r[19] = base.hour;
    break :blk r;
};

fn cOptions(params: []const u8, base_time: *c.DateTime) c.Options {
    var r = c_record_default;
    const n = @min(params.len, r.len);
    @memcpy(r[0..n], params[0..n]);
    base_time.* = .{
        .year = std.mem.readInt(i32, r[1..5], .little),
        .offset_seconds = std.mem.readInt(i32, r[13..17], .little),
        .month = r[17],
        .day = r[18],
        .hour = r[19],
        .minute = r[20],
        .second = r[21],
        .nanosecond = std.mem.readInt(u32, r[22..26], .little),
    };
    return .{
        .base_time = if (r[0] & 1 == 0) base_time else null,
        .timezone_offset = std.mem.readInt(i32, r[5..9], .little),
        .locales = std.mem.readInt(u32, r[9..13], .little),
        .prefer_day_first = r[0] & 2,
        .prefer_year_first = r[0] & 4,
        .prefer_future = r[0] & 8,
        .strict = r[0] & 16,
    };
}

/// What the C API must make of o, worked out apart from src/c_api.zig: the
/// Zig options, or null where it must refuse.
fn cExpected(o: *const c.Options) ?dp.Options {
    var opts: dp.Options = .{
        .timezone_offset = o.timezone_offset,
        .prefer_day_first = o.prefer_day_first != 0,
        .prefer_year_first = o.prefer_year_first != 0,
        .prefer_future = o.prefer_future != 0,
        .strict = o.strict != 0,
    };
    if (o.base_time) |b| {
        const t: dp.DateTime = .{
            .year = b.year,
            .month = b.month,
            .day = b.day,
            .hour = b.hour,
            .minute = b.minute,
            .second = b.second,
            .nanosecond = b.nanosecond,
            .offset_seconds = b.offset_seconds,
        };
        if (!t.isValid() or @abs(t.offset_seconds) >= 86_400 or @abs(t.year) > 999_999_999) return null;
        opts.base_time = t;
    }
    if (@abs(o.timezone_offset) >= 86_400) return null;
    const Backing = @typeInfo(dp.LocaleSet).@"struct".backing_integer.?;
    var set: Backing = 0;
    for (0..32) |i| {
        if ((o.locales >> @intCast(i)) & 1 == 0) continue;
        if (i >= locale.every_tag.len) return null;
        set |= @bitCast(dp.localeSet(locale.every_tag[i]) orelse return null);
    }
    opts.locales = @bitCast(set);
    return opts;
}

fn cOne(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    var params_buf: [max_input]u8 = undefined;
    const s = input(smith, &buf);
    var base_time: c.DateTime = undefined;
    var o = cOptions(input(smith, &params_buf), &base_time);
    var diag: c.Diagnostics = undefined;
    o.diagnostics = &diag;
    errdefer std.debug.print("input \"{f}\"\nC options {any}\nbase time {any}\n", .{ std.zig.fmtString(s), o, base_time });

    var r: c.Result = undefined;
    const got = c.dateparsa_parse(s.ptr, s.len, &o, &r);
    const opts = cExpected(&o) orelse {
        try expectEqual(c.Status.invalid_argument, got);
        try expect(diag.message_len > 0);
        return;
    };
    const want = dp.parseWith(s, opts) catch |err| {
        try expectEqual(@as(c.Status, switch (err) {
            error.NoMatch => .no_match,
            error.Ambiguous => .ambiguous,
            error.NoBaseTime => .no_base_time,
        }), got);
        return;
    };
    try expectEqual(c.Status.ok, got);
    const t = want.time;
    try expectEqual(c.DateTime{
        .year = t.year,
        .month = t.month,
        .day = t.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
        .offset_seconds = t.offset_seconds,
    }, r.time);
    try expectEqual(t.toEpoch().seconds, r.unix_seconds);
    try expectEqual(want.ambiguous, r.ambiguous);
    try std.testing.expectEqualStrings(want.layout.label, r.label[0..r.label_len]);
    if (want.layout.source == .program) {
        var again: c.DateTime = undefined;
        try expectEqual(c.Status.ok, c.dateparsa_layout_parse(&r.layout, s.ptr, s.len, &again));
        try expectEqual(r.time, again);
    }
    // What a result holds can be handed back in.
    var text: [c.rfc3339_max]u8 = undefined;
    var unix: i64 = 0;
    try expectEqual(c.Status.ok, c.dateparsa_format_rfc3339(&r.time, &text, text.len, null));
    try expectEqual(c.Status.ok, c.dateparsa_to_unix(&r.time, &unix));
    try expectEqual(r.unix_seconds, unix);
}

/// Go's FuzzParse and FuzzDetect seeds and committed crashers, and inputs
/// past the length bounds.
const singles = [_][]const u8{
    "2024-03-15",
    "2024-03-15T10:30:00Z",
    "2024-03-15T10:30:00+05:30",
    "2024-03-15 10:30:00",
    "March 15, 2024",
    "15 Mar 2024",
    "01/02/2024",
    "15.03.2024",
    "10:30",
    "10:30:00",
    "",
    "not a date",
    "2024-03-15T10:30:00.123456789Z",
    "first monday of march 2024",
    "the 3rd of March 2024",
    "dEC0000A\xbe\xc2\xd0 At 0",
    "0000000000",
    "\xcaMAY",
    "123456789012345678901234567890",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "MAY00\xc30\xae\x840000 At 0",
    &@as([600]u8, @splat('1')),
    "in 2 days" ++ @as([504]u8, @splat(' ')),
    &@as([513]u8, @splat('a')),
    // Found here. textual.trimSpace decoded the tail "\x7f\x84" as one
    // two-byte sequence, which std.unicode asserts it is not.
    "202March 15, 2024\xcd\x7f\x84",
    // Go's FuzzScanString seed: a crasher there (C1, detect.trimAtSuffix).
    "deC0000\xcd\xcd\xcd At 0",
};

/// Go's FuzzUnmarshalJSON seeds, and numbers and escapes at the edges of
/// what FlexTime reads.
const json_singles = [_][]const u8{
    "\"2024-03-15T10:30:00Z\"",
    "\"03/15/2024\"",
    "1710505800",
    "1710505800.123",
    "null",
    "\"\"",
    "\"garbage\"",
    "true",
    "{}",
    "86400",
    "-0",
    "1.7105e9",
    "1e300",
    "-9223372036854775808",
    "99999999999999999999",
    "\"2024-03-15T10:30:00\\u005a\"",
    "\"03\\/15\\/2024\"",
};

/// Go's FuzzUnmarshalJSONAcrossFormats seeds that are not a pair below in
/// quotes.
const json_pairs = [_][2][]const u8{
    .{ "1710505800", "\"2024-03-15\"" },
    .{ "\"2024-03-15\"", "null" },
    .{ "0", "\"in0S\"" },
};

/// Go's FuzzLayoutReuse and FuzzParserAgreesWithParse seeds, nearly all of
/// them a defect the Go fuzzer found (C24 to C34 in its fuzz_test.go), and
/// the README's reuse table.
const pairs = [_][2][]const u8{
    .{ "2024-03-15", "2024-03-16T10:30:00Z" },
    .{ "2024-03-15", "2024-03-17T23:59:59+05:30" },
    .{ "2024-03-15", "2024-03-15 10:30:00" },
    .{ "10:30", "10:30:45" },
    .{ "2024-03-15T10:30:00Z", "2024-03-15" },
    .{ "March 15, 2024", "15 Mar 2024" },
    .{ "01/02/2024", "25/12/2024" },
    .{ "03/15/2024", "01/02/2024" },
    .{ "25/12/2024", "01/02/2024" },
    .{ "", "" },
    .{ "70/01/1 00", "01/01/1000" },
    .{ "1MAY", "1MAr" },
    .{ "020/1/0000", "17/11/0000" },
    .{ "0000-001", "00000101" },
    .{ "MAY A1", "MAY1010" },
    .{ "MAY A1", "MAY 15" },
    .{ "00:00:00", "00000101" },
    .{ "10:30", "1030" },
    .{ "20-1-00", "10:01:00" },
    .{ "10:30:45", "12/25/24" },
    .{ "MAr A1AAA", "MArAA1MAY" },
    .{ "2024-03-15", "2024-03-16 " },
    .{ " 2024-03-15", "2024-03-16" },
    .{ "2024-03-15", "2024-03-16T10:30:00Z " },
    .{ "70MAY1", "01MAY10" },
    .{ "70-1-17", "17-1-01" },
    .{ "MAY1 00:00 1000", "MAY1 00:00+0000" },
    .{ "\x00MAY1", "1MAY10" },
    .{ "MAY1 70:00:00", "MAY1 00:00:00" },
    .{ "MAY1AAA", "mAY1MAr" },
    .{ "MAY1AAA", "mAI1MAr" },
    .{ "MAY1 00:00! 1000", "MAY1 00:00A+0000" },
    .{ "May 1 10:30:00, 2024", "May 1 10:30:00 -0700" },
    .{ "MAY1 10:00  PM", "MAY1 10:00\t\tPM" },
    .{ "MAY1 00:00A-0000", "MAY1 00:00Z-1000" },
    .{ "MAY1 00:00ZA+0000", "MAY1 10:00AM+1000" },
    .{ "MAY1 10:00 GMT+0000", "MAY1 10:00   Z+1000" },
    .{ "MAY70", "MAY10" },
    .{ "March 32", "March 31" },
    .{ "2024-03-15", "1710505800" },
    .{ "2024-03-15", "yesterday" },
    .{ "yesterday", "2024-03-15" },
    .{ "2024-03-15", "3 days ago" },
    .{ "0000-01-01 00:00:00  0000", "0000-01-01 00:00:00 " },
    .{ "2024-03-15", " 2024-03-16\r\n" },
    .{ "1 May 2024", "12 May 2024" },
    .{ "12 May 2024", "1 May 2024" },
    .{ "Fri, 15 Mar 2024 10:30:00 +0000", "Sat, 16 Mar 2024 11:30:00 -0700" },
    .{ "March 15, 2024", "March 16; 2024" },
    .{ "March 15, 2024", "April 16, 2024" },
    .{ "15 mars 2024", "16 mai 2024" },
    // From the Go flextime targets.
    .{ "2024-03-15T10:30:00Z", "03/15/2024" },
    .{ "1710505800", "2024-03-15" },
    .{ "0", "in0S" },
};

/// A seed as Smith reads one: each string a four-byte little-endian length
/// and its bytes.
fn seed(arena: Allocator, strings: []const []const u8) ![]const u8 {
    var len: usize = 0;
    for (strings) |s| len += 4 + s.len;
    const out = try arena.alloc(u8, len);
    var w: std.Io.Writer = .fixed(out);
    for (strings) |s| {
        try w.writeInt(u32, @intCast(s.len), .little);
        try w.writeAll(s);
    }
    return out;
}

fn goldenInputs(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, @import("golden_corpus").text, '\n');
    var buf: [4096]u8 = undefined;
    while (lines.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        const quoted = row[0 .. std.mem.indexOfScalar(u8, row, '\t') orelse row.len];
        try out.append(arena, try arena.dupe(u8, try golden.unquote(&buf, quoted)));
    }
    return out.items;
}

fn singleSeeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (singles) |s| try out.append(arena, try seed(arena, &.{s}));
    for (formats.examples) |ex| try out.append(arena, try seed(arena, &.{ex[1]}));
    for (try goldenInputs(arena)) |s| try out.append(arena, try seed(arena, &.{s}));
    return out.items;
}

/// The pairs, each format's example against itself and the next format's,
/// and each golden row against the next, which sorts beside it and so often
/// shares its shape.
fn pairSeeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (pairs) |p| try out.append(arena, try seed(arena, &p));
    const ex = formats.examples;
    for (ex, 0..) |e, i| {
        try out.append(arena, try seed(arena, &.{ e[1], e[1] }));
        try out.append(arena, try seed(arena, &.{ e[1], ex[(i + 1) % ex.len][1] }));
    }
    const rows = try goldenInputs(arena);
    for (rows[0 .. rows.len - 1], rows[1..]) |a, b| try out.append(arena, try seed(arena, &.{ a, b }));
    return out.items;
}

/// s as a JSON string. Bytes that are not UTF-8 are kept, which makes a
/// document std.json refuses: a seed for that path too.
fn quote(arena: Allocator, s: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.encodeJsonString(s, .{}, &w.writer);
    return w.written();
}

/// The JSON values, then every single seed and format example as a string.
fn jsonSeeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (json_singles) |s| try out.append(arena, try seed(arena, &.{s}));
    for (singles) |s| try out.append(arena, try seed(arena, &.{try quote(arena, s)}));
    for (formats.examples) |ex| try out.append(arena, try seed(arena, &.{try quote(arena, ex[1])}));
    return out.items;
}

/// The pairs, then numeric dates that settle, narrow, or contradict each
/// other's order.
fn columnSeeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const columns = [_][2][]const u8{
        .{ "01/02/2024", "13/02/2024" },
        .{ "01/02/2024", "02/13/2024" },
        .{ "13/02/03", "05/06/31" },
        .{ "32/01/02", "01/02/03" },
        .{ "13/02/2024", "02/13/2024" },
        .{ "01.01.1946", "02/13/2024" },
        .{ "01-02-2024 10:30", "31/12/24" },
        .{ "1/2/2024 10:30 PM", "12/31/24" },
    };
    for (columns) |p| try out.append(arena, try seed(arena, &p));
    for (try pairSeeds(arena)) |p| try out.append(arena, p);
    return out.items;
}

/// A params string for cOptions: the switches byte, the base year, the
/// timezone offset and the locale bits; the rest of the record stays the
/// golden base time's.
fn cParams(arena: Allocator, switches: u8, year: i32, tz: i32, locales: u32) ![]const u8 {
    const out = try arena.alloc(u8, 13);
    out[0] = switches;
    std.mem.writeInt(i32, out[1..5], year, .little);
    std.mem.writeInt(i32, out[5..9], tz, .little);
    std.mem.writeInt(u32, out[9..13], locales, .little);
    return out;
}

/// Every single seed with the default options, then inputs against the
/// edges of the options the C API allows, and just past them.
fn cSeeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (singles) |s| try out.append(arena, try seed(arena, &.{s}));
    for (formats.examples) |ex| try out.append(arena, try seed(arena, &.{ex[1]}));
    const far = 999_999_999;
    const fr = 1 << 6;
    const edges = [_]struct { []const u8, u8, i32, i32, u32 }{
        .{ "in 999999 years", 0, far, 0, 0 },
        .{ "999999 years ago", 0, -far, 0, 0 },
        .{ "999999 months ago", 0, -far, 0, 0 },
        .{ "in 999999 weeks", 0, far, 0, 0 },
        .{ "next friday", 8, far, 0, 0 },
        .{ "last monday", 0, -far, 0, 0 },
        .{ "end of month", 0, far, 0, 0 },
        .{ "beginning of year", 0, -far, 0, 0 },
        .{ "December 23rd", 0, far, 0, 0 },
        .{ "10:30", 0, -far, 0, 0 },
        .{ "today", 0, far + 1, 0, 0 },
        .{ "today", 0, -far - 1, 0, 0 },
        .{ "2024-03-15 10:30:00", 0, 2024, 86_399, 0 },
        .{ "2024-03-15 10:30:00", 0, 2024, -86_400, 0 },
        .{ "15 mars 2024", 0, 2024, 0, fr },
        .{ "15 mars 2024", 0, 2024, 0, 1 << 20 },
        .{ "01/02/03", 16, 2024, 0, 0 },
        .{ "3 days ago", 1, 2024, 0, 0 },
    };
    for (edges) |e| try out.append(arena, try seed(arena, &.{ e[0], try cParams(arena, e[1], e[2], e[3], e[4]) }));
    return out.items;
}

/// The JSON pairs, then every pair as two strings.
fn jsonPairSeeds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (json_pairs) |p| try out.append(arena, try seed(arena, &p));
    for (pairs) |p| try out.append(arena, try seed(arena, &.{ try quote(arena, p[0]), try quote(arena, p[1]) }));
    return out.items;
}

test "fuzz: parseWith on any bytes answers a valid time its layout re-reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, parseOne, .{ .corpus = try singleSeeds(arena.allocator()) });
}

test "fuzz: a layout on another input refuses it or agrees with detection" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, reuseOne, .{ .corpus = try pairSeeds(arena.allocator()) });
}

test "fuzz: a primed Parser agrees with parseWith" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, parserOne, .{ .corpus = try pairSeeds(arena.allocator()) });
}

test "fuzz: the fast path agrees with the interpreter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, fastOne, .{ .corpus = try pairSeeds(arena.allocator()) });
}

test "fuzz: a JSON value FlexTime reads is valid and its RFC 3339 reads back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, jsonOne, .{ .corpus = try jsonSeeds(arena.allocator()) });
}

test "fuzz: FlexTime's std.json cache agrees with a cold one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, flexJsonOne, .{ .corpus = try jsonPairSeeds(arena.allocator()) });
}

test "fuzz: FlexTime's fromValue cache agrees with a cold one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, flexValueOne, .{ .corpus = try pairSeeds(arena.allocator()) });
}

test "fuzz: a column's order is the order its options read its values in" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, columnOne, .{ .corpus = try columnSeeds(arena.allocator()) });
}

test "fuzz: the C API refuses what it must and otherwise answers as parseWith" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.fuzz({}, cOne, .{ .corpus = try cSeeds(arena.allocator()) });
}

test seed {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var smith: Smith = .{ .in = try seed(arena.allocator(), &.{ "ab", "" }) };
    var buf: [max_input]u8 = undefined;
    try std.testing.expectEqualStrings("ab", input(&smith, &buf));
    try std.testing.expectEqualStrings("", input(&smith, &buf));
    try expectEqual(dp.Options{ .base_time = base }, options(&smith));
}

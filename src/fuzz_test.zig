//! Fuzz targets, after the Go dateparsa's fuzz_test.go. Under zig build test
//! each replays its seeds once; under tools/fuzz.sh the fuzzer mutates them.
//! Each holds a property, not only "does not crash":
//!
//! - parseWith on any bytes trips no safety check and answers a valid time;
//!   its layout re-reads the input it came from to that time, and the time
//!   written as RFC 3339 parses back to itself.
//! - A layout detected from one input either refuses another or agrees with
//!   detecting that input afresh: the property Parser depends on.
//! - A Parser primed with one input agrees with parseWith on the next.
//! - The fixed-slot fast path agrees with the interpreter.
//!
//! The seeds are the Go targets' seeds and committed crashers, every format's
//! example and every row of the golden corpus.

const std = @import("std");
const dp = @import("root.zig");
const formats = @import("formats.zig");
const golden = @import("golden_test.zig");

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

test seed {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var smith: Smith = .{ .in = try seed(arena.allocator(), &.{ "ab", "" }) };
    var buf: [max_input]u8 = undefined;
    try std.testing.expectEqualStrings("ab", input(&smith, &buf));
    try std.testing.expectEqualStrings("", input(&smith, &buf));
    try expectEqual(dp.Options{ .base_time = base }, options(&smith));
}

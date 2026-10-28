//! A date-time field for std.json, after the Go dateparsa's flextime: it
//! reads whatever a document holds for a time and writes RFC 3339.
//!
//!     const Event = struct { at: dateparsa.FlexTime };
//!     const e = try std.json.parseFromSliceLeaky(Event, arena, json, .{});
//!
//! A JSON string is read as parse reads it, with the default Options. A JSON
//! number is a Unix timestamp, and null is no time. Written out, a time is
//! an RFC 3339 string (DateTime.format) and no time is null.
//!
//! A number and a string of the same digits are read differently, and that
//! is deliberate. A number written as an integer takes its precision from
//! its digit count, as a string does (13 digits are milliseconds), but under
//! ten digits it is seconds, so 86400 is 1970-01-02: a typed number is not a
//! compact date. The string "86400" is refused, because a short run of
//! digits in a string could be anything and "2024" is a year. A number with
//! a fraction or an exponent is seconds, the only thing a fractional
//! timestamp can mean.
//!
//! std.json's error set is closed, so a refusal arrives as one of its
//! errors: error.UnexpectedToken for a string no format reads, or for a
//! bool, array or object, and error.InvalidNumber for a number that is no
//! timestamp. fromValue reads the same values outside std.json and says
//! which refusal it was.
//!
//! The std.json hooks keep the layout the last string they read was detected
//! with, as a Parser does, and fromValue keeps one of its own, so a document
//! or a column in one format detects once. A FlexTime is built by
//! std.json, not by the caller, so there is nowhere else to keep one. The
//! caches are per thread. What one value leaves there cannot change the time
//! the next one parses to: a layout that does not fit is detected afresh,
//! and an ambiguity-prone layout is never reused. It can change whether a
//! value parses, because a layout that fits accepts bytes detection would
//! refuse, as for any Parser. forgetLayouts clears this thread's.

const std = @import("std");
const root = @import("root.zig");
const epoch = @import("epoch.zig");

const DateTime = root.DateTime;
const Parser = root.Parser;
const ParseError = root.ParseError;

const FlexTime = @This();

/// The time, or null for none: a JSON null.
time: ?DateTime = null,
/// The time came from a guess: "01/02/2024" is the 2nd of January or the
/// 1st of February, and the preferences picked one. Never set for a number.
/// Refusing to guess needs Options.strict, which std.json cannot pass:
/// check this after parsing, or read strings with fromValueWith.
ambiguous: bool = false,

/// A typed value, as a database row or a decoded document holds one.
pub const Value = union(enum) {
    null,
    /// A Unix timestamp whose digit count is its precision; under ten
    /// digits it is seconds.
    integer: i64,
    /// Unix seconds, fraction included.
    float: f64,
    /// Read as parse reads it.
    string: []const u8,
};

threadlocal var json_parser: Parser = .init(.{});
threadlocal var value_parser: Parser = .init(.{});

/// v read with the default Options. A number that is no timestamp is
/// error.NoMatch.
pub fn fromValue(v: Value) ParseError!FlexTime {
    return read(&value_parser, v);
}

/// v read through p: its Options for a string, and its cache, which this
/// replaces as Parser.parse does. Options do not change how a number reads.
/// The configured path, and the one that can refuse a guess with
/// error.Ambiguous: `Parser.init(.{ .strict = true })`.
pub fn fromValueWith(p: *Parser, v: Value) ParseError!FlexTime {
    return read(p, v);
}

/// Forgets the layouts this thread's std.json hooks and fromValue cached,
/// so the next string each reads is detected afresh.
pub fn forgetLayouts() void {
    json_parser.reset();
    value_parser.reset();
}

fn read(p: *Parser, v: Value) ParseError!FlexTime {
    return switch (v) {
        .null => .{},
        .integer => |i| .{ .time = epoch.fromInt(i) orelse return error.NoMatch },
        .float => |f| .{ .time = epoch.fromSeconds(f) orelse return error.NoMatch },
        .string => |s| {
            const r = try p.parse(s);
            return .{ .time = r.time, .ambiguous = r.ambiguous };
        },
    };
}

/// A JSON number's text as the value it names. An integer too wide for an
/// i64 is read as a float, which refuses it on range.
fn number(text: []const u8) Value {
    if (std.json.isNumberFormattedLikeAnInteger(text)) {
        if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .integer = i } else |_| {}
    }
    return .{ .float = std.fmt.parseFloat(f64, text) catch std.math.nan(f64) };
}

/// std.json's hook: a string, a number or null.
pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!FlexTime {
    // A string with an escape in it, or one a reader splits across its
    // buffer, comes back allocated. Nothing here keeps it.
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    defer switch (token) {
        .allocated_number, .allocated_string => |slice| allocator.free(slice),
        else => {},
    };
    return switch (token) {
        .null => .{},
        inline .number, .allocated_number => |text| read(&json_parser, number(text)) catch
            return error.InvalidNumber,
        inline .string, .allocated_string => |s| read(&json_parser, .{ .string = s }) catch
            return error.UnexpectedToken,
        else => error.UnexpectedToken,
    };
}

/// std.json's hook for a document already parsed into a std.json.Value.
pub fn jsonParseFromValue(
    allocator: std.mem.Allocator,
    source: std.json.Value,
    options: std.json.ParseOptions,
) std.json.ParseFromValueError!FlexTime {
    _ = allocator;
    _ = options;
    const v: Value = switch (source) {
        .null => .null,
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |text| number(text),
        .string => |s| .{ .string = s },
        .bool, .array, .object => return error.UnexpectedToken,
    };
    return read(&json_parser, v) catch
        return if (v == .string) error.UnexpectedToken else error.InvalidNumber;
}

/// std.json's hook: an RFC 3339 string, or null for no time.
pub fn jsonStringify(ft: FlexTime, jws: anytype) !void {
    const t = ft.time orelse return jws.write(null);
    try jws.print("\"{f}\"", .{t});
}

const testing = std.testing;
const json = std.json;

fn parseJson(text: []const u8) !FlexTime {
    return json.parseFromSliceLeaky(FlexTime, testing.allocator, text, .{});
}

fn stringify(ft: FlexTime, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try json.Stringify.value(ft, .{}, &w);
    return w.buffered();
}

/// Go's time.Unix(sec, nsec).UTC().
fn unix(sec: i64, nsec: u32) DateTime {
    return DateTime.fromEpoch(.{ .seconds = sec, .nanosecond = nsec }, 0);
}

fn utc(year: i32, month: u8, day: u8, hour: u8, minute: u8) DateTime {
    return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute };
}

// Go's TestMarshalJSON.
test jsonStringify {
    var buf: [64]u8 = undefined;
    const Case = struct { FlexTime, []const u8 };
    var nanos = utc(2024, 3, 15, 10, 30);
    nanos.nanosecond = 123_456_789;
    for ([_]Case{
        .{ .{ .time = utc(2024, 3, 15, 10, 30) }, "\"2024-03-15T10:30:00Z\"" },
        .{ .{ .time = nanos }, "\"2024-03-15T10:30:00.123456789Z\"" },
        .{ .{}, "null" },
    }) |c| try testing.expectEqualStrings(c[1], try stringify(c[0], &buf));
}

// Go's TestUnmarshalJSON.
test jsonParse {
    const Case = struct { []const u8, ?DateTime };
    for ([_]Case{
        .{ "\"2024-03-15T10:30:00Z\"", utc(2024, 3, 15, 10, 30) },
        .{ "\"2024-03-15\"", utc(2024, 3, 15, 0, 0) },
        .{ "\"03/15/2024\"", utc(2024, 3, 15, 0, 0) },
        .{ "1710505800", unix(1710505800, 0) },
        .{ "1710505800.5", unix(1710505800, 500_000_000) },
        .{ "null", null },
    }) |c| {
        errdefer std.debug.print("input {s}\n", .{c[0]});
        const ft = try parseJson(c[0]);
        try testing.expectEqual(c[1], ft.time);
    }
    try testing.expectError(error.UnexpectedToken, parseJson("\"not a date\""));
    // The object opens before the scanner reaches the bad byte.
    try testing.expectError(error.UnexpectedToken, parseJson("{bad}"));
    try testing.expectError(error.UnexpectedEndOfInput, parseJson("\"2024-03-15"));
    try testing.expectError(error.UnexpectedToken, parseJson("true"));
    try testing.expectError(error.UnexpectedToken, parseJson("{}"));
    try testing.expectError(error.UnexpectedToken, parseJson("[]"));
}

// Go's TestJSONRoundTrip.
test "a record round-trips through JSON" {
    const Record = struct {
        created_at: FlexTime = .{},
        updated_at: FlexTime = .{},
        deleted_at: FlexTime = .{},
    };
    const original: Record = .{
        .created_at = .{ .time = utc(2024, 3, 15, 10, 30) },
        .updated_at = .{ .time = utc(2024, 3, 16, 12, 0) },
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.Stringify.value(original, .{}, &w);
    try testing.expectEqualStrings(
        \\{"created_at":"2024-03-15T10:30:00Z","updated_at":"2024-03-16T12:00:00Z","deleted_at":null}
    , w.buffered());

    const decoded = try json.parseFromSliceLeaky(Record, testing.allocator, w.buffered(), .{});
    try testing.expectEqual(original, decoded);
}

test "an offset and a fraction survive the round trip" {
    var t: DateTime = .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .offset_seconds = -7 * 3600 };
    t.nanosecond = 120_000_000;
    var buf: [64]u8 = undefined;
    const text = try stringify(.{ .time = t }, &buf);
    try testing.expectEqualStrings("\"2024-03-15T10:00:00.12-07:00\"", text);
    try testing.expectEqual(t, (try parseJson(text)).time);
}

// Go's TestUnmarshalJSONStringAllocates, which allows one allocation: Go
// copies the string out. std.json hands over a slice of the input.
test "a string with no escape allocates nothing" {
    const ft = try json.parseFromSliceLeaky(FlexTime, testing.failing_allocator, "\"2024-03-15T10:30:00Z\"", .{});
    try testing.expectEqual(utc(2024, 3, 15, 10, 30), ft.time);
}

test "an escaped string is read, and its copy freed" {
    // Z is Z, and \/ is /. testing.allocator fails the test on a leak.
    try testing.expectEqual(utc(2024, 3, 15, 10, 30), (try parseJson("\"2024-03-15T10:30:00\\u005a\"")).time);
    try testing.expectEqual(utc(2024, 3, 15, 0, 0), (try parseJson("\"03\\/15\\/2024\"")).time);
}

test "a string split across a reader's buffer is read" {
    var buf: [64]u8 = undefined;
    var in: testing.Reader = .init(&buf, &.{
        .{ .buffer = "\"2024-03-1" },
        .{ .buffer = "5T10:30:00Z\"" },
    });
    var reader: json.Reader = .init(testing.allocator, &in.interface);
    defer reader.deinit();
    const ft = try json.parseFromTokenSourceLeaky(FlexTime, testing.allocator, &reader, .{});
    try testing.expectEqual(utc(2024, 3, 15, 10, 30), ft.time);
}

// Go's TestUnmarshalJSONAcrossFormats: alternating formats through the one
// cache, every value but the first read against another format's layout.
test "values in alternating formats read as parse reads them" {
    const values = [_][]const u8{
        "\"2024-03-15T10:30:00Z\"", "\"03/15/2024\"",          "\"2024-03-15\"",
        "\"March 15, 2024\"",       "\"2024-03-15 10:30:00\"", "\"15 Mar 2024\"",
        "\"2024-03-15T10:30:00Z\"", "\"20240315\"",            "\"2024-03-15\"",
        "\"2024-03-15T10:30:00Z\"",
    };
    for (0..3) |_| for (values) |v| {
        errdefer std.debug.print("value {s}\n", .{v});
        const ft = try parseJson(v);
        const want = try root.parse(v[1 .. v.len - 1]);
        try testing.expectEqual(want.time, ft.time.?);
        try testing.expectEqual(want.ambiguous, ft.ambiguous);
    };
}

// Go's TestUnmarshalJSONAmbiguityThroughTheCache: a layout detected from an
// unambiguous value of the same shape must not make a guess look decided.
test "a guess stays a guess through a primed cache" {
    const primed = try parseJson("\"03/15/2024\"");
    try testing.expect(!primed.ambiguous); // 15 cannot be a month
    const ft = try parseJson("\"01/02/2024\"");
    try testing.expect(ft.ambiguous);
    try testing.expectEqual((try root.parse("01/02/2024")).time, ft.time.?);
}

// Go's TestUnmarshalJSONConcurrentFormats. The caches are per thread, so
// this checks that threads reading different formats each get their own.
test "threads reading different formats each get their answer" {
    const Case = struct { text: []const u8, want: DateTime };
    const cases = [_]Case{
        .{ .text = "\"2024-03-15T10:30:00Z\"", .want = utc(2024, 3, 15, 10, 30) },
        .{ .text = "\"03/15/2024\"", .want = utc(2024, 3, 15, 0, 0) },
        .{ .text = "\"2024-03-15\"", .want = utc(2024, 3, 15, 0, 0) },
        .{ .text = "\"March 15, 2024\"", .want = utc(2024, 3, 15, 0, 0) },
        .{ .text = "\"2024-03-15 10:30:00\"", .want = utc(2024, 3, 15, 10, 30) },
        .{ .text = "\"20240315\"", .want = utc(2024, 3, 15, 0, 0) },
    };
    const run = struct {
        fn run(c: Case, ok: *bool) void {
            for (0..500) |_| {
                const ft = json.parseFromSliceLeaky(FlexTime, testing.failing_allocator, c.text, .{}) catch return;
                if (!std.meta.eql(ft.time orelse return, c.want)) return;
            }
            ok.* = true;
        }
    }.run;
    var ok: [cases.len]bool = @splat(false);
    var threads: [cases.len]std.Thread = undefined;
    for (cases, &threads, &ok) |c, *t, *o| t.* = try std.Thread.spawn(.{}, run, .{ c, o });
    for (threads) |t| t.join();
    for (ok, cases) |o, c| {
        errdefer std.debug.print("value {s}\n", .{c.text});
        try testing.expect(o);
    }
}

// Go's TestNumericAgreesWithString: the same timestamp as a string, as a
// typed integer and as a JSON number names one instant. Under ten digits
// the string is refused and the typed forms are seconds.
test "a number and a string of its digits agree" {
    for ([_]i64{
        1710500000,           1710500000000,  1710500000000000, 1710500000000000000,
        -1710500000,          -1710500000000, 0,                86400,
        std.math.maxInt(i64),
    }) |v| {
        errdefer std.debug.print("value {d}\n", .{v});
        var buf: [24]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
        const via_int = (try fromValue(.{ .integer = v })).time.?;
        const via_json = (try parseJson(s)).time.?;
        try testing.expectEqual(via_int, via_json);
        const digits = s.len - @intFromBool(v < 0);
        if (digits < 10) {
            try testing.expectError(error.NoMatch, fromValue(.{ .string = s }));
        } else {
            try testing.expectEqual(via_int, (try fromValue(.{ .string = s })).time.?);
        }
    }
    try testing.expectEqual(unix(86400, 0), (try parseJson("86400")).time.?);
}

// Go's TestNumericRefusesWhatIsNotATimestamp.
test "a number that is no timestamp is refused" {
    for ([_][]const u8{
        "1e15",
        "1e18",
        "1e300",
        "-1e300",
        "1.7976931348623157e308",
        "100000000000000", // 15 digits, no precision
        "17105000000000", // 14 digits
        "-9223372036854775808", // one digit past what the positive side holds
        "99999999999999999999", // wider than an i64, so a float, out of range
    }) |text| {
        errdefer std.debug.print("number {s}\n", .{text});
        try testing.expectError(error.InvalidNumber, parseJson(text));
    }
    for ([_]i64{ std.math.minInt(i64), 100000000000000, 17105000000000, 171050000000000000 }) |i| {
        try testing.expectError(error.NoMatch, fromValue(.{ .integer = i }));
    }
    for ([_]f64{
        std.math.nan(f64),      std.math.inf(f64),       -std.math.inf(f64),
        std.math.floatMax(f64), -std.math.floatMax(f64), 1e15,
        -1e15,
    }) |f| {
        try testing.expectError(error.NoMatch, fromValue(.{ .float = f }));
    }
}

// Go's TestJSONFractionalIsSeconds.
test "a number with a fraction or an exponent is seconds" {
    const Case = struct { []const u8, DateTime };
    for ([_]Case{
        .{ "1710500000.5", unix(1710500000, 500_000_000) },
        .{ "1710500000.0", unix(1710500000, 0) },
        .{ "-1710500000.5", unix(-1710500001, 500_000_000) },
        .{ "1.7105e9", unix(1710500000, 0) },
        .{ "-0", unix(0, 0) },
    }) |c| {
        errdefer std.debug.print("number {s}\n", .{c[0]});
        try testing.expectEqual(c[1], (try parseJson(c[0])).time.?);
    }
}

// Go's TestScannerNumericMatchesFlexTime: a configured read of a number is
// the default one.
test "options do not change how a number reads" {
    var p: Parser = .init(.{ .prefer_day_first = true, .strict = true, .timezone_offset = 3600 });
    for ([_]i64{ 1710500000, 1710500000000, 1710500000000000, 0, std.math.maxInt(i64) }) |i| {
        try testing.expectEqual(try fromValue(.{ .integer = i }), try fromValueWith(&p, .{ .integer = i }));
    }
}

test fromValueWith {
    var strict: Parser = .init(.{ .strict = true });
    try testing.expectError(error.Ambiguous, fromValueWith(&strict, .{ .string = "01/02/2024" }));
    var day_first: Parser = .init(.{ .prefer_day_first = true });
    const ft = try fromValueWith(&day_first, .{ .string = "01/02/2024" });
    try testing.expectEqual(utc(2024, 2, 1, 0, 0), ft.time.?);
    try testing.expect(ft.ambiguous);
    // No base time, so a relative expression is refused, never read
    // against a clock; a Parser that carries one reads it.
    try testing.expectError(error.NoBaseTime, fromValue(.{ .string = "yesterday" }));
    var based: Parser = .init(.{ .base_time = utc(2024, 3, 15, 12, 0) });
    try testing.expectEqual(utc(2024, 3, 14, 0, 0), (try fromValueWith(&based, .{ .string = "yesterday" })).time.?);
}

test fromValue {
    try testing.expectEqual(FlexTime{}, try fromValue(.null));
    try testing.expectError(error.NoMatch, fromValue(.{ .string = "" }));
    try testing.expectError(error.NoMatch, fromValue(.{ .string = "not a date" }));
    try testing.expectEqual(unix(1710505800, 0), (try fromValue(.{ .string = "1710505800" })).time.?);
}

test jsonParseFromValue {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc =
        \\[ "2024-03-15T10:30:00Z", 1710505800, 1710505800.5, null,
        \\  99999999999999999999, "not a date", true ]
    ;
    const v = try json.parseFromSliceLeaky(json.Value, a, doc, .{});
    const items = v.array.items;
    try testing.expectEqual(utc(2024, 3, 15, 10, 30), (try json.parseFromValueLeaky(FlexTime, a, items[0], .{})).time.?);
    try testing.expectEqual(unix(1710505800, 0), (try json.parseFromValueLeaky(FlexTime, a, items[1], .{})).time.?);
    try testing.expectEqual(unix(1710505800, 500_000_000), (try json.parseFromValueLeaky(FlexTime, a, items[2], .{})).time.?);
    try testing.expectEqual(FlexTime{}, try json.parseFromValueLeaky(FlexTime, a, items[3], .{}));
    try testing.expectError(error.InvalidNumber, json.parseFromValueLeaky(FlexTime, a, items[4], .{}));
    try testing.expectError(error.UnexpectedToken, json.parseFromValueLeaky(FlexTime, a, items[5], .{}));
    try testing.expectError(error.UnexpectedToken, json.parseFromValueLeaky(FlexTime, a, items[6], .{}));

    // parse_numbers off leaves every number as its text.
    const raw = try json.parseFromSliceLeaky(json.Value, a, "[1710505800, 1.7105e9]", .{ .parse_numbers = false });
    try testing.expectEqual(unix(1710505800, 0), (try json.parseFromValueLeaky(FlexTime, a, raw.array.items[0], .{})).time.?);
    try testing.expectEqual(unix(1710500000, 0), (try json.parseFromValueLeaky(FlexTime, a, raw.array.items[1], .{})).time.?);
}

test forgetLayouts {
    _ = try parseJson("\"2024-03-15\"");
    try testing.expect(json_parser.cache != null);
    forgetLayouts();
    try testing.expect(json_parser.cache == null);
}

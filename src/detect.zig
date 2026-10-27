//! Format detection: which format an input is written in, as the list of
//! fields a program compiles from.
//!
//! A cascade, first answer wins: the ISO week and ordinal shapes, CJK
//! dates, the signature trie, then fallback detectors for shapes the trie
//! cannot hold (a fraction of any width, Go's time.String(), a date with an
//! offset and no time). Nothing here allocates: a Def holds its fields
//! inline, and every trie entry's Def is built at comptime.

const std = @import("std");
const compile = @import("compile.zig");
const formats = @import("formats.zig");
const signature = @import("signature.zig");
const trie = @import("trie.zig");

const Field = compile.Field;
const FieldKind = compile.FieldKind;
const isDigit = std.ascii.isDigit;

/// A detected format: its name and its fields, in input order.
pub const Def = struct {
    name: []const u8,
    buf: [compile.max_instructions]Field = undefined,
    len: u8 = 0,

    /// Asserts list fits.
    pub fn init(name: []const u8, list: []const Field) Def {
        var d: Def = .{ .name = name };
        for (list) |f| d.append(f) catch unreachable;
        return d;
    }

    pub fn fields(d: *const Def) []const Field {
        return d.buf[0..d.len];
    }

    /// A format past max_instructions is one compile refuses, so a detector
    /// that runs out of room refuses the input.
    pub fn append(d: *Def, f: Field) error{TooManyFields}!void {
        if (d.len == d.buf.len) return error.TooManyFields;
        d.buf[d.len] = f;
        d.len += 1;
    }
};

/// The question an ambiguous input left open. The kinds take different
/// answers: a field-order question is answered by reading the same digits
/// as the other field, a day-or-year one by reading one field as the other
/// kind, and treating every ambiguity as the first kind handed strict mode
/// two copies of one reading.
pub const Ambiguity = enum {
    none,
    /// "01/02/2024": two parts that are each a valid month and a valid day.
    field_order,
    /// "March 15": a bare number beside a month name, the 15th or 2015.
    day_or_year,
    /// "01/02/03" read year-first: one reading of three.
    year_position,
};

pub const Result = struct {
    def: Def,
    /// Which guess this input needed, if any.
    ambiguity: Ambiguity = .none,
    /// Whether the format can need a guess, whether or not this input did:
    /// "25/12/2024" needed none, but "01/02/2024" has its shape. A layout
    /// cannot answer ambiguity for the next row, only say it can arise.
    prone: bool = false,

    pub fn ambiguous(r: *const Result) bool {
        return r.ambiguity != .none;
    }
};

pub const Config = struct {
    prefer_day_first: bool = false,
    prefer_year_first: bool = false,
};

/// The Def each trie entry hands back, literals stamped with their class.
const prebuilt = blk: {
    @setEvalBranchQuota(10_000);
    var defs: [formats.table.len]Def = undefined;
    for (formats.table, 0..) |e, i| defs[i] = Def.init(e.name, &formats.stampedFields(e));
    break :blk defs;
};

/// The format s is written in, or null when no detector recognises it.
pub fn detect(s: []const u8, cfg: Config) ?Result {
    // Read by the ambiguity resolution and the textual detector, which are
    // not ported yet.
    _ = cfg;

    // Nothing longer can be described, and the fallbacks are linear in the
    // input: refusing here bounds the work as well as the answer.
    if (s.len > compile.max_describable_len) return null;

    if (detectIsoWeekOrOrdinal(s)) |r| return r;
    if (detectCjkDate(s)) |r| return r;

    const sig = signature.scan(s);
    const hit = trie.lookup(&sig);
    // Not yet ported, in cascade order: when the trie misses and the input
    // holds a letter (sig.has_letter or signature.hasLetterPastSignature),
    // the textual-month detector runs here, and every answer it gives is
    // refused when a skipped run holds a word that changes the date.
    const index = hit orelse {
        if (detectIso8601Frac(s)) |r| return r;
        // Not yet ported: variable-width numeric dates ("3/15/2024") here.
        if (detectGoTimeString(s)) |r| return r;
        if (detectDatePlusTz(s)) |r| return r;
        return null;
    };
    // Not yet ported: NUMERIC_SEP ("03/15/2024") is ambiguous by signature
    // and is resolved by value and preference.
    if (formats.table[index].ambiguous) return null;
    return .{ .def = prebuilt[index] };
}

fn field(kind: FieldKind, offset: u8, len: u8) Field {
    return .{ .kind = kind, .offset = offset, .len = len };
}

/// A literal holding the byte the detector checked, so the executor checks
/// it too: ISO_ORDINAL once described nothing for its '-', and a layout from
/// "0000-001" read "00000101" as day-of-year 101.
fn lit(s: []const u8, off: u8) Field {
    return .{ .kind = .literal, .offset = off, .len = 1, .aux = s[off] };
}

/// Covers s[off..off+len] with skips, one per piece compile.skipRun cuts
/// and none longer than a field can say.
fn appendSkip(
    d: *Def,
    s: []const u8,
    off: usize,
    len: usize,
) error{ TooManyFields, OutOfRange }!void {
    var at = off;
    const end = off + len;
    while (at < end) {
        const piece = compile.skipRun(s, at, @min(end, at + 255));
        if (piece.len == 0) return error.OutOfRange;
        try d.append(.{
            .kind = .skip,
            .offset = std.math.cast(u8, at) orelse return error.OutOfRange,
            .len = @intCast(piece.len),
            .aux = piece.aux,
        });
        at += piece.len;
    }
}

/// "2024-W11-5", "2024-W11" (Monday), and "2024-074".
fn detectIsoWeekOrOrdinal(s: []const u8) ?Result {
    const n = s.len;
    if (n >= 8 and s[4] == '-' and (s[5] == 'W' or s[5] == 'w')) {
        if (n == 8 and isDigit(s[6]) and isDigit(s[7])) {
            return .{ .def = .init("ISO_WEEK", &.{
                field(.year4, 0, 4), lit(s, 4), lit(s, 5), field(.iso_week, 6, 2),
            }) };
        }
        if (n == 10 and isDigit(s[6]) and isDigit(s[7]) and s[8] == '-' and isDigit(s[9])) {
            return .{ .def = .init("ISO_WEEK_DATE", &.{
                field(.year4, 0, 4),    lit(s, 4), lit(s, 5),
                field(.iso_week, 6, 2), lit(s, 8), field(.iso_week_day, 9, 1),
            }) };
        }
    }
    if (n == 8 and s[4] == '-' and isDigit(s[0]) and signature.allDigits(s[5..8])) {
        // Three digits where a month would be two: a day of the year.
        const v = @as(u16, s[5] - '0') * 100 + @as(u16, s[6] - '0') * 10 + (s[7] - '0');
        if (v >= 1 and v <= 366) {
            return .{ .def = .init("ISO_ORDINAL", &.{
                field(.year4, 0, 4), lit(s, 4), field(.ordinal_day, 5, 3),
            }) };
        }
    }
    return null;
}

/// "2014年04月08日": four year digits, then month and day of one or two.
fn detectCjkDate(s: []const u8) ?Result {
    const mark_len = "年".len;
    const y = std.mem.indexOf(u8, s, "年") orelse return null;
    const m = std.mem.indexOf(u8, s, "月") orelse return null;
    const d = std.mem.indexOf(u8, s, "日") orelse return null;
    if (y != 4 or y >= m or m >= d) return null;
    const month = s[y + mark_len .. m];
    const day = s[m + mark_len .. d];
    if (!signature.allDigits(s[0..4]) or !signature.allDigits(month) or !signature.allDigits(day))
        return null;
    const at = struct {
        fn f(i: usize) ?u8 {
            return std.math.cast(u8, i);
        }
    }.f;
    var def: Def = .{ .name = "CJK_DATE" };
    def.append(field(.year4, 0, 4)) catch unreachable;
    appendSkip(&def, s, y, mark_len) catch return null;
    def.append(field(
        .month1or2,
        at(y + mark_len) orelse return null,
        at(month.len) orelse return null,
    )) catch return null;
    appendSkip(&def, s, m, mark_len) catch return null;
    def.append(field(
        .day1or2,
        at(m + mark_len) orelse return null,
        at(day.len) orelse return null,
    )) catch return null;
    appendSkip(&def, s, d, mark_len) catch return null;
    return .{ .def = def };
}

/// The date and time every ISO-shaped fallback starts with:
/// YYYY-MM-DD, the separator at 10, HH:MM:SS.
fn appendIsoDateTime(def: *Def, s: []const u8) void {
    const head = [_]Field{
        field(.year4, 0, 4),    lit(s, 4),
        field(.month2, 5, 2),   lit(s, 7),
        field(.day2, 8, 2),     lit(s, 10),
        field(.hour24, 11, 2),  lit(s, 13),
        field(.minute2, 14, 2), lit(s, 16),
        field(.second2, 17, 2),
    };
    for (head) |f| def.append(f) catch unreachable;
}

/// ISO 8601 with a fraction of any width up to nine digits, and an optional
/// Z or numeric offset straight after it: "2024-03-15T10:30:00.1",
/// "2024-03-15 10:30:00.123456+05:30". The trie holds only three- and
/// six-digit fractions.
fn detectIso8601Frac(s: []const u8) ?Result {
    const n = s.len;
    if (n < 21) return null; // "YYYY-MM-DDTHH:MM:SS.f"; the zone is optional
    if (!(isDigit(s[0]) and s[4] == '-' and s[7] == '-' and (s[10] == 'T' or s[10] == ' ') and
        s[13] == ':' and s[16] == ':' and s[19] == '.')) return null;
    var frac_end: usize = 20;
    while (frac_end < n and isDigit(s[frac_end])) frac_end += 1;
    const frac_len = frac_end - 20;
    if (frac_len < 1 or frac_len > compile.max_frac_digits) return null;

    var def: Def = .{ .name = "ISO8601_FRAC" };
    appendIsoDateTime(&def, s);
    def.append(lit(s, 19)) catch unreachable;
    def.append(field(.frac_sec, 20, @intCast(frac_len))) catch unreachable;
    const pos = frac_end;
    if (pos < n) {
        const zone_at: u8 = @intCast(pos);
        if (s[pos] == 'Z' and pos + 1 == n) {
            def.append(field(.tz_z, zone_at, 1)) catch unreachable;
        } else if ((s[pos] == '+' or s[pos] == '-') and (n - pos == 5 or n - pos == 6)) {
            def.append(field(.tz_offset, zone_at, @intCast(n - pos))) catch unreachable;
        } else {
            // A space means a Go time.String() or a separated zone, which
            // detectGoTimeString reads; describing only the prefix here read
            // "...18:31:59.257000000 +0300 MSK" as UTC.
            return null;
        }
    }
    return .{ .def = def };
}

/// Go's time.Time.String(): "2015-02-08 03:02:00 +0300 MSK",
/// "2012-08-03 18:31:59.257000000 +0000 UTC m=+0.000000001". The zone name
/// and monotonic reading are a tail the program ignores but bounds.
fn detectGoTimeString(s: []const u8) ?Result {
    const n = s.len;
    if (n < 25) return null; // "YYYY-MM-DD HH:MM:SS +HHMM"
    if (!(isDigit(s[0]) and s[4] == '-' and s[7] == '-' and s[10] == ' ' and
        s[13] == ':' and s[16] == ':')) return null;

    var def: Def = .{ .name = "GO_TIME_STRING" };
    appendIsoDateTime(&def, s);
    var pos: usize = 19;
    if (s[pos] == '.') {
        var frac_end = pos + 1;
        while (frac_end < n and isDigit(s[frac_end])) frac_end += 1;
        const frac_len = frac_end - (pos + 1);
        if (frac_len > compile.max_frac_digits) return null;
        if (frac_len > 0) {
            def.append(lit(s, @intCast(pos))) catch unreachable;
            def.append(field(.frac_sec, @intCast(pos + 1), @intCast(frac_len))) catch unreachable;
            pos = frac_end;
        }
    }
    if (pos < n and s[pos] == ' ') {
        def.append(lit(s, @intCast(pos))) catch unreachable;
        pos += 1;
    }
    if (pos < n and (s[pos] == '+' or s[pos] == '-')) {
        const zone_at = pos;
        pos += 1;
        while (pos < n and (isDigit(s[pos]) or s[pos] == ':')) pos += 1;
        if (pos - zone_at - 1 >= 4) {
            def.append(field(
                .tz_offset,
                @intCast(zone_at),
                std.math.cast(u8, pos - zone_at) orelse return null,
            )) catch return null;
        }
    }
    if (pos < n) {
        // Refused here as in the executor, so detection and a reused layout
        // agree that a megabyte after the timestamp is not a date.
        if (!compile.validTail(s[pos..])) return null;
        def.append(.{
            .kind = .tail,
            .offset = std.math.cast(u8, pos) orelse return null,
            .len = 0,
        }) catch return null;
    }
    return .{ .def = def };
}

/// A date with an offset and no time: "2020-07-20+08:00".
fn detectDatePlusTz(s: []const u8) ?Result {
    const n = s.len;
    if (n != 15 and n != 16) return null;
    if (!(isDigit(s[0]) and s[4] == '-' and isDigit(s[5]) and s[7] == '-' and isDigit(s[8])))
        return null;
    if (s[10] != '+' and s[10] != '-') return null;
    return .{ .def = .init("ISO_DATE_TZ", &.{
        field(.year4, 0, 4),  lit(s, 4),
        field(.month2, 5, 2), lit(s, 7),
        field(.day2, 8, 2),   field(.tz_offset, 10, @intCast(n - 10)),
    }) };
}

const DateTime = @import("DateTime.zig");

test {
    std.testing.refAllDecls(@This());
}

test "every structured format's example detects as that format" {
    for (formats.table, formats.examples) |e, ex| {
        const r = detect(ex[1], .{}) orelse {
            // NUMERIC_SEP waits on ambiguity resolution.
            if (e.ambiguous) continue;
            std.debug.print("{s}: \"{s}\" not detected\n", .{ e.name, ex[1] });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(e.name, r.def.name);
        try std.testing.expect(!r.ambiguous());
    }
}

test "trie literals carry the class of the position they sit at" {
    var seen: usize = 0;
    for (formats.table, prebuilt) |e, def| {
        for (def.fields()) |f| {
            if (f.kind != .literal) continue;
            seen += 1;
            try std.testing.expectEqual(1, f.len);
            try std.testing.expectEqual(compile.auxFor(formats.litClassOf(e.sig[f.offset])), f.aux);
        }
    }
    // A stamping pass that silently matched nothing would pass the loop.
    try std.testing.expect(seen >= 100);
}

fn dt(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8, ns: u32, offset: i32) DateTime {
    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .nanosecond = ns,
        .offset_seconds = offset,
    };
}

/// detect, compile and execute, as parse will.
fn parseOnce(s: []const u8) !struct { name: []const u8, time: DateTime } {
    const r = detect(s, .{}) orelse return error.NotDetected;
    const fields = r.def.fields();
    const year: i32 = if (compile.needsBaseYear(fields)) 2026 else 0;
    const p = try compile.compile(fields, .{ .base_year = year });
    return .{ .name = r.def.name, .time = try p.execute(s) };
}

test "the fallback detectors, end to end" {
    const Case = struct { []const u8, []const u8, DateTime };
    const cases = [_]Case{
        .{ "2024-W11", "ISO_WEEK", dt(2024, 3, 11, 0, 0, 0, 0, 0) },
        .{ "2024-W11-5", "ISO_WEEK_DATE", dt(2024, 3, 15, 0, 0, 0, 0, 0) },
        .{ "2024-w11-5", "ISO_WEEK_DATE", dt(2024, 3, 15, 0, 0, 0, 0, 0) },
        .{ "2024-074", "ISO_ORDINAL", dt(2024, 3, 14, 0, 0, 0, 0, 0) },
        .{ "2014年04月08日", "CJK_DATE", dt(2014, 4, 8, 0, 0, 0, 0, 0) },
        .{ "2014年4月8日", "CJK_DATE", dt(2014, 4, 8, 0, 0, 0, 0, 0) },
        .{ "2024-03-15T10:30:00.1", "ISO8601_FRAC", dt(2024, 3, 15, 10, 30, 0, 100_000_000, 0) },
        .{ "2024-03-15 10:30:00.123456789Z", "ISO8601_FRAC", dt(2024, 3, 15, 10, 30, 0, 123_456_789, 0) },
        .{ "2024-03-15T10:30:00.12345+05:30", "ISO8601_FRAC", dt(2024, 3, 15, 10, 30, 0, 123_450_000, 19800) },
        .{ "2024-03-15T10:30:00.1234-0800", "ISO8601_FRAC", dt(2024, 3, 15, 10, 30, 0, 123_400_000, -28800) },
        .{ "2015-02-08 03:02:00 +0300 MSK", "GO_TIME_STRING", dt(2015, 2, 8, 3, 2, 0, 0, 10800) },
        .{
            "2012-08-03 18:31:59.257000000 +0000 UTC",
            "GO_TIME_STRING",
            dt(2012, 8, 3, 18, 31, 59, 257_000_000, 0),
        },
        .{
            "2024-03-15 10:30:00 +0000 UTC m=+0.000000001",
            "GO_TIME_STRING",
            dt(2024, 3, 15, 10, 30, 0, 0, 0),
        },
        .{ "2024-03-15 10:30:00.123 -07:00", "GO_TIME_STRING", dt(2024, 3, 15, 10, 30, 0, 123_000_000, -25200) },
        .{ "2020-07-20+08:00", "ISO_DATE_TZ", dt(2020, 7, 20, 0, 0, 0, 0, 28800) },
        .{ "2020-07-20-0330", "ISO_DATE_TZ", dt(2020, 7, 20, 0, 0, 0, 0, -12600) },
    };
    for (cases) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        const got = try parseOnce(c[0]);
        try std.testing.expectEqualStrings(c[1], got.name);
        try std.testing.expectEqual(c[2], got.time);
    }
}

test "the fallback detectors refuse what they cannot describe" {
    for ([_][]const u8{
        "2024-000", "2024-367", "2024-W1", "2024-W11-",
        "2024-03-15T10:30:00.1234567890Z", // a fraction past nanoseconds
        "2024-03-15T10:30:00.123+05", // no zone shape this detector knows
        "2024-03-15 10:30:00 +0000 UTC ; DROP TABLE users",
        "2024-03-15 10:30:00.99999999999999999999999 +0000 UTC",
        "14年04月08日",
        "20141年04月08日", // a fifth year digit
        "2014年04日08月",
        "2014年月08日",
    }) |s| {
        // Refused by detection itself, not left to the executor: the two
        // agree because each checks.
        if (detect(s, .{})) |r| {
            std.debug.print("\"{s}\" detected as {s}\n", .{ s, r.def.name });
            return error.TestUnexpectedResult;
        }
    }
    // Detected by shape; the executor refuses the offset.
    try std.testing.expectError(error.NoMatch, parseOnce("2020-07-20+8:00"));
}

test "detect refuses what no program can describe" {
    const long: [compile.max_describable_len + 1]u8 = @splat('1');
    try std.testing.expectEqual(null, detect(&long, .{}));
    const huge = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(huge);
    for (huge, 0..) |*c, i| c.* = "ab 12 "[i % 6];
    try std.testing.expectEqual(null, detect(huge, .{}));

    // Positions past a byte refuse rather than wrap.
    var cjk: [400]u8 = @splat('0');
    @memcpy(cjk[0..7], "2014年");
    @memcpy(cjk[390..393], "月");
    @memcpy(cjk[393..395], "08");
    @memcpy(cjk[395..398], "日");
    try std.testing.expectEqual(null, detect(cjk[0..398], .{}));
    var go: [300]u8 = @splat('0');
    @memcpy(go[0..21], "2024-03-15 10:30:00 +");
    try std.testing.expectEqual(null, detect(&go, .{}));
}

/// Go's fieldCorpus: what the field-list invariants below are swept over.
/// Inputs no detector here recognises yet are skipped, since refusing is
/// always allowed; they start counting as their detectors land.
const field_corpus = [_][]const u8{
    "2024-03-15",
    "2024/03/15",
    "2024.03.15",
    "2024-03-15T10:30:00Z",
    "2024-03-15T10:30:00+05:30",
    "2024-03-15T10:30:00.123456+05:30",
    "2024-03-15T10:30:00.123Z",
    "2024-03-15 10:30:00",
    "2024-03-15 10:30:00 UTC",
    "2024-03-15 10:30:00.123456",
    "2015-02-08 03:02:00 +0300 MSK",
    "2012-08-03 18:31:59.257000000 +0000 UTC",
    "2024-03-15 10:30:00 m=+0.000000001",
    "0000-001",
    "2024-074",
    "2024-W11-5",
    "2024-W11",
    "2014年04月08日",
    "2020-07-20+08:00",
    "20240315",
    "20240315T103000Z",
    "March 15, 2024",
    "September 17, 2012 at 10:09am",
    "15 Mar 2024",
    "December 23rd",
    "March 2024",
    "sept. 1, 2020",
    "Fri Jul 03 2015 18:04:07 GMT+0100",
    "Thu, 4 Jan 2018 17:53:36 +0000",
    "3/15/2024",
    "3/15/2024 10:30:00 AM",
    "3/15/2024 10:30:00",
    "15.03.2024",
    "01/02/2024",
    "10:30",
    "10:30:00",
    "10:30 PM",
    "10:30:00.123",
    "\x00MAY1",
    "1MAY10",
    "1 MAY",
    "MAY 1",
    "2024:03:15",
    "2014:04:08 22:05:13",
    "171113 14:14:20",
};

test "every detected format describes each byte once, in order, at its op's width" {
    var detected: usize = 0;
    for (field_corpus) |s| {
        const r = detect(s, .{}) orelse continue;
        detected += 1;
        errdefer std.debug.print("\"{s}\" [{s}]\n", .{ s, r.def.name });
        var count: [compile.max_describable_len]u8 = @splat(0);
        var prev: usize = 0;
        for (r.def.fields()) |f| {
            try std.testing.expect(f.offset >= prev); // the executor's delta assumes it
            prev = f.offset;
            if (compile.fixedWidth(f.kind)) |w| try std.testing.expectEqual(w, f.len);
            const w: usize = if (f.kind == .tail) s.len - f.offset else f.len;
            for (count[f.offset..][0..w]) |*c| c.* += 1;
            // A byte no field reads may not be a digit: a digit is a token.
            const unread = f.kind == .skip or (f.kind == .literal and f.aux == 0);
            if (unread) for (s[f.offset..][0..f.len]) |c| try std.testing.expect(!isDigit(c));
        }
        for (count[0..s.len]) |c| try std.testing.expectEqual(1, c);
    }
    try std.testing.expect(detected >= 25);
}

test "detect, compile and execute never trip a safety check" {
    // Each corpus input with every position overwritten by bytes that move
    // a detector's decision. Debug builds turn any overflow or out-of-bounds
    // index into a test failure; the answer itself is not checked here.
    const subs = "09 -:.+TZW\xe5\x00";
    var buf: [64]u8 = undefined;
    for (field_corpus) |s| {
        if (s.len > buf.len) continue;
        for (0..s.len) |i| {
            for (subs) |c| {
                @memcpy(buf[0..s.len], s);
                buf[i] = c;
                _ = parseOnce(buf[0..s.len]) catch {};
                _ = parseOnce(buf[0..i]) catch {};
            }
        }
    }
}

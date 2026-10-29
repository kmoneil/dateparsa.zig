//! The dates email (RFC 2822 and 5322) and HTTP (RFC 7231) write, read
//! without the textual detector's general search: "Fri, 15 Mar 2024
//! 10:30:00 +0000", "Sun, 06 Nov 1994 08:49:37 GMT".
//!
//! The textual detector found these in about 240 ns, the month-name search,
//! classification and gap covering it runs for any input with a month name
//! in it. For one of the shapes here its answer is always the same fields
//! but for the month, so each shape's fields are the detector's own,
//! taken at comptime from an example, and so is a compiled layout for each
//! month. match accepts only an input the detector would read that way: the
//! shape byte for byte (digits as digits, the zone's sign either way),
//! English weekday and month abbreviations, a year above 31, and a weekday
//! and zone that no other language read with it takes for a month or a
//! word that changes the date. Anything else is left to the detector. A
//! fuzz target holds match to it.

const std = @import("std");
const compile = @import("compile.zig");
const detect = @import("detect.zig");
const locale = @import("locale.zig");
const textual = @import("textual.zig");
const Layout = @import("Layout.zig");

const Field = compile.Field;

/// The shapes, as an example of each. In each, the weekday is "Fri", the
/// month "Mar", the year "2024" and a zone name "GMT"; a numeric zone may
/// take either sign.
const examples = [_][]const u8{
    "Fri, 15 Mar 2024 10:30:00 +0000",
    "Fri, 5 Mar 2024 10:30:00 +0000",
    "15 Mar 2024 10:30:00 +0000",
    "5 Mar 2024 10:30:00 +0000",
    "Fri, 15 Mar 2024 10:30 +0000",
    "Fri, 15 Mar 2024 10:30:00 GMT",
    "Fri, 5 Mar 2024 10:30:00 GMT",
};

const Shape = struct {
    example: []const u8,
    /// Per byte: 'd' any digit, 'w' the weekday's, 'm' the month's, 'z' the
    /// zone name's letters, 's' a zone sign, else that byte itself.
    pattern: []const u8,
    month_at: usize,
    year_at: usize,
    weekday: bool,
    zone_at: ?usize,
    /// The detector's fields for the example, whose month field is at
    /// month_field.
    def: detect.Def,
    month_field: usize,
};

const shapes: [examples.len]Shape = blk: {
    @setEvalBranchQuota(2_000_000);
    var out: [examples.len]Shape = undefined;
    for (examples, &out) |ex, *sh| {
        const month_at = std.mem.indexOf(u8, ex, "Mar").?;
        const year_at = std.mem.indexOf(u8, ex, "2024").?;
        const zone_at = std.mem.indexOf(u8, ex, "GMT");
        var pattern: [ex.len]u8 = ex[0..ex.len].*;
        for (&pattern, 0..) |*p, i| {
            if (std.ascii.isDigit(ex[i])) p.* = 'd';
        }
        if (std.mem.startsWith(u8, ex, "Fri")) @memcpy(pattern[0..3], "www");
        @memcpy(pattern[month_at..][0..3], "mmm");
        if (zone_at) |z| @memcpy(pattern[z..][0..3], "zzz");
        if (std.mem.indexOfScalar(u8, ex, '+')) |plus| pattern[plus] = 's';
        // What detect answers for the example: the trie misses it, so it is
        // the textual detector's, which no skipped word overrules.
        const r = textual.detectTextual(ex, .{}).?;
        if (r.ambiguity != .none or r.prone or textual.skipRunCarriesMeaning(ex, r.def.fields(), .{}))
            @compileError("not a plain textual shape: " ++ ex);
        const final = pattern;
        sh.* = .{
            .example = ex,
            .pattern = &final,
            .month_at = month_at,
            .year_at = year_at,
            .weekday = std.mem.startsWith(u8, ex, "Fri"),
            .zone_at = zone_at,
            .def = r.def,
            .month_field = for (r.def.fields(), 0..) |f, i| {
                if (f.kind == .month_name) break i;
            } else @compileError("no month field: " ++ ex),
        };
    }
    break :blk out;
};

/// A shape and the month (1 to 12) an input of it names.
pub const Match = struct { shape: u8, month: u8 };

/// The shape s has, with the month it names, when the textual detector
/// would read s with that shape's fields; else null.
pub fn match(s: []const u8, locales: locale.LocaleSet) ?Match {
    for (&shapes, 0..) |*sh, i| {
        if (s.len != sh.pattern.len or !fits(s, sh.pattern)) continue;
        // Another language may spell a month, or a word that moves the
        // date, the way the weekday or zone is written: then the detector
        // would find a rival month or a skipped word that decides.
        const set: Backing = @bitCast(locales);
        if (sh.weekday) {
            const w = wordIndex(s[0..3], &weekdays, true) orelse return null;
            if (taken[w] & set != 0) return null;
        }
        if (sh.zone_at) |z| {
            const w = wordIndex(s[z..][0..3], &zones, false) orelse return null;
            if (taken[weekdays.len + w] & set != 0) return null;
        }
        // A year of 31 or less would read as the day, and the day as the year.
        const y = s[sh.year_at..][0..4];
        const year = @as(u16, y[0] - '0') * 1000 + @as(u16, y[1] - '0') * 100 + @as(u16, y[2] - '0') * 10 + (y[3] - '0');
        if (year <= 31) return null;
        const month = monthOf(s[sh.month_at..][0..3]) orelse return null;
        return .{ .shape = @intCast(i), .month = month };
    }
    return null;
}

fn fits(s: []const u8, pattern: []const u8) bool {
    for (s, pattern) |c, p| {
        const ok = switch (p) {
            'd' => std.ascii.isDigit(c),
            'w', 'm', 'z' => std.ascii.isAlphabetic(c),
            's' => c == '+' or c == '-',
            else => c == p,
        };
        if (!ok) return false;
    }
    return true;
}

/// The English weekdays' three letters, read in any case: never an English
/// month name or a word that changes which day a date is.
const weekdays = [_]*const [3]u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
/// The zone names a shape takes, as written: case matters to a zone.
const zones = [_]*const [3]u8{ "GMT", "UTC" };

/// Where w is among names, in any case when fold.
fn wordIndex(w: *const [3]u8, names: []const *const [3]u8, fold: bool) ?usize {
    for (names, 0..) |n, i| {
        if (if (fold) std.ascii.eqlIgnoreCase(w, n) else std.mem.eql(u8, w, n)) return i;
    }
    return null;
}

const Backing = @typeInfo(locale.LocaleSet).@"struct".backing_integer.?;

/// For each weekday, then each zone name, the compiled locales that read it
/// as a month name or a word that moves the date: none in today's tables.
/// Worked out at comptime, one locale at a time, since a set of locales
/// reads a word that way when one of them does.
const taken: [weekdays.len + zones.len]Backing = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: [weekdays.len + zones.len]Backing = @splat(0);
    for (weekdays ++ zones, &out) |w, *o| {
        for (0..locale.compiled.len) |li| {
            const one = locale.only(li);
            if (textual.findMonthName(w, one) != null or textual.wordCarriesMeaning(w, one))
                o.* |= @as(Backing, @bitCast(one));
        }
    }
    break :blk out;
};

/// The month an English three-letter abbreviation names, in any case.
fn monthOf(w: *const [3]u8) ?u8 {
    const names = [_]*const [3]u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    for (names, 1..) |n, m| if (std.ascii.eqlIgnoreCase(w, n)) return @intCast(m);
    return null;
}

/// The detector's Result for an input m matched.
pub fn result(m: Match) detect.Result {
    const sh = &shapes[m.shape];
    var def = sh.def;
    def.buf[sh.month_field].aux = m.month;
    return .{ .def = def };
}

/// The compiled layout for m, as Layout.fromDetection makes it under the
/// default options.
pub fn layout(m: Match) *const Layout {
    return &layouts[m.shape][m.month - 1];
}

const layouts: [examples.len][12]Layout = blk: {
    @setEvalBranchQuota(2_000_000);
    var out: [examples.len][12]Layout = undefined;
    for (0..examples.len) |i| for (0..12) |mi| {
        const r = result(.{ .shape = i, .month = mi + 1 });
        out[i][mi] = Layout.fromDetection(&r, .{}) catch unreachable;
    };
    break :blk out;
};

test {
    std.testing.refAllDecls(@This());
}

test "each shape's example matches it, and reads as the detector reads it" {
    for (&shapes, 0..) |*sh, i| {
        const m = match(sh.example, .{}).?;
        try std.testing.expectEqual(i, m.shape);
        try std.testing.expectEqual(3, m.month);
    }
}

test "what match refuses" {
    const refused = [_][]const u8{
        "Fri+ 15 Mar 2024 10:30:00 +0000", // a byte the shape does not have
        "Fri, 15 Mar 2024\t10:30:00 +0000",
        "Foo, 15 Mar 2024 10:30:00 +0000", // no weekday
        "Mar, 15 Mar 2024 10:30:00 +0000",
        "Fri, 15 Xyz 2024 10:30:00 +0000", // no month
        "Fri, 15 Mar 0031 10:30:00 +0000", // a year that reads as a day
        "Fri, 15 Mar 2024 10:30:00 EST", // a zone name not GMT or UTC
        "Fri, 15 Mar 2024 10:30:00 *0000",
        "Fri, 15 Mar 2024 10:30:00 +000",
    };
    for (refused) |s| try std.testing.expectEqual(null, match(s, .{}));
    // No language this library reads takes an English weekday, GMT or UTC
    // for a month or a word that moves the date, so the shapes match under
    // every one; the check is for locale data that one day does.
    const fr = locale.only(locale.lookup("fr") orelse return error.SkipZigTest);
    try std.testing.expect(match("Fri, 15 Mar 2024 10:30:00 +0000", fr) != null);
    try std.testing.expect(match("fri, 15 mar 2024 10:30:00 -0500", .{}) != null);
    try std.testing.expect(match("Sun, 06 Nov 1994 08:49:37 UTC", .{}) != null);
}

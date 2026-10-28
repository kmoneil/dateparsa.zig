//! A layout's format spelled as another tool's format string: strftime (C,
//! Python, pandas, Ruby), Go's reference time, or Java's DateTimeFormatter
//! (Java, Kotlin, Spark). Detect once, then hand the format to whatever
//! reads the column next.
//!
//! A layout keeps no input bytes: a separator or a skipped word is held as a
//! byte class ("2024-03-15" and "2024/03/15" share one layout). So the text
//! between fields is read from the value the layout was detected from, and
//! the format string spells that value's separators.
//!
//! A field a dialect cannot spell is error.Unsupported, never a string that
//! reads something else: an ordinal suffix ("23rd") in any dialect, an ISO
//! week date outside strftime, Go text that Go would read as a field, a
//! fraction past microseconds or a zone name other than UTC or GMT in
//! strftime (Python reads no others).

const std = @import("std");
const compile = @import("compile.zig");
const locale = @import("locale.zig");
const signature = @import("signature.zig");
const Layout = @import("Layout.zig");

pub const Dialect = enum {
    /// strftime and strptime directives: C, Python, pandas, Ruby, Rust's
    /// chrono. "%Y-%m-%d %H:%M:%S".
    strftime,
    /// Go's reference time, Mon Jan 2 15:04:05 MST 2006: "2006-01-02 15:04:05".
    go,
    /// Java's DateTimeFormatter, also Kotlin and Spark: "yyyy-MM-dd HH:mm:ss".
    java,
};

pub const Error = error{
    /// The dialect has no way to spell one of the format's fields.
    Unsupported,
    /// The value is not one this layout reads at the widths it was
    /// detected at: pass the value the layout came from.
    NotDetectedFrom,
} || std.Io.Writer.Error;

/// The format l reads, spelled in dialect, into w. detected_from is the
/// value l was detected from; its separators and words are the ones
/// written.
pub fn write(l: *const Layout, dialect: Dialect, detected_from: []const u8, w: *std.Io.Writer) Error!void {
    if (l.source != .program) return error.Unsupported;
    const s = if (l.trims_padding) signature.trimPadding(detected_from) else detected_from;
    _ = l.parse(s) catch return error.NotDetectedFrom;

    const insts = l.program.insts[0..l.program.n];
    var twelve_hour = false;
    var week_date = false;
    for (insts) |inst| switch (inst.op) {
        .ampm => twelve_hour = true,
        .iso_week => week_date = true,
        else => {},
    };

    var end: usize = 0;
    for (insts, 0..) |inst, i| {
        const off: usize = inst.offset;
        if (off != end) return error.NotDetectedFrom;
        var width: usize = inst.len;
        // A zone that may be 'Z' or an offset is one byte when it is 'Z'.
        if (inst.op == .tz_z_or_offset and off < s.len and s[off] == 'Z') width = 1;
        if (off + width > s.len) return error.NotDetectedFrom;
        const text = s[off..][0..width];
        switch (inst.op) {
            .literal, .skip => {
                // Text glued to a number's digits is a unit, never a
                // weekday: 年, 月 and 日 in "2014年04月08日" (月 and 日 are
                // also Japanese weekday names), or an ordinal suffix, which
                // no dialect spells.
                const glued = i > 0 and isNumber(insts[i - 1].op) and insts[i - 1].aux == compile.sep_none;
                if (glued and text[0] < 0x80 and std.ascii.isAlphabetic(text[0])) return error.Unsupported;
                if (inst.op == .skip and !glued) try skipped(w, dialect, text) else try literal(w, dialect, text);
            },
            .month_name => try token(w, dialect, switch (monthName(text)) {
                .wide => .{ "%B", "January", "MMMM" },
                .abbr => .{ "%b", "Jan", "MMM" },
                .wide_foreign => .{ "%B", null, "MMMM" },
                .abbr_foreign => .{ "%b", null, "MMM" },
            }),
            .year4 => try token(w, dialect, .{ if (week_date) "%G" else "%Y", "2006", "yyyy" }),
            .year2 => try token(w, dialect, .{ "%y", "06", "yy" }),
            .month2 => try token(w, dialect, .{ "%m", "01", "MM" }),
            .month1or2 => try token(w, dialect, .{ "%m", "1", "M" }),
            .day2 => try token(w, dialect, .{ "%d", "02", "dd" }),
            .day1or2 => try token(w, dialect, .{ "%d", "2", "d" }),
            .day_space_pad => try token(w, dialect, .{ "%e", "_2", "ppd" }),
            .hour24 => try token(w, dialect, .{ "%H", "15", "HH" }),
            .hour12 => try token(w, dialect, .{ "%I", "03", "hh" }),
            .hour1or2 => try token(w, dialect, if (twelve_hour) .{ "%I", "3", "h" } else .{ "%H", "15", "H" }),
            .minute2 => try token(w, dialect, .{ "%M", "04", "mm" }),
            .second2 => try token(w, dialect, .{ "%S", "05", "ss" }),
            .frac_sec => switch (dialect) {
                .strftime => if (width <= 6) try w.writeAll("%f") else return error.Unsupported,
                .go => try w.splatByteAll('0', width),
                .java => try w.splatByteAll('S', width),
            },
            .ampm => try token(w, dialect, .{ "%p", "PM", "a" }),
            // A field rather than the letter, so the tool knows it is UTC:
            // each reads 'Z' as offset zero.
            .tz_z => try token(w, dialect, .{ "%z", "Z07:00", "X" }),
            .tz_offset => try token(w, dialect, switch (width) {
                6 => .{ "%z", "-07:00", "xxx" },
                5 => .{ "%z", "-0700", "xx" },
                3 => .{ null, "-07", "x" },
                else => return error.Unsupported,
            }),
            .tz_z_or_offset => {
                // The value wrote 'Z' or an offset; the format takes either.
                try token(w, dialect, switch (inst.len) {
                    6 => .{ "%z", "Z07:00", "XXX" },
                    5 => .{ "%z", "Z0700", "XX" },
                    3 => .{ null, "Z07", "X" },
                    else => return error.Unsupported,
                });
            },
            .tz_name => {
                const utc = std.mem.eql(u8, text, "UTC") or std.mem.eql(u8, text, "GMT");
                try token(w, dialect, .{ if (utc) "%Z" else null, "MST", "z" });
            },
            .iso_week => try token(w, dialect, .{ "%V", null, null }),
            .iso_week_day => try token(w, dialect, .{ "%u", null, null }),
            .ordinal_day => try token(w, dialect, .{ "%j", "002", "DDD" }),
            .tail, .nop => return error.Unsupported,
        }
        end = off + width;
        // A separator fused into a numeric field's instruction.
        if (inst.aux != compile.sep_none and fuses(inst.op)) {
            if (end >= s.len) return error.NotDetectedFrom;
            try literal(w, dialect, s[end..][0..1]);
            end += 1;
        }
    }
    if (end != s.len) return error.NotDetectedFrom;
}

/// A skipped run. A weekday name is a field, with any punctuation after it
/// as text. GMT or UTC, and text in no Latin letters (the 年, 月 and 日 of
/// "2014年04月08日"), are text, since they do not vary. Any other word is
/// refused: the layout accepts any word of that width there, and a format
/// string holding this one would refuse every row with another.
fn skipped(w: *std.Io.Writer, dialect: Dialect, text: []const u8) Error!void {
    var word_end: usize = 0;
    while (word_end < text.len and (std.ascii.isAlphabetic(text[word_end]) or text[word_end] >= 0x80)) word_end += 1;
    const word = text[0..word_end];
    const rest = text[word_end..];
    if (word.len > 0) {
        if (weekday(word)) |wd| {
            for (rest) |c| if (std.ascii.isAlphabetic(c) or c >= 0x80) return error.Unsupported;
            try token(w, dialect, switch (wd) {
                .wide => .{ "%A", "Monday", "EEEE" },
                .abbr => .{ "%a", "Mon", "EEE" },
                .wide_foreign => .{ "%A", null, "EEEE" },
                .abbr_foreign => .{ "%a", null, "EEE" },
            });
            return literal(w, dialect, rest);
        }
    }
    const constant = std.mem.eql(u8, word, "GMT") or std.mem.eql(u8, word, "UTC");
    if (!constant) for (text) |c| if (std.ascii.isAlphabetic(c)) return error.Unsupported;
    try literal(w, dialect, text);
}

fn fuses(op: compile.Op) bool {
    return switch (op) {
        .year4, .year2, .month2, .day2, .hour24, .hour12, .minute2, .second2, .iso_week, .day_space_pad => true,
        else => false,
    };
}

fn isNumber(op: compile.Op) bool {
    return switch (op) {
        .year4, .year2, .month2, .month1or2, .day2, .day1or2, .hour24, .hour12, .hour1or2, .minute2, .second2 => true,
        else => false,
    };
}

/// A field in each dialect, null where the dialect cannot spell it.
fn token(w: *std.Io.Writer, dialect: Dialect, t: [3]?[]const u8) Error!void {
    const spelled = switch (dialect) {
        .strftime => t[0],
        .go => t[1],
        .java => t[2],
    } orelse return error.Unsupported;
    try w.writeAll(spelled);
}

/// Text between fields, as each dialect takes it literally.
fn literal(w: *std.Io.Writer, dialect: Dialect, text: []const u8) Error!void {
    switch (dialect) {
        .strftime => for (text) |c| {
            if (c == '%') try w.writeAll("%%") else try w.writeByte(c);
        },
        .go => {
            // Go has no escape: text it would read as a field is refused.
            for (text) |c| if (std.ascii.isDigit(c)) return error.Unsupported;
            for ([_][]const u8{ "Jan", "Mon", "MST", "PM", "pm", "_" }) |t| {
                if (std.mem.indexOf(u8, text, t) != null) return error.Unsupported;
            }
            try w.writeAll(text);
        },
        .java => {
            const quote = for (text) |c| {
                if (std.ascii.isAlphabetic(c) or std.mem.indexOfScalar(u8, "'[]{}#", c) != null) break true;
            } else false;
            if (!quote) return w.writeAll(text);
            try w.writeByte('\'');
            for (text) |c| {
                if (c == '\'') try w.writeAll("''") else try w.writeByte(c);
            }
            try w.writeByte('\'');
        },
    }
}

const NameKind = enum { wide, abbr, wide_foreign, abbr_foreign };

fn english() *const locale.Data {
    return locale.compiled[locale.lookup("en").?];
}

/// Whether text is a month name wide or abbreviated, and whether English
/// (Go spells English names only).
fn monthName(text: []const u8) NameKind {
    const bare = std.mem.trimEnd(u8, text, ".");
    for (english().months_wide) |n| if (std.ascii.eqlIgnoreCase(n, bare)) return .wide;
    for (english().months_abbr) |n| if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, n, "."), bare)) return .abbr;
    for (locale.compiled) |d| for (d.months_wide) |n| {
        if (std.ascii.eqlIgnoreCase(n, text)) return .wide_foreign;
    };
    return .abbr_foreign;
}

/// Whether text is a weekday name, wide or abbreviated, in any compiled
/// locale; null for any other word.
fn weekday(text: []const u8) ?NameKind {
    const bare = std.mem.trimEnd(u8, text, ".");
    for (english().weekdays_wide) |n| if (std.ascii.eqlIgnoreCase(n, bare)) return .wide;
    for (english().weekdays_abbr) |n| if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, n, "."), bare)) return .abbr;
    for (locale.compiled) |d| {
        for (d.weekdays_wide) |n| if (std.ascii.eqlIgnoreCase(n, bare)) return .wide_foreign;
        for (d.weekdays_abbr) |n| if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, n, "."), bare)) return .abbr_foreign;
    }
    return null;
}

fn expectFormat(input: []const u8, want: [3]?[]const u8) !void {
    const root = @import("root.zig");
    errdefer std.debug.print("\"{s}\"\n", .{input});
    const r = try root.parseWith(input, .{ .base_time = .{ .year = 2024, .month = 1, .day = 1 } });
    for ([_]Dialect{ .strftime, .go, .java }, want) |d, expected| {
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        if (expected) |e| {
            try write(&r.layout, d, input, &w);
            try std.testing.expectEqualStrings(e, w.buffered());
        } else try std.testing.expectError(error.Unsupported, write(&r.layout, d, input, &w));
    }
}

test "format strings, each checked by tools/format_check.sh in Python, Go and Java" {
    try expectFormat("2024-03-15", .{ "%Y-%m-%d", "2006-01-02", "yyyy-MM-dd" });
    try expectFormat("2024/03/15", .{ "%Y/%m/%d", "2006/01/02", "yyyy/MM/dd" });
    try expectFormat("2024-03-15T10:30:00Z", .{ "%Y-%m-%dT%H:%M:%S%z", "2006-01-02T15:04:05Z07:00", "yyyy-MM-dd'T'HH:mm:ssX" });
    try expectFormat("2024-03-15T10:30:00.123+05:30", .{ "%Y-%m-%dT%H:%M:%S.%f%z", "2006-01-02T15:04:05.000-07:00", "yyyy-MM-dd'T'HH:mm:ss.SSSxxx" });
    try expectFormat("13/02/2024 10:30", .{ "%d/%m/%Y %H:%M", "02/01/2006 15:04", "dd/MM/yyyy HH:mm" });
    try expectFormat("3/15/2024 10:30 PM", .{ "%m/%d/%Y %I:%M %p", "1/02/2006 03:04 PM", "M/dd/yyyy hh:mm a" });
    try expectFormat("Fri, 15 Mar 2024 10:30:00 +0000", .{ "%a, %d %b %Y %H:%M:%S %z", "Mon, 02 Jan 2006 15:04:05 -0700", "EEE, dd MMM yyyy HH:mm:ss xx" });
    try expectFormat("Mon Jan 2 15:04:05 2006", .{ "%a %b %d %H:%M:%S %Y", "Mon Jan 2 15:04:05 2006", "EEE MMM d HH:mm:ss yyyy" });
    try expectFormat("March 15, 2024", .{ "%B %d, %Y", "January 02, 2006", "MMMM dd, yyyy" });
    try expectFormat("2014-12-16 06:20:00 UTC", .{ "%Y-%m-%d %H:%M:%S %Z", "2006-01-02 15:04:05 MST", "yyyy-MM-dd HH:mm:ss z" });
    try expectFormat("2014年04月08日", .{ "%Y年%m月%d日", "2006年1月2日", "yyyy年M月d日" });
    try expectFormat("2024-W11-5", .{ "%G-W%V-%u", null, null });
    try expectFormat("2024-074", .{ "%Y-%j", "2006-002", "yyyy-DDD" });
    try expectFormat("2024-03-15 10:30:00+00", .{ null, "2006-01-02 15:04:05-07", "yyyy-MM-dd HH:mm:ssx" });
    try expectFormat("2024-03-15T10:30:00.123456789Z", .{ null, "2006-01-02T15:04:05.000000000Z07:00", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSX" });
    try expectFormat("10:30", .{ "%H:%M", "15:04", "HH:mm" });
}

test "what no dialect spells is refused, not misspelled" {
    // Ordinal suffixes; a zone name after an offset, which the layout
    // ignores; a timestamp and natural language, which have no format.
    for ([_][]const u8{ "December 23rd", "the 15th of March 2024", "2015-02-08 03:02:00 +0300 MSK", "1710504800", "3 days ago" }) |s| {
        try expectFormat(s, .{ null, null, null });
    }
}

test "the value must be the one the layout came from" {
    const root = @import("root.zig");
    const r = try root.parse("1/2/2024");
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Read by the layout, but at other widths: the fields do not line up.
    try std.testing.expectError(error.NotDetectedFrom, write(&r.layout, .strftime, "11/12/2024", &w));
    try std.testing.expectError(error.NotDetectedFrom, write(&r.layout, .strftime, "2024-01-02", &w));
    // Padding is trimmed as the layout trims it.
    w.end = 0;
    try write(&r.layout, .go, "  1/2/2024 ", &w);
    try std.testing.expectEqualStrings("1/2/2006", w.buffered());
}

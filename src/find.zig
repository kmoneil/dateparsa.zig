//! Where a date can sit inside a longer text: the rules findFirst,
//! findAll and Layout.find share. A date starts on a word's first byte and
//! ends on a word's last, where a word is letters, digits and any
//! non-ASCII byte (a UTF-8 month name is one word); it crosses no line
//! break and no byte that no date holds (stops), and is at most max_span
//! bytes.

const std = @import("std");
const compile = @import("compile.zig");
const locale = @import("locale.zig");

/// The longest span a date is looked for in. The longest a log writes,
/// a Go time.String() with its monotonic reading
/// ("2012-08-03 18:31:59.257000000 +0000 UTC m=+0.000000001"), is 56.
pub const max_span = 80;

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Whether a date can start at text[i]: a word's first byte.
pub fn isStart(text: []const u8, i: usize) bool {
    return isWordByte(text[i]) and (i == 0 or !isWordByte(text[i - 1]));
}

/// Whether a date can end before text[end]: just after a word's last byte.
pub fn isEnd(text: []const u8, end: usize) bool {
    return end > 0 and isWordByte(text[end - 1]) and (end == text.len or !isWordByte(text[end]));
}

/// Bytes no date this library reads holds, so a span stops before them:
/// the line's end, and the quotes, brackets and markup a date sits inside
/// in a log line ("[09/Nov/2026:23:59:59 +0000]", "\"ts\":\"...\""). The
/// detectors are lenient about what follows a date, and a span let past
/// one read `+0000] "GET / HTTP` as a zone name.
const stops = "\r\n\"'`[]{}()<>=|;";

/// Where a span starting at start must end by: max_span on, or the first
/// stop, whichever comes first.
pub fn limit(text: []const u8, start: usize) usize {
    const far = @min(text.len, start + max_span);
    return std.mem.indexOfAnyPos(u8, text[0..far], start, stops) orelse far;
}

/// Where the last value a program reads ends: past it, the program only
/// skips (words detection passed over, a tail it ignores). The detectors
/// pass over words after a date ("March 5, after the freeze" reads as
/// March 5), so a span whose value ends before the span does was too long:
/// the date ended there.
pub fn valueEnd(p: *const compile.Program) usize {
    var end: usize = 0;
    for (p.insts[0..p.n]) |inst| switch (inst.op) {
        .skip, .tail, .nop => {},
        else => end = @max(end, @as(usize, inst.offset) + inst.len),
    };
    return end;
}

/// Whether s is a lone number: digits, with at most one dot among them.
pub fn isNumber(s: []const u8) bool {
    var dots: usize = 0;
    for (s) |c| {
        if (c == '.') {
            dots += 1;
        } else if (!std.ascii.isDigit(c)) return false;
    }
    return dots <= 1;
}

/// Whether a structured date can start at text[i], a word's first byte: a
/// digit, or a month's or weekday's name in English or a locale of
/// locales ("Nov  8 10:00:05", "Sun, 08 Nov 2026"). Most words of a log
/// line are neither, and are passed over without a parse.
pub fn mayStartStructured(text: []const u8, i: usize, locales: locale.LocaleSet) bool {
    if (std.ascii.isDigit(text[i])) return true;
    return compile.readMonthName(text, i, locales) != null or compile.readWeekdayName(text, i, locales) != null;
}

test isStart {
    const t = "a 12-x é9";
    try std.testing.expect(isStart(t, 0));
    try std.testing.expect(!isStart(t, 1));
    try std.testing.expect(isStart(t, 2));
    try std.testing.expect(!isStart(t, 3));
    try std.testing.expect(isStart(t, 5));
    // A UTF-8 letter and a digit after it are one word.
    try std.testing.expect(isStart(t, 7));
    try std.testing.expect(!isStart(t, 9));
}

test isEnd {
    const t = "12-x é";
    try std.testing.expect(!isEnd(t, 0));
    try std.testing.expect(!isEnd(t, 1));
    try std.testing.expect(isEnd(t, 2));
    try std.testing.expect(isEnd(t, 4));
    try std.testing.expect(isEnd(t, t.len));
}

test isNumber {
    try std.testing.expect(isNumber("2024"));
    try std.testing.expect(isNumber("1710504800.123"));
    try std.testing.expect(!isNumber("15.03.2024"));
    try std.testing.expect(!isNumber("2024-03-15"));
}

test limit {
    try std.testing.expectEqual(10, limit("2024-03-15\n10:30", 0));
    try std.testing.expectEqual(26, limit("09/Nov/2026:23:59:59 +0000] \"GET", 0));
    try std.testing.expectEqual(max_span, limit(&@as([200]u8, @splat('1')), 0));
    try std.testing.expectEqual(3, limit("abc", 1));
}

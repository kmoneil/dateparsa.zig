//! The Unicode the natural-language scanner needs, with Go's answers: Go's
//! unicode.ToLower, IsLetter and IsDigit (tables generated from Go's own
//! unicode package by tools/unicode_gen.go), strings.ToLower's handling of
//! invalid UTF-8, and the accent folding the Go scanner applies.

const std = @import("std");
const data = @import("unicode_data.zig");

pub const unicode_version = data.unicode_version;

const replacement: u21 = 0xFFFD;

fn findRange(comptime T: type, ranges: []const T, cp: u21) ?T {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return if ((cp - r.lo) % r.stride == 0) r else null;
        }
    }
    return null;
}

pub fn isLetter(cp: u21) bool {
    return findRange(data.Range, &data.letter, cp) != null;
}

pub fn isDigit(cp: u21) bool {
    return findRange(data.Range, &data.digit, cp) != null;
}

/// Go's unicode.ToLower.
pub fn toLower(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    const r = findRange(data.LowerRange, &data.lower, cp) orelse return cp;
    return @intCast(@as(i32, cp) + r.delta);
}

/// Decodes the code point at s[i..], as Go's range over a string does: an
/// invalid or truncated sequence is U+FFFD of width 1.
pub fn decode(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = replacement, .len = 1 };
    if (i + n > s.len) return .{ .cp = replacement, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ .cp = replacement, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// The longest result lowerInto can write for an input of n bytes: an
/// invalid byte becomes a three-byte U+FFFD, and no lowercase mapping grows
/// a code point's encoding by more than that.
pub fn maxLowerLen(n: usize) usize {
    return n * 3;
}

/// Go's strings.ToLower(s) written into out, which must hold
/// maxLowerLen(s.len) bytes. Each code point maps through toLower; an
/// invalid byte becomes U+FFFD, as Go's strings.Map writes it.
pub fn lowerInto(out: []u8, s: []const u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        w += std.unicode.utf8Encode(toLower(d.cp), out[w..]) catch unreachable;
        i += d.len;
    }
    return out[0..w];
}

/// The accented Latin-1 lowercase letters the Go scanner folds to ASCII,
/// so "próximo" also matches "proximo".
fn foldRune(cp: u21) u21 {
    return switch (cp) {
        'à'...'å', 'æ' => 'a',
        'ç' => 'c',
        'è'...'ë' => 'e',
        'ì'...'ï' => 'i',
        'ñ' => 'n',
        'ò'...'ö' => 'o',
        'ù'...'ü' => 'u',
        'ý', 'ÿ' => 'y',
        else => cp,
    };
}

/// Go's foldAccents written into out (at most s.len bytes: folding only
/// shortens). Invalid bytes become U+FFFD, as Go's range over a string
/// reads them; lowerInto's output has none left.
pub fn foldAccentsInto(out: []u8, s: []const u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        w += std.unicode.utf8Encode(foldRune(d.cp), out[w..]) catch unreachable;
        i += d.len;
    }
    return out[0..w];
}

/// Whether the code point at s[pos..] is a letter or a digit, as the Go
/// scanner's word-boundary check asks. Past the end is not.
pub fn isWordAt(s: []const u8, pos: usize) bool {
    if (pos >= s.len) return false;
    const cp = decode(s, pos).cp;
    return isLetter(cp) or isDigit(cp);
}

/// The start of the code point before pos, stepping back over
/// continuation bytes, as Go's prevCharPos does.
pub fn prevCharPos(s: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and s[p] & 0xc0 == 0x80) p -= 1;
    return p;
}

test {
    std.testing.refAllDecls(@This());
}

test "lowercasing and classes, spot checks against Go" {
    try std.testing.expectEqual('a', toLower('A'));
    try std.testing.expectEqual('ä', toLower('Ä'));
    try std.testing.expectEqual('я', toLower('Я'));
    try std.testing.expectEqual('і', toLower('І')); // Ukrainian
    try std.testing.expectEqual('ґ', toLower('Ґ'));
    try std.testing.expectEqual('i', toLower('İ')); // Go: U+0130 to i
    try std.testing.expectEqual('ı', toLower('ı'));
    try std.testing.expectEqual('k', toLower(0x212A)); // KELVIN SIGN
    try std.testing.expectEqual(0x2C65, toLower(0x23A)); // grows from 2 to 3 bytes
    try std.testing.expect(isLetter('a') and isLetter('я') and isLetter('क') and isLetter('日'));
    try std.testing.expect(!isLetter(0x093E)); // DEVANAGARI VOWEL SIGN AA is a mark
    try std.testing.expect(!isLetter('1') and isDigit('1') and isDigit(0x0967)); // ० digits
    try std.testing.expect(!isLetter(' ') and !isLetter(replacement));
}

test "lowerInto follows Go's strings.ToLower" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("вчера", lowerInto(&buf, "ВЧЕРА"));
    try std.testing.expectEqualStrings("mañana", lowerInto(&buf, "MAÑANA"));
    try std.testing.expectEqualStrings("x\u{fffd}y", lowerInto(&buf, "X\xffY"));
    // Each byte of a bad sequence is its own U+FFFD, as Go reads them.
    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}", lowerInto(&buf, "\xe2\x82"));
    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}\u{fffd}", lowerInto(&buf, "\xed\xa0\x80")); // surrogate
    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}", lowerInto(&buf, "\xc0\xaf")); // overlong
    try std.testing.expectEqualStrings("\u{2c65}", lowerInto(&buf, "\u{23a}"));
}

test "foldAccentsInto" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("proximo", foldAccentsInto(&buf, "próximo"));
    try std.testing.expectEqualStrings("naechste", foldAccentsInto(&buf, "naechste"));
    try std.testing.expectEqualStrings("nachsten", foldAccentsInto(&buf, "nächsten"));
    try std.testing.expectEqualStrings("Ä", foldAccentsInto(&buf, "Ä")); // lowercase only
}

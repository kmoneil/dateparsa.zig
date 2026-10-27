//! Character-class signatures and the padding trim.
//!
//! Detection looks at the classes of an input's bytes, not the bytes: scan
//! maps each byte to one of six classes in one pass, and the trie walks that
//! sequence to find the format. "2024-03-15" and "1999-12-31" share a
//! signature, which is the point.
//!
//! The padding trim lives here because it decides which bytes reach the
//! scan. Surrounding whitespace is a property of the row, not of the format
//! (a padded CSV column, a log line ending in CRLF), so it is removed once
//! ahead of the whole cascade. Interior whitespace is not padding: it stays
//! in the signature, and "2024-03-15  10:30" with two spaces matches no
//! format.

const std = @import("std");

pub const CharClass = enum(u3) {
    digit, // 0-9
    letter, // a-z A-Z, non-ASCII, rare punctuation; T and Z outside their contexts
    sep, // - / .
    space, // space, tab
    colon, // :
    special, // + , and T, Z, - in their timestamp contexts
};

pub const num_classes = @typeInfo(CharClass).@"enum".field_names.len;

/// scan classifies at most this many bytes, so its work is bounded whatever
/// the input length. hasLetterPastSignature answers the one question asked
/// about the bytes past it.
pub const max_len = 64;

pub const Signature = struct {
    buf: [max_len]CharClass = undefined,
    len: u8 = 0,
    /// Whether any classified byte is a letter. Covers the first max_len
    /// bytes only; see hasLetterPastSignature.
    has_letter: bool = false,

    pub fn classes(sig: *const Signature) []const CharClass {
        return sig.buf[0..sig.len];
    }
};

/// Each byte's class when its neighbours do not matter. scan overrides T, Z
/// and - in the contexts that make them timestamp punctuation.
const context_free_class: [256]CharClass = blk: {
    var t: [256]CharClass = @splat(.letter);
    for ("0123456789") |c| t[c] = .digit;
    for ("-/.") |c| t[c] = .sep;
    for (" \t") |c| t[c] = .space;
    t[':'] = .colon;
    for ("+,") |c| t[c] = .special;
    break :blk t;
};

/// Maps each byte of the first max_len bytes of s to its class. Three bytes
/// depend on their neighbours, and "the end" for them is the end of the
/// classified window, not of s:
///   - T between digits is the ISO 8601 date-time separator, else a letter.
///   - Z at the end or before + or - is the UTC marker, else a letter.
///   - '-' after a Z or shortly after a colon is an offset sign, else a
///     date separator.
pub fn scan(s: []const u8) Signature {
    const n = @min(s.len, max_len);
    var sig: Signature = .{ .len = @intCast(n) };
    for (s[0..n], 0..) |c, i| {
        const cc: CharClass = switch (c) {
            'T' => if (i > 0 and i + 1 < n and isDigit(s[i - 1]) and isDigit(s[i + 1]))
                .special
            else
                .letter,
            'Z' => if (i + 1 == n or s[i + 1] == '+' or s[i + 1] == '-') .special else .letter,
            '-' => if (i > 0 and isTzSignPosition(s, i)) .special else .sep,
            else => context_free_class[c],
        };
        sig.buf[i] = cc;
        if (cc == .letter) sig.has_letter = true;
    }
    return sig;
}

/// Whether the - at i follows a Z ("Z-05:00") or a colon in the seven bytes
/// before it ("10:30:00-05:00", "10:30:00.123-05:00"). Asserts i > 0.
fn isTzSignPosition(s: []const u8, i: usize) bool {
    std.debug.assert(i > 0);
    if (s[i - 1] == 'Z') return true;
    if (i < 8) return false;
    return std.mem.indexOfScalar(u8, s[i - 7 .. i], ':') != null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Whether scan could classify c as a letter, for bytes past the window scan
/// classified. T and Z count even though scan sometimes makes them special:
/// that depends on neighbours this does not look at, and over-reporting is
/// the safe direction, since the answer only lets a fallback detector look
/// at the input and that detector can refuse.
pub fn maybeLetter(c: u8) bool {
    return context_free_class[c] == .letter;
}

/// Whether a letter sits past the bytes scan classified; false for any s
/// scan saw in full. Signature.has_letter alone means "a letter in the first
/// max_len bytes", and gating the textual detector on it sent a date behind
/// 64 bytes of padding to natural language instead. Kept out of scan so
/// scan's work stays bounded: only the path that already missed the trie
/// pays for the rest of the input.
pub fn hasLetterPastSignature(s: []const u8) bool {
    if (s.len <= max_len) return false;
    for (s[max_len..]) |c| {
        if (maybeLetter(c)) return true;
    }
    return false;
}

/// Whether s is non-empty and every byte is an ASCII digit.
pub fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isDigit(c)) return false;
    }
    return true;
}

/// Whether c is one of the six ASCII bytes treated as padding: space, tab,
/// newline, vertical tab, form feed, carriage return (the same set as
/// std.ascii.whitespace). Deliberately not Unicode space: U+00A0 arrives
/// from the same spreadsheets as padded columns, but it is a character
/// written to stop a line break, and admitting it turns a byte test into a
/// decode. The set is ' ' plus the contiguous run 0x09..0x0D.
pub fn isPadding(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// s without leading or trailing padding: a subslice, never a copy. An
/// all-padding input trims to the empty slice, which every detector refuses.
/// Cost is linear in the padding, not the input: unpadded s fails both loop
/// conditions on the first byte tested and comes back whole.
pub fn trimPadding(s: []const u8) []const u8 {
    var i: usize = 0;
    var j: usize = s.len;
    while (i < j and isPadding(s[i])) i += 1;
    while (j > i and isPadding(s[j - 1])) j -= 1;
    return s[i..j];
}

/// Whether s starts or ends with padding. The test a reused layout runs on
/// every row instead of trimming every row: two byte loads, no loop.
pub fn hasPadding(s: []const u8) bool {
    return s.len != 0 and (isPadding(s[0]) or isPadding(s[s.len - 1]));
}

/// Writes sig as one letter per class (D L S W C X, the Go tests' spelling)
/// into out and returns the written part.
fn classString(sig: *const Signature, out: *[max_len]u8) []const u8 {
    for (sig.classes(), 0..) |cc, i| out[i] = "DLSWCX"[@backingInt(cc)];
    return out[0..sig.len];
}

fn expectSignature(input: []const u8, want: []const u8) !void {
    const sig = scan(input);
    var buf: [max_len]u8 = undefined;
    const got = classString(&sig, &buf);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("scan(\"{s}\") = {s}, want {s}\n", .{ input, got, want });
        return error.TestUnexpectedResult;
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "scan: basic signatures" {
    try expectSignature("2024-03-15", "DDDDSDDSDD");
    try expectSignature("10:30:00", "DDCDDCDD");
    try expectSignature("10:30", "DDCDD");
    try expectSignature("15.03.2024", "DDSDDSDDDD");
    try expectSignature("2024-03-15T10:30:00Z", "DDDDSDDSDDXDDCDDCDDX");
    try expectSignature("2024-03-15T10:30:00+05:30", "DDDDSDDSDDXDDCDDCDDXDDCDD");
}

test "scan: T, Z and - depend on their neighbours" {
    // T: special between digits, letter otherwise.
    try expectSignature("2024-03-15T10:30:00", "DDDDSDDSDDXDDCDDCDD");
    try expectSignature("T12345", "LDDDDD");
    try expectSignature("abcT", "LLLL");
    try expectSignature("1T2", "DXD");

    // Z: special at the end or before a sign, letter otherwise.
    try expectSignature("Zone", "LLLL");
    try expectSignature("Z", "X");
    try expectSignature("Z+05:00", "XXDDCDD");
    try expectSignature("Z-05:00", "XXDDCDD");
    try expectSignature("Z1234", "LDDDD");

    // + and , are always special.
    try expectSignature("+05:30", "XDDCDD");
    try expectSignature("Fri, 15", "LLLXWDD");

    // -: a separator in a date, a sign after a time.
    try expectSignature("2024-03-15", "DDDDSDDSDD");
    try expectSignature("10:30:00-05:00", "DDCDDCDDXDDCDD");
    try expectSignature("10:30:00.123-05:00", "DDCDDCDDSDDDXDDCDD");

    try expectSignature("2024 03", "DDDDWDD");
}

test "scan: has_letter" {
    try std.testing.expect(!scan("2024-03-15").has_letter);
    try std.testing.expect(!scan("2024-03-15T10:30:00Z").has_letter);
    try std.testing.expect(scan("March").has_letter);
    try std.testing.expect(scan("15 \u{a0}").has_letter);
}

test "scan: each byte's class away from any context" {
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        const want: CharClass = switch (c) {
            '0'...'9' => .digit,
            '-', '/', '.' => .sep,
            ' ', '\t' => .space,
            ':' => .colon,
            '+', ',' => .special,
            else => .letter,
        };
        // Between two spaces no context rule fires.
        const sig = scan(&[_]u8{ ' ', c, ' ' });
        try std.testing.expectEqual(want, sig.buf[1]);
        try std.testing.expectEqual(want == .letter, sig.has_letter);
    }
}

test "scan classifies at most max_len bytes" {
    var buf: [100]u8 = @splat('1');
    buf[80] = 'x';
    const sig = scan(&buf);
    try std.testing.expectEqual(max_len, sig.len);
    try std.testing.expect(!sig.has_letter);
    try std.testing.expect(hasLetterPastSignature(&buf));
}

test "maybeLetter answers yes for every byte scan can call a letter" {
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        if (scan(&[_]u8{ ' ', c, ' ' }).has_letter) try std.testing.expect(maybeLetter(c));
    }
    // Or a numeric date behind a long separator run would reach the textual
    // detector.
    for ("0123456789-/. \t:+,") |c| try std.testing.expect(!maybeLetter(c));
}

test "hasLetterPastSignature looks only past the buffer" {
    try std.testing.expect(!hasLetterPastSignature("March 15, 2024"));
    var buf: [max_len + 1]u8 = @splat(' ');
    try std.testing.expect(!hasLetterPastSignature(&buf));
    buf[max_len] = 'M';
    try std.testing.expect(hasLetterPastSignature(&buf));
}

test "allDigits" {
    try std.testing.expect(!allDigits(""));
    try std.testing.expect(allDigits("0"));
    try std.testing.expect(allDigits("20240315"));
    try std.testing.expect(!allDigits("2024-03"));
    try std.testing.expect(!allDigits("-1"));
}

test "isPadding and trimPadding cover exactly the six bytes" {
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        const want = std.mem.indexOfScalar(u8, " \t\n\r\x0b\x0c", c) != null;
        try std.testing.expectEqual(want, isPadding(c));
        const trimmed = std.mem.eql(u8, trimPadding(&[_]u8{ c, 'x', c }), "x");
        try std.testing.expectEqual(want, trimmed);
    }
}

test "trimPadding: all-padding input trims to empty" {
    const inputs = [_][]const u8{ "", " ", "  ", "\t", "\n", "\r\n", " \t\r\n\x0b\x0c " };
    for (inputs) |in| try std.testing.expectEqual(0, trimPadding(in).len);
    const long: [1000]u8 = @splat(' ');
    try std.testing.expectEqual(0, trimPadding(&long).len);
}

test "trimPadding: Unicode spaces are not padding" {
    // NO-BREAK SPACE, FIGURE SPACE, NARROW NO-BREAK SPACE, IDEOGRAPHIC SPACE.
    const inputs = [_][]const u8{
        "\u{a0}2024-03-15",
        "2024-03-15\u{a0}",
        "\u{a0}March 15, 2024\u{a0}",
        "\u{2007}2024-03-15",
        "\u{202f}2024-03-15",
        "\u{3000}2024-03-15",
    };
    for (inputs) |in| try std.testing.expectEqualStrings(in, trimPadding(in));
    try std.testing.expectEqualStrings("\u{a0}x", trimPadding(" \u{a0}x "));
}

test "trimPadding keeps interior whitespace and returns a subslice" {
    const padded = " 2024-03-15  10:30\r\n";
    const out = trimPadding(padded);
    try std.testing.expectEqualStrings("2024-03-15  10:30", out);
    try std.testing.expectEqual(padded.ptr + 1, out.ptr);

    const unpadded = "2024-03-15";
    const same = trimPadding(unpadded);
    try std.testing.expectEqual(unpadded.ptr, same.ptr);
    try std.testing.expectEqual(unpadded.len, same.len);
}

test "hasPadding looks only at the ends" {
    try std.testing.expect(!hasPadding(""));
    try std.testing.expect(!hasPadding("2024-03-15"));
    try std.testing.expect(!hasPadding("2024  03"));
    try std.testing.expect(!hasPadding("\u{a0}2024-03-15"));
    try std.testing.expect(hasPadding(" 2024-03-15"));
    try std.testing.expect(hasPadding("2024-03-15\n"));
    try std.testing.expect(hasPadding("\x0b"));
}

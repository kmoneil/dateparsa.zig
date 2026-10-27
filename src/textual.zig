//! Dates written around a month name: "March 15, 2024", "15 Mar 2024",
//! "Fri, 15 Mar 2024 10:30:00 +0000", "2024년 11월 11일" with ko.
//!
//! The month is found by name, English first and then the configured
//! locales, as a whole word with ASCII case folded. The numbers around it
//! are read by count and value: over 31 is a year, one or two digits beside
//! the month is a day, and a bare two-digit number with no year is a guess
//! between the two ("March 15" is also March 2015). Everything between the
//! fields is skipped byte for byte, and a skipped word that would change the
//! date ("first monday of march") refuses the input instead.

const std = @import("std");
const compile = @import("compile.zig");
const detect = @import("detect.zig");
const locale = @import("locale.zig");

const Field = compile.Field;
const FieldKind = compile.FieldKind;
const Def = detect.Def;
const Result = detect.Result;
const Config = detect.Config;
const isDigit = std.ascii.isDigit;
const isWordChar = compile.isWordChar;

/// How a spelling is looked for, as Go's spellingLookup.
const Lookup = enum {
    /// Every byte a word character: it can only match a whole word of its
    /// own length, which the word list answers.
    word_list,
    /// Word characters and one trailing dot, which the word list answers
    /// too: the word before the dot, then the dot and a boundary.
    dotted,
    /// Anything else, which scans the input: the Chinese, Japanese and
    /// Korean spellings that write a month as a digit and a character.
    scan,
};

/// A month spelling and what the word matcher filters it on.
const Spelling = struct {
    name: []const u8,
    month: u8,
    how: Lookup,
    /// The bit for the length of word it matches; every bit for a scan.
    len_bit: u64,
    /// The bit for its first byte; every bit for a scan.
    first_bit: u32,
};

fn spelling(name: []const u8, month: u8) Spelling {
    const how: Lookup = if (allWordChars(name))
        .word_list
    else if (name.len >= 2 and name[name.len - 1] == '.' and allWordChars(name[0 .. name.len - 1]))
        .dotted
    else
        .scan;
    return .{
        .name = name,
        .month = month,
        .how = how,
        .len_bit = switch (how) {
            .word_list => lenBit(name.len),
            .dotted => lenBit(name.len - 1),
            .scan => ~@as(u64, 0),
        },
        .first_bit = if (how == .scan) ~@as(u32, 0) else firstBit(name[0]),
    };
}

fn allWordChars(name: []const u8) bool {
    for (name) |c| if (!isWordChar(c)) return false;
    return true;
}

/// One bit per word length, saturating at 63. Bit 0 is no word's, and every
/// mask has it, so a spelling carrying every bit is never filtered out.
fn lenBit(n: usize) u64 {
    return @as(u64, 1) << @intCast(@min(n, 63));
}

/// One bit per ASCII letter, case folded; every other byte, a UTF-8 lead
/// byte included, shares first_bit_other. first_bit_sentinel is no byte's
/// and plays bit 0's part for the first-byte mask.
fn firstBit(b: u8) u32 {
    const c = std.ascii.toLower(b);
    return if (c >= 'a' and c <= 'z') @as(u32, 1) << @intCast(c - 'a') else first_bit_other;
}

const first_bit_other: u32 = 1 << 26;
const first_bit_sentinel: u32 = 1 << 31;

/// English, always searched first, in Go's order: a spelling comes before
/// the shorter ones it contains ("september", then "sept", then "sep").
const english = [_]Spelling{
    spelling("september", 9),
    spelling("february", 2),
    spelling("november", 11),
    spelling("december", 12),
    spelling("january", 1),
    spelling("october", 10),
    spelling("august", 8),
    spelling("march", 3),
    spelling("april", 4),
    spelling("june", 6),
    spelling("july", 7),
    spelling("sept", 9),
    spelling("jan", 1),
    spelling("feb", 2),
    spelling("mar", 3),
    spelling("apr", 4),
    spelling("may", 5),
    spelling("jun", 6),
    spelling("jul", 7),
    spelling("aug", 8),
    spelling("sep", 9),
    spelling("oct", 10),
    spelling("nov", 11),
    spelling("dec", 12),
};

/// Each compiled locale's spellings: per month the wide name, the
/// abbreviation, and the abbreviation without its trailing dots. When one
/// spelling ends with another the list is ordered longest first, so "11월"
/// is tried before "1월", which it contains.
const locale_spellings: [locale.compiled.len][]const Spelling = blk: {
    @setEvalBranchQuota(1_000_000);
    var all: [locale.compiled.len][]const Spelling = undefined;
    for (locale.compiled, 0..) |d, li| {
        var list: [36]Spelling = undefined;
        var n: usize = 0;
        for (d.months_wide, d.months_abbr, 1..) |wide, abbr, month| {
            for ([_][]const u8{ wide, abbr, std.mem.trimEnd(u8, abbr, ".") }, 0..) |name, k| {
                if (name.len == 0 or (k == 2 and name.len == abbr.len)) continue;
                list[n] = spelling(name, month);
                n += 1;
            }
        }
        if (hasSuffixPair(list[0..n])) {
            // Stable insertion sort, longest first.
            for (1..n) |i| {
                var j = i;
                while (j > 0 and list[j - 1].name.len < list[j].name.len) : (j -= 1) {
                    std.mem.swap(Spelling, &list[j - 1], &list[j]);
                }
            }
        }
        const final = list[0..n].*;
        all[li] = &final;
    }
    break :blk all;
};

fn hasSuffixPair(list: []const Spelling) bool {
    for (list) |a| for (list) |b| {
        if (a.name.len < b.name.len and std.mem.endsWith(u8, b.name, a.name)) return true;
    };
    return false;
}

const Span = struct { start: usize, end: usize };

/// The first place word occurs in s as a whole word, ASCII case folded: the
/// bytes either side are not word characters, so a digit or punctuation
/// may touch it ("MAY10") and a letter may not.
fn matchWord(s: []const u8, word: []const u8) ?Span {
    if (word.len == 0 or word.len > s.len) return null;
    for (0..s.len - word.len + 1) |i| {
        if (!std.ascii.eqlIgnoreCase(s[i..][0..word.len], word)) continue;
        const end = i + word.len;
        if ((i == 0 or !isWordChar(s[i - 1])) and (end == s.len or !isWordChar(s[end]))) {
            return .{ .start = i, .end = end };
        }
    }
    return null;
}

/// Above this many words the matcher keeps no list and every spelling
/// scans, as Go's does.
const word_cap = 48;

/// Go's wordMatcher: the input's words, listed once, so that each spelling
/// is asked only about words of its own length rather than scanning the
/// input. A spelling of word characters can only match a whole maximal run
/// of them, so the answer is matchWord's. The masks say which lengths and
/// first bytes the words have, and dismiss most spellings before any
/// compare; they decide whether a spelling can match, never which wins.
const WordMatcher = struct {
    s: []const u8,
    buf: [word_cap]Span,
    /// How many words s holds, or null over word_cap, when every spelling
    /// scans and the masks admit all of them.
    n: ?usize,
    len_mask: u64,
    first_mask: u32,

    fn init(m: *WordMatcher, s: []const u8) void {
        m.s = s;
        m.n = 0;
        m.len_mask = 1;
        m.first_mask = first_bit_sentinel;
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const b = s[i];
            if (!isWordChar(b)) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < s.len and isWordChar(s[i])) i += 1;
            if (n == word_cap) {
                m.n = null;
                m.len_mask = ~@as(u64, 0);
                m.first_mask = ~@as(u32, 0);
                return;
            }
            m.buf[n] = .{ .start = start, .end = i };
            m.len_mask |= lenBit(i - start);
            m.first_mask |= firstBit(b);
            n += 1;
        }
        m.n = n;
    }

    fn admits(m: *const WordMatcher, sp: *const Spelling) bool {
        return sp.len_bit & m.len_mask != 0 and sp.first_bit & m.first_mask != 0;
    }

    /// The first whole-word occurrence of sp, as matchWord finds it.
    fn find(m: *const WordMatcher, sp: *const Spelling) ?Span {
        const n = m.n orelse return matchWord(m.s, sp.name);
        if (sp.how == .scan) return matchWord(m.s, sp.name);
        if (sp.name.len > m.s.len) return null;
        const dotted = sp.how == .dotted;
        const wlen = sp.name.len - @intFromBool(dotted);
        for (m.buf[0..n]) |w| {
            if (w.end - w.start != wlen) continue;
            var end = w.end;
            if (dotted) {
                // The dot, then a boundary. A miss here is not the end of
                // the search: "sept." occurs in "sept sept." at 5.
                if (end >= m.s.len or m.s[end] != '.') continue;
                if (end + 1 < m.s.len and isWordChar(m.s[end + 1])) continue;
                end += 1;
            }
            if (std.ascii.eqlIgnoreCase(m.s[w.start..w.end], sp.name[0..wlen])) {
                return .{ .start = w.start, .end = end };
            }
        }
        return null;
    }
};

pub const Found = struct { month: u8, start: usize, end: usize, rival: bool };

/// The first spelling found, English then each locale in tag order, and
/// whether a spelling of a different month also occurs outside it.
pub fn findMonthName(s: []const u8, locales: locale.LocaleSet) ?Found {
    var m: WordMatcher = undefined;
    m.init(s);
    for (&english) |*sp| {
        if (!m.admits(sp)) continue;
        if (m.find(sp)) |at| return found(&m, sp.month, at, locales);
    }
    for (locale_spellings, 0..) |spellings, li| {
        if (!locale.contains(locales, li)) continue;
        for (spellings) |*sp| {
            if (!m.admits(sp)) continue;
            if (m.find(sp)) |at| return found(&m, sp.month, at, locales);
        }
    }
    return null;
}

fn found(m: *const WordMatcher, month: u8, at: Span, locales: locale.LocaleSet) Found {
    return .{
        .month = month,
        .start = at.start,
        .end = at.end,
        .rival = hasRival(m, month, at, locales),
    };
}

/// Whether a spelling of another month occurs, at its first occurrence,
/// outside the one found. Two month names leave no way to say which the
/// date is written around, and picking the first spelling tried would let
/// the table's order decide "MAY1MAR".
fn hasRival(m: *const WordMatcher, month: u8, at: Span, locales: locale.LocaleSet) bool {
    // One word cannot hold two month names at two spans.
    if (m.n) |n| if (n < 2) return false;
    for (&english) |*sp| {
        if (rivals(m, sp, month, at)) return true;
    }
    for (locale_spellings, 0..) |spellings, li| {
        if (!locale.contains(locales, li)) continue;
        for (spellings) |*sp| {
            if (rivals(m, sp, month, at)) return true;
        }
    }
    return false;
}

/// Whether sp names another month and first occurs clear of at.
fn rivals(m: *const WordMatcher, sp: *const Spelling, month: u8, at: Span) bool {
    if (sp.month == month or !m.admits(sp)) return false;
    const o = m.find(sp) orelse return false;
    return o.start >= at.end or o.end <= at.start;
}

/// Whether cp is white space by Go's unicode.IsSpace, which strings.TrimSpace
/// trims: the ASCII six, NEL, NBSP and the Unicode space separators.
fn isSpace(cp: u21) bool {
    return switch (cp) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ', 0x85, 0xa0, 0x1680 => true,
        0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// s without leading or trailing white space, as Go's strings.TrimSpace.
fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
        if (start + n > s.len) break;
        const cp = std.unicode.utf8Decode(s[start..][0..n]) catch break;
        if (!isSpace(cp)) break;
        start += n;
    }
    var end = s.len;
    while (end > start) {
        var lead = end - 1;
        while (lead > start and s[lead] & 0xc0 == 0x80) lead -= 1;
        // A tail that is not one whole sequence is U+FFFD to Go, not space.
        const n = std.unicode.utf8ByteSequenceLength(s[lead]) catch break;
        if (lead + n != end) break;
        const cp = std.unicode.utf8Decode(s[lead..end]) catch break;
        if (!isSpace(cp)) break;
        end = lead;
    }
    return s[start..end];
}

fn indexFoldAscii(s: []const u8, sub: []const u8) ?usize {
    if (sub.len > s.len) return null;
    for (0..s.len - sub.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(s[i..][0..sub.len], sub)) return i;
    }
    return null;
}

/// How many runs of digits s holds and the value of the first, saturating
/// (Go's int wrapped on a twenty-digit run; either way it is over 31).
fn countNumbers(s: []const u8) struct { n: usize, first: u64 } {
    var n: usize = 0;
    var first: u64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (!isDigit(s[i])) {
            i += 1;
            continue;
        }
        var v: u64 = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) v = v *| 10 +| (s[i] - '0');
        if (n == 0) first = v;
        n += 1;
    }
    return .{ .n = n, .first = first };
}

fn hasFourDigitYear(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (!isDigit(s[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < s.len and isDigit(s[i])) i += 1;
        if (i - start == 4) return true;
    }
    return false;
}

/// "25th at 5pm" is "25th": an " at " clause is dropped unless what comes
/// before it already holds two numbers and a four-digit year, so a time's
/// hour is not counted as a year.
fn trimAtSuffix(s: []const u8) []const u8 {
    const at = indexFoldAscii(s, " at ") orelse return s;
    const before = s[0..at];
    if (countNumbers(before).n <= 1 or !hasFourDigitYear(before)) return before;
    return s;
}

/// The format's name from how many numbers sit on each side of the month.
fn classify(s: []const u8, start: usize, end: usize) ?[]const u8 {
    const before = countNumbers(trimSpace(s[0..start]));
    const after_text = std.mem.trimStart(u8, trimSpace(s[end..]), ", ");
    const after = countNumbers(trimAtSuffix(after_text));
    if (before.n == 0 and after.n >= 2) return "MONTH_DAY_YEAR";
    if (before.n >= 1 and after.n >= 1) return "DAY_MONTH_YEAR";
    if (before.n == 0 and after.n == 1) return if (after.first > 31) "MONTH_YEAR" else "MONTH_DAY";
    if (before.n == 1 and after.n == 0) return "DAY_MONTH";
    return null;
}

const Num = struct { value: u64, start: usize, end: usize };

const BuildError = error{ TooManyFields, OutOfRange, NotADate };

fn add(def: *Def, kind: FieldKind, off: usize, len: usize, aux: u16) BuildError!void {
    try def.append(.{
        .kind = kind,
        .offset = std.math.cast(u8, off) orelse return error.OutOfRange,
        .len = std.math.cast(u8, len) orelse return error.OutOfRange,
        .aux = aux,
    });
}

fn addYear(def: *Def, n: Num) BuildError!void {
    const kind: FieldKind = if (n.end - n.start <= 2) .year2 else .year4;
    try add(def, kind, n.start, n.end - n.start, 0);
}

fn addDay(def: *Def, s: []const u8, n: Num) BuildError!void {
    const kind: FieldKind = if (n.end - n.start == 1) .day1or2 else .day2;
    try add(def, kind, n.start, n.end - n.start, 0);
    const suffix = ordinalSuffixLen(s, n.end);
    if (suffix > 0) try detect.appendSkip(def, s, n.end, suffix);
}

/// The width of an English ordinal suffix at at ("st", "nd", "rd", "th")
/// when a word ends there, else 0.
fn ordinalSuffixLen(s: []const u8, at: usize) usize {
    if (at + 2 > s.len) return 0;
    const c0 = s[at] | 0x20;
    const c1 = s[at + 1] | 0x20;
    const ordinal = (c0 == 's' and c1 == 't') or (c0 == 'n' and c1 == 'd') or
        (c0 == 'r' and c1 == 'd') or (c0 == 't' and c1 == 'h');
    if (!ordinal) return 0;
    if (at + 2 == s.len or !std.ascii.isAlphabetic(s[at + 2])) return 2;
    return 0;
}

fn isYear4(n: Num) bool {
    return n.end - n.start == 4 and n.value >= 1000;
}

/// The month and the numbers around it, then any time after them. The
/// fields come out of order (the month first) and coverGaps sorts them.
fn buildFields(def: *Def, s: []const u8, month: u8, start: usize, end: usize) BuildError!void {
    var nums_buf: [compile.max_describable_len / 2 + 1]Num = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i >= start and i < end) {
            i = end;
            continue;
        }
        if (!isDigit(s[i])) {
            i += 1;
            continue;
        }
        const from = i;
        var v: u64 = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) v = v *| 10 +| (s[i] - '0');
        nums_buf[count] = .{ .value = v, .start = from, .end = i };
        count += 1;
    }
    const nums = nums_buf[0..count];

    try add(def, .month_name, start, end - start, month);
    switch (nums.len) {
        0 => {},
        1 => {
            const n = nums[0];
            if (n.value > 31) try addYear(def, n) else try addDay(def, s, n);
            _ = detect.appendTimeComponent(def, s, n.end);
        },
        2 => {
            const n0, const n1 = .{ nums[0], nums[1] };
            if (n0.value > 31 or (n1.value <= 31 and n0.start > end)) {
                try addYear(def, n0);
                try addDay(def, s, n1);
            } else {
                try addDay(def, s, n0);
                try addYear(def, n1);
            }
            _ = detect.appendTimeComponent(def, s, n1.end);
        },
        else => try appendMultiNum(def, s, nums),
    }
}

/// Three numbers or more: a date and a time. A colon after the second
/// number means the time started there and the year, if any, trails it.
fn appendMultiNum(def: *Def, s: []const u8, nums: []const Num) BuildError!void {
    const n0, const n1 = .{ nums[0], nums[1] };
    const time_at_n1 = n1.end < s.len and s[n1.end] == ':';
    if (time_at_n1 and !isYear4(n1)) {
        if (n1.value > 23) return error.NotADate;
        if (n0.value <= 31) try addDay(def, s, n0) else try addYear(def, n0);
        const time_start = def.len;
        _ = detect.appendTimeComponent(def, s, n0.end);
        if (n0.value <= 31) {
            if (trailingYear(nums, def.buf[time_start..def.len], n0.end)) |y| try addYear(def, y);
        }
        return;
    }
    if (n1.value > 31) {
        try addDay(def, s, n0);
        try addYear(def, n1);
    } else if (n0.value > 31) {
        try addYear(def, n0);
        try addDay(def, s, n1);
    } else {
        try addDay(def, s, n0);
        try addYear(def, n1);
    }
    _ = detect.appendTimeComponent(def, s, n1.end);
}

/// A four-digit number after the time that no time field read: the year of
/// "Fri Mar 15 10:30:00 UTC 2024".
fn trailingYear(nums: []const Num, time: []const Field, after: usize) ?Num {
    for (nums) |n| {
        if (n.start <= after or n.value < 1000 or n.value > 9999) continue;
        const read = for (time) |f| {
            if (f.offset == n.start) break true;
        } else false;
        if (!read) return n;
    }
    return null;
}

const Guess = struct { prone: bool, guess: bool };

/// Whether the number read as a day could equally be a two-digit year.
/// "March 5" is a day (no year is one digit), "March 32" a year, and
/// "March 15" either; an ordinal suffix ("March 15th") or a four-digit year
/// settles it. prone: the shape can ask the question; guess: this input did.
fn dayIsAGuess(s: []const u8, fields: []const Field) Guess {
    var day: ?Field = null;
    var year: ?Field = null;
    for (fields) |f| switch (f.kind) {
        .year2, .year4 => year = f,
        .day1or2, .day2 => if (ordinalSuffixLen(s, @as(usize, f.offset) + f.len) == 0) {
            day = f;
        },
        else => {},
    };
    if (year) |y| if (y.kind == .year4) return .{ .prone = false, .guess = false };
    const prone = day != null or year != null;
    if (!prone) return .{ .prone = false, .guess = false };
    const d = day orelse return .{ .prone = true, .guess = false };
    if (d.kind != .day2 or d.len != 2) return .{ .prone = true, .guess = false };
    const y = year orelse return .{ .prone = true, .guess = true };
    // "01MAY10": the written year is also a day only when it is 31 or less.
    if (y.len < 1 or y.len > 2) return .{ .prone = true, .guess = false };
    var v: u8 = 0;
    for (s[y.offset..][0..y.len]) |c| {
        if (!isDigit(c)) return .{ .prone = true, .guess = false };
        v = v * 10 + (c - '0');
    }
    return .{ .prone = true, .guess = v <= 31 };
}

/// A date written around a month name, or null.
pub fn detectTextual(s: []const u8, cfg: Config) ?Result {
    if (s.len > compile.max_describable_len) return null;
    const f = findMonthName(s, cfg.locales) orelse return null;
    if (f.rival) return null;
    // "december 25th at 5pm" with no four-digit year is natural language.
    const after = trimSpace(s[f.end..]);
    if (indexFoldAscii(after, " at ") != null and !hasFourDigitYear(after)) return null;
    const name = classify(s, f.start, f.end) orelse return null;
    var def: Def = .{ .name = name };
    buildFields(&def, s, f.month, f.start, f.end) catch return null;
    detect.coverGaps(&def, s) catch return null;
    const g = dayIsAGuess(s, def.fields());
    return .{ .def = def, .ambiguity = if (g.guess) .day_or_year else .none, .prone = g.prone };
}

/// English words that change which day a skipped run describes: ordinals
/// that select ("first monday of march"), boundaries, times of day,
/// selectors, relative words and unit names.
const meaning_words = std.StaticStringMap(void).initComptime(.{
    .{"first"},     .{"second"},   .{"third"}, .{"fourth"},    .{"fifth"},
    .{"beginning"}, .{"start"},    .{"end"},   .{"morning"},   .{"afternoon"},
    .{"evening"},   .{"night"},    .{"noon"},  .{"midnight"},  .{"half"},
    .{"last"},      .{"previous"}, .{"past"},  .{"next"},      .{"coming"},
    .{"this"},      .{"now"},      .{"today"}, .{"yesterday"}, .{"tomorrow"},
    .{"seconds"},   .{"sec"},      .{"secs"},  .{"minute"},    .{"minutes"},
    .{"min"},       .{"mins"},     .{"hour"},  .{"hours"},     .{"hr"},
    .{"hrs"},       .{"day"},      .{"days"},  .{"week"},      .{"weeks"},
    .{"month"},     .{"months"},   .{"year"},  .{"years"},
});

const max_meaning_word = 16;

/// Whether a run of skips in fields holds a word that changes the date. A
/// format whose skipped bytes say "first monday of" has not described the
/// input, it has discarded the part that decides the day.
pub fn skipRunCarriesMeaning(s: []const u8, fields: []const Field, locales: locale.LocaleSet) bool {
    var i: usize = 0;
    while (i < fields.len) : (i += 1) {
        if (fields[i].kind != .skip) continue;
        // Abutting skips are one run: "último" is two pieces and one word.
        const off: usize = fields[i].offset;
        var end = off + fields[i].len;
        while (i + 1 < fields.len and fields[i + 1].kind == .skip and fields[i + 1].offset == end) {
            i += 1;
            end += fields[i].len;
        }
        if (off > s.len) continue;
        if (runCarriesMeaning(s[off..@min(end, s.len)], locales)) return true;
    }
    return false;
}

fn runCarriesMeaning(run: []const u8, locales: locale.LocaleSet) bool {
    var i: usize = 0;
    while (i < run.len) {
        if (!isWordChar(run[i])) {
            i += 1;
            continue;
        }
        const start = i;
        var ascii = false;
        while (i < run.len and isWordChar(run[i])) : (i += 1) {
            if (std.ascii.isAlphabetic(run[i])) ascii = true;
        }
        // A word with no ASCII letter in it is never compared.
        if (ascii and wordCarriesMeaning(run[start..i], locales)) return true;
    }
    return false;
}

fn wordCarriesMeaning(w: []const u8, locales: locale.LocaleSet) bool {
    if (w.len == 0) return false;
    if (w.len <= max_meaning_word) {
        var buf: [max_meaning_word]u8 = undefined;
        if (meaning_words.has(std.ascii.lowerString(&buf, w))) return true;
    }
    for (locale.compiled, 0..) |d, li| {
        if (!locale.contains(locales, li)) continue;
        const r = d.relative;
        // Not ago or in_future: "in" and its kin are everyday words.
        for ([_][]const []const u8{
            r.last,    r.next,    r.this,  r.now,  r.today, r.yesterday, r.tomorrow,
            r.seconds, r.minutes, r.hours, r.days, r.weeks, r.months,    r.years,
        }) |list| {
            for (list) |e| {
                if (e.len == w.len and std.ascii.eqlIgnoreCase(w, e)) return true;
            }
        }
    }
    return false;
}

const DateTime = @import("DateTime.zig");
const ambiguity = @import("ambiguity.zig");

test {
    std.testing.refAllDecls(@This());
}

/// The set holding the locale tagged tag, or a skip when the build left it out.
fn localeSet(tag: []const u8) !locale.LocaleSet {
    return locale.only(locale.lookup(tag) orelse return error.SkipZigTest);
}

fn parseIn(s: []const u8, locales: locale.LocaleSet) !struct { name: []const u8, time: DateTime } {
    const r = detect.detect(s, .{ .locales = locales }) orelse return error.NotDetected;
    const fields = r.def.fields();
    const year: i32 = if (compile.needsBaseYear(fields)) 2026 else 0;
    const p = try compile.compile(fields, .{ .base_year = year, .locales = locales });
    return .{ .name = r.def.name, .time = try p.execute(s) };
}

test "detectTextual names every pattern" {
    const Case = struct { []const u8, ?[]const u8 };
    const cases = [_]Case{
        .{ "March 15, 2024", "MONTH_DAY_YEAR" },
        .{ "Mar 15, 2024", "MONTH_DAY_YEAR" },
        .{ "January 1, 2000", "MONTH_DAY_YEAR" },
        .{ "15 March 2024", "DAY_MONTH_YEAR" },
        .{ "15 Mar 2024", "DAY_MONTH_YEAR" },
        .{ "1 January 2020", "DAY_MONTH_YEAR" },
        .{ "March 2024", "MONTH_YEAR" },
        .{ "March 15", "MONTH_DAY" },
        .{ "December 25", "MONTH_DAY" },
        .{ "15 March", "DAY_MONTH" },
        .{ "1 January", "DAY_MONTH" },
        .{ "Fri, 15 Mar 2024 10:30:00 +0000", "DAY_MONTH_YEAR" },
        .{ "Mar 15, 2024 10:30:00", "MONTH_DAY_YEAR" },
        .{ "december 25th at 5pm", null }, // natural language
        .{ "2024-03-15", null }, // no month name
    };
    for (cases) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        const r = detectTextual(c[0], .{});
        if (c[1]) |want| {
            try std.testing.expectEqualStrings(want, r.?.def.name);
        } else {
            try std.testing.expectEqual(null, r);
        }
    }
}

test "findMonthName" {
    const Case = struct { []const u8, ?u8 };
    for ([_]Case{
        .{ "march 15, 2024", 3 },
        .{ "15 jan 2024", 1 },
        .{ "december 31, 1999", 12 },
        .{ "sep 1, 2020", 9 },
        .{ "sept. 1, 2020", 9 },
        .{ "MAY10", 5 },
        .{ "no month here", null },
        .{ "marching band", null }, // not a whole word
    }) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        const f = findMonthName(c[0], .{});
        try std.testing.expectEqual(c[1], if (f) |x| x.month else null);
    }
}

test "a month name past the signature's 64 bytes is still found" {
    var buf: [200]u8 = undefined;
    for ([_]usize{ 0, 63, 64, 65, 100 }) |pad| {
        errdefer std.debug.print("pad {d}\n", .{pad});
        @memset(buf[0..pad], ' ');
        const date = "March 15, 2024";
        @memcpy(buf[pad..][0..date.len], date);
        const r = detect.detect(buf[0 .. pad + date.len], .{}).?;
        try std.testing.expectEqualStrings("MONTH_DAY_YEAR", r.def.name);
    }
}

test "an ordinal suffix ends the day-or-year question" {
    for ([_][]const u8{ "March 15th", "MAY 15th", "15th March", "December 25th", "March 1st" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        const r = detect.detect(s, .{}).?;
        try std.testing.expect(!r.ambiguous() and !r.prone);
    }
    for ([_][]const u8{ "March 15", "MAY 15", "15 March", "December 25" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expect(detect.detect(s, .{}).?.ambiguous());
    }
}

test "a second month name is refused, not chosen" {
    const es = try localeSet("es");
    const it = try localeSet("it");
    const ko = try localeSet("ko");
    const Case = struct { []const u8, locale.LocaleSet, bool };
    const cases = [_]Case{
        .{ "MAY1MAR", .{}, false },
        .{ "mAY1MAr", .{}, false },
        .{ "mar 1 september 2024", .{}, false },
        .{ "March 15, 2024 May", .{}, false },
        .{ "1 may march", .{}, false },
        .{ "mar 15 mag 2024", it, false }, // martedi against maggio
        .{ "mar 15 maggio 2024", it, false },
        .{ "mar, 15 mar 2024", es, true }, // martes and marzo share "mar"
        .{ "mar 15 mar 2024", es, true },
        .{ "Fri, 15 Mar 2024 10:30:00 +0000", .{}, true },
        .{ "sept. 1, 2020", .{}, true },
        .{ "the 15th of March 2024", .{}, true },
        .{ "invoice 15 March 2024 paid", .{}, true },
        .{ "15 Mar 2024", .{}, true },
        .{ "March 15, 2024", .{}, true },
        .{ "2024년 11월 11일", ko, true }, // 1월 inside 11월 overlaps it
    };
    for (cases) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        try std.testing.expectEqual(c[2], detectTextual(c[0], .{ .locales = c[1] }) != null);
    }
}

test "a rival needs a different month outside the one found" {
    const es = try localeSet("es");
    const Case = struct { []const u8, locale.LocaleSet, bool };
    for ([_]Case{
        .{ "MAY1MAR", .{}, true },
        .{ "march 15 may", .{}, true },
        .{ "march 15 mar", .{}, false },
        .{ "mar, 15 mar 2024", es, false },
        .{ "15 March 2024", .{}, false },
        .{ "Fri, 15 Mar 2024", .{}, false },
        .{ "sept. 1, 2020", .{}, false },
    }) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        try std.testing.expectEqual(c[2], findMonthName(c[0], c[1]).?.rival);
    }
}

test "no spelling names two months" {
    var seen: usize = 0;
    var lower_a: [64]u8 = undefined;
    var lower_b: [64]u8 = undefined;
    const lists = [_][]const Spelling{&english} ++ locale_spellings;
    for (lists) |list_a| for (list_a) |a| {
        seen += 1;
        for (lists) |list_b| for (list_b) |b| {
            if (a.month == b.month or a.name.len != b.name.len) continue;
            const x = std.ascii.lowerString(&lower_a, a.name);
            const y = std.ascii.lowerString(&lower_b, b.name);
            if (std.mem.eql(u8, x, y)) {
                std.debug.print("\"{s}\" names month {d} and {d}\n", .{ a.name, a.month, b.month });
                return error.TestUnexpectedResult;
            }
        };
    };
    try std.testing.expect(seen >= 24);
}

test "a skipped word that decides the day refuses the input" {
    for ([_][]const u8{
        "first monday of march 2024",
        "third thursday of november 2024",
        "last friday in march 2024",
        "last day of february 2024",
        "end of march 2024",
        "Last modified: March 15, 2024",
        "On Wed 8 March in the year 2020",
        "this March 15, 2024",
        "next March 15, 2024",
        "beginning of March 2024",
        "March 15, 2024 morning",
        "March 15, 2024 midnight",
        "half of March 2024",
        "yesterday March 15, 2024",
        "a week from March 15, 2024",
    }) |s| {
        if (detect.detect(s, .{})) |r| {
            std.debug.print("\"{s}\" detected as {s}\n", .{ s, r.def.name });
            return error.TestUnexpectedResult;
        }
    }
}

test "the words a format needs are kept" {
    for ([_][]const u8{
        "Fri, 15 Mar 2024 10:30:00 +0000",
        "Fri Mar 15 10:30:00 UTC 2024",
        "Friday, 15-Mar-24 10:30:00 UTC",
        "the 3rd of March 2024",
        "15th of March 2024",
        "March 15, 2024 at 10:30",
        "15/Mar/2024:10:30:00 +0000",
        "invoice 15 March 2024 paid",
        "2014年04月08日",
    }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        try std.testing.expect(detect.detect(s, .{}) != null);
    }
}

test "a configured locale's relative words refuse too" {
    const fr = try localeSet("fr");
    try std.testing.expectEqual(null, detect.detect("dernier 15 mars 2024", .{ .locales = fr }));
    try std.testing.expect(detect.detect("15 mars 2024", .{ .locales = fr }) != null);
    try std.testing.expect(detect.detect("viime 15 mars 2024", .{ .locales = fr }) != null);

    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "es", "último 15 marzo 2024" },
        .{ "pt", "última 15 março 2024" },
        .{ "es", "próximo 15 marzo 2024" },
        .{ "de", "nächsten 15 März 2024" },
    }) |c| {
        // A case whose locale the build left out is skipped, not the test.
        const set = localeSet(c[0]) catch continue;
        errdefer std.debug.print("{s}: \"{s}\"\n", .{ c[0], c[1] });
        try std.testing.expectEqual(null, detect.detect(c[1], .{ .locales = set }));
        const date = c[1][std.mem.indexOfScalar(u8, c[1], ' ').? + 1 ..];
        try std.testing.expect(detect.detect(date, .{ .locales = set }) != null);
    }
}

test "wordCarriesMeaning" {
    const en = try localeSet("en");
    const Case = struct { []const u8, bool };
    for ([_]Case{
        .{ "first", true },
        .{ "FIRST", true },
        .{ "First", true },
        .{ "firstly", false },
        .{ "last", true },
        .{ "of", false },
        .{ "at", false },
        .{ "the", false },
        .{ "fri", false },
        .{ "march", false },
        .{ "", false },
        .{ "日", false },
        .{ "abcdefghijklmnopqrstuvwxyz", false },
    }) |c| {
        errdefer std.debug.print("\"{s}\"\n", .{c[0]});
        try std.testing.expectEqual(c[1], wordCarriesMeaning(c[0], en));
    }
    for (meaning_words.keys()) |w| try std.testing.expect(w.len <= max_meaning_word);
}

fn when(y: i32, mo: u8, d: u8, h: u8, mi: u8, s: u8, offset: i32) DateTime {
    return .{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi, .second = s, .offset_seconds = offset };
}

test "textual dates, end to end" {
    const Case = struct { []const u8, []const u8, DateTime };
    const cases = [_]Case{
        .{ "March 15, 2024", "", when(2024, 3, 15, 0, 0, 0, 0) },
        .{ "15 Mar 2024", "", when(2024, 3, 15, 0, 0, 0, 0) },
        .{ "Fri, 15 Mar 2024 10:30:00 +0000", "", when(2024, 3, 15, 10, 30, 0, 0) },
        .{ "Sat, 03 Feb 2024 11:45:00 GMT", "", when(2024, 2, 3, 11, 45, 0, 0) },
        .{ "Mon Jan 2 15:04:05 2006", "", when(2006, 1, 2, 15, 4, 5, 0) },
        .{ "Fri Jul 03 2015 18:04:07 GMT+0100", "", when(2015, 7, 3, 18, 4, 7, 3600) },
        .{ "Fri Mar 15 10:30:00 UTC 2024", "", when(2024, 3, 15, 10, 30, 0, 0) },
        .{ "Friday, 15-Mar-24 10:30:00 UTC", "", when(2024, 3, 15, 10, 30, 0, 0) },
        .{ "15/Mar/2024:10:30:00 +0000", "", when(2024, 3, 15, 10, 30, 0, 0) },
        .{ "September 17, 2012 at 10:09am", "", when(2012, 9, 17, 10, 9, 0, 0) },
        .{ "sept. 1, 2020", "", when(2020, 9, 1, 0, 0, 0, 0) },
        .{ "the 15th of March 2024", "", when(2024, 3, 15, 0, 0, 0, 0) },
        .{ "December 23rd", "", when(2026, 12, 23, 0, 0, 0, 0) },
        .{ "March 15", "", when(2026, 3, 15, 0, 0, 0, 0) },
        .{ "March 2024", "", when(2024, 3, 1, 0, 0, 0, 0) },
        .{ "MAY70", "", when(1970, 5, 1, 0, 0, 0, 0) },
        .{ "01MAY10", "", when(2010, 5, 1, 0, 0, 0, 0) },
        .{ "May 10, 24", "", when(2010, 5, 24, 0, 0, 0, 0) },
        .{ "15 März 2024", "de", when(2024, 3, 15, 0, 0, 0, 0) },
        .{ "15 марта 2024", "ru", when(2024, 3, 15, 0, 0, 0, 0) },
        .{ "2024년 11월 11일", "ko", when(2024, 11, 11, 0, 0, 0, 0) },
    };
    for (cases) |c| {
        const set: locale.LocaleSet = if (c[1].len == 0) .{} else localeSet(c[1]) catch continue;
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        try std.testing.expectEqual(c[2], (try parseIn(c[0], set)).time);
    }
}

test "a layout detected in German reads German, and only as detection would" {
    const de = try localeSet("de");
    const r = detect.detect("15 März 2024", .{ .locales = de }).?;
    const p = try compile.compile(r.def.fields(), .{ .locales = de });
    try std.testing.expectEqual(when(2025, 3, 20, 0, 0, 0, 0), try p.execute("20 März 2025"));
    try std.testing.expectEqual(when(2025, 3, 20, 0, 0, 0, 0), try p.execute("20 MäRZ 2025"));
    // Same width, another month: a mismatch is a refusal, never another month.
    try std.testing.expectError(error.NoMatch, p.execute("20 April 2025"));
    // Detection folds ASCII only, so the layout does too (DESIGN divergence 7).
    try std.testing.expectError(error.NoMatch, p.execute("20 MÄRZ 2025"));
    try std.testing.expectEqual(null, detect.detect("20 MÄRZ 2025", .{ .locales = de }));
    // Without German configured the layout does not read it either.
    const plain = try compile.compile(r.def.fields(), .{});
    try std.testing.expectError(error.NoMatch, plain.execute("20 März 2025"));
}

test "a month name and a bare number offer both readings" {
    const Case = struct { []const u8, [2][]const u8 };
    for ([_]Case{
        .{ "March 15", .{ "MONTH_DAY", "MONTH_YEAR" } },
        .{ "15 March", .{ "DAY_MONTH", "YEAR_MONTH" } },
        .{ "MAY15", .{ "MONTH_DAY", "MONTH_YEAR" } },
        .{ "01MAY10", .{ "DAY_MONTH_YEAR", "YEAR_MONTH_DAY" } },
        // Go reads the 10 as the year here: 2010-05-24, then May 10, 2024.
        .{ "May 10, 24", .{ "MONTH_YEAR_DAY", "MONTH_DAY_YEAR" } },
    }) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        const r = detect.detect(c[0], .{}).?;
        try std.testing.expectEqual(detect.Ambiguity.day_or_year, r.ambiguity);
        const rs = ambiguity.readings(&r);
        try std.testing.expectEqual(2, rs.len);
        try std.testing.expectEqualStrings(c[1][0], rs.slice()[0].label);
        try std.testing.expectEqualStrings(c[1][1], rs.slice()[1].label);
    }
    // The alternative reads the other date: "01MAY10" as the 10th of May 2001.
    const r = detect.detect("01MAY10", .{}).?;
    const alt = ambiguity.readings(&r).slice()[1];
    const p = try compile.compile(alt.def.fields(), .{});
    try std.testing.expectEqual(when(2001, 5, 10, 0, 0, 0, 0), try p.execute("01MAY10"));
}

test "a textual date that needed no guess offers no readings" {
    for ([_][]const u8{
        "March 15, 2024", "March 2024",   "March 32",                        "MAY70",   "March 5",
        "March 15th",     "15th March",   "70MAY1",                          "70MAY10", "70-MAY-01",
        "01MAY2010",      "May 10, 2024", "Fri, 15 Mar 2024 10:30:00 +0000",
    }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        const r = detect.detect(s, .{}).?;
        try std.testing.expectEqual(detect.Ambiguity.none, r.ambiguity);
        try std.testing.expectEqual(0, ambiguity.readings(&r).len);
    }
}

test "trimSpace trims what Go's strings.TrimSpace trims" {
    try std.testing.expectEqualStrings("x", trimSpace(" \t\u{a0}x\u{3000}\n"));
    try std.testing.expectEqualStrings("x\u{a0}y", trimSpace("x\u{a0}y"));
    try std.testing.expectEqualStrings("", trimSpace(" \u{2009} "));
    try std.testing.expectEqualStrings("\xffx", trimSpace(" \xffx"));
    // A broken tail is U+FFFD to Go, which is not space, so trimming stops.
    // Each of these once decoded a sequence its lead byte does not start.
    try std.testing.expectEqualStrings("x\x7f\x84", trimSpace("x\x7f\x84 "));
    try std.testing.expectEqualStrings("a\x80", trimSpace("a\x80"));
    try std.testing.expectEqualStrings("\xe0\x80", trimSpace("\xe0\x80"));
    try std.testing.expectEqualStrings("x\xe2\x80\x83\x80", trimSpace("x\xe2\x80\x83\x80"));
    try std.testing.expectEqualStrings("\x80\x80\x80\x80\x80", trimSpace("\x80\x80\x80\x80\x80"));
    // A lone byte is not the code point of the same number: 0x85 is not NEL.
    try std.testing.expectEqualStrings("\x85", trimSpace("\x85"));
    try std.testing.expectEqualStrings("\xa0", trimSpace("\xa0 "));
}
test "the word matcher finds what scanning finds" {
    // Go's TestWordMatcherAgreesWithScanning: every spelling of every
    // compiled locale against every golden input, and the shapes that broke
    // drafts of Go's matcher.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inputs: std.ArrayList([]const u8) = .empty;
    try inputs.appendSlice(a, &.{
        "",           "2024-03-15",       "sept. 1, 2020", "x sept.y",
        "sept sept.", "SEPT.",            "sept.1",        "MAY10",
        "10MAY",      "mAy 1 mar",
        "15 März 2024",
        "15 MÄRZ",
        "1월 11월",
        "2024年3月15日",
        "févr. 2024",
        "mai.",       "Fri, 15 Mar 2024", "mar, 15 mar",   "\xffmay\xff",
        "may\x00",
    });
    // Over word_cap words, where every spelling scans.
    var long: std.ArrayList(u8) = .empty;
    for (0..60) |_| try long.appendSlice(a, "a ");
    try long.appendSlice(a, "Sept. 3");
    try inputs.append(a, long.items);
    var lines = std.mem.splitScalar(u8, @import("golden_corpus").text, '\n');
    var buf: [4096]u8 = undefined;
    while (lines.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        const quoted = row[0 .. std.mem.indexOfScalar(u8, row, '\t') orelse row.len];
        try inputs.append(a, try a.dupe(u8, try @import("golden_test.zig").unquote(&buf, quoted)));
    }

    var checked: usize = 0;
    for (inputs.items) |s| {
        var m: WordMatcher = undefined;
        m.init(s);
        const tables = [_][]const Spelling{&english} ++ locale_spellings;
        for (tables) |table| for (table) |*sp| {
            const want = matchWord(s, sp.name);
            const got = if (m.admits(sp)) m.find(sp) else null;
            std.testing.expectEqual(want, got) catch |err| {
                std.debug.print("\"{f}\" spelling \"{s}\"\n", .{ std.zig.fmtString(s), sp.name });
                return err;
            };
            checked += 1;
        };
    }
    try std.testing.expect(checked > 100_000);
}

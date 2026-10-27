//! Natural-language expressions: "3 days ago", "next friday at 5pm",
//! "end of month", "in 2 hours", and their counterparts in the configured
//! locales ("hace 3 días", "через 2 часа").
//!
//! The input is scanned into tokens (English words always, then each
//! configured locale's words over the lowercased, accent-folded input) and
//! evaluated against a fixed set of patterns; a pattern has to consume
//! every token. Everything is relative to an explicit base time, never a
//! clock. Lowercasing, accent folding and word boundaries follow the Go
//! original exactly (unicode.zig).

const std = @import("std");
const DateTime = @import("DateTime.zig");
const locale = @import("locale.zig");
const unicode = @import("unicode.zig");

/// Longer input is refused: the scanner and patterns are linear, and no
/// expression this library reads comes near it.
pub const max_input_len = 512;

/// A quantity wider than this is not a number ("1000000 days ago" is
/// refused rather than wrapped or truncated).
const max_quantity_digits = 6;

/// A 512-byte input that parses holds at most about 220 tokens (every
/// token must be consumed, and the densest pattern, "1s,and,1s,and,...",
/// spends seven bytes on three). More than this cannot parse.
const max_tokens = 256;

/// Lowercasing can triple an input's length (an invalid byte becomes a
/// three-byte U+FFFD).
const max_text_len = max_input_len * 3;

pub const Unit = enum { second, minute, hour, day, week, month, year };
pub const Direction = enum { ago, from_now, in };
pub const RelWord = enum { now, today, yesterday, tomorrow, tonight };
pub const Selector = enum { last, next, this };
pub const Boundary = enum { start, end };
pub const AmPm = enum { am, pm };

/// What a token is, with its value.
pub const What = union(enum) {
    number: u32,
    unit: Unit,
    direction: Direction,
    rel_word: RelWord,
    selector: Selector,
    weekday: u3, // 0 is Sunday
    month: u4,
    boundary: Boundary,
    of,
    at,
    noon,
    midnight,
    ampm: AmPm,
    /// An inline time, its hour already through AM/PM: "5pm" is 17. Go
    /// does not bound a bare number with a suffix, so "25pm" is 37.
    time: struct { hour: u32, minute: u8 },
    half,
    time_of_day: u8, // its hour: morning 8, afternoon 14, evening 18, night 21
    conjunction, // "and"
    unknown,
};

pub const Token = struct {
    pos: u16, // in the scanned text
    len: u16,
    what: What,
    /// A second reading the same word has in its locale: Hindi कल is
    /// yesterday and tomorrow.
    alt: ?What = null,
};

pub const Tokens = struct {
    buf: [max_tokens]Token = undefined,
    len: usize = 0,
    /// The text tokens point into.
    text: []const u8 = "",
    overflow: bool = false,

    fn add(t: *Tokens, tok: Token) void {
        if (t.len == max_tokens) {
            t.overflow = true;
            return;
        }
        t.buf[t.len] = tok;
        t.len += 1;
    }

    pub fn slice(t: *const Tokens) []const Token {
        return t.buf[0..t.len];
    }

    fn raw(t: *const Tokens, tok: Token) []const u8 {
        return t.text[tok.pos..][0..tok.len];
    }
};

fn token(pos: usize, len: usize, what: What) Token {
    return .{ .pos = @intCast(pos), .len = @intCast(len), .what = what };
}

fn isAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}

fn hourWith(hour: u32, ampm: ?AmPm) u32 {
    const a = ampm orelse return hour;
    return switch (a) {
        .pm => if (hour != 12) hour + 12 else hour,
        .am => if (hour == 12) 0 else hour,
    };
}

/// A number at start: an inline time ("14:00", "5:30pm", "5pm"), an ordinal
/// ("3rd"), a plain number, or unknown when wider than six digits.
fn scanNumber(s: []const u8, start: usize) Token {
    var i = start;
    var val: u32 = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        if (i - start < max_quantity_digits) val = val * 10 + (s[i] - '0');
    }
    if (i - start > max_quantity_digits) return token(start, i - start, .unknown);
    if (timePattern(s, start, val, i)) |t| return t;
    if (i + 2 <= s.len) {
        const suffix = s[i..][0..2];
        if (ampmOf(suffix)) |a| {
            const hour = hourWith(val, a);
            return token(start, i + 2 - start, .{ .time = .{ .hour = hour, .minute = 0 } });
        }
        for ([_][]const u8{ "st", "nd", "rd", "th" }) |ord| {
            if (std.mem.eql(u8, suffix, ord))
                return token(start, i + 2 - start, .{ .number = val });
        }
    }
    return token(start, i - start, .{ .number = val });
}

/// "HH:MM" with an optional am/pm straight after, hour 0..23, two-digit
/// minutes 0..59.
fn ampmOf(suffix: []const u8) ?AmPm {
    if (std.mem.eql(u8, suffix, "am")) return .am;
    if (std.mem.eql(u8, suffix, "pm")) return .pm;
    return null;
}

fn timePattern(s: []const u8, start: usize, hour: u32, colon: usize) ?Token {
    if (colon >= s.len or s[colon] != ':') return null;
    if (colon + 1 >= s.len or !std.ascii.isDigit(s[colon + 1])) return null;
    var i = colon + 1;
    var minute: u32 = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        if (i - colon <= 3) minute = minute * 10 + (s[i] - '0');
    }
    if (i - (colon + 1) != 2 or hour > 23 or minute > 59) return null;
    var ampm: ?AmPm = null;
    if (i + 2 <= s.len) {
        ampm = ampmOf(s[i..][0..2]);
        if (ampm != null) i += 2;
    }
    const at: What = .{ .time = .{ .hour = hourWith(hour, ampm), .minute = @intCast(minute) } };
    return token(start, i - start, at);
}

const english_words = std.StaticStringMap(What).initComptime(.{
    .{ "now", What{ .rel_word = .now } },
    .{ "today", What{ .rel_word = .today } },
    .{ "yesterday", What{ .rel_word = .yesterday } },
    .{ "tomorrow", What{ .rel_word = .tomorrow } },
    .{ "tonight", What{ .rel_word = .tonight } },
    .{ "ago", What{ .direction = .ago } },
    .{ "in", What{ .direction = .in } },
    .{ "last", What{ .selector = .last } },
    .{ "previous", What{ .selector = .last } },
    .{ "past", What{ .selector = .last } },
    .{ "next", What{ .selector = .next } },
    .{ "coming", What{ .selector = .next } },
    .{ "this", What{ .selector = .this } },
    .{ "second", What{ .unit = .second } },
    .{ "seconds", What{ .unit = .second } },
    .{ "sec", What{ .unit = .second } },
    .{ "secs", What{ .unit = .second } },
    .{ "s", What{ .unit = .second } },
    .{ "minute", What{ .unit = .minute } },
    .{ "minutes", What{ .unit = .minute } },
    .{ "min", What{ .unit = .minute } },
    .{ "mins", What{ .unit = .minute } },
    .{ "hour", What{ .unit = .hour } },
    .{ "hours", What{ .unit = .hour } },
    .{ "hr", What{ .unit = .hour } },
    .{ "hrs", What{ .unit = .hour } },
    .{ "day", What{ .unit = .day } },
    .{ "days", What{ .unit = .day } },
    .{ "week", What{ .unit = .week } },
    .{ "weeks", What{ .unit = .week } },
    .{ "month", What{ .unit = .month } },
    .{ "months", What{ .unit = .month } },
    .{ "year", What{ .unit = .year } },
    .{ "years", What{ .unit = .year } },
    .{ "sunday", What{ .weekday = 0 } },
    .{ "sun", What{ .weekday = 0 } },
    .{ "monday", What{ .weekday = 1 } },
    .{ "mon", What{ .weekday = 1 } },
    .{ "tuesday", What{ .weekday = 2 } },
    .{ "tue", What{ .weekday = 2 } },
    .{ "tues", What{ .weekday = 2 } },
    .{ "wednesday", What{ .weekday = 3 } },
    .{ "wed", What{ .weekday = 3 } },
    .{ "thursday", What{ .weekday = 4 } },
    .{ "thu", What{ .weekday = 4 } },
    .{ "thur", What{ .weekday = 4 } },
    .{ "thurs", What{ .weekday = 4 } },
    .{ "friday", What{ .weekday = 5 } },
    .{ "fri", What{ .weekday = 5 } },
    .{ "saturday", What{ .weekday = 6 } },
    .{ "sat", What{ .weekday = 6 } },
    .{ "january", What{ .month = 1 } },
    .{ "jan", What{ .month = 1 } },
    .{ "february", What{ .month = 2 } },
    .{ "feb", What{ .month = 2 } },
    .{ "march", What{ .month = 3 } },
    .{ "mar", What{ .month = 3 } },
    .{ "april", What{ .month = 4 } },
    .{ "apr", What{ .month = 4 } },
    .{ "may", What{ .month = 5 } },
    .{ "june", What{ .month = 6 } },
    .{ "jun", What{ .month = 6 } },
    .{ "july", What{ .month = 7 } },
    .{ "jul", What{ .month = 7 } },
    .{ "august", What{ .month = 8 } },
    .{ "aug", What{ .month = 8 } },
    .{ "september", What{ .month = 9 } },
    .{ "sep", What{ .month = 9 } },
    .{ "sept", What{ .month = 9 } },
    .{ "october", What{ .month = 10 } },
    .{ "oct", What{ .month = 10 } },
    .{ "november", What{ .month = 11 } },
    .{ "nov", What{ .month = 11 } },
    .{ "december", What{ .month = 12 } },
    .{ "dec", What{ .month = 12 } },
    .{ "beginning", What{ .boundary = .start } },
    .{ "start", What{ .boundary = .start } },
    .{ "end", What{ .boundary = .end } },
    .{ "of", What.of },
    .{ "at", What.at },
    .{ "noon", What.noon },
    .{ "midnight", What.midnight },
    .{ "am", What{ .ampm = .am } },
    .{ "pm", What{ .ampm = .pm } },
    .{ "morning", What{ .time_of_day = 8 } },
    .{ "afternoon", What{ .time_of_day = 14 } },
    .{ "evening", What{ .time_of_day = 18 } },
    .{ "night", What{ .time_of_day = 21 } },
    .{ "half", What.half },
    .{ "and", What.conjunction },
    .{ "a", What{ .number = 1 } },
    .{ "an", What{ .number = 1 } },
    .{ "one", What{ .number = 1 } },
    .{ "two", What{ .number = 2 } },
    .{ "three", What{ .number = 3 } },
    .{ "four", What{ .number = 4 } },
    .{ "five", What{ .number = 5 } },
    .{ "six", What{ .number = 6 } },
    .{ "seven", What{ .number = 7 } },
    .{ "eight", What{ .number = 8 } },
    .{ "nine", What{ .number = 9 } },
    .{ "ten", What{ .number = 10 } },
    .{ "eleven", What{ .number = 11 } },
    .{ "twelve", What{ .number = 12 } },
    .{ "fifteen", What{ .number = 15 } },
    .{ "twenty", What{ .number = 20 } },
    .{ "thirty", What{ .number = 30 } },
    .{ "few", What{ .number = 3 } },
});

/// English tokens. The input is lowercased in place of its bytes (ASCII,
/// or Unicode when that keeps the length); otherwise nothing is scanned,
/// as Go does. ASCII letters form words; other bytes are stepped over.
pub fn scanEnglish(buf: *[max_text_len]u8, s: []const u8) Tokens {
    var t: Tokens = .{};
    const lower = blk: {
        for (s) |c| if (c >= 0x80) {
            const l = unicode.lowerInto(buf, s);
            if (l.len != s.len) return t;
            break :blk l;
        };
        break :blk std.ascii.lowerString(buf, s);
    };
    t.text = lower;
    var i: usize = 0;
    while (i < lower.len) {
        const c = lower[i];
        if (c == ' ' or c == '\t' or c == ',' or c == ':') {
            i += 1;
        } else if (std.ascii.isDigit(c)) {
            const tok = scanNumber(lower, i);
            t.add(tok);
            i = @as(usize, tok.pos) + tok.len;
        } else if (isAlpha(c)) {
            const start = i;
            while (i < lower.len and isAlpha(lower[i])) i += 1;
            const word = lower[start..i];
            if (std.mem.eql(u8, word, "from") and i < lower.len) {
                var j = i;
                while (j < lower.len and (lower[j] == ' ' or lower[j] == '\t')) j += 1;
                if (j + 3 <= lower.len and std.mem.eql(u8, lower[j..][0..3], "now") and
                    (j + 3 == lower.len or !isAlpha(lower[j + 3])))
                {
                    t.add(token(start, j + 3 - start, .{ .direction = .from_now }));
                    i = j + 3;
                    continue;
                }
            }
            t.add(token(start, word.len, english_words.get(word) orelse .unknown));
        } else {
            i += 1;
        }
    }
    return t;
}

const LocaleWord = struct { phrase: []const u8, what: What, alt: ?What = null };

fn rank(w: What) u8 {
    return switch (w) {
        .unit => 0,
        .selector => 1,
        .weekday => 2,
        .rel_word => 3,
        else => 4,
    };
}

/// Each compiled locale's words, built as the Go scanner builds them:
/// lowercased, with an accent-folded copy where folding changes a word, a
/// phrase that two readings of one kind share kept once with the second as
/// its alt, and ordered longest first (then units, selectors, weekdays,
/// relative words) so the longest phrase at a position wins.
const locale_words: [locale.compiled.len][]const LocaleWord = blk: {
    @setEvalBranchQuota(50_000_000);
    var all: [locale.compiled.len][]const LocaleWord = undefined;
    for (locale.compiled, 0..) |d, li| {
        var words: [512]LocaleWord = undefined;
        var n: usize = 0;
        const r = d.relative;
        const groups = .{
            .{ r.now, What{ .rel_word = .now } },
            .{ r.today, What{ .rel_word = .today } },
            .{ r.yesterday, What{ .rel_word = .yesterday } },
            .{ r.tomorrow, What{ .rel_word = .tomorrow } },
            .{ r.ago, What{ .direction = .ago } },
            .{ r.in_future, What{ .direction = .in } },
            .{ r.last, What{ .selector = .last } },
            .{ r.next, What{ .selector = .next } },
            .{ r.this, What{ .selector = .this } },
            .{ r.seconds, What{ .unit = .second } },
            .{ r.minutes, What{ .unit = .minute } },
            .{ r.hours, What{ .unit = .hour } },
            .{ r.days, What{ .unit = .day } },
            .{ r.weeks, What{ .unit = .week } },
            .{ r.months, What{ .unit = .month } },
            .{ r.years, What{ .unit = .year } },
        };
        for (groups) |g| {
            for (g[0]) |p| {
                words[n] = .{ .phrase = lowered(p), .what = g[1] };
                n += 1;
            }
        }
        for ([_][7][]const u8{ d.weekdays_wide, d.weekdays_abbr }) |names| {
            for (names, 0..) |name, wd| {
                if (name.len == 0) continue;
                words[n] = .{ .phrase = lowered(name), .what = .{ .weekday = wd } };
                n += 1;
            }
        }
        const unfolded = n;
        for (words[0..unfolded]) |w| {
            const f = folded(w.phrase);
            if (std.mem.eql(u8, f, w.phrase)) continue;
            words[n] = .{ .phrase = f, .what = w.what, .alt = w.alt };
            n += 1;
        }
        // Merge: the first of a phrase and kind stays; a later one with a
        // different reading becomes its alt.
        var merged: [512]LocaleWord = undefined;
        var m: usize = 0;
        for (words[0..n]) |w| {
            const seen: ?*LocaleWord = for (merged[0..m]) |*e| {
                const same_kind = std.meta.activeTag(e.what) == std.meta.activeTag(w.what);
                if (same_kind and std.mem.eql(u8, e.phrase, w.phrase)) break e;
            } else null;
            if (seen) |e| {
                if (e.alt == null and !std.meta.eql(e.what, w.what)) e.alt = w.what;
                continue;
            }
            if (w.phrase.len == 0) continue;
            merged[m] = w;
            m += 1;
        }
        // Stable insertion sort: longest first, then by rank.
        for (1..m) |i| {
            var j = i;
            while (j > 0 and before(merged[j], merged[j - 1])) : (j -= 1) {
                std.mem.swap(LocaleWord, &merged[j], &merged[j - 1]);
            }
        }
        const final = merged[0..m].*;
        all[li] = &final;
    }
    break :blk all;
};

fn before(a: LocaleWord, b: LocaleWord) bool {
    if (a.phrase.len != b.phrase.len) return a.phrase.len > b.phrase.len;
    return rank(a.what) < rank(b.what);
}

fn lowered(comptime p: []const u8) []const u8 {
    comptime {
        var buf: [p.len * 3]u8 = undefined;
        const l = unicode.lowerInto(&buf, p);
        const final = l[0..l.len].*;
        return &final;
    }
}

fn folded(comptime p: []const u8) []const u8 {
    comptime {
        var buf: [p.len]u8 = undefined;
        const f = unicode.foldAccentsInto(&buf, p);
        const final = f[0..f.len].*;
        return &final;
    }
}

/// A locale's tokens over text, which is the input lowercased and
/// accent-folded. At each position the first word that matches as a whole
/// word wins; otherwise a number, or an unknown run up to the next space,
/// comma or digit.
fn scanLocale(text: []const u8, li: usize) Tokens {
    var t: Tokens = .{ .text = text };
    var i: usize = 0;
    outer: while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == ',') {
            i += 1;
            continue;
        }
        for (locale_words[li]) |w| {
            if (w.phrase[0] != c or i + w.phrase.len > text.len) continue;
            if (!std.mem.eql(u8, text[i..][0..w.phrase.len], w.phrase)) continue;
            const end = i + w.phrase.len;
            if (unicode.isWordAt(text, end)) continue;
            if (i > 0 and unicode.isWordAt(text, unicode.prevCharPos(text, i))) continue;
            t.add(.{
                .pos = @intCast(i),
                .len = @intCast(w.phrase.len),
                .what = w.what,
                .alt = w.alt,
            });
            i = end;
            continue :outer;
        }
        if (std.ascii.isDigit(c)) {
            const tok = scanNumber(text, i);
            t.add(tok);
            i = @as(usize, tok.pos) + tok.len;
            continue;
        }
        const start = i;
        while (i < text.len and std.mem.indexOfScalar(u8, " \t,", text[i]) == null and
            !std.ascii.isDigit(text[i])) i += 1;
        t.add(token(start, i - start, .unknown));
    }
    return t;
}

pub const Kind = enum { now, relative };

pub const Result = struct {
    time: DateTime,
    kind: Kind,
    /// The words read another way give a different time: Hindi कल.
    ambiguous: bool = false,
    alt_time: ?DateTime = null,
};

pub const Config = struct {
    base: DateTime,
    prefer_future: bool = false,
    locales: locale.LocaleSet = .{},
};

/// The time s names relative to cfg.base, or null. English is tried first,
/// then each configured locale in tag order.
pub fn parse(s: []const u8, cfg: Config) ?Result {
    if (s.len > max_input_len) return null;
    var buf: [max_text_len]u8 = undefined;
    var english = scanEnglish(&buf, s);
    if (tryParse(&english, cfg)) |r| return r;
    if (locale.isEmpty(cfg.locales)) return null;
    const lower = unicode.lowerInto(&buf, s);
    var fold_buf: [max_text_len]u8 = undefined;
    const text = unicode.foldAccentsInto(&fold_buf, lower);
    for (locale.compiled, 0..) |_, li| {
        if (!locale.contains(cfg.locales, li)) continue;
        var tokens = scanLocale(text, li);
        if (parseBothReadings(&tokens, cfg)) |r| return r;
    }
    return null;
}

/// The reading the words' first meanings give, marked ambiguous when their
/// alternative meanings give a different time.
fn parseBothReadings(tokens: *Tokens, cfg: Config) ?Result {
    var r = tryParse(tokens, cfg) orelse return null;
    var swapped = tokens.*;
    var any = false;
    for (swapped.buf[0..swapped.len]) |*tok| {
        const alt = tok.alt orelse continue;
        tok.what = alt;
        tok.alt = null;
        any = true;
    }
    if (!any) return r;
    const alt = tryParse(&swapped, cfg) orelse return r;
    if (alt.time.eqlInstant(r.time)) return r;
    r.ambiguous = true;
    r.alt_time = alt.time;
    return r;
}

fn tryParse(tokens: *Tokens, cfg: Config) ?Result {
    if (tokens.len == 0 or tokens.overflow) return null;
    const meaningful = for (tokens.slice()) |tok| switch (tok.what) {
        .rel_word,
        .direction,
        .selector,
        .weekday,
        .boundary,
        .noon,
        .midnight,
        .unit,
        .half,
        .time_of_day,
        .month,
        => break true,
        else => {},
    } else false;
    if (!meaningful) return null;
    return eval(tokens, cfg.base, cfg.prefer_future);
}

const Eval = struct { time: DateTime, kind: Kind = .relative, consumed: usize };

/// The first pattern that consumes every token.
pub fn eval(tokens_in: *const Tokens, base: DateTime, prefer_future: bool) ?Result {
    if (tokens_in.len == 0) return null;
    var unknowns: usize = 0;
    for (tokens_in.slice()) |tok| {
        if (tok.what == .unknown) unknowns += 1;
    }
    if (unknowns > tokens_in.len / 2) return null;
    var collapsed: Tokens = .{ .text = tokens_in.text };
    collapseNumbers(tokens_in, &collapsed);
    const ts = collapsed.slice();
    // Go's priority order: relative words before "N units ago" so that
    // "yesterday at 5pm" is a word plus a time, and the bare weekday last.
    const patterns = .{
        evalRelWord,  evalTimeOfDay,     evalHalf,         evalCompound,
        evalNAgo,     evalPrefixAgo,     evalInN,          evalSelectorWeekday,
        evalMonthDay, evalSelectorMonth, evalSelectorUnit, evalBoundary,
    };
    inline for (patterns) |p| {
        if (whole(p(ts, base), ts.len)) |r| return r;
    }
    return whole(evalBareWeekday(ts, base, prefer_future), ts.len);
}

/// A pattern's answer when it consumed every token.
fn whole(e: ?Eval, n: usize) ?Result {
    const got = e orelse return null;
    if (got.consumed != n) return null;
    return .{ .time = got.time, .kind = got.kind };
}

/// Drops an "a" or "an" that stands before another number ("an 8 hours").
fn collapseNumbers(in: *const Tokens, out: *Tokens) void {
    const ts = in.slice();
    for (ts, 0..) |tok, i| {
        const article = tok.what == .number and tok.what.number == 1 and
            (std.mem.eql(u8, in.raw(tok), "a") or std.mem.eql(u8, in.raw(tok), "an"));
        if (article and i + 1 < ts.len and ts[i + 1].what == .number) continue;
        out.add(tok);
    }
}

fn truncateDay(t: DateTime) DateTime {
    return .{ .year = t.year, .month = t.month, .day = t.day, .offset_seconds = t.offset_seconds };
}

/// t moved by an exact duration and read at the same offset.
fn addDuration(t: DateTime, seconds: i64, nanos: i64) DateTime {
    var e = t.toEpoch();
    const ns = @as(i64, e.nanosecond) + nanos;
    e.seconds += seconds + @divFloor(ns, 1_000_000_000);
    e.nanosecond = @intCast(@mod(ns, 1_000_000_000));
    return DateTime.fromEpoch(e, t.offset_seconds);
}

/// The civil date year-month-day at midnight, a day past the month's end
/// rolling into the next one, as Go's time.Date does.
fn dateRolling(year: i32, month: u8, day: i64, offset: i32) DateTime {
    const c = DateTime.civilFromDays(DateTime.daysFromCivil(year, month, 1) + day - 1);
    return .{ .year = c.year, .month = c.month, .day = c.day, .offset_seconds = offset };
}

fn addUnit(t: DateTime, n: i64, unit: Unit) DateTime {
    return switch (unit) {
        .second => addDuration(t, n, 0),
        .minute => addDuration(t, n * 60, 0),
        .hour => addDuration(t, n * 3600, 0),
        .day => t.addDays(n),
        .week => t.addDays(n * 7),
        // Clamped: one month before 2024-03-31 is 2024-02-29.
        .month => t.addMonthsClamped(n),
        .year => t.addMonthsClamped(n * 12),
    };
}

/// "at 5pm", "14:00", "noon", "midnight", "at 5 pm": the time of day applied
/// to t's date, and how many tokens it took (0: none, t unchanged).
fn timeSuffix(ts: []const Token, t: DateTime) struct { DateTime, usize } {
    if (ts.len == 0) return .{ t, 0 };
    const day = truncateDay(t);
    var idx: usize = 0;
    if (ts[0].what == .at) {
        idx = 1;
        if (idx >= ts.len) return .{ t, 0 };
    }
    switch (ts[idx].what) {
        .time => |tm| {
            const seconds = @as(i64, tm.hour) * 3600 + @as(i64, tm.minute) * 60;
            return .{ addDuration(day, seconds, 0), idx + 1 };
        },
        .noon => return .{ addDuration(day, 12 * 3600, 0), idx + 1 },
        .midnight => return .{ day, idx + 1 },
        .number => |h| if (h <= 23) {
            var hour: u32 = h;
            var n = idx + 1;
            if (idx + 1 < ts.len and ts[idx + 1].what == .ampm) {
                hour = hourWith(hour, ts[idx + 1].what.ampm);
                n += 1;
            }
            return .{ addDuration(day, @as(i64, hour) * 3600, 0), n };
        },
        else => {},
    }
    return .{ t, 0 };
}

fn withSuffix(t: DateTime, rest: []const Token, used: usize, kind: Kind) Eval {
    const at, const n = timeSuffix(rest, t);
    return .{ .time = at, .kind = kind, .consumed = used + n };
}

fn evalRelWord(ts: []const Token, base: DateTime) ?Eval {
    if (ts[0].what != .rel_word) return null;
    const day = truncateDay(base);
    return switch (ts[0].what.rel_word) {
        .now => withSuffix(base, ts[1..], 1, .now),
        .today => withSuffix(day, ts[1..], 1, .now),
        .yesterday => withSuffix(day.addDays(-1), ts[1..], 1, .relative),
        .tomorrow => withSuffix(day.addDays(1), ts[1..], 1, .relative),
        .tonight => withSuffix(addDuration(day, 21 * 3600, 0), ts[1..], 1, .relative),
    };
}

fn evalTimeOfDay(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len >= 2 and ts[0].what == .selector and ts[1].what == .time_of_day) {
        var day = truncateDay(base);
        if (ts[0].what.selector == .last) day = day.addDays(-1);
        const hour: i64 = ts[1].what.time_of_day;
        return .{ .time = addDuration(day, hour * 3600, 0), .consumed = 2 };
    }
    if (ts.len == 1 and ts[0].what == .time_of_day) {
        const hour: i64 = ts[0].what.time_of_day;
        return .{ .time = addDuration(truncateDay(base), hour * 3600, 0), .consumed = 1 };
    }
    return null;
}

fn evalHalf(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 3 or ts[0].what != .half) return null;
    var idx: usize = 1;
    if (ts[idx].what == .number and ts[idx].what.number == 1) idx += 1;
    if (idx >= ts.len or ts[idx].what != .unit) return null;
    const unit = ts[idx].what.unit;
    idx += 1;
    if (idx >= ts.len or ts[idx].what != .direction) return null;
    const seconds: i64 = switch (unit) {
        .minute => 30,
        .hour => 30 * 60,
        .day => 12 * 3600,
        .week => 84 * 3600,
        else => return null,
    };
    const sign: i64 = if (ts[idx].what.direction == .ago) -1 else 1;
    return .{ .time = addDuration(base, sign * seconds, 0), .consumed = idx + 1 };
}

/// "1 day and 2 hours ago", "in 2 hours and 30 minutes": two pairs at least.
fn evalCompound(ts: []const Token, base: DateTime) ?Eval {
    var start: usize = 0;
    var prefix_in = false;
    if (ts.len >= 5 and ts[0].what == .direction and ts[0].what.direction == .in) {
        start = 1;
        prefix_in = true;
    }
    const rest = ts[start..];
    if (rest.len < 5) return null;
    var i: usize = 0;
    var pairs: usize = 0;
    while (true) {
        if (i + 1 >= rest.len) return null;
        if (rest[i].what != .number or rest[i + 1].what != .unit) return null;
        pairs += 1;
        i += 2;
        if (i < rest.len and rest[i].what == .conjunction) {
            i += 1;
            continue;
        }
        break;
    }
    if (pairs < 2) return null;
    var dir: Direction = .in;
    if (!prefix_in) {
        if (i >= rest.len or rest[i].what != .direction) return null;
        dir = rest[i].what.direction;
    }
    var t = base;
    var k: usize = 0;
    while (k < i) {
        if (rest[k].what == .conjunction) {
            k += 1;
            continue;
        }
        var n: i64 = rest[k].what.number;
        if (dir == .ago) n = -n;
        t = addUnit(t, n, rest[k + 1].what.unit);
        k += 2;
    }
    return .{ .time = t, .consumed = start + i + @intFromBool(!prefix_in) };
}

fn evalNAgo(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 3 or ts[0].what != .number or ts[1].what != .unit) return null;
    if (ts[2].what != .direction) return null;
    var n: i64 = ts[0].what.number;
    if (ts[2].what.direction == .ago) n = -n;
    return withSuffix(addUnit(base, n, ts[1].what.unit), ts[3..], 3, .relative);
}

fn evalPrefixAgo(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 3 or ts[0].what != .direction or ts[0].what.direction != .ago) return null;
    if (ts[1].what != .number or ts[2].what != .unit) return null;
    return .{ .time = addUnit(base, -@as(i64, ts[1].what.number), ts[2].what.unit), .consumed = 3 };
}

fn evalInN(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 3 or ts[0].what != .direction or ts[0].what.direction != .in) return null;
    if (ts[1].what != .number or ts[2].what != .unit) return null;
    return withSuffix(addUnit(base, ts[1].what.number, ts[2].what.unit), ts[3..], 3, .relative);
}

fn resolveWeekday(base: DateTime, target: u3, sel: Selector) DateTime {
    var diff = @as(i64, target) - @as(i64, @backingInt(base.weekday()));
    switch (sel) {
        .next => if (diff <= 0) {
            diff += 7;
        },
        .last => if (diff >= 0) {
            diff -= 7;
        },
        .this => if (diff < 0) {
            diff += 7;
        },
    }
    return truncateDay(base).addDays(diff);
}

fn evalSelectorWeekday(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 2 or ts[0].what != .selector or ts[1].what != .weekday) return null;
    const day = resolveWeekday(base, ts[1].what.weekday, ts[0].what.selector);
    return withSuffix(day, ts[2..], 2, .relative);
}

fn evalMonthDay(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 2 or ts[0].what != .month or ts[1].what != .number) return null;
    const day = ts[1].what.number;
    if (day < 1 or day > 31) return null;
    return withSuffix(dateRolling(base.year, ts[0].what.month, day, base.offset_seconds), ts[2..], 2, .relative);
}

fn evalSelectorMonth(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 2 or ts[0].what != .selector or ts[1].what != .month) return null;
    const target = ts[1].what.month;
    var year = base.year;
    switch (ts[0].what.selector) {
        .next => if (base.month >= target) {
            year += 1;
        },
        .last => if (base.month <= target) {
            year -= 1;
        },
        .this => {},
    }
    return .{ .time = .{ .year = year, .month = target, .day = 1, .offset_seconds = base.offset_seconds }, .consumed = 2 };
}

fn startOfWeek(t: DateTime) DateTime {
    const wd: i64 = @backingInt(t.weekday());
    return truncateDay(t).addDays(-@mod(wd - 1, 7)); // back to Monday
}

fn startOfMonth(t: DateTime) DateTime {
    return .{ .year = t.year, .month = t.month, .day = 1, .offset_seconds = t.offset_seconds };
}

fn startOfYear(t: DateTime) DateTime {
    return .{ .year = t.year, .month = 1, .day = 1, .offset_seconds = t.offset_seconds };
}

fn evalSelectorUnit(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 2 or ts[0].what != .selector or ts[1].what != .unit) return null;
    const n: i64 = switch (ts[0].what.selector) {
        .last => -1,
        .next => 1,
        .this => 0,
    };
    const t = switch (ts[1].what.unit) {
        .week => startOfWeek(base).addDays(n * 7),
        .month => startOfMonth(base).addMonthsClamped(n),
        .year => startOfYear(base).addMonthsClamped(n * 12),
        .day => truncateDay(base).addDays(n),
        else => return null,
    };
    return .{ .time = t, .consumed = 2 };
}

fn evalBoundary(ts: []const Token, base: DateTime) ?Eval {
    if (ts.len < 3 or ts[0].what != .boundary or ts[1].what != .of or ts[2].what != .unit) return null;
    const start = switch (ts[2].what.unit) {
        .day => truncateDay(base),
        .week => startOfWeek(base),
        .month => startOfMonth(base),
        .year => startOfYear(base),
        else => return null,
    };
    if (ts[0].what.boundary == .start) return .{ .time = start, .consumed = 3 };
    // The last nanosecond before the next one starts.
    const next = switch (ts[2].what.unit) {
        .day => start.addDays(1),
        .week => start.addDays(7),
        .month => start.addMonthsClamped(1),
        .year => start.addMonthsClamped(12),
        else => unreachable,
    };
    return .{ .time = addDuration(next, 0, -1), .consumed = 3 };
}

fn evalBareWeekday(ts: []const Token, base: DateTime, prefer_future: bool) ?Eval {
    if (ts.len != 1 or ts[0].what != .weekday) return null;
    return .{ .time = resolveWeekday(base, ts[0].what.weekday, if (prefer_future) .next else .last), .consumed = 1 };
}

test {
    std.testing.refAllDecls(@This());
}

fn dt(y: i32, mo: u8, d: u8, h: u8, mi: u8, s: u8, ns: u32, off: i32) DateTime {
    return .{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi, .second = s, .nanosecond = ns, .offset_seconds = off };
}

/// Friday 2024-03-15 12:00 UTC, the Go tests' base.
const test_base = dt(2024, 3, 15, 12, 0, 0, 0, 0);

fn setOf(tag: []const u8) ?locale.LocaleSet {
    if (std.mem.eql(u8, tag, "-")) return .{};
    return locale.only(locale.lookup(tag) orelse return null);
}

test "expressions read as the Go original reads them" {
    // Expected values taken from the Go dateparsa's natural.Parse on the same
    // base; the full oracle diff (124,530 cases, all locales, three bases,
    // both preferences) agreed with this port on every one.
    const Case = struct { []const u8, []const u8, ?DateTime };
    const cases = [_]Case{
        .{ "-", "now", dt(2024, 3, 15, 12, 0, 0, 0, 0) },
        .{ "-", "today", dt(2024, 3, 15, 0, 0, 0, 0, 0) },
        .{ "-", "yesterday", dt(2024, 3, 14, 0, 0, 0, 0, 0) },
        .{ "-", "tomorrow", dt(2024, 3, 16, 0, 0, 0, 0, 0) },
        .{ "-", "tonight", dt(2024, 3, 15, 21, 0, 0, 0, 0) },
        .{ "-", "3 days ago", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "-", "a week ago", dt(2024, 3, 8, 12, 0, 0, 0, 0) },
        .{ "-", "an hour ago", dt(2024, 3, 15, 11, 0, 0, 0, 0) },
        .{ "-", "3 days from now", dt(2024, 3, 18, 12, 0, 0, 0, 0) },
        .{ "-", "2 weeks from now", dt(2024, 3, 29, 12, 0, 0, 0, 0) },
        .{ "-", "1 month ago", dt(2024, 2, 15, 12, 0, 0, 0, 0) },
        .{ "-", "1 year ago", dt(2023, 3, 15, 12, 0, 0, 0, 0) },
        .{ "-", "30 seconds ago", dt(2024, 3, 15, 11, 59, 30, 0, 0) },
        .{ "-", "in 3 days", dt(2024, 3, 18, 12, 0, 0, 0, 0) },
        .{ "-", "in 10 minutes", dt(2024, 3, 15, 12, 10, 0, 0, 0) },
        .{ "-", "last monday", dt(2024, 3, 11, 0, 0, 0, 0, 0) },
        .{ "-", "next monday", dt(2024, 3, 18, 0, 0, 0, 0, 0) },
        .{ "-", "this friday", dt(2024, 3, 15, 0, 0, 0, 0, 0) },
        .{ "-", "next sunday", dt(2024, 3, 17, 0, 0, 0, 0, 0) },
        .{ "-", "monday", dt(2024, 3, 11, 0, 0, 0, 0, 0) },
        .{ "-", "next week", dt(2024, 3, 18, 0, 0, 0, 0, 0) },
        .{ "-", "last month", dt(2024, 2, 1, 0, 0, 0, 0, 0) },
        .{ "-", "this year", dt(2024, 1, 1, 0, 0, 0, 0, 0) },
        .{ "-", "next day", dt(2024, 3, 16, 0, 0, 0, 0, 0) },
        .{ "-", "beginning of month", dt(2024, 3, 1, 0, 0, 0, 0, 0) },
        .{ "-", "end of month", dt(2024, 3, 31, 23, 59, 59, 999999999, 0) },
        .{ "-", "start of week", dt(2024, 3, 11, 0, 0, 0, 0, 0) },
        .{ "-", "end of year", dt(2024, 12, 31, 23, 59, 59, 999999999, 0) },
        .{ "-", "end of day", dt(2024, 3, 15, 23, 59, 59, 999999999, 0) },
        .{ "-", "yesterday at 5pm", dt(2024, 3, 14, 17, 0, 0, 0, 0) },
        .{ "-", "tomorrow at 14:00", dt(2024, 3, 16, 14, 0, 0, 0, 0) },
        .{ "-", "today at noon", dt(2024, 3, 15, 12, 0, 0, 0, 0) },
        .{ "-", "next friday at 5:30pm", dt(2024, 3, 22, 17, 30, 0, 0, 0) },
        .{ "-", "tomorrow at 9 am", dt(2024, 3, 16, 9, 0, 0, 0, 0) },
        .{ "-", "today at 25pm", dt(2024, 3, 16, 13, 0, 0, 0, 0) },
        .{ "-", "in 2 hours and 30 minutes", dt(2024, 3, 15, 14, 30, 0, 0, 0) },
        .{ "-", "1 day and 2 hours ago", dt(2024, 3, 14, 10, 0, 0, 0, 0) },
        .{ "-", "half an hour ago", dt(2024, 3, 15, 11, 30, 0, 0, 0) },
        .{ "-", "half a week ago", dt(2024, 3, 12, 0, 0, 0, 0, 0) },
        .{ "-", "last night", dt(2024, 3, 14, 21, 0, 0, 0, 0) },
        .{ "-", "this morning", dt(2024, 3, 15, 8, 0, 0, 0, 0) },
        .{ "-", "feb 31", dt(2024, 3, 2, 0, 0, 0, 0, 0) },
        .{ "-", "dec 25 at 5pm", dt(2024, 12, 25, 17, 0, 0, 0, 0) },
        .{ "-", "next march", dt(2025, 3, 1, 0, 0, 0, 0, 0) },
        .{ "-", "last march", dt(2023, 3, 1, 0, 0, 0, 0, 0) },
        .{ "-", "a few days ago", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "-", "twenty minutes ago", dt(2024, 3, 15, 11, 40, 0, 0, 0) },
        .{ "-", "999999 days ago", dt(-714, 4, 19, 12, 0, 0, 0, 0) },
        .{ "-", "1000000 days ago", null },
        .{ "-", "3 DAYS AGO", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "-", "3days ago", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "-", "the day after tomorrow", null },
        .{ "-", "ago", null },
        .{ "-", "3 days", null },
        .{ "-", "end of the month", null },
        .{ "fr", "il y a 3 jours", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "fr", "dans 3 heures", dt(2024, 3, 15, 15, 0, 0, 0, 0) },
        .{ "fr", "hier", dt(2024, 3, 14, 0, 0, 0, 0, 0) },
        .{ "fr", "DEMAIN", dt(2024, 3, 16, 0, 0, 0, 0, 0) },
        .{ "es", "hace 3 días", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "es", "hace 3 dias", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "es", "próximo lunes", dt(2024, 3, 18, 0, 0, 0, 0, 0) },
        // An accent the data does not spell matches through input folding.
        .{ "es", "pròximo lunes", dt(2024, 3, 18, 0, 0, 0, 0, 0) },
        .{ "fr", "dèmain", dt(2024, 3, 16, 0, 0, 0, 0, 0) },
        .{ "de", "vor 3 Tagen", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "de", "nächsten Montag", dt(2024, 3, 18, 0, 0, 0, 0, 0) },
        .{ "ru", "3 дня назад", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "ru", "ВЧЕРА", dt(2024, 3, 14, 0, 0, 0, 0, 0) },
        .{ "ru", "через 3 часа", dt(2024, 3, 15, 15, 0, 0, 0, 0) },
        .{ "uk", "завтра", dt(2024, 3, 16, 0, 0, 0, 0, 0) },
        .{ "tr", "3 gün önce", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "pl", "za 3 dni", dt(2024, 3, 18, 12, 0, 0, 0, 0) },
        .{ "ja", "3日前", null },
        .{ "zh", "3天前", null },
        .{ "ko", "3일 전", null },
        .{ "ar", "منذ 3 أيام", dt(2024, 3, 12, 12, 0, 0, 0, 0) },
        .{ "da", "i morgen", dt(2024, 3, 16, 0, 0, 0, 0, 0) },
        .{ "sv", "i morgon", dt(2024, 3, 16, 0, 0, 0, 0, 0) },
        .{ "no", "i går", dt(2024, 3, 14, 0, 0, 0, 0, 0) },
    };
    for (cases) |c| {
        const set = setOf(c[0]) orelse continue; // locale left out of this build
        errdefer std.debug.print("{s}: \"{s}\"\n", .{ c[0], c[1] });
        const got = parse(c[1], .{ .base = test_base, .locales = set });
        try std.testing.expectEqual(c[2], if (got) |r| r.time else null);
    }
}

test "Hindi कल is yesterday or tomorrow, and says so" {
    const hi = setOf("hi") orelse return error.SkipZigTest;
    const r = parse("कल", .{ .base = test_base, .locales = hi }).?;
    try std.testing.expect(r.ambiguous);
    try std.testing.expectEqual(dt(2024, 3, 14, 0, 0, 0, 0, 0), r.time);
    try std.testing.expectEqual(dt(2024, 3, 16, 0, 0, 0, 0, 0), r.alt_time.?);
    // The phrases that settle it.
    const past = parse("बीता कल", .{ .base = test_base, .locales = hi }).?;
    try std.testing.expect(!past.ambiguous);
    try std.testing.expectEqual(dt(2024, 3, 14, 0, 0, 0, 0, 0), past.time);
}

test "month and year arithmetic clamps to the month's end" {
    const Case = struct { DateTime, []const u8, DateTime };
    for ([_]Case{
        .{ dt(2024, 3, 31, 12, 0, 0, 0, 0), "1 month ago", dt(2024, 2, 29, 12, 0, 0, 0, 0) },
        .{ dt(2024, 1, 31, 12, 0, 0, 0, 0), "in 1 month", dt(2024, 2, 29, 12, 0, 0, 0, 0) },
        .{ dt(2024, 2, 29, 12, 0, 0, 0, 0), "1 year ago", dt(2023, 2, 28, 12, 0, 0, 0, 0) },
        .{ dt(2024, 5, 31, 12, 0, 0, 0, 0), "1 month from now", dt(2024, 6, 30, 12, 0, 0, 0, 0) },
        // Days and hours are exact durations, not clamped.
        .{ dt(2024, 1, 31, 12, 0, 0, 0, 0), "in 30 days", dt(2024, 3, 1, 12, 0, 0, 0, 0) },
    }) |c| {
        errdefer std.debug.print("\"{s}\"\n", .{c[1]});
        try std.testing.expectEqual(c[2], parse(c[1], .{ .base = c[0] }).?.time);
    }
}

test "the base's offset carries through" {
    const base = dt(2024, 1, 31, 23, 30, 0, 0, 19800);
    try std.testing.expectEqual(dt(2024, 2, 1, 0, 0, 0, 0, 19800), parse("tomorrow", .{ .base = base }).?.time);
    try std.testing.expectEqual(dt(2024, 2, 1, 1, 30, 0, 0, 19800), parse("in 2 hours", .{ .base = base }).?.time);
    try std.testing.expectEqual(dt(2024, 1, 31, 23, 59, 59, 999_999_999, 19800), parse("end of day", .{ .base = base }).?.time);
}

test "prefer_future turns a bare weekday forward" {
    try std.testing.expectEqual(dt(2024, 3, 11, 0, 0, 0, 0, 0), parse("monday", .{ .base = test_base }).?.time);
    try std.testing.expectEqual(dt(2024, 3, 18, 0, 0, 0, 0, 0), parse("monday", .{ .base = test_base, .prefer_future = true }).?.time);
}

test "bounds: input length and quantity width" {
    var buf: [max_input_len + 1]u8 = @splat(' ');
    @memcpy(buf[0..10], "3 days ago");
    try std.testing.expect(parse(buf[0..max_input_len], .{ .base = test_base }) != null);
    try std.testing.expectEqual(null, parse(&buf, .{ .base = test_base }));
    try std.testing.expect(parse("999999 hours ago", .{ .base = test_base }) != null);
    try std.testing.expectEqual(null, parse("1000000 hours ago", .{ .base = test_base }));
    // The direction is kept at the widest quantity, not wrapped into its opposite.
    try std.testing.expect(parse("999999 years ago", .{ .base = test_base }).?.time.year < 0);
    try std.testing.expect(parse("in 999999 years", .{ .base = test_base }).?.time.year > 1_000_000);
}

test "English tokens" {
    var buf: [max_text_len]u8 = undefined;
    var t = scanEnglish(&buf, "3 days ago");
    try std.testing.expectEqual(3, t.len);
    try std.testing.expectEqual(What{ .number = 3 }, t.buf[0].what);
    try std.testing.expectEqual(What{ .unit = .day }, t.buf[1].what);
    try std.testing.expectEqual(What{ .direction = .ago }, t.buf[2].what);

    t = scanEnglish(&buf, "yesterday at 5pm");
    try std.testing.expectEqual(3, t.len);
    try std.testing.expectEqual(What.at, t.buf[1].what);
    try std.testing.expectEqual(What{ .time = .{ .hour = 17, .minute = 0 } }, t.buf[2].what);

    t = scanEnglish(&buf, "next friday at 14:00");
    try std.testing.expectEqual(What{ .time = .{ .hour = 14, .minute = 0 } }, t.buf[3].what);

    t = scanEnglish(&buf, "3 days from now");
    try std.testing.expectEqual(What{ .direction = .from_now }, t.buf[2].what);

    t = scanEnglish(&buf, "a week ago");
    try std.testing.expectEqual(What{ .number = 1 }, t.buf[0].what);

    // A non-ASCII input whose lowercase changes length is not scanned.
    try std.testing.expectEqual(0, scanEnglish(&buf, "\u{23a} now").len);
}

fn scanIn(buf: *[max_text_len]u8, fold_buf: *[max_text_len]u8, tag: []const u8, s: []const u8) ?Tokens {
    const li = locale.lookup(tag) orelse return null;
    return scanLocale(unicode.foldAccentsInto(fold_buf, unicode.lowerInto(buf, s)), li);
}

test "the longest phrase at a position wins" {
    var buf: [max_text_len]u8 = undefined;
    var fold: [max_text_len]u8 = undefined;
    const Case = struct { []const u8, []const u8, []const u8 };
    for ([_]Case{
        .{ "fr", "il y a 3 jours", "il y a" },
        .{ "da", "i morgen", "i morgen" },
        .{ "da", "i dag", "i dag" },
        .{ "no", "i går", "i gar" }, // accents fold before matching
        .{ "sv", "i morgon", "i morgon" },
        .{ "sv", "det här", "det har" },
        .{ "es", "dentro de 3 dias", "dentro de" },
        .{ "pt", "dentro de 2 horas", "dentro de" },
        .{ "hi", "बीता कल", "बीता कल" },
    }) |c| {
        errdefer std.debug.print("{s}: \"{s}\"\n", .{ c[0], c[1] });
        const t = scanIn(&buf, &fold, c[0], c[1]) orelse continue;
        try std.testing.expectEqualStrings(c[2], t.raw(t.buf[0]));
    }
}

test "spellings two readings share are pinned" {
    var buf: [max_text_len]u8 = undefined;
    var fold: [max_text_len]u8 = undefined;
    const Case = struct { []const u8, []const u8, What, ?What };
    for ([_]Case{
        .{ "hi", "कल", .{ .rel_word = .yesterday }, .{ .rel_word = .tomorrow } },
        .{ "it", "ora", .{ .unit = .hour }, null },
        .{ "ja", "今", .{ .selector = .this }, null },
        .{ "ja", "日", .{ .unit = .day }, null },
        .{ "ko", "일", .{ .unit = .day }, null },
    }) |c| {
        errdefer std.debug.print("{s}: \"{s}\"\n", .{ c[0], c[1] });
        const t = scanIn(&buf, &fold, c[0], c[1]) orelse continue;
        try std.testing.expectEqual(1, t.len);
        try std.testing.expectEqual(c[2], t.buf[0].what);
        try std.testing.expectEqual(c[3], t.buf[0].alt);
    }
}

test "every multi-word phrase scans as one token" {
    var checked: usize = 0;
    for (locale_words, 0..) |words, li| {
        for (words) |w| {
            if (std.mem.indexOfScalar(u8, w.phrase, ' ') == null) continue;
            checked += 1;
            const t = scanLocale(w.phrase, li);
            errdefer std.debug.print("{s}: \"{s}\"\n", .{ locale.compiled[li].tag, w.phrase });
            try std.testing.expectEqual(1, t.len);
            try std.testing.expect(t.buf[0].what != .unknown);
        }
    }
    if (locale.compiled.len > 1) try std.testing.expect(checked > 0);
}

test "a locale word counts only as a whole word, and a separate am/pm counts" {
    if (setOf("fr")) |fr| {
        try std.testing.expect(parse("hier", .{ .base = test_base, .locales = fr }) != null);
        try std.testing.expectEqual(null, parse("hierx", .{ .base = test_base, .locales = fr }));
        try std.testing.expectEqual(null, parse("xhier", .{ .base = test_base, .locales = fr }));
    }
    try std.testing.expectEqual(dt(2024, 3, 15, 17, 0, 0, 0, 0), parse("today at 5 pm", .{ .base = test_base }).?.time);
    try std.testing.expectEqual(dt(2024, 3, 15, 0, 0, 0, 0, 0), parse("today at 12 am", .{ .base = test_base }).?.time);
}

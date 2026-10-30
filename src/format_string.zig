//! A layout's format spelled as another tool's format string: strftime (C,
//! Python, pandas, Ruby), Go's reference time, or Java's DateTimeFormatter
//! (Java, Kotlin, Spark). Detect once, then hand the format to whatever
//! reads the column next. And back: read a format string into the fields a
//! layout compiles from, for a column whose format is already known.
//!
//! A layout keeps no input bytes: a separator or a skipped word is held as a
//! byte class ("2024-03-15" and "2024/03/15" share one layout). So the text
//! between fields is read from a value the layout reads, such as the one it
//! was detected from, and the format string spells that value's separators.
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
    /// The layout does not read the value: pass the one it was detected
    /// from.
    NotDetectedFrom,
} || std.Io.Writer.Error;

/// The longest format string write spells; a longer one is refused. A
/// layout read from a format string can hold text past 255 bytes, which
/// Java's quoting doubles.
pub const max_len = 1023;

/// The format l reads, spelled in dialect, into w. value is one l reads,
/// such as the one it was detected from; its separators and words are the
/// ones written. A format read cannot hold (more fields than a layout has,
/// counting each run of text) or longer than max_len is refused, so what
/// is written always reads back.
pub fn write(l: *const Layout, dialect: Dialect, value: []const u8, w: *std.Io.Writer) Error!void {
    var buf: [max_len]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    spell(l, dialect, value, &out) catch |err| return switch (err) {
        error.WriteFailed => error.Unsupported,
        else => |e| e,
    };
    _ = read(dialect, out.buffered()) catch return error.Unsupported;
    try w.writeAll(out.buffered());
}

fn spell(l: *const Layout, dialect: Dialect, value: []const u8, w: *std.Io.Writer) Error!void {
    if (l.source != .program) return error.Unsupported;
    const s = if (l.trims_padding) signature.trimPadding(value) else value;
    // Where each field sits in this value: a field the input decides the
    // width of is wherever the fields before it left it.
    var spans: [compile.max_instructions]compile.Span = undefined;
    _ = l.program.trace(s, &spans) catch return error.NotDetectedFrom;

    const insts = l.program.insts[0..l.program.n];
    var twelve_hour = false;
    var week_date = false;
    for (insts) |inst| switch (inst.op) {
        .ampm => twelve_hour = true,
        .iso_week => week_date = true,
        else => {},
    };

    // Text is held until the next field and written as one run, so a
    // dialect that quotes text quotes it once: 'GMT', where 'G''M''T' is
    // G'M'T to Java.
    var held: Held = .{ .s = s };
    // A format names each field once; a strptime refuses a second %a.
    var weekday_written = false;
    var end: usize = 0;
    for (insts, spans[0..insts.len], 0..) |inst, span, i| {
        if (span.off != end) return error.NotDetectedFrom;
        // A separator fused into a numeric field's instruction is the last
        // byte it read.
        const fused = inst.aux != compile.sep_none and fuses(inst.op);
        const width = span.len - @intFromBool(fused);
        const text = s[span.off..][0..width];
        if (inst.op != .literal and inst.op != .skip) try held.flush(w, dialect);
        switch (inst.op) {
            .literal => held.add(span.off, width),
            .skip => {
                // Text glued to a number's digits is a unit, never a
                // weekday: 年, 月 and 日 in "2014年04月08日" (月 and 日 are
                // also Japanese weekday names), or an ordinal suffix, which
                // no dialect spells.
                const glued = i > 0 and isNumber(insts[i - 1].op) and insts[i - 1].aux == compile.sep_none;
                if (glued and text[0] < 0x80 and std.ascii.isAlphabetic(text[0])) return error.Unsupported;
                // A weekday is a whole word, as a format reads one.
                const after_word = span.off > 0 and compile.isWordChar(s[span.off - 1]);
                const wd = if (!glued) try skipped(text, after_word, l.program.locales) else null;
                if (wd) |day| {
                    if (weekday_written) return error.Unsupported;
                    weekday_written = true;
                    try held.flush(w, dialect);
                    try token(w, dialect, weekdayToken(day.name));
                    held.after_abbr = day.name == .abbr;
                    held.add(span.off + day.len, width - day.len);
                } else held.add(span.off, width);
            },
            .month_name, .month_any => {
                const name = monthName(text);
                try token(w, dialect, switch (name) {
                    .wide => .{ "%B", "January", "MMMM" },
                    .abbr => .{ "%b", "Jan", "MMM" },
                    .wide_foreign => .{ "%B", null, "MMMM" },
                    .abbr_foreign => .{ "%b", null, "MMM" },
                });
                held.after_abbr = name == .abbr;
            },
            .weekday_name => {
                if (weekday_written) return error.Unsupported;
                weekday_written = true;
                const name = weekday(text, l.program.locales) orelse return error.Unsupported;
                try token(w, dialect, weekdayToken(name));
                held.after_abbr = name == .abbr;
            },
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
            .frac_sec, .frac_any => switch (dialect) {
                .strftime => if (width <= 6) try w.writeAll("%f") else return error.Unsupported,
                .go => {
                    // Go's fraction is the digits and the '.' or ',' before.
                    if (span.off == 0 or (s[span.off - 1] != '.' and s[span.off - 1] != ',')) return error.Unsupported;
                    try w.splatByteAll('0', width);
                },
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
            // Go and Java take 'Z' with one offset form; the value says which.
            .tz_any => try token(w, dialect, if (width == 5) .{ "%z", "Z0700", "XX" } else .{ "%z", "Z07:00", "XXX" }),
            .tz_name => {
                const utc = std.mem.eql(u8, text, "UTC") or std.mem.eql(u8, text, "GMT");
                try token(w, dialect, .{ if (utc) "%Z" else null, "MST", "z" });
            },
            .iso_week => try token(w, dialect, .{ "%V", null, null }),
            .iso_week_day => try token(w, dialect, .{ "%u", null, null }),
            .ordinal_day => try token(w, dialect, .{ "%j", "002", "DDD" }),
            .tail, .nop => return error.Unsupported,
        }
        if (fused) held.add(span.off + width, 1);
        end = span.off + span.len;
    }
    if (end != s.len) return error.NotDetectedFrom;
    try held.flush(w, dialect);
}

/// Text between fields not yet written: s[start..end].
const Held = struct {
    s: []const u8,
    start: usize = 0,
    end: usize = 0,
    /// The field before was an English abbreviation, "Jan" or "Mon" to Go,
    /// which Go reads as text before a lower-case letter ("Janet").
    after_abbr: bool = false,

    /// s[off..][0..len], which follows what is held: the fields tile s.
    fn add(h: *Held, off: usize, len: usize) void {
        if (h.end == h.start) h.start = off;
        h.end = off + len;
    }

    fn flush(h: *Held, w: *std.Io.Writer, dialect: Dialect) Error!void {
        defer h.after_abbr = false;
        if (h.end == h.start) return;
        const t = h.s[h.start..h.end];
        if (dialect == .go and h.after_abbr and std.ascii.isLower(t[0])) return error.Unsupported;
        try literal(w, dialect, t);
        h.start = h.end;
    }
};

/// A skipped run's weekday, and the bytes its name takes, or null when the
/// run is text. A weekday name that starts a word is a field, with any
/// punctuation after it as text. GMT or UTC, and text in no Latin letters
/// (the 年, 月 and 日 of "2014年04月08日"), are text, since they do not
/// vary. Any other word is refused: the layout accepts any word of that
/// width there, and a format string holding this one would refuse every
/// row with another.
fn skipped(text: []const u8, after_word: bool, locales: locale.LocaleSet) Error!?struct { name: NameKind, len: usize } {
    var word_end: usize = 0;
    while (word_end < text.len and (std.ascii.isAlphabetic(text[word_end]) or text[word_end] >= 0x80)) word_end += 1;
    const word = text[0..word_end];
    if (word.len > 0 and !after_word) {
        if (weekday(word, locales)) |wd| {
            for (text[word_end..]) |c| if (std.ascii.isAlphabetic(c) or c >= 0x80) return error.Unsupported;
            return .{ .name = wd, .len = word_end };
        }
    }
    const constant = std.mem.eql(u8, word, "GMT") or std.mem.eql(u8, word, "UTC");
    if (!constant) for (text) |c| if (std.ascii.isAlphabetic(c)) return error.Unsupported;
    return null;
}

fn weekdayToken(name: NameKind) [3]?[]const u8 {
    return switch (name) {
        .wide => .{ "%A", "Monday", "EEEE" },
        .abbr => .{ "%a", "Mon", "EEE" },
        .wide_foreign => .{ "%A", null, "EEEE" },
        .abbr_foreign => .{ "%a", null, "EEE" },
    };
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

/// Text between fields, as each dialect takes it literally. A NUL is
/// refused: a C format string ends there.
fn literal(w: *std.Io.Writer, dialect: Dialect, text: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.Unsupported;
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

/// Whether text is a weekday name, wide or abbreviated, in English or a
/// locale of locales, the ones a layout reads a weekday in; null for any
/// other word.
fn weekday(text: []const u8, locales: locale.LocaleSet) ?NameKind {
    const bare = std.mem.trimEnd(u8, text, ".");
    for (english().weekdays_wide) |n| if (std.ascii.eqlIgnoreCase(n, bare)) return .wide;
    for (english().weekdays_abbr) |n| if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, n, "."), bare)) return .abbr;
    for (locale.compiled, 0..) |d, i| {
        if (!locale.contains(locales, i)) continue;
        for (d.weekdays_wide) |n| if (std.ascii.eqlIgnoreCase(n, bare)) return .wide_foreign;
        for (d.weekdays_abbr) |n| if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, n, "."), bare)) return .abbr_foreign;
    }
    return null;
}

pub const ReadError = error{
    /// The format has a field no layout reads: a directive or pattern
    /// letter with no field for it (%c, %U, Go's "4", Java's "w"), a width
    /// a field does not come in, or more fields than a layout holds.
    Unsupported,
    /// The string is not a format a layout can read: a '%' that ends it, an
    /// unclosed quote, a field written twice, a 12-hour hour without AM/PM
    /// or AM/PM without one, a day with no month, an ISO week without its
    /// year, or no date or time field at all.
    InvalidFormat,
};

/// The fields a format string reads, in input order, at the offsets a value
/// with each field at its usual width has them. A field whose width the
/// input decides (%B, %f, %z, a one-or-two-digit month) moves the ones after
/// it when the program runs.
pub const Fields = struct {
    buf: [compile.max_instructions]compile.Field = undefined,
    n: usize = 0,

    pub fn slice(f: *const Fields) []const compile.Field {
        return f.buf[0..f.n];
    }
};

/// The fields format, written in dialect, reads: the inverse of write.
///
/// Each dialect reads as its own parser does, within what a layout holds.
/// A one-or-two-digit field (strftime's %m, %d, %H, %I; Go's 1, 2, 15, 3;
/// Java's M, d, H, h) reads two digits when another number touches it,
/// since a value with no separator cannot say where one stops. A month or
/// weekday name, wide or abbreviated alike, reads any month's or weekday's
/// name in English and the locales the layout is compiled with; a month's
/// abbreviation takes its dot, as detection reads it, and after a weekday's
/// the dot is text, as write spells it. Text between fields is held byte
/// for byte; a run of non-ASCII bytes, as a detected layout holds it, to
/// non-ASCII bytes of its width.
///
/// strftime: %Y %G %y %m %d %e %H %I %M %S %f (one to nine digits) %p %z
/// ('Z', +HH:MM or +HHMM) %Z %a %A %b %B %h %j %V %u %%.
/// Go: 2006 06 01 1 Jan January 02 2 _2 002 15 03 3 04 05 .000 ,000 PM pm
/// MST Z07:00 Z0700 Z07 -07:00 -0700 -07 Mon Monday.
/// Java: yyyy yy uuuu uu MM M MMM MMMM (and L) dd d ppd DDD HH H hh h mm ss
/// S to SSSSSSSSS a E to EEEE X XX XXX x xx xxx z zz zzz, and 'quoted' text.
pub fn read(dialect: Dialect, format: []const u8) ReadError!Fields {
    var t: Tokens = .{};
    switch (dialect) {
        .strftime => try readStrftime(&t, format),
        .go => try readGo(&t, format),
        .java => try readJava(&t, format),
    }
    return t.fields();
}

/// One piece of a format string: a field, or text.
const Token = struct {
    /// literal for text.
    kind: compile.FieldKind,
    /// The width the field usually has, which the next field's offset is
    /// counted from.
    len: u8 = 0,
    text: []const u8 = "",
    /// An hour on a 12-hour clock.
    twelve_hour: bool = false,
    /// strftime's %G: the year an ISO week belongs to.
    iso_year: bool = false,
};

fn field(kind: compile.FieldKind, len: u8) Token {
    return .{ .kind = kind, .len = len };
}

fn textToken(s: []const u8) Token {
    return .{ .kind = .literal, .text = s };
}

/// More than a layout's instructions could ever come from.
const max_tokens = 4 * compile.max_instructions;

const Tokens = struct {
    buf: [max_tokens]Token = undefined,
    n: usize = 0,

    fn add(t: *Tokens, tok: Token) ReadError!void {
        if (tok.kind == .literal and tok.text.len == 0) return;
        if (t.n == max_tokens) return error.Unsupported;
        t.buf[t.n] = tok;
        t.n += 1;
    }

    /// The fields the tokens read, once they are checked to make a date.
    fn fields(t: *Tokens) ReadError!Fields {
        const toks = t.buf[0..t.n];
        try check(toks);
        // A one-or-two-digit field touching another number reads two.
        for (toks, 0..) |*tok, i| {
            const fixed: compile.FieldKind = switch (tok.kind) {
                .month1or2 => .month2,
                .day1or2 => .day2,
                .hour1or2 => if (tok.twelve_hour) .hour12 else .hour24,
                else => continue,
            };
            const before = i > 0 and endsInDigit(toks[i - 1]);
            const after = i + 1 < toks.len and startsWithDigit(toks[i + 1]);
            if (before or after) tok.kind = fixed;
        }
        var out: Fields = .{};
        var off: usize = 0;
        for (toks) |tok| {
            if (tok.kind == .literal) {
                try addText(&out, &off, tok.text);
            } else {
                const aux = if (tok.kind == .hour1or2 and tok.twelve_hour) compile.twelve_hour else 0;
                try addField(&out, .{ .kind = tok.kind, .offset = 0, .len = tok.len, .aux = aux }, off);
                off += tok.len;
            }
        }
        return out;
    }
};

/// What a format may not say: a field twice, AM/PM without a 12-hour hour
/// or one without the other, an ISO week without %G or %G without a week, a
/// week or a day of the year beside a month or a day, a day with no month,
/// or nothing that is a date or a time.
fn check(toks: []const Token) ReadError!void {
    const Role = enum { year, month, day, hour, minute, second, frac, ampm, zone, weekday, week, week_day, year_day };
    var seen: std.EnumSet(Role) = .empty;
    var twelve_hour = false;
    var iso_year = false;
    for (toks) |tok| {
        const role: Role = switch (tok.kind) {
            .literal, .skip => continue,
            .year4, .year2 => .year,
            .month2, .month1or2, .month_name, .month_any => .month,
            .day2, .day1or2, .day_space_pad => .day,
            .hour24, .hour12, .hour1or2 => .hour,
            .minute2 => .minute,
            .second2 => .second,
            .frac_sec, .frac_any => .frac,
            .ampm => .ampm,
            .tz_z, .tz_offset, .tz_name, .tz_z_or_offset, .tz_any => .zone,
            .weekday_name => .weekday,
            .iso_week => .week,
            .iso_week_day => .week_day,
            .ordinal_day => .year_day,
            .tail => return error.Unsupported,
        };
        if (seen.contains(role)) return error.InvalidFormat;
        seen.insert(role);
        if (tok.kind == .hour12 or tok.twelve_hour) twelve_hour = true;
        if (tok.iso_year) iso_year = true;
    }
    const has = struct {
        fn any(set: std.EnumSet(Role), roles: []const Role) bool {
            for (roles) |r| if (set.contains(r)) return true;
            return false;
        }
    }.any;
    if (seen.contains(.ampm) != twelve_hour) return error.InvalidFormat;
    if (seen.contains(.week) != iso_year) return error.InvalidFormat;
    if (seen.contains(.week_day) and !seen.contains(.week)) return error.InvalidFormat;
    if (has(seen, &.{ .week, .year_day }) and has(seen, &.{ .month, .day })) return error.InvalidFormat;
    if (seen.contains(.week) and seen.contains(.year_day)) return error.InvalidFormat;
    if (seen.contains(.day) and !seen.contains(.month)) return error.InvalidFormat;
    if (!has(seen, &.{ .year, .month, .day, .hour, .minute, .second, .frac, .week, .year_day })) return error.InvalidFormat;
}

/// Whether a value's bytes for tok can end in a digit.
fn endsInDigit(tok: Token) bool {
    return switch (tok.kind) {
        .literal => std.ascii.isDigit(tok.text[tok.text.len - 1]),
        .tz_offset, .tz_z_or_offset, .tz_any => true,
        else => startsWithDigit(tok),
    };
}

/// Whether a value's bytes for tok can start with a digit.
fn startsWithDigit(tok: Token) bool {
    return switch (tok.kind) {
        .literal => std.ascii.isDigit(tok.text[0]),
        .year4, .year2, .month2, .month1or2, .day2, .day1or2, .day_space_pad => true,
        .hour24, .hour12, .hour1or2, .minute2, .second2, .frac_sec, .frac_any => true,
        .iso_week, .iso_week_day, .ordinal_day => true,
        else => false,
    };
}

fn addField(out: *Fields, f: compile.Field, off: usize) ReadError!void {
    if (out.n == out.buf.len or off > std.math.maxInt(u8)) return error.Unsupported;
    out.buf[out.n] = f;
    out.buf[out.n].offset = @intCast(off);
    out.n += 1;
}

/// Text, as literal runs of one ASCII byte and skipped runs of non-ASCII
/// bytes, each joined to the run before it when that holds the same.
fn addText(out: *Fields, off: *usize, s: []const u8) ReadError!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        // An exact byte is aux 1..255: there is no aux for a NUL alone.
        if (c == 0) return error.Unsupported;
        const ascii = c < 0x80;
        var n: usize = 1;
        while (i + n < s.len and (if (ascii) s[i + n] == c else s[i + n] >= 0x80)) n += 1;
        const kind: compile.FieldKind = if (ascii) .literal else .skip;
        const aux: u16 = if (ascii) c else compile.auxClass(.nonprinting);
        const last = if (out.n > 0) &out.buf[out.n - 1] else null;
        if (last != null and last.?.kind == kind and last.?.aux == aux and
            @as(usize, last.?.offset) + last.?.len == off.*)
        {
            if (@as(usize, last.?.len) + n > std.math.maxInt(u8)) return error.Unsupported;
            last.?.len += @intCast(n);
        } else {
            if (n > std.math.maxInt(u8)) return error.Unsupported;
            try addField(out, .{ .kind = kind, .offset = 0, .len = @intCast(n), .aux = aux }, off.*);
        }
        off.* += n;
        i += n;
    }
}

fn readStrftime(t: *Tokens, f: []const u8) ReadError!void {
    var i: usize = 0;
    while (i < f.len) {
        if (f[i] != '%') {
            const start = i;
            while (i < f.len and f[i] != '%') i += 1;
            try t.add(textToken(f[start..i]));
            continue;
        }
        if (i + 1 == f.len) return error.InvalidFormat;
        const directive = f[i + 1];
        i += 2;
        try t.add(switch (directive) {
            'Y' => field(.year4, 4),
            'G' => .{ .kind = .year4, .len = 4, .iso_year = true },
            'y' => field(.year2, 2),
            'm' => field(.month1or2, 2),
            'd' => field(.day1or2, 2),
            'e' => field(.day_space_pad, 2),
            'H' => field(.hour1or2, 2),
            'I' => .{ .kind = .hour1or2, .len = 2, .twelve_hour = true },
            'M' => field(.minute2, 2),
            'S' => field(.second2, 2),
            'f' => field(.frac_any, 6),
            'p' => field(.ampm, 2),
            'z' => field(.tz_any, 6),
            'Z' => field(.tz_name, 3),
            'a', 'A' => field(.weekday_name, 3),
            'b', 'B', 'h' => field(.month_any, 3),
            'j' => field(.ordinal_day, 3),
            'V' => field(.iso_week, 2),
            'u' => field(.iso_week_day, 1),
            '%' => textToken("%"),
            else => return error.Unsupported,
        });
    }
}

/// Go's layout elements, found as time.Parse finds them: anything else is
/// text, and Go has no escape for text that would read as an element.
fn readGo(t: *Tokens, f: []const u8) ReadError!void {
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < f.len) {
        const el = try goElement(f[i..]) orelse {
            i += 1;
            continue;
        };
        try t.add(textToken(f[text_start..i]));
        // A fraction's element starts with the '.' or ',' before its digits.
        if (el.token.kind == .frac_sec) try t.add(textToken(f[i..][0..1]));
        try t.add(el.token);
        i += el.len;
        text_start = i;
    }
    try t.add(textToken(f[text_start..]));
}

const GoElement = struct { token: Token, len: usize };

/// The element rest starts with and its length, or null when rest starts
/// with text. error.Unsupported for one no field reads: a one-or-two-digit
/// minute or second ("4", "5"), a space-padded day of the year, a zone with
/// seconds, or a fraction of optional digits (".999").
fn goElement(rest: []const u8) ReadError!?GoElement {
    const starts = struct {
        fn f(s: []const u8, prefix: []const u8) bool {
            return std.mem.startsWith(u8, s, prefix);
        }
    }.f;
    const el = struct {
        fn f(tok: Token, len: usize) ?GoElement {
            return .{ .token = tok, .len = len };
        }
    }.f;
    // "Jan" and "Mon" are text before a lower-case letter: "Janet".
    const lower_after = rest.len > 3 and std.ascii.isLower(rest[3]);
    switch (rest[0]) {
        'J' => {
            if (starts(rest, "January")) return el(field(.month_any, 3), 7);
            if (starts(rest, "Jan") and !lower_after) return el(field(.month_any, 3), 3);
        },
        'M' => {
            if (starts(rest, "Monday")) return el(field(.weekday_name, 3), 6);
            if (starts(rest, "Mon") and !lower_after) return el(field(.weekday_name, 3), 3);
            if (starts(rest, "MST")) return el(field(.tz_name, 3), 3);
        },
        '0' => if (rest.len >= 2) switch (rest[1]) {
            '1' => return el(field(.month2, 2), 2),
            '2' => return el(field(.day2, 2), 2),
            '3' => return el(.{ .kind = .hour12, .len = 2, .twelve_hour = true }, 2),
            '4' => return el(field(.minute2, 2), 2),
            '5' => return el(field(.second2, 2), 2),
            '6' => return el(field(.year2, 2), 2),
            '0' => if (starts(rest, "002")) return el(field(.ordinal_day, 3), 3),
            else => {},
        },
        '1' => {
            if (starts(rest, "15")) return el(field(.hour1or2, 2), 2);
            return el(field(.month1or2, 2), 1);
        },
        '2' => {
            if (starts(rest, "2006")) return el(field(.year4, 4), 4);
            return el(field(.day1or2, 2), 1);
        },
        '_' => {
            // "_2006" is text, then the year.
            if (starts(rest, "_2") and !starts(rest, "_2006")) return el(field(.day_space_pad, 2), 2);
            if (starts(rest, "__2")) return error.Unsupported;
        },
        '3' => return el(.{ .kind = .hour1or2, .len = 2, .twelve_hour = true }, 1),
        '4', '5' => return error.Unsupported,
        'P' => if (starts(rest, "PM")) return el(field(.ampm, 2), 2),
        'p' => if (starts(rest, "pm")) return el(field(.ampm, 2), 2),
        '-', 'Z' => {
            if (starts(rest[1..], "070000") or starts(rest[1..], "07:00:00")) return error.Unsupported;
            const kind: compile.FieldKind = if (rest[0] == 'Z') .tz_z_or_offset else .tz_offset;
            if (starts(rest[1..], "0700")) return el(field(kind, 5), 5);
            if (starts(rest[1..], "07:00")) return el(field(kind, 6), 6);
            if (starts(rest[1..], "07")) return el(field(kind, 3), 3);
        },
        '.', ',' => if (rest.len >= 2 and (rest[1] == '0' or rest[1] == '9')) {
            var j: usize = 1;
            while (j < rest.len and rest[j] == rest[1]) j += 1;
            // Only a run that ends the digits is a fraction.
            if (j == rest.len or !std.ascii.isDigit(rest[j])) {
                if (rest[1] == '9' or j - 1 > compile.max_frac_digits) return error.Unsupported;
                return el(field(.frac_sec, @intCast(j - 1)), j);
            }
        },
        else => {},
    }
    return null;
}

/// Java's pattern letters, quoted text and the rest as text. Text Java
/// reserves ('[', ']', '{', '}', '#') and the optional sections it opens
/// are unsupported.
fn readJava(t: *Tokens, f: []const u8) ReadError!void {
    var i: usize = 0;
    var pad: usize = 0;
    while (i < f.len) {
        const c = f[i];
        if (std.ascii.isAlphabetic(c)) {
            var n: usize = 1;
            while (i + n < f.len and f[i + n] == c) n += 1;
            i += n;
            if (c == 'p') {
                if (pad != 0) return error.Unsupported;
                pad = n;
                continue;
            }
            var tok = try javaField(c, n);
            if (pad != 0) {
                // "ppd": a day padded to two with a space.
                if (pad != 2 or tok.kind != .day1or2) return error.Unsupported;
                tok = field(.day_space_pad, 2);
                pad = 0;
            }
            try t.add(tok);
            continue;
        }
        if (pad != 0) return error.Unsupported;
        switch (c) {
            '\'' => {
                // As Java scans it: quoted text runs to a quote that is not
                // one of two, two inside it are a quote, and none ('') is a
                // quote too.
                const start = i + 1;
                var end = start;
                while (end < f.len) : (end += 1) {
                    if (f[end] != '\'') continue;
                    if (end + 1 < f.len and f[end + 1] == '\'') end += 1 else break;
                }
                if (end >= f.len) return error.InvalidFormat;
                if (end == start) try t.add(textToken("'"));
                var it = std.mem.splitSequence(u8, f[start..end], "''");
                var first = true;
                while (it.next()) |piece| : (first = false) {
                    if (!first) try t.add(textToken("'"));
                    try t.add(textToken(piece));
                }
                i = end + 1;
            },
            '[', ']', '{', '}', '#' => return error.Unsupported,
            else => {
                const start = i;
                while (i < f.len and !std.ascii.isAlphabetic(f[i]) and std.mem.indexOfScalar(u8, "'[]{}#", f[i]) == null) i += 1;
                try t.add(textToken(f[start..i]));
            },
        }
    }
    if (pad != 0) return error.Unsupported;
}

/// The field n repeats of Java's pattern letter c read.
fn javaField(c: u8, n: usize) ReadError!Token {
    const unsupported = error.Unsupported;
    return switch (c) {
        'y', 'u' => switch (n) {
            2 => field(.year2, 2),
            4 => field(.year4, 4),
            else => unsupported,
        },
        'M', 'L' => switch (n) {
            1 => field(.month1or2, 2),
            2 => field(.month2, 2),
            3, 4 => field(.month_any, 3),
            else => unsupported,
        },
        'd' => switch (n) {
            1 => field(.day1or2, 2),
            2 => field(.day2, 2),
            else => unsupported,
        },
        'D' => if (n == 3) field(.ordinal_day, 3) else unsupported,
        'H' => switch (n) {
            1 => field(.hour1or2, 2),
            2 => field(.hour24, 2),
            else => unsupported,
        },
        'h' => switch (n) {
            1 => .{ .kind = .hour1or2, .len = 2, .twelve_hour = true },
            2 => .{ .kind = .hour12, .len = 2, .twelve_hour = true },
            else => unsupported,
        },
        'm' => if (n == 2) field(.minute2, 2) else unsupported,
        's' => if (n == 2) field(.second2, 2) else unsupported,
        'S' => if (n <= compile.max_frac_digits) field(.frac_sec, @intCast(n)) else unsupported,
        'a' => if (n == 1) field(.ampm, 2) else unsupported,
        'E' => if (n <= 4) field(.weekday_name, 3) else unsupported,
        'X', 'x' => {
            const kind: compile.FieldKind = if (c == 'X') .tz_z_or_offset else .tz_offset;
            return switch (n) {
                1 => field(kind, 3),
                2 => field(kind, 5),
                3 => field(kind, 6),
                else => unsupported,
            };
        },
        'z' => if (n <= 3) field(.tz_name, 3) else unsupported,
        else => unsupported,
    };
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

test "the value must be one the layout reads" {
    const root = @import("root.zig");
    const r = try root.parse("1/2/2024");
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.NotDetectedFrom, write(&r.layout, .strftime, "2024-01-02", &w));
    // Read at other widths than it was detected at: each field is where
    // reading the value put it.
    try write(&r.layout, .go, "11/12/2024", &w);
    try std.testing.expectEqualStrings("1/2/2006", w.buffered());
    // Padding is trimmed as the layout trims it.
    w.end = 0;
    try write(&r.layout, .go, "  1/2/2024 ", &w);
    try std.testing.expectEqualStrings("1/2/2006", w.buffered());
}

const DateTime = @import("DateTime.zig");

const read_base: DateTime = .{ .year = 2024, .month = 1, .day = 1 };

/// format, read with opts, reads each value to its time.
fn expectReads(dialect: Dialect, format: []const u8, opts: @import("root.zig").Options, cases: []const struct { []const u8, DateTime }) !void {
    errdefer std.debug.print("{t} \"{s}\"\n", .{ dialect, format });
    const l = try Layout.fromFormatString(dialect, format, opts);
    try std.testing.expect(l.reusable());
    for (cases) |c| {
        errdefer std.debug.print("  value \"{s}\"\n", .{c[0]});
        try std.testing.expectEqual(c[1], try l.parse(c[0]));
    }
}

/// format, read with opts, refuses each value.
fn expectRefuses(dialect: Dialect, format: []const u8, opts: @import("root.zig").Options, values: []const []const u8) !void {
    const l = try Layout.fromFormatString(dialect, format, opts);
    for (values) |v| {
        errdefer std.debug.print("{t} \"{s}\" read \"{s}\"\n", .{ dialect, format, v });
        try std.testing.expectError(error.NoMatch, l.parse(v));
    }
}

fn ymd(y: i32, mo: u8, d: u8, h: u8, mi: u8, sec: u8) DateTime {
    return .{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi, .second = sec };
}

test "strftime formats read their values" {
    const opts: @import("root.zig").Options = .{ .base_time = read_base };
    try expectReads(.strftime, "%Y-%m-%d", opts, &.{
        .{ "2024-03-15", ymd(2024, 3, 15, 0, 0, 0) },
        .{ "2024-3-5", ymd(2024, 3, 5, 0, 0, 0) },
        .{ " 2024-03-15\n", ymd(2024, 3, 15, 0, 0, 0) },
    });
    try expectRefuses(.strftime, "%Y-%m-%d", opts, &.{ "2024/03/15", "2024-13-01", "2024-02-30", "24-03-15" });
    // The order is the format's, whatever the first value could have been.
    try expectReads(.strftime, "%d/%m/%Y %H:%M", opts, &.{
        .{ "01/02/2024 10:30", ymd(2024, 2, 1, 10, 30, 0) },
        .{ "13/02/2024 9:05", ymd(2024, 2, 13, 9, 5, 0) },
    });
    try expectRefuses(.strftime, "%d/%m/%Y %H:%M", opts, &.{"02/13/2024 10:30"});
    // Numbers that touch read two digits each.
    try expectReads(.strftime, "%Y%m%d%H%M%S", opts, &.{.{ "20240315103000", ymd(2024, 3, 15, 10, 30, 0) }});
    try expectRefuses(.strftime, "%Y%m%d", opts, &.{ "2024315", "202431" });
    // Any month a name names, wide or abbreviated.
    try expectReads(.strftime, "%B %d, %Y", opts, &.{
        .{ "March 15, 2024", ymd(2024, 3, 15, 0, 0, 0) },
        .{ "April 20, 2024", ymd(2024, 4, 20, 0, 0, 0) },
        .{ "may 1, 2024", ymd(2024, 5, 1, 0, 0, 0) },
        .{ "Sept 3, 2024", ymd(2024, 9, 3, 0, 0, 0) },
    });
    try expectRefuses(.strftime, "%B %d, %Y", opts, &.{ "Marchy 15, 2024", "Mars 15, 2024", "15 March, 2024" });
    try expectReads(.strftime, "%a, %d %b %Y %H:%M:%S %z", opts, &.{
        .{ "Fri, 15 Mar 2024 10:30:00 +0000", ymd(2024, 3, 15, 10, 30, 0) },
        .{ "Wednesday, 20 March 2024 10:30:00 -0700", .{ .year = 2024, .month = 3, .day = 20, .hour = 10, .minute = 30, .offset_seconds = -7 * 3600 } },
        .{ "sat, 16 Mar 2024 11:30:00 +05:30", .{ .year = 2024, .month = 3, .day = 16, .hour = 11, .minute = 30, .offset_seconds = 19800 } },
    });
    try expectRefuses(.strftime, "%a, %d %b %Y %H:%M:%S %z", opts, &.{ "Xyz, 15 Mar 2024 10:30:00 +0000", "Fri, 15 Mar 2024 10:30:00 +05", "Fri, 15 Mar 2024 10:30:00 Z0" });
    try expectReads(.strftime, "%Y-%m-%dT%H:%M:%S.%f%z", opts, &.{
        .{ "2024-03-15T10:30:00.1Z", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .nanosecond = 100_000_000 } },
        .{ "2024-03-15T10:30:00.123456789+0530", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .nanosecond = 123_456_789, .offset_seconds = 19800 } },
    });
    // A tenth digit is refused, not cut.
    try expectRefuses(.strftime, "%Y-%m-%dT%H:%M:%S.%f%z", opts, &.{ "2024-03-15T10:30:00.1234567891Z", "2024-03-15T10:30:00.Z" });
    try expectReads(.strftime, "%I:%M %p", opts, &.{
        .{ "9:30 PM", ymd(2024, 1, 1, 21, 30, 0) },
        .{ "12:05 am", ymd(2024, 1, 1, 0, 5, 0) },
    });
    // A 12-hour clock's hour is 1 to 12, whatever AM or PM says.
    try expectRefuses(.strftime, "%I:%M %p", opts, &.{ "13:30 AM", "0:30 PM", "13:30 PM" });
    try expectReads(.strftime, "%G-W%V-%u", opts, &.{.{ "2024-W11-5", ymd(2024, 3, 15, 0, 0, 0) }});
    try expectReads(.strftime, "%Y-%j", opts, &.{.{ "2024-075", ymd(2024, 3, 15, 0, 0, 0) }});
    try expectReads(.strftime, "%Y年%m月%d日", opts, &.{.{ "2014年4月8日", ymd(2014, 4, 8, 0, 0, 0) }});
    try expectReads(.strftime, "%Y-%m-%d %H:%M:%S %Z", opts, &.{
        .{ "2014-12-16 06:20:00 UTC", ymd(2014, 12, 16, 6, 20, 0) },
        .{ "2014-12-16 06:20:00 EST", .{ .year = 2014, .month = 12, .day = 16, .hour = 6, .minute = 20, .offset_seconds = -5 * 3600 } },
    });
    try expectReads(.strftime, "100%% on %d.%m.%Y", opts, &.{.{ "100% on 15.03.2024", ymd(2024, 3, 15, 0, 0, 0) }});
    // No zone in the format: the options' offset.
    try expectReads(.strftime, "%Y-%m-%d %H:%M", .{ .timezone_offset = 3600 }, &.{
        .{ "2024-03-15 10:30", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .offset_seconds = 3600 } },
    });
}

test "Go layouts read their values" {
    const opts: @import("root.zig").Options = .{ .base_time = read_base };
    try expectReads(.go, "2006-01-02 15:04:05", opts, &.{
        .{ "2024-03-15 10:30:00", ymd(2024, 3, 15, 10, 30, 0) },
        .{ "2024-03-15 9:30:00", ymd(2024, 3, 15, 9, 30, 0) },
    });
    try expectRefuses(.go, "2006-01-02 15:04:05", opts, &.{"2024-3-15 10:30:00"});
    try expectReads(.go, "Jan _2 15:04:05", opts, &.{
        .{ "Mar  5 10:30:00", ymd(2024, 3, 5, 10, 30, 0) },
        .{ "Dec 15 10:30:00", ymd(2024, 12, 15, 10, 30, 0) },
    });
    try expectReads(.go, "Mon, 02 Jan 2006 15:04:05 MST", opts, &.{
        .{ "Fri, 15 Mar 2024 10:30:00 GMT", ymd(2024, 3, 15, 10, 30, 0) },
    });
    try expectReads(.go, "2006-01-02T15:04:05.000Z07:00", opts, &.{
        .{ "2024-03-15T10:30:00.123Z", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .nanosecond = 123_000_000 } },
        .{ "2024-03-15T10:30:00.123+05:30", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .nanosecond = 123_000_000, .offset_seconds = 19800 } },
    });
    try expectReads(.go, "1/2/2006 3:04 PM", opts, &.{
        .{ "3/15/2024 9:05 PM", ymd(2024, 3, 15, 21, 5, 0) },
        .{ "12/1/2024 12:00 AM", ymd(2024, 12, 1, 0, 0, 0) },
    });
    // "Janet" and "Month" are text, and "_2006" is '_' and a year.
    try expectReads(.go, "Janet 2006", opts, &.{.{ "Janet 2024", ymd(2024, 1, 1, 0, 0, 0) }});
    try expectReads(.go, "x_2006-01", opts, &.{.{ "x_2024-03", ymd(2024, 3, 1, 0, 0, 0) }});
}

test "Java patterns read their values" {
    const opts: @import("root.zig").Options = .{ .base_time = read_base };
    try expectReads(.java, "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", opts, &.{
        .{ "2024-03-15T10:30:00.123Z", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .nanosecond = 123_000_000 } },
        .{ "2024-03-15T10:30:00.123-08:00", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .nanosecond = 123_000_000, .offset_seconds = -8 * 3600 } },
    });
    try expectReads(.java, "EEE, d MMM yyyy", opts, &.{
        .{ "Fri, 15 Mar 2024", ymd(2024, 3, 15, 0, 0, 0) },
        .{ "Mon, 1 Apr 2024", ymd(2024, 4, 1, 0, 0, 0) },
    });
    try expectReads(.java, "MMM ppd HH:mm", opts, &.{.{ "Mar  5 10:30", ymd(2024, 3, 5, 10, 30, 0) }});
    try expectReads(.java, "h:mm a", opts, &.{.{ "9:30 PM", ymd(2024, 1, 1, 21, 30, 0) }});
    try expectReads(.java, "dd.MM.yyyy 'um' HH:mm 'Uhr'", opts, &.{.{ "15.03.2024 um 10:30 Uhr", ymd(2024, 3, 15, 10, 30, 0) }});
    try expectReads(.java, "yyyy''MM", opts, &.{.{ "2024'03", ymd(2024, 3, 1, 0, 0, 0) }});
    try expectReads(.java, "'it''s' yyyy", opts, &.{.{ "it's 2024", ymd(2024, 1, 1, 0, 0, 0) }});
    // Found by the fuzzer: '''' is one quote to Java, as formatString writes it.
    try expectReads(.java, "yyyy''''", opts, &.{.{ "2024'", ymd(2024, 1, 1, 0, 0, 0) }});
    try expectReads(.java, "yyyy'''x'''", opts, &.{.{ "2024'x'", ymd(2024, 1, 1, 0, 0, 0) }});
}

test "month and weekday names read in the locales given" {
    const root = @import("root.zig");
    const fr = root.localeSet("fr") orelse return error.SkipZigTest;
    const opts: root.Options = .{ .locales = fr };
    // A month's abbreviation takes its dot, as detection reads it; after a
    // weekday's, the dot is text, as formatString writes it.
    try expectReads(.strftime, "%a. %d %b %Y", opts, &.{
        .{ "ven. 15 janv. 2024", ymd(2024, 1, 15, 0, 0, 0) },
        .{ "ven. 15 janv 2024", ymd(2024, 1, 15, 0, 0, 0) },
        .{ "ven. 15 mars 2024", ymd(2024, 3, 15, 0, 0, 0) },
        .{ "Fri. 15 Mar 2024", ymd(2024, 3, 15, 0, 0, 0) },
    });
    const r = try root.parseWith("ven. 15 janv. 2024", opts);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.layout.formatString(.strftime, "ven. 15 janv. 2024", &w);
    try std.testing.expectEqualStrings("%a. %d %b %Y", w.buffered());
    // Without French, a French name is no month.
    try expectRefuses(.strftime, "%d %B %Y", .{}, &.{"15 mars 2024"});
}

test "a format string that is no layout is refused" {
    const Case = struct { Dialect, []const u8, Layout.FromFormatError };
    const cases = [_]Case{
        // Fields no layout reads, or not at that width.
        .{ .strftime, "%c", error.Unsupported },
        .{ .strftime, "%Y-%U", error.Unsupported },
        .{ .strftime, "%-m/%d/%Y", error.Unsupported },
        .{ .strftime, "%Y\x00%m", error.Unsupported },
        .{ .go, "15:4", error.Unsupported },
        .{ .go, "2006-01-02T15:04:05Z07:00:00", error.Unsupported },
        .{ .go, "15:04:05.999", error.Unsupported },
        .{ .go, "2006 __2", error.Unsupported },
        .{ .java, "yyyy-ww", error.Unsupported },
        .{ .java, "yyy", error.Unsupported },
        .{ .java, "HH:mm:ss.SSSSSSSSSS", error.Unsupported },
        .{ .java, "[yyyy]", error.Unsupported },
        .{ .java, "ppH", error.Unsupported },
        // Strings that are no format, or no date.
        .{ .strftime, "%Y-%m-%", error.InvalidFormat },
        .{ .strftime, "%Y %Y", error.InvalidFormat },
        .{ .strftime, "%I:%M", error.InvalidFormat },
        .{ .strftime, "%H:%M %p", error.InvalidFormat },
        .{ .strftime, "%Y-W%V-%u", error.InvalidFormat },
        .{ .strftime, "%G-%m-%d", error.InvalidFormat },
        .{ .strftime, "%Y-%j %m", error.InvalidFormat },
        .{ .strftime, "%d %Y", error.InvalidFormat },
        .{ .strftime, "", error.InvalidFormat },
        .{ .strftime, "%a %z", error.InvalidFormat },
        .{ .java, "yyyy-MM-dd'T", error.InvalidFormat },
        .{ .go, "Monday", error.InvalidFormat },
        // No year, and no base time to take one from.
        .{ .strftime, "%H:%M", error.NoBaseTime },
        .{ .go, "Jan _2", error.NoBaseTime },
    };
    for (cases) |c| {
        errdefer std.debug.print("{t} \"{s}\"\n", .{ c[0], c[1] });
        try std.testing.expectError(c[2], Layout.fromFormatString(c[0], c[1], .{}));
    }
    // More fields than a layout holds.
    try std.testing.expectError(error.Unsupported, Layout.fromFormatString(.strftime, "%Y-a-b-a-b-a-b-a-b-a-b-a-b-a-b", .{}));
}

test "a format string's padded fields take the fast path" {
    for ([_]struct { Dialect, []const u8 }{
        .{ .java, "yyyy-MM-dd'T'HH:mm:ssX" },
        .{ .go, "2006-01-02 03:04:05 PM" },
        .{ .strftime, "%Y%m%d" },
    }) |c| {
        errdefer std.debug.print("{t} \"{s}\"\n", .{ c[0], c[1] });
        try std.testing.expect((try Layout.fromFormatString(c[0], c[1], .{})).program.isFast());
    }
}

/// The values the format-string corpus spells (tools/format_strings.zig)
/// and each structured format's example.
const spelled_values = [_][]const u8{
    "2024-03-15",                     "2024-03-15T10:30:00Z",              "2024-03-15T10:30:00.123456+05:30",
    "2024-W11-5",                     "2024-074",                          "2020-07-20+08:00",
    "2024-03-15 10:30:00.000000",     "2024-03-15 10:30:00+00",            "2014-12-16 06:20:00 UTC",
    "2014-05-11 08:20:13,787",        "20240315T103000Z",                  "20240315103000",
    "171113",                         "03/15/2024",                        "15.03.2024",
    "3/15/24",                        "3/15/2024 10:30 PM",                "March 15, 2024",
    "15 Mar 2024",                    "March 2024",                        "Fri, 15 Mar 2024 10:30:00 +0000",
    "Friday, 15-Mar-24 10:30:00 UTC", "Mon Jan 2 15:04:05 2006",           "15/Mar/2024:10:30:00 +0000",
    "2014:04:08 22:05:13",
    "2014年04月08日",
    "10:30:00.123",                   "2024-03-15T10:30:00.123456789Z",    "Mon Jan  2 15:04:05 2006",
    "2014-04-26 05:24:37 PM",         "Friday, March 15, 2024",            "15 March 2024 10:30",
    "1/2/2024",                       "Fri Jul 03 2015 18:04:07 GMT+0100",
};

test "every format string formatString writes reads its value back, and spells the same" {
    const root = @import("root.zig");
    const formats = @import("formats.zig");
    var values: [spelled_values.len + formats.examples.len][]const u8 = undefined;
    for (spelled_values, 0..) |v, i| values[i] = v;
    for (formats.examples, spelled_values.len..) |ex, i| values[i] = ex[1];
    const opts: root.Options = .{ .base_time = read_base };
    var spelled: usize = 0;
    for (values) |v| {
        const r = root.parseWith(v, opts) catch return error.TestUnexpectedResult;
        for ([_]Dialect{ .strftime, .go, .java }) |d| {
            var buf: [128]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            r.layout.formatString(d, v, &w) catch |err| switch (err) {
                error.Unsupported => continue,
                else => return err,
            };
            const format = w.buffered();
            errdefer std.debug.print("{t} \"{s}\" from \"{s}\"\n", .{ d, format, v });
            const l = try Layout.fromFormatString(d, format, opts);
            try std.testing.expectEqual(r.time, try l.parse(v));
            var again_buf: [128]u8 = undefined;
            var again: std.Io.Writer = .fixed(&again_buf);
            try l.formatString(d, v, &again);
            try std.testing.expectEqualStrings(format, again.buffered());
            spelled += 1;
        }
    }
    try std.testing.expect(spelled > 100);
}

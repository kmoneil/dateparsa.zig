//! Format definitions compile into programs, and programs execute.
//!
//! A format is a list of fields, each naming what sits at a byte range of
//! the input. Detection produces the list (formats.zig holds the static
//! ones), compile turns it into instructions, and execute runs them against
//! an input. A program must describe every byte of the input exactly once;
//! it refuses rather than normalises, so 2024-02-30 is error.NoMatch, never
//! the 1st of March.
//!
//! A program whose fields all sit at fixed offsets also gets a slot form
//! that runs as straight-line code (fast.zig); the interpreter here stays the
//! reference it is checked against.

const std = @import("std");
const DateTime = @import("DateTime.zig");
const fast = @import("fast.zig");
const locale = @import("locale.zig");

/// What one field of a format reads.
pub const FieldKind = enum(u8) {
    year4,
    year2,
    month2,
    month1or2,
    month_name, // textual month, resolved at detection time
    day2,
    day1or2,
    hour24,
    hour12,
    hour1or2,
    minute2,
    second2,
    frac_sec,
    ampm,
    tz_z, // literal 'Z'
    tz_offset, // +HH:MM, +HHMM or +HH
    tz_name, // zone abbreviation
    literal, // one separator byte
    skip, // len bytes the program does not read
    iso_week,
    iso_week_day, // 1 is Monday
    ordinal_day, // day of year, 1..366
    tz_z_or_offset, // 'Z' for UTC, or an offset
    tail, // everything from offset to the end of the input is ignored
    day_space_pad, // a space and a digit, or two digits
    month_any, // any month's name, as wide as the name
    weekday_name, // a weekday's name, as wide as the name; checked, not read
    frac_any, // one to nine fractional digits, as many as the input has
    tz_any, // 'Z', +HH:MM or +HHMM, whichever the input writes
};

/// One component of a format. A format cannot address a byte past 255, so
/// offset and len are bytes: the widest input any format describes is a
/// 255-byte field starting at byte 255. A detector building fields from a
/// longer input refuses it before narrowing.
pub const Field = struct {
    kind: FieldKind,
    offset: u8,
    /// Bytes the field covers. For fixed-width kinds this must equal
    /// fixedWidth(kind).
    len: u8,
    /// Pre-resolved value the instruction needs: a month number, a literal
    /// byte or its class (see Inst.aux). Zero in the static table, where
    /// detection derives each literal's class from the signature.
    aux: u16 = 0,
};

/// The number of input bytes the instruction for k reads, or null when the
/// width comes from the input or from the field's len. A field's len has to
/// agree with this: Go's detector once gave a day field len 3 over an op
/// that reads 2, and detection validated a different value than the program
/// returned.
pub fn fixedWidth(k: FieldKind) ?u8 {
    return switch (k) {
        .year4 => 4,
        .year2,
        .month2,
        .day2,
        .hour24,
        .hour12,
        .minute2,
        .second2,
        .ampm,
        .iso_week,
        .day_space_pad,
        => 2,
        .tz_z, .iso_week_day => 1,
        // One byte or two.
        .month1or2, .day1or2, .hour1or2 => null,
        // Exactly len.
        .month_name, .frac_sec, .tz_offset, .tz_name, .ordinal_day, .literal, .skip => null,
        // Depends on the input.
        .tz_z_or_offset, .tail, .month_any, .weekday_name, .frac_any, .tz_any => null,
    };
}

/// The most instructions a program holds, and so the bound on the work one
/// execute does. Detection's widest format is 16 fields. Raising it grows
/// every Program, and a Layout carries one by value.
pub const max_instructions = 24;

/// How many fractional digits a nanosecond holds, and so the widest frac_sec
/// field any program executes. Detectors bound their fields by it too: a
/// wider fraction is refused, not truncated.
pub const max_frac_digits = 9;

/// The widest tail a program executes. A Go time.String() tail is a zone
/// name and a monotonic reading: at most 33 + 24 bytes.
pub const max_tail_len = 64;

/// The longest input any program describes: a field starts at byte 255 at
/// the latest and runs 255 bytes at most. Detection refuses a longer input
/// before running any detector, which bounds the work as well as the answer.
pub const max_describable_len = 2 * 255;

pub const Error = error{NoMatch};

/// An instruction's operation: one per field kind, with the same name, plus
/// nop for an unused fast-path slot.
pub const Op = enum(u8) {
    year4,
    year2,
    month2,
    month1or2,
    month_name,
    day2,
    day1or2,
    hour24,
    hour12,
    hour1or2,
    minute2,
    second2,
    frac_sec,
    ampm,
    tz_z,
    tz_offset,
    tz_name,
    literal,
    skip,
    iso_week,
    iso_week_day,
    ordinal_day,
    tz_z_or_offset,
    tail,
    day_space_pad,
    month_any,
    weekday_name,
    frac_any,
    tz_any,
    nop,
};

/// The op a field kind compiles to: the one with its name. Go mapped the two
/// enums through an array whose zero value was OpYear4, so a kind added
/// without an entry silently parsed a year; here a kind with no op of the
/// same name does not compile.
pub fn opFor(k: FieldKind) Op {
    return switch (k) {
        inline else => |tag| @field(Op, @tagName(tag)),
    };
}

/// One instruction. What aux means depends on op:
///
///   month_name     the month, 1..12, resolved when the format was detected
///   literal, skip  what each byte has to be
///   numeric ops    sep_none, or a separator fused onto the field
///   hour1or2       twelve_hour for a 12-hour clock's hour, 1 to 12; else
///                  sep_none, 0 to 23
///
/// The two readings that describe a byte share one encoding (litAccepts):
///
///   0           any byte that is not a digit (numeric ops: no separator)
///   1..255      exactly that byte
///   256 and up  the low byte is a mask of LitClass bits
pub const Inst = struct {
    op: Op,
    offset: u8,
    len: u8,
    aux: u16 = 0,
};

pub const nop: Inst = .{ .op = .nop, .offset = 0, .len = 0 };

/// Aux on a numeric op that carries no fused separator.
pub const sep_none: u16 = 0;

/// Aux on hour1or2 for a 12-hour clock's hour, which reads 1 to 12. A
/// one-or-two-digit field fuses no separator, so its aux is free.
pub const twelve_hour: u16 = 12;

/// Marks an aux holding a class mask: the first bit above byte range, so a
/// class cannot collide with an exact byte, and truncating to a byte leaves
/// the mask.
const aux_class_base: u16 = 256;

/// The set of bytes a literal, a fused separator or a skipped run accepts.
/// The first six mirror signature.CharClass, because one trie entry serves
/// every byte of a class ("2024-03-15", "2024/03/15" and "2024.03.15" share
/// ISO8601_DATE), and each is a superset of what scan assigns its class.
/// Not-a-digit alone was too loose: NUMERIC_MDY and TIME_HMS are both
/// DD?DD?DD, and the class is what tells "10:01:00" from "20-1-00".
pub const LitClass = enum(u3) {
    any, // any byte that is not a digit
    sep, // - / .
    space, // space, tab
    colon, // :
    special, // T Z - + ,
    letter, // anything scan could call a letter
    alpha, // A-Z a-z; skipped runs only
    nonprinting, // control bytes but tab, DEL, 0x80 and up; skipped runs only
};

fn classBit(c: LitClass) u8 {
    return @as(u8, 1) << @backingInt(c);
}

/// Aux that accepts every byte in c.
pub fn auxClass(c: LitClass) u16 {
    return aux_class_base | classBit(c);
}

/// Aux for a literal that has to match class c: the byte itself when the
/// class holds exactly one (colon), so the executor compares instead of
/// looking up, and the class otherwise.
pub fn auxFor(c: LitClass) u16 {
    if (class_sole_byte[@backingInt(c)]) |b| return b;
    return auxClass(c);
}

/// Accepts any byte that is not a digit: what a separator of unknown class
/// can always be held to, since a digit there is a token the format does
/// not model.
const sep_any_non_digit = auxClass(.any);

/// lit_class_set[b] has one bit per LitClass that byte b belongs to, so a
/// class test is a load and a mask.
const lit_class_set: [256]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u8 = @splat(0);
    for (&t, 0..) |*m, i| {
        const c: u8 = @intCast(i);
        const digit = isDigit(c);
        if (!digit) m.* |= classBit(.any);
        switch (c) {
            '-', '/', '.' => m.* |= classBit(.sep),
            ' ', '\t' => m.* |= classBit(.space),
            ':' => m.* |= classBit(.colon),
            else => {},
        }
        switch (c) {
            'T', 'Z', '-', '+', ',' => m.* |= classBit(.special),
            else => {},
        }
        // Scan calls every byte a letter that is not a digit and not one of
        // these eight, non-ASCII included.
        switch (c) {
            '-', '/', '.', ' ', '\t', ':', '+', ',' => {},
            else => if (!digit) {
                m.* |= classBit(.letter);
            },
        }
        if (std.ascii.isAlphabetic(c)) m.* |= classBit(.alpha);
        if ((c < ' ' and c != '\t') or c >= 0x7f) m.* |= classBit(.nonprinting);
    }
    break :blk t;
};

/// The one byte each class accepts, for classes that accept exactly one.
const class_sole_byte: [8]?u8 = blk: {
    @setEvalBranchQuota(10_000);
    var sole: [8]?u8 = @splat(null);
    for (&sole, 0..) |*s, k| {
        var n: usize = 0;
        var last: u8 = 0;
        for (lit_class_set, 0..) |m, b| {
            if (m & (@as(u8, 1) << @intCast(k)) != 0) {
                n += 1;
                last = @intCast(b);
            }
        }
        if (n == 1) s.* = last;
    }
    break :blk sole;
};

/// Whether c satisfies aux, under the three readings on Inst.
pub fn litAccepts(aux: u16, c: u8) bool {
    if (aux == 0) return !isDigit(c);
    if (aux < aux_class_base) return c == aux;
    return lit_class_set[c] & @as(u8, @truncate(aux)) != 0;
}

/// What a piece of a run of words may hold: letters, spaces and tabs, and
/// bytes that are not printable ASCII.
const words_mask = classBit(.alpha) | classBit(.space) | classBit(.nonprinting);

/// One piece of a skipped run s[off..end]: how many bytes a single skip
/// describes, and the aux that holds a reused layout to what those bytes
/// were. The caller covers the rest of the run with further calls. A piece
/// is decided by the byte it starts with:
///
///   a letter       it, and the letters, spaces, tabs and non-printing
///                  bytes after it ("Mon ", "th", "Miércoles")
///   non-printing   it, and the non-printing bytes after it ("年", "é")
///   a digit        the digits, with aux 0, which refuses them on reuse
///   anything else  that byte, repeated (" ", ",", "--")
///
/// Words give up their exact bytes because the weekday a column's first row
/// skipped is not its second row's; everything else is held byte for byte,
/// since one aux over ", " took " +" and read a zone offset as a year.
pub fn skipRun(s: []const u8, off: usize, end: usize) struct { len: usize, aux: u16 } {
    if (end > s.len or off >= end) return .{ .len = 0, .aux = 0 };
    const run = s[off..end];
    const c = run[0];
    var n: usize = 1;
    if (isDigit(c)) {
        while (n < run.len and isDigit(run[n])) n += 1;
        return .{ .len = n, .aux = 0 };
    }
    if (lit_class_set[c] & classBit(.alpha) != 0) {
        while (n < run.len and lit_class_set[run[n]] & words_mask != 0) n += 1;
        return .{ .len = n, .aux = aux_class_base | words_mask };
    }
    if (lit_class_set[c] & classBit(.nonprinting) != 0) {
        while (n < run.len and lit_class_set[run[n]] & classBit(.nonprinting) != 0) n += 1;
        return .{ .len = n, .aux = auxClass(.nonprinting) };
    }
    while (n < run.len and run[n] == c) n += 1;
    return .{ .len = n, .aux = c };
}

/// The width a field of kind k reads when a separator can be fused onto it,
/// or null. Only the fixed-width numeric kinds: their width is known here
/// and their aux is otherwise unused.
fn fusesSeparator(k: FieldKind) ?u8 {
    return switch (k) {
        .year4 => 4,
        .year2,
        .month2,
        .day2,
        .hour24,
        .hour12,
        .minute2,
        .second2,
        .iso_week,
        .day_space_pad,
        => 2,
        else => null,
    };
}

/// Where an instruction read: the bytes s[off..][0..len], a fused separator
/// included.
pub const Span = struct { off: usize, len: usize };

pub const Program = struct {
    /// insts[0..n] is the program as compiled. A fast program also keeps a
    /// copy of each instruction at insts[fast.slot_base + slot].
    insts: [max_instructions]Inst = @splat(nop),
    n: u8 = 0,
    /// The year for a format with no year field ("10:30:00"), fixed when the
    /// program is compiled so that reusing a layout never answers a
    /// different instant on a different day.
    base_year: i32 = 0,
    /// UTC offset, seconds east, for an input that writes no zone.
    offset_seconds: i32 = 0,
    /// The input lengths a fast program describes; zero when fast.plan
    /// refused the program. width_alt differs from width only when the zone
    /// slot is tz_z_or_offset, whose 'Z' form is narrower than its offset.
    width: u16 = 0,
    width_alt: u16 = 0,
    /// The locales whose month names a month_name field accepts besides
    /// English: the ones detection searched, and no others.
    locales: locale.LocaleSet = .{},

    pub fn isFast(p: *const Program) bool {
        return p.width != 0;
    }

    pub fn execute(p: *const Program, s: []const u8) Error!DateTime {
        if (p.isFast()) return fast.execute(p, s);
        return interpret(p, s, false, {});
    }

    /// What execute answers, and where in s each instruction read, by the
    /// interpreter: a field the input decides the width of reads where no
    /// offset in the program says.
    pub fn trace(p: *const Program, s: []const u8, spans: *[max_instructions]Span) Error!DateTime {
        return interpret(p, s, true, spans);
    }
};

pub const Config = struct {
    base_year: i32 = 0,
    offset_seconds: i32 = 0,
    locales: locale.LocaleSet = .{},
};

/// Compiles fields (in input order, as formats.problem requires) into a
/// program. A single-byte literal sitting exactly where a fixed-width
/// numeric field ends is fused into that field's aux, so ISO8601_DATE is
/// three instructions, not five.
pub fn compile(fields: []const Field, config: Config) error{TooManyFields}!Program {
    // Counts fields, not the instructions fusion leaves, so the limit is one
    // a caller can derive from the format they wrote.
    if (fields.len > max_instructions) return error.TooManyFields;
    var p: Program = .{
        .base_year = config.base_year,
        .offset_seconds = config.offset_seconds,
        .locales = config.locales,
    };
    var i: usize = 0;
    while (i < fields.len) : (i += 1) {
        const f = fields[i];
        var aux = f.aux;
        if (fusesSeparator(f.kind)) |w| {
            if (i + 1 < fields.len) {
                const next = fields[i + 1];
                if (next.kind == .literal and next.len == 1 and
                    @as(usize, next.offset) == @as(usize, f.offset) + w)
                {
                    aux = if (next.aux == 0) sep_any_non_digit else next.aux;
                    i += 1;
                }
            }
        }
        p.insts[p.n] = .{ .op = opFor(f.kind), .offset = f.offset, .len = f.len, .aux = aux };
        p.n += 1;
    }
    _ = fast.plan(&p);
    return p;
}

/// Whether a format with these fields takes its year from the base year.
pub fn needsBaseYear(fields: []const Field) bool {
    for (fields) |f| {
        if (f.kind == .year4 or f.kind == .year2) return false;
    }
    return true;
}

pub const AmPm = enum { none, am, pm };

/// Field values as an executor reads them, before they are a DateTime.
pub const Reading = struct {
    year: i32 = 0,
    year_set: bool = false,
    month: u8 = 1,
    day: u8 = 1,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    nanosecond: u32 = 0,
    offset_seconds: i32,
    ampm: AmPm = .none,
    iso_week: u8 = 0,
    iso_week_day: u8 = 0,
    ordinal_day: u16 = 0,

    /// The DateTime these fields name, or error.NoMatch when they name none:
    /// a day its month does not have, ISO week 53 of a 52-week year, day 366
    /// of a common year. The fields were each range-checked as read; this is
    /// where they are checked against each other.
    pub fn finish(r: Reading, base_year: i32) Error!DateTime {
        const year = if (r.year_set) r.year else base_year;
        const hour = applyAmPm(r.hour, r.ampm);
        // Only an hour24 field under a PM reaches this. Detection always
        // pairs AM/PM with hour12; Go normalised 25:00 into the next day.
        if (hour > 23) return error.NoMatch;
        var date: DateTime.CivilDate = .{ .year = year, .month = r.month, .day = r.day };
        if (r.iso_week != 0) {
            const wk = isoWeek1(year);
            if (r.iso_week > wk.weeks) return error.NoMatch;
            const from_monday: i64 = if (r.iso_week_day == 0) 0 else r.iso_week_day - 1;
            date = DateTime.civilFromDays(wk.monday + (@as(i64, r.iso_week) - 1) * 7 + from_monday);
        } else if (r.ordinal_day != 0) {
            if (r.ordinal_day > DateTime.daysInYear(year)) return error.NoMatch;
            date = DateTime.civilFromDays(DateTime.daysFromCivil(year, 1, 1) + r.ordinal_day - 1);
        } else if (!DateTime.dayExists(year, r.month, r.day)) {
            return error.NoMatch;
        }
        return .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .hour = hour,
            .minute = r.minute,
            .second = r.second,
            .nanosecond = r.nanosecond,
            .offset_seconds = r.offset_seconds,
        };
    }
};

fn applyAmPm(hour: u8, ampm: AmPm) u8 {
    return switch (ampm) {
        .none => hour,
        .am => if (hour == 12) 0 else hour,
        .pm => if (hour == 12) 12 else hour + 12,
    };
}

/// The Monday of ISO week 1 of year (days since the epoch), and how many ISO
/// weeks the year has. Both come from the weekday of 4 January, which is
/// always in week 1. A year has 53 weeks when 1 January is a Thursday, or a
/// Wednesday in a leap year; being a leap year alone is not enough.
fn isoWeek1(year: i32) struct { monday: i64, weeks: u8 } {
    const jan4 = DateTime.daysFromCivil(year, 1, 4);
    const jan4_wd = @mod(jan4 + 4, 7); // 0 is Sunday
    const jan1_wd = @mod(jan4_wd + 4, 7); // three days earlier
    const long = jan1_wd == 4 or (DateTime.isLeapYear(year) and jan1_wd == 3);
    return .{ .monday = jan4 - @mod(jan4_wd + 6, 7), .weeks = if (long) 53 else 52 };
}

/// The program's reading of s. Each instruction reads at its offset plus
/// delta, which a variable-width field moves when it reads more or fewer
/// bytes than its len; that is only right because instructions ascend by
/// offset. end and covered must both equal s.len at the end: end alone let a
/// byte between two fields go unexamined, and the sum alone cannot see a gap
/// that an overlap cancels. A traced run also records each instruction's span.
fn interpret(
    p: *const Program,
    s: []const u8,
    comptime traced: bool,
    spans: if (traced) *[max_instructions]Span else void,
) Error!DateTime {
    if (p.n > max_instructions) return error.NoMatch;
    var r: Reading = .{ .offset_seconds = p.offset_seconds };
    var delta: isize = 0;
    var end: usize = 0;
    var covered: usize = 0;
    for (p.insts[0..p.n], 0..) |inst, i| {
        const signed_off = @as(isize, inst.offset) + delta;
        if (signed_off < 0) return error.NoMatch;
        const off: usize = @intCast(signed_off);
        var w: usize = inst.len;
        switch (inst.op) {
            .year4 => {
                r.year = parse4(s, off) orelse return error.NoMatch;
                r.year_set = true;
                w = numericW(s, off, 4, inst.aux) orelse return error.NoMatch;
            },
            .year2 => {
                const v = parse2Bounded(s, off, 0, 99) orelse return error.NoMatch;
                r.year = normalizeTwoDigitYear(v);
                r.year_set = true;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .month2 => {
                r.month = parse2Bounded(s, off, 1, 12) orelse return error.NoMatch;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .month1or2 => {
                const v = parse1or2Bounded(s, off, 1, 12) orelse return error.NoMatch;
                r.month = v.value;
                w = v.width;
                delta += @as(isize, v.width) - inst.len;
            },
            .month_name => {
                // The month was resolved at detection; the input must still
                // name it, or a reused layout answers with the month it was
                // built from.
                if (!monthNameMatches(s, off, inst.len, inst.aux, p.locales)) return error.NoMatch;
                r.month = @intCast(inst.aux);
            },
            .month_any => {
                const m = readMonthName(s, off, p.locales) orelse return error.NoMatch;
                r.month = m.month;
                w = m.len;
                delta += @as(isize, @intCast(m.len)) - inst.len;
            },
            .weekday_name => {
                w = readWeekdayName(s, off, p.locales) orelse return error.NoMatch;
                delta += @as(isize, @intCast(w)) - inst.len;
            },
            .day2 => {
                r.day = parse2Bounded(s, off, 1, 31) orelse return error.NoMatch;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .day1or2 => {
                const v = parse1or2Bounded(s, off, 1, 31) orelse return error.NoMatch;
                r.day = v.value;
                w = v.width;
                delta += @as(isize, v.width) - inst.len;
            },
            .day_space_pad => {
                r.day = parseDaySpacePad(s, off) orelse return error.NoMatch;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .hour24 => {
                r.hour = parse2Bounded(s, off, 0, 23) orelse return error.NoMatch;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .hour12 => {
                r.hour = parse2Bounded(s, off, 1, 12) orelse return error.NoMatch;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .hour1or2 => {
                const twelve = inst.aux == twelve_hour;
                const v = parse1or2Bounded(s, off, @intFromBool(twelve), if (twelve) 12 else 23) orelse return error.NoMatch;
                r.hour = v.value;
                w = v.width;
                delta += @as(isize, v.width) - inst.len;
            },
            .minute2 => {
                r.minute = parse2Bounded(s, off, 0, 59) orelse return error.NoMatch;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .second2 => {
                // 0..59: a leap second has no POSIX reading that does not
                // collide with a neighbour, and Go's normalising answer moved
                // the date.
                r.second = parse2Bounded(s, off, 0, 59) orelse return error.NoMatch;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .frac_sec => {
                if (off + inst.len > s.len) return error.NoMatch;
                r.nanosecond = parseFracSec(s[off..][0..inst.len]) orelse return error.NoMatch;
            },
            .frac_any => {
                w = 0;
                while (off + w < s.len and isDigit(s[off + w])) w += 1;
                if (w == 0) return error.NoMatch;
                // More digits than a nanosecond holds are refused, not cut.
                r.nanosecond = parseFracSec(s[off..][0..w]) orelse return error.NoMatch;
                delta += @as(isize, @intCast(w)) - inst.len;
            },
            .ampm => {
                r.ampm = parseAmPm(s, off) orelse return error.NoMatch;
                w = 2;
            },
            .tz_z => {
                // Checked, not assumed: a reused layout meets inputs no
                // detector looked at, and "...10:30:00+" is not UTC.
                if (off >= s.len or s[off] != 'Z') return error.NoMatch;
                r.offset_seconds = 0;
                w = 1;
            },
            .tz_offset => {
                if (off + inst.len > s.len) return error.NoMatch;
                r.offset_seconds = parseTzOffset(s[off..][0..inst.len]) orelse return error.NoMatch;
            },
            .tz_name => {
                if (off + inst.len > s.len) return error.NoMatch;
                const name = s[off..][0..inst.len];
                r.offset_seconds = tz_abbreviations.get(name) orelse return error.NoMatch;
            },
            .tz_z_or_offset => {
                if (off >= s.len) return error.NoMatch;
                if (s[off] == 'Z') {
                    r.offset_seconds = 0;
                    w = 1;
                    delta += 1 - @as(isize, inst.len);
                } else {
                    if (off + inst.len > s.len) return error.NoMatch;
                    const t = s[off..][0..inst.len];
                    r.offset_seconds = parseTzOffset(t) orelse return error.NoMatch;
                }
            },
            .tz_any => {
                if (off >= s.len) return error.NoMatch;
                if (s[off] == 'Z') {
                    r.offset_seconds = 0;
                    w = 1;
                } else {
                    // +HH:MM when a colon follows the hours, +HHMM otherwise.
                    w = if (off + 3 < s.len and s[off + 3] == ':') 6 else 5;
                    if (off + w > s.len) return error.NoMatch;
                    r.offset_seconds = parseTzOffset(s[off..][0..w]) orelse return error.NoMatch;
                }
                delta += @as(isize, @intCast(w)) - inst.len;
            },
            .iso_week => {
                r.iso_week = parse2Bounded(s, off, 1, 53) orelse return error.NoMatch;
                w = numericW(s, off, 2, inst.aux) orelse return error.NoMatch;
            },
            .iso_week_day => {
                if (off >= s.len) return error.NoMatch;
                const d = s[off] -% '0';
                if (d < 1 or d > 7) return error.NoMatch;
                r.iso_week_day = d;
                w = 1;
            },
            .ordinal_day => {
                if (off + inst.len > s.len) return error.NoMatch;
                var v: u32 = 0;
                for (s[off..][0..inst.len]) |c| {
                    if (!isDigit(c)) return error.NoMatch;
                    v = v * 10 + (c - '0');
                    if (v > 366) return error.NoMatch;
                }
                if (v < 1) return error.NoMatch;
                r.ordinal_day = @intCast(v);
            },
            .literal, .skip => {
                // A skip holds no value, but its bytes are still held to aux:
                // a digit inside one is a token detection saw and this program
                // does not model, and a '+' where a space was turns a zone
                // offset into a year.
                if (off + w > s.len) return error.NoMatch;
                for (s[off..][0..w]) |c| {
                    if (!litAccepts(inst.aux, c)) return error.NoMatch;
                }
            },
            .tail => {
                if (off > s.len or !validTail(s[off..])) return error.NoMatch;
                w = s.len - off;
            },
            .nop => w = 0,
        }
        if (traced) spans[i] = .{ .off = off, .len = w };
        covered += w;
        end = @max(end, off + w);
    }
    if (end != s.len or covered != s.len) return error.NoMatch;
    return r.finish(p.base_year);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn parse2(s: []const u8, off: usize) ?u8 {
    if (off + 2 > s.len) return null;
    const d0 = s[off] -% '0';
    const d1 = s[off + 1] -% '0';
    if (d0 > 9 or d1 > 9) return null;
    return d0 * 10 + d1;
}

/// Two digits at off, within lo..hi.
pub fn parse2Bounded(s: []const u8, off: usize, lo: u8, hi: u8) ?u8 {
    const v = parse2(s, off) orelse return null;
    if (v < lo or v > hi) return null;
    return v;
}

pub fn parse4(s: []const u8, off: usize) ?i32 {
    if (off + 4 > s.len) return null;
    var v: i32 = 0;
    for (s[off..][0..4]) |c| {
        if (!isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// One digit at off, or two when the next byte is a digit too, within
/// lo..hi, and how many bytes that took.
fn parse1or2Bounded(s: []const u8, off: usize, lo: u8, hi: u8) ?struct { value: u8, width: u8 } {
    if (off >= s.len or !isDigit(s[off])) return null;
    var v: u8 = s[off] - '0';
    var width: u8 = 1;
    if (off + 1 < s.len and isDigit(s[off + 1])) {
        v = v * 10 + (s[off + 1] - '0');
        width = 2;
    }
    if (v < lo or v > hi) return null;
    return .{ .value = v, .width = width };
}

/// Go's "_2": two bytes, a space and a digit or two digits, within 1..31.
pub fn parseDaySpacePad(s: []const u8, off: usize) ?u8 {
    if (off + 2 > s.len) return null;
    if (s[off] == ' ') {
        const d = s[off + 1] -% '0';
        return if (d >= 1 and d <= 9) d else null;
    }
    return parse2Bounded(s, off, 1, 31);
}

/// The width a fixed-width numeric field of width w covers at off: w, or
/// w + 1 when aux fuses a separator onto it and the byte after it is one.
fn numericW(s: []const u8, off: usize, w: usize, aux: u16) ?usize {
    if (aux == sep_none) return w;
    const at = off + w;
    if (at >= s.len or !litAccepts(aux, s[at])) return null;
    return w + 1;
}

/// Years 69..99 are the 1900s and 00..68 the 2000s, as in Go's time.Parse.
pub fn normalizeTwoDigitYear(y: u8) i32 {
    return if (y >= 69) 1900 + @as(i32, y) else 2000 + @as(i32, y);
}

pub fn parseAmPm(s: []const u8, off: usize) ?AmPm {
    if (off + 2 > s.len) return null;
    const c0 = s[off] | 0x20;
    const c1 = s[off + 1] | 0x20;
    if (c1 != 'm') return null;
    return switch (c0) {
        'a' => .am,
        'p' => .pm,
        else => null,
    };
}

/// Nanoseconds from a run of fractional digits. Every byte must be a digit,
/// and a run longer than a nanosecond holds is refused rather than
/// truncated: Go once added the digits past the ninth without dividing them
/// back out and moved the answer by years.
pub fn parseFracSec(digits: []const u8) ?u32 {
    if (digits.len > max_frac_digits) return null;
    var v: u32 = 0;
    for (digits) |c| {
        if (!isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    for (digits.len..max_frac_digits) |_| v *= 10;
    return v;
}

/// Seconds east of UTC from +HH, +HHMM or +HH:MM (or -). Hours up to 23 and
/// minutes up to 59, as RFC 3339 allows.
pub fn parseTzOffset(t: []const u8) ?i32 {
    if (t.len < 3) return null;
    const sign: i32 = switch (t[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const h = parse2Bounded(t, 1, 0, 23) orelse return null;
    var m: u8 = 0;
    switch (t.len) {
        3 => {},
        5 => m = parse2Bounded(t, 3, 0, 59) orelse return null,
        6 => {
            if (t[3] != ':') return null;
            m = parse2Bounded(t, 4, 0, 59) orelse return null;
        },
        else => return null,
    }
    return sign * (@as(i32, h) * 3600 + @as(i32, m) * 60);
}

/// Zone abbreviations, each a fixed offset taken as written: CET is +01:00
/// even in July, because a caller who means summer time writes CEST. Exact
/// case, as in Go. The tzdata country aliases (PRC, ROC, ROK) are refused.
pub const tz_abbreviations = std.StaticStringMap(i32).initComptime(.{
    .{ "UTC", 0 },
    .{ "UCT", 0 },
    .{ "GMT", 0 },
    .{ "EST", -5 * 3600 },
    .{ "EDT", -4 * 3600 },
    .{ "CST", -6 * 3600 },
    .{ "CDT", -5 * 3600 },
    .{ "MST", -7 * 3600 },
    .{ "MDT", -6 * 3600 },
    .{ "PST", -8 * 3600 },
    .{ "PDT", -7 * 3600 },
    .{ "HST", -10 * 3600 },
    .{ "CET", 1 * 3600 },
    .{ "EET", 2 * 3600 },
    .{ "MET", 1 * 3600 },
    .{ "WET", 0 },
});

/// Whether t is trailing content a Go time.String() may carry after its
/// numeric offset: empty, " ZONE", or " ZONE m=±reading". Anything else,
/// and anything past max_tail_len, is refused, so a megabyte of prose with
/// a timestamp on the front is not a date.
pub fn validTail(t: []const u8) bool {
    if (t.len > max_tail_len) return false;
    if (t.len == 0) return true;
    if (t[0] != ' ') return false;
    const rest = t[1..];
    const zone_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    if (zone_end == 0) return false; // two spaces in a row is not a zone name
    if (zone_end == rest.len) return true;
    // The monotonic reading: one piece starting "m=". Its digits are not
    // checked; the instant has already been read.
    const mono = rest[zone_end + 1 ..];
    if (mono.len < 3 or mono[0] != 'm' or mono[1] != '=') return false;
    for (mono[2..]) |c| {
        if (!isDigit(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

/// Whether c can be part of a word: an ASCII letter or any byte of a UTF-8
/// sequence. Detection and verification must agree on this exactly, or a
/// reused layout reads a month detection would not have found.
pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c >= 0x80;
}

/// The month s names at off, as a whole word, and how many bytes the name
/// takes: English, then each locale of locales in tag order, the order
/// detection searches them. A locale's abbreviation that ends in a dot
/// takes the dot, as detection's spelling does.
pub fn readMonthName(s: []const u8, off: usize, locales: locale.LocaleSet) ?struct { month: u8, len: usize } {
    const word = wordAt(s, off) orelse return null;
    for (english_months, 1..) |names, month| for (names) |name| {
        if (std.ascii.eqlIgnoreCase(word, name)) return .{ .month = @intCast(month), .len = word.len };
    };
    const end = off + word.len;
    const dot = end < s.len and s[end] == '.' and (end + 1 == s.len or !isWordChar(s[end + 1]));
    const m = locale.findMonth(word, dot, locales) orelse return null;
    return .{ .month = m.month, .len = word.len + @intFromBool(m.took_dot) };
}

/// How many bytes the weekday s names at off takes, as a whole word, in
/// English or a locale of locales, or null when the word is no weekday. A
/// dot after an abbreviation is left for the text after it.
pub fn readWeekdayName(s: []const u8, off: usize, locales: locale.LocaleSet) ?usize {
    const word = wordAt(s, off) orelse return null;
    if (!locale.isWeekday(word, locales)) return null;
    return word.len;
}

/// The run of word characters starting at off, when a word starts there.
fn wordAt(s: []const u8, off: usize) ?[]const u8 {
    if (off >= s.len or (off > 0 and isWordChar(s[off - 1]))) return null;
    var end = off;
    while (end < s.len and isWordChar(s[end])) end += 1;
    if (end == off) return null;
    return s[off..end];
}

/// Every English spelling detection matches, indexed by month - 1.
/// September has three: detection accepts "sept", so verification must.
const english_months = [12][]const []const u8{
    &.{ "january", "jan" },
    &.{ "february", "feb" },
    &.{ "march", "mar" },
    &.{ "april", "apr" },
    &.{"may"},
    &.{ "june", "jun" },
    &.{ "july", "jul" },
    &.{ "august", "aug" },
    &.{ "september", "sept", "sep" },
    &.{ "october", "oct" },
    &.{ "november", "nov" },
    &.{ "december", "dec" },
};

/// Whether s[off..off+len] names month, as a whole word: a letter either
/// side is a refusal, a digit or punctuation is not ("MAY10" is accepted).
/// Only the one month the instruction names is checked, so a mismatch is a
/// refusal, never a different month. English always counts; another
/// locale's spellings count when locales holds it, so a layout accepts the
/// locales detection searched and no others.
pub fn monthNameMatches(
    s: []const u8,
    off: usize,
    len: usize,
    month: u16,
    locales: locale.LocaleSet,
) bool {
    if (month < 1 or month > 12 or len == 0 or off + len > s.len) return false;
    if (off > 0 and isWordChar(s[off - 1])) return false;
    if (off + len < s.len and isWordChar(s[off + len])) return false;
    const got = s[off..][0..len];
    for (english_months[month - 1]) |want| {
        if (std.ascii.eqlIgnoreCase(got, want)) return true;
    }
    return locale.matchesMonth(got, @intCast(month), locales);
}

const formats = @import("formats.zig");
const signature = @import("signature.zig");

test {
    std.testing.refAllDecls(@This());
}

/// A program of exactly these instructions, as Go's tests build them by
/// hand: no fusion, no fast plan.
fn program(insts: []const Inst) Program {
    var p: Program = .{};
    for (insts, 0..) |inst, i| p.insts[i] = inst;
    p.n = @intCast(insts.len);
    return p;
}

fn civil(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) DateTime {
    return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second };
}

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "execute: hand-built programs" {
    const date = program(&.{
        .{ .op = .year4, .offset = 0, .len = 4 },
        .{ .op = .literal, .offset = 4, .len = 1 },
        .{ .op = .month2, .offset = 5, .len = 2 },
        .{ .op = .literal, .offset = 7, .len = 1 },
        .{ .op = .day2, .offset = 8, .len = 2 },
    });
    try expectEqual(civil(2024, 3, 15, 0, 0, 0), try date.execute("2024-03-15"));

    const pm = program(&.{
        .{ .op = .hour12, .offset = 0, .len = 2 },
        .{ .op = .literal, .offset = 2, .len = 1 },
        .{ .op = .minute2, .offset = 3, .len = 2 },
        .{ .op = .literal, .offset = 5, .len = 1 },
        .{ .op = .ampm, .offset = 6, .len = 2 },
    });
    try expectEqual(civil(0, 1, 1, 15, 30, 0), try pm.execute("03:30 PM"));
    try expectEqual(civil(0, 1, 1, 0, 30, 0), try pm.execute("12:30 am"));
    try expectEqual(civil(0, 1, 1, 12, 30, 0), try pm.execute("12:30 PM"));

    const frac = program(&.{
        .{ .op = .hour24, .offset = 0, .len = 2 },
        .{ .op = .literal, .offset = 2, .len = 1 },
        .{ .op = .minute2, .offset = 3, .len = 2 },
        .{ .op = .literal, .offset = 5, .len = 1 },
        .{ .op = .second2, .offset = 6, .len = 2 },
        .{ .op = .literal, .offset = 8, .len = 1 },
        .{ .op = .frac_sec, .offset = 9, .len = 3 },
    });
    try expectEqual(123_000_000, (try frac.execute("10:30:45.123")).nanosecond);

    const zoned = program(&.{
        .{ .op = .hour24, .offset = 0, .len = 2 },
        .{ .op = .literal, .offset = 2, .len = 1 },
        .{ .op = .minute2, .offset = 3, .len = 2 },
        .{ .op = .tz_offset, .offset = 5, .len = 6 },
    });
    try expectEqual(5 * 3600 + 30 * 60, (try zoned.execute("10:30+05:30")).offset_seconds);

    try expectError(error.NoMatch, program(&.{.{ .op = .year4, .offset = 0, .len = 4 }}).execute("abcd"));
}

test "execute: tz_z_or_offset takes Z or an offset" {
    const p = program(&.{
        .{ .op = .hour24, .offset = 0, .len = 2 },
        .{ .op = .literal, .offset = 2, .len = 1 },
        .{ .op = .minute2, .offset = 3, .len = 2 },
        .{ .op = .literal, .offset = 5, .len = 1 },
        .{ .op = .second2, .offset = 6, .len = 2 },
        .{ .op = .tz_z_or_offset, .offset = 8, .len = 6 },
    });
    try expectEqual(0, (try p.execute("10:30:00Z")).offset_seconds);
    try expectEqual(19800, (try p.execute("10:30:00+05:30")).offset_seconds);
    try expectEqual(-8 * 3600, (try p.execute("10:30:00-08:00")).offset_seconds);

    var compact = p;
    compact.insts[5].len = 5;
    try expectEqual(19800, (try compact.execute("10:30:00+0530")).offset_seconds);
}

test "compile fuses separators and still checks them" {
    const fields = [_]Field{
        .{ .kind = .year4, .offset = 0, .len = 4 },
        .{ .kind = .literal, .offset = 4, .len = 1 },
        .{ .kind = .month2, .offset = 5, .len = 2 },
        .{ .kind = .literal, .offset = 7, .len = 1 },
        .{ .kind = .day2, .offset = 8, .len = 2 },
    };
    const p = try compile(&fields, .{});
    try expectEqual(3, p.n);
    try expectEqual(civil(2024, 3, 15, 0, 0, 0), try p.execute("2024-03-15"));
    // A digit where a separator belongs is refused: it is a token.
    for ([_][]const u8{ "20240315", "2024-0315", "2024030-15" }) |bad| {
        try expectError(error.NoMatch, p.execute(bad));
    }
    // Any other byte passes an unstamped literal, as before fusion.
    try expectEqual(civil(2024, 3, 15, 0, 0, 0), try p.execute("2024x03x15"));
}

test "compile refuses more fields than a program holds" {
    var fields: [max_instructions + 1]Field = undefined;
    for (&fields, 0..) |*f, i| f.* = .{ .kind = .literal, .offset = @intCast(i), .len = 1, .aux = 'x' };
    try expectError(error.TooManyFields, compile(&fields, .{}));
    const p = try compile(fields[0..max_instructions], .{});
    try expectEqual(max_instructions, p.n);
}

test "opFor maps each field kind to its namesake" {
    for (std.enums.values(FieldKind)) |k| {
        try std.testing.expectEqualStrings(@tagName(k), @tagName(opFor(k)));
    }
}

test "execute refuses a malformed program instead of reading out of bounds" {
    // 'Z' takes the one-byte branch of a 6-wide zone, so the year would sit
    // at offset -4.
    const negative = program(&.{
        .{ .op = .tz_z_or_offset, .offset = 0, .len = 6 },
        .{ .op = .year4, .offset = 1, .len = 4 },
    });
    try expectError(error.NoMatch, negative.execute("Z2024"));

    var too_long = program(&.{.{ .op = .year4, .offset = 0, .len = 4 }});
    too_long.n = max_instructions + 7;
    try expectError(error.NoMatch, too_long.execute("2024"));
}

/// One instruction per field, nothing fused: what fusion is checked against.
fn compileUnfused(fields: []const Field) Program {
    var p: Program = .{};
    for (fields, 0..) |f, i| p.insts[i] = .{ .op = opFor(f.kind), .offset = f.offset, .len = f.len, .aux = f.aux };
    p.n = @intCast(fields.len);
    return p;
}

test "fusion answers what the unfused program answers" {
    const lit = struct {
        fn class(off: u8) Field {
            return .{ .kind = .literal, .offset = off, .len = 1 };
        }
        fn exact(off: u8, b: u8) Field {
            return .{ .kind = .literal, .offset = off, .len = 1, .aux = b };
        }
    };
    const Shape = struct { fields: []const Field, inputs: []const []const u8 };
    const shapes = [_]Shape{
        .{
            .fields = &.{
                .{ .kind = .year4, .offset = 0, .len = 4 },  lit.class(4),
                .{ .kind = .month2, .offset = 5, .len = 2 }, lit.class(7),
                .{ .kind = .day2, .offset = 8, .len = 2 },
            },
            .inputs = &.{
                "2024-03-15", "2024/03/15",  "2024.03.15", "2024x03x15", "20240315",   "2024-0315",
                "2024-03-1",  "2024-03-15x", "",           "2024-13-15", "2024-03-32", "abcd-03-15",
            },
        },
        .{
            .fields = &.{
                .{ .kind = .year4, .offset = 0, .len = 4 },    lit.class(4),
                .{ .kind = .month2, .offset = 5, .len = 2 },   lit.class(7),
                .{ .kind = .day2, .offset = 8, .len = 2 },     lit.class(10),
                .{ .kind = .hour24, .offset = 11, .len = 2 },  lit.class(13),
                .{ .kind = .minute2, .offset = 14, .len = 2 }, lit.class(16),
                .{ .kind = .second2, .offset = 17, .len = 2 }, .{ .kind = .tz_z, .offset = 19, .len = 1 },
            },
            .inputs = &.{
                "2024-03-15T10:30:00Z", "2024-03-15 10:30:00Z", "2024-03-1510:30:00Z",  "2024-03-15T103000Z",
                "2024-03-15T10:30:00",  "2024-03-15T10:30:60Z", "2024-03-15T24:30:00Z", "2024-03-15T10:30:00+",
            },
        },
        .{
            .fields = &.{
                .{ .kind = .year4, .offset = 0, .len = 4 },  lit.exact(4, '-'),
                .{ .kind = .month2, .offset = 5, .len = 2 }, lit.exact(7, '-'),
                .{ .kind = .day2, .offset = 8, .len = 2 },
            },
            .inputs = &.{ "2024-03-15", "2024/03/15", "2024.03.15", "2024x03-15", "20240315", "2024-03/15", "2024-03-15 " },
        },
        .{
            .fields = &.{
                .{ .kind = .hour24, .offset = 0, .len = 2 },  lit.exact(2, ':'),
                .{ .kind = .minute2, .offset = 3, .len = 2 }, lit.exact(5, ':'),
                .{ .kind = .second2, .offset = 6, .len = 2 },
            },
            .inputs = &.{ "10:30:45", "10:30:60", "10-30-45", "103045", "10:30:4", "24:30:45" },
        },
        .{
            .fields = &.{
                .{ .kind = .day_space_pad, .offset = 0, .len = 2 }, lit.exact(2, ' '),
                .{ .kind = .month2, .offset = 3, .len = 2 },        lit.exact(5, '/'),
                .{ .kind = .year2, .offset = 6, .len = 2 },
            },
            .inputs = &.{ " 5 03/24", "15 03/24", " 5 03-24", "1503/24", " 5 13/24", " 5 03/2" },
        },
        .{
            .fields = &.{
                .{ .kind = .year4, .offset = 0, .len = 4 }, lit.exact(4, '-'),
                lit.class(5),                               .{ .kind = .iso_week, .offset = 6, .len = 2 },
                lit.exact(8, '-'),                          .{ .kind = .iso_week_day, .offset = 9, .len = 1 },
            },
            .inputs = &.{ "2024-W05-1", "2024-W05-7", "2024-W54-1", "2024-W05-8", "2024-W0501" },
        },
        .{
            .fields = &.{
                .{ .kind = .year4, .offset = 0, .len = 4 },
                .{ .kind = .month2, .offset = 4, .len = 2 },
                .{ .kind = .day2, .offset = 6, .len = 2 },
            },
            .inputs = &.{ "20240315", "2024-03-15", "202403", "2024xx15" },
        },
        .{
            // Not adjacent to a numeric field, so it stays an instruction.
            .fields = &.{
                .{ .kind = .year4, .offset = 0, .len = 4 },
                .{ .kind = .skip, .offset = 4, .len = 2 },
                lit.exact(6, '-'),
                .{ .kind = .month2, .offset = 7, .len = 2 },
            },
            .inputs = &.{ "2024ab-03", "2024ab-13", "2024a1-03", "2024ab/03" },
        },
    };
    for (shapes) |sh| {
        const fused = try compile(sh.fields, .{});
        var slow = fused;
        slow.width = 0; // the interpreter, so this tests fusion and not the fast path
        const plain = compileUnfused(sh.fields);
        try std.testing.expect(fused.n <= plain.n);
        for (sh.inputs) |in| {
            const want = plain.execute(in);
            const got = slow.execute(in);
            std.testing.expectEqual(want, got) catch |err| {
                std.debug.print("fused and unfused disagree on \"{s}\"\n", .{in});
                return err;
            };
        }
    }
}

test "monthNameMatches requires a whole word" {
    const Case = struct { []const u8, usize, bool };
    const cases = [_]Case{
        .{ "Mar", 0, true },
        .{ "1 Mar 2024", 2, true },
        .{ "Mar 15", 0, true },
        .{ "15 Mar", 3, true },
        .{ "Mar15", 0, true },
        .{ "15Mar", 2, true },
        .{ "Mar, 2024", 0, true },
        .{ "15-Mar-2024", 3, true },
        .{ "MAR", 0, true },
        .{ "MarAA1MAY", 0, false },
        .{ "AAMar 15", 2, false },
        .{ "xMary", 1, false },
        .{ "Maré", 0, false },
        .{ "éMar", 2, false },
        .{ "Apr", 0, false },
    };
    for (cases) |c| {
        std.testing.expectEqual(c[2], monthNameMatches(c[0], c[1], 3, 3, .{})) catch |err| {
            std.debug.print("monthNameMatches(\"{s}\", {d})\n", .{ c[0], c[1] });
            return err;
        };
    }
    try std.testing.expect(monthNameMatches("sept. 1", 0, 4, 9, .{}));
    try std.testing.expect(!monthNameMatches("Mar", 0, 3, 13, .{}));
    // Another locale's spelling counts only when the program carries it.
    if (locale.lookup("fr")) |fr| {
        try std.testing.expect(!monthNameMatches("15 mars", 3, 4, 3, .{}));
        try std.testing.expect(monthNameMatches("15 mars", 3, 4, 3, locale.only(fr)));
        try std.testing.expect(!monthNameMatches("15 mars", 3, 4, 4, locale.only(fr)));
    }
}

test "every structured format round-trips its example" {
    const base_year = 2026;
    const Want = struct { []const u8, DateTime };
    const z: DateTime = civil(2024, 3, 15, 10, 30, 0);
    const wants = [_]Want{
        .{ "ISO8601_DATE", civil(2024, 3, 15, 0, 0, 0) },
        .{ "ISO8601_DATETIME", z },
        .{ "ISO8601_DATETIME_Z", z },
        .{ "RFC3339", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .offset_seconds = 19800 } },
        .{ "RFC3339_NANO", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .nanosecond = 123_456_789 } },
        .{ "SQL_DATETIME", z },
        .{ "TIME_HM", civil(base_year, 1, 1, 10, 30, 0) },
        .{ "TIME_HMS", civil(base_year, 1, 1, 10, 30, 0) },
        .{ "COMPACT_DATE", civil(2024, 3, 15, 0, 0, 0) },
        .{ "COMPACT_DATETIME", z },
        .{ "COMPACT_DATETIME_NOSEP", z },
        .{ "COMPACT_DATETIME_Z", z },
        .{ "TIME_HM_AMPM", civil(base_year, 1, 1, 22, 30, 0) },
        .{ "TIME_HMS_AMPM", civil(base_year, 1, 1, 22, 30, 0) },
        .{ "TIME_HMS_FRAC3", .{ .year = base_year, .month = 1, .day = 1, .hour = 10, .minute = 30, .nanosecond = 123_000_000 } },
        .{ "TIME_HMS_FRAC6", .{ .year = base_year, .month = 1, .day = 1, .hour = 10, .minute = 30, .nanosecond = 123_456_000 } },
        .{ "SQL_DATETIME_FRAC6", z },
        .{ "SQL_DATETIME_FRAC3", z },
        .{ "SQL_DATETIME_TZ_SHORT", z },
        .{ "SQL_DATETIME_TZ", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .offset_seconds = 19800 } },
        .{ "RFC3339_FRAC3_TZ", .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30, .nanosecond = 123_000_000, .offset_seconds = 19800 } },
        .{ "SQL_DATETIME_COMMA_FRAC3", .{ .year = 2014, .month = 5, .day = 11, .hour = 8, .minute = 20, .second = 13, .nanosecond = 787_000_000 } },
        .{ "ISO_YEAR_MONTH", civil(2014, 4, 1, 0, 0, 0) },
        .{ "BARE_YEAR", civil(2014, 1, 1, 0, 0, 0) },
        .{ "SQL_DATETIME_TZ_NAME", civil(2014, 12, 16, 6, 20, 0) },
        .{ "SQL_DATETIME_AMPM", civil(2014, 4, 26, 17, 24, 37) },
        .{ "EXIF_DATE", civil(2014, 3, 31, 0, 0, 0) },
        .{ "EXIF_DATETIME_HM", civil(2014, 4, 8, 22, 5, 0) },
        .{ "EXIF_DATETIME_HMS", civil(2014, 4, 8, 22, 5, 13) },
        .{ "COMPACT_YYMMDD", civil(2017, 11, 13, 0, 0, 0) },
        .{ "COMPACT_YYMMDD_TIME", civil(2017, 11, 13, 14, 14, 20) },
    };
    var checked: usize = 0;
    inline for (formats.table, formats.examples) |e, ex| {
        if (e.ambiguous) continue;
        const fields = formats.stampedFields(e);
        const year: i32 = if (needsBaseYear(&fields)) base_year else 0;
        const p = try compile(&fields, .{ .base_year = year });
        const want = for (wants) |w| {
            if (std.mem.eql(u8, w[0], e.name)) break w[1];
        } else return error.NoExpectedValue;
        std.testing.expectEqual(want, try p.execute(ex[1])) catch |err| {
            std.debug.print("{s}: \"{s}\"\n", .{ e.name, ex[1] });
            return err;
        };
        checked += 1;
    }
    try expectEqual(wants.len, checked);
}

/// Compiles a table entry the way detection will, by name.
fn tableProgram(comptime name: []const u8) !Program {
    inline for (formats.table) |e| {
        if (comptime std.mem.eql(u8, e.name, name)) return compile(&formats.stampedFields(e), .{});
    }
    unreachable;
}

test "execute refuses what the calendar refuses" {
    const iso = try tableProgram("ISO8601_DATE");
    for ([_][]const u8{ "2024-02-30", "2023-02-29", "1900-02-29", "2024-04-31", "2024-00-10", "2024-01-00" }) |bad| {
        try expectError(error.NoMatch, iso.execute(bad));
    }
    try expectEqual(civil(2024, 2, 29, 0, 0, 0), try iso.execute("2024-02-29"));
    try expectEqual(civil(2000, 2, 29, 0, 0, 0), try iso.execute("2000-02-29"));
    try expectEqual(civil(0, 2, 29, 0, 0, 0), try iso.execute("0000-02-29"));

    const z = try tableProgram("ISO8601_DATETIME_Z");
    try expectError(error.NoMatch, z.execute("2016-12-31T23:59:60Z")); // leap second
    try expectError(error.NoMatch, z.execute("2024-03-15T24:00:00Z"));
    try expectError(error.NoMatch, z.execute("2024-03-15T10:60:00Z"));
    try expectError(error.NoMatch, z.execute("2024-03-15T10:30:00+"));

    // A fraction wider than a nanosecond holds is refused, not truncated.
    const wide = program(&.{
        .{ .op = .second2, .offset = 0, .len = 2 },
        .{ .op = .literal, .offset = 2, .len = 1 },
        .{ .op = .frac_sec, .offset = 3, .len = 10 },
    });
    try expectError(error.NoMatch, wide.execute("00.9999999999"));

    // hour24 under a PM would be hour 25; detection never builds it.
    const odd = program(&.{
        .{ .op = .hour24, .offset = 0, .len = 2 },
        .{ .op = .ampm, .offset = 2, .len = 2 },
    });
    try expectError(error.NoMatch, odd.execute("13PM"));
    try expectEqual(civil(0, 1, 1, 23, 0, 0), try odd.execute("11PM"));
}

test "ISO week dates exist only in years that have the week" {
    const p = program(&.{
        .{ .op = .year4, .offset = 0, .len = 4 },
        .{ .op = .literal, .offset = 4, .len = 1, .aux = '-' },
        .{ .op = .literal, .offset = 5, .len = 1, .aux = 'W' },
        .{ .op = .iso_week, .offset = 6, .len = 2 },
        .{ .op = .literal, .offset = 8, .len = 1, .aux = '-' },
        .{ .op = .iso_week_day, .offset = 9, .len = 1 },
    });
    try expectEqual(civil(2020, 12, 31, 0, 0, 0), try p.execute("2020-W53-4"));
    try expectEqual(civil(2025, 12, 29, 0, 0, 0), try p.execute("2026-W01-1"));
    try expectEqual(civil(2024, 1, 7, 0, 0, 0), try p.execute("2024-W01-7"));
    try expectEqual(civil(2015, 12, 31, 0, 0, 0), try p.execute("2015-W53-4"));
    try expectError(error.NoMatch, p.execute("2023-W53-1"));
    try expectError(error.NoMatch, p.execute("2024-W53-1"));
    try expectError(error.NoMatch, p.execute("2024-W54-1"));
    try expectError(error.NoMatch, p.execute("2024-W05-8"));
    try expectError(error.NoMatch, p.execute("2024-W00-1"));
}

test "ordinal dates exist only in years that have the day" {
    const p = program(&.{
        .{ .op = .year4, .offset = 0, .len = 4 },
        .{ .op = .literal, .offset = 4, .len = 1, .aux = '-' },
        .{ .op = .ordinal_day, .offset = 5, .len = 3 },
    });
    try expectEqual(civil(2024, 12, 31, 0, 0, 0), try p.execute("2024-366"));
    try expectEqual(civil(2000, 12, 31, 0, 0, 0), try p.execute("2000-366"));
    try expectEqual(civil(2023, 2, 1, 0, 0, 0), try p.execute("2023-032"));
    for ([_][]const u8{ "2023-366", "1900-366", "2024-367", "2024-000", "2024-3x6" }) |bad| {
        try expectError(error.NoMatch, p.execute(bad));
    }
}

test "parseTzOffset" {
    try expectEqual(19800, parseTzOffset("+05:30"));
    try expectEqual(-8 * 3600, parseTzOffset("-0800"));
    try expectEqual(0, parseTzOffset("+00"));
    try expectEqual(23 * 3600 + 59 * 60, parseTzOffset("+23:59"));
    for ([_][]const u8{ "+24:00", "+05:60", "+05x30", "05:30", "+5:30", "+0", "+05:3", "+05:300" }) |bad| {
        try expectEqual(null, parseTzOffset(bad));
    }
}

test "zone abbreviations are fixed offsets, exact case" {
    try expectEqual(3600, tz_abbreviations.get("CET"));
    try expectEqual(-5 * 3600, tz_abbreviations.get("EST"));
    try expectEqual(0, tz_abbreviations.get("UCT"));
    for ([_][]const u8{ "cet", "Utc", "PRC", "ROK", "CEST", "" }) |bad| {
        try expectEqual(null, tz_abbreviations.get(bad));
    }
}

test "validTail accepts what time.String writes and nothing else" {
    for ([_][]const u8{ "", " UTC", " +0545", " Europe/Berlin", " UTC m=+0.003691376", " CEST m=-1.5" }) |t| {
        try std.testing.expect(validTail(t));
    }
    const long: [max_tail_len + 1]u8 = @splat('x');
    for ([_][]const u8{ "x", "  UTC", " UTC ; DROP TABLE users", " UTC m=", " UTC m=abc", " UTC n=1", &long }) |t| {
        try std.testing.expect(!validTail(t));
    }
}

test "literal classes hold every byte scan gives the class" {
    try expectEqual(':', auxFor(.colon));
    try std.testing.expect(auxFor(.sep) >= aux_class_base);
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        const cc = signature.scan(&[_]u8{ ' ', c, ' ' }).buf[1];
        if (cc == .digit) {
            try std.testing.expect(!litAccepts(sep_any_non_digit, c));
            continue;
        }
        try std.testing.expect(litAccepts(auxFor(formats.litClassOf(cc)), c));
    }
    // The context-dependent bytes, in the contexts that make them special.
    for ([_]struct { []const u8, usize }{ .{ "1T2", 1 }, .{ "Z", 0 }, .{ "10:30:00-05:00", 8 } }) |ctx| {
        const sig = signature.scan(ctx[0]);
        try expectEqual(.special, sig.buf[ctx[1]]);
        try std.testing.expect(litAccepts(auxFor(.special), ctx[0][ctx[1]]));
    }
    // And the narrow ones stay narrow.
    try std.testing.expect(!litAccepts(auxFor(.sep), ':'));
    try std.testing.expect(!litAccepts(auxFor(.colon), '-'));
    try std.testing.expect(!litAccepts(auxFor(.space), '+'));
}

test "needsBaseYear" {
    try std.testing.expect(needsBaseYear(&.{.{ .kind = .hour24, .offset = 0, .len = 2 }}));
    try std.testing.expect(!needsBaseYear(&.{.{ .kind = .year2, .offset = 0, .len = 2 }}));
}

test fixedWidth {
    try expectEqual(4, fixedWidth(.year4));
    try expectEqual(2, fixedWidth(.day_space_pad));
    try expectEqual(1, fixedWidth(.tz_z));
    try expectEqual(null, fixedWidth(.frac_sec));
    try expectEqual(null, fixedWidth(.day1or2));
}

test "execute refuses a byte described by nothing or by two fields" {
    // The '-' at 4 belongs to no field. end alone is 8 = len; the sum is 7.
    const gap = program(&.{
        .{ .op = .year4, .offset = 0, .len = 4 },
        .{ .op = .ordinal_day, .offset = 5, .len = 3 },
    });
    try expectError(error.NoMatch, gap.execute("2024-001"));

    // Byte 1 is read as year and as month. end is 3 = len; the sum is 4.
    const overlap = program(&.{
        .{ .op = .year2, .offset = 0, .len = 2 },
        .{ .op = .month2, .offset = 1, .len = 2 },
    });
    try expectError(error.NoMatch, overlap.execute("112"));
}

test "skipRun cuts a run into the pieces its bytes allow" {
    const Piece = struct { []const u8, usize, u16 };
    const cases = [_]Piece{
        .{ "Mon 15", 4, aux_class_base | words_mask }, // a word and the space after it
        .{ "Miércoles,", 10, aux_class_base | words_mask }, // é is two bytes inside the word
        .{ "年04", 3, auxClass(.nonprinting) },
        .{ "\x00\x01x", 2, auxClass(.nonprinting) },
        .{ ", 2024", 1, ',' },
        .{ "  15", 2, ' ' },
        .{ "--x", 2, '-' },
        .{ " \t", 1, ' ' }, // a space and a tab are different bytes outside a word
        .{ "12ab", 2, 0 },
    };
    for (cases) |c| {
        errdefer std.debug.print("skipRun(\"{s}\")\n", .{c[0]});
        const piece = skipRun(c[0], 0, c[0].len);
        try expectEqual(c[1], piece.len);
        try expectEqual(c[2], piece.aux);
    }
    try expectEqual(0, skipRun("abc", 2, 2).len);
    try expectEqual(0, skipRun("abc", 0, 4).len);
    // A word piece accepts another word's letters but not a '+' or a digit.
    const word = skipRun("Mon", 0, 3).aux;
    try std.testing.expect(litAccepts(word, 'T') and litAccepts(word, ' '));
    try std.testing.expect(!litAccepts(word, '+') and !litAccepts(word, '7'));
}

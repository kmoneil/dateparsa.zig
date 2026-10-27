//! Format definitions compile into programs.
//!
//! A format is a list of fields, each naming what sits at a byte range of
//! the input. Detection produces the list (formats.zig holds the static
//! ones), and compiling turns it into the instructions the executor runs.

const std = @import("std");

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
    /// byte or its class. Zero in the static table, where detection derives
    /// each literal's class from the signature.
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
        .tz_z_or_offset, .tail => null,
    };
}

test fixedWidth {
    try std.testing.expectEqual(4, fixedWidth(.year4));
    try std.testing.expectEqual(2, fixedWidth(.day_space_pad));
    try std.testing.expectEqual(1, fixedWidth(.tz_z));
    try std.testing.expectEqual(null, fixedWidth(.frac_sec));
    try std.testing.expectEqual(null, fixedWidth(.day1or2));
}

//! The structured formats the detection trie knows: one entry per signature,
//! naming the fields a matching input holds.
//!
//! A signature is a sequence of character classes (signature.zig), so one
//! entry matches every spelling of its separators: "2024-03-15",
//! "2024/03/15" and "2024.03.15" are one signature and one entry. Literal
//! positions are the offsets of the .literal fields; there is no separate
//! list of them, and no Go layout string (DESIGN.md, divergence 3).
//!
//! The table is comptime data, checked at compile time against the rules
//! the executor relies on (see problem): an entry that breaks one is a
//! compile error, not a wrong date at run time.

const std = @import("std");
const signature = @import("signature.zig");
const compile = @import("compile.zig");

const CharClass = signature.CharClass;
const Field = compile.Field;
const FieldKind = compile.FieldKind;

pub const Format = struct {
    name: []const u8,
    sig: []const CharClass,
    /// In input order, covering every byte of the signature exactly once.
    fields: []const Field = &.{},
    /// The signature alone cannot say which field is which (DD/DD/DDDD):
    /// detection settles the reading and builds the fields, so this entry
    /// has none.
    ambiguous: bool = false,
};

/// Spells a signature with one letter per class, as the Go table did:
/// D digit, L letter, S separator, W space, C colon, X special.
fn sig(comptime s: []const u8) []const CharClass {
    comptime {
        var out: [s.len]CharClass = undefined;
        for (s, 0..) |c, i| out[i] = switch (c) {
            'D' => .digit,
            'L' => .letter,
            'S' => .sep,
            'W' => .space,
            'C' => .colon,
            'X' => .special,
            else => @compileError("signature letter not one of DLSWCX: " ++ s),
        };
        const final = out;
        return &final;
    }
}

fn field(kind: FieldKind, offset: u8, len: u8) Field {
    return .{ .kind = kind, .offset = offset, .len = len };
}

/// Why e cannot be a trie entry, or null when it can.
///
/// The executor counts the bytes each field covers rather than marking them,
/// so a gap, an overlap or a field listed out of order passes its check and
/// reads the wrong bytes. Go found each of those the hard way (C9, C30 and
/// the ISO_ORDINAL gap); here they are refused before the table compiles.
pub fn problem(comptime e: Format) ?[]const u8 {
    const fmt = std.fmt.comptimePrint;
    // scan stops at max_len, so a longer input truncated to max_len classes
    // would walk the trie to an entry this long and stop the cascade there.
    if (e.sig.len >= signature.max_len)
        return fmt("{s}: signature longer than scan reads", .{e.name});
    if (e.ambiguous) {
        if (e.fields.len != 0) return fmt("{s}: ambiguous entries carry no fields", .{e.name});
        return null;
    }
    if (e.fields.len == 0) return fmt("{s}: no fields", .{e.name});

    var at: usize = 0;
    for (e.fields, 0..) |f, i| {
        if (f.offset != at) return fmt(
            "{s}: field {d} at offset {d}, want {d}: fields ascend with no gap",
            .{ e.name, i, f.offset, at },
        );
        if (f.len == 0) return fmt("{s}: field {d} is empty", .{ e.name, i });
        if (compile.fixedWidth(f.kind)) |w| {
            if (f.len != w) return fmt(
                "{s}: field {d} ({t}) has len {d}, its op reads {d}",
                .{ e.name, i, f.kind, f.len, w },
            );
        }
        if (at + f.len > e.sig.len)
            return fmt("{s}: field {d} runs past the signature", .{ e.name, i });
        if (!classesFit(f.kind, e.sig[at..][0..f.len]))
            return fmt("{s}: field {d} ({t}) on classes it cannot read", .{ e.name, i, f.kind });
        at += f.len;
    }
    if (at != e.sig.len)
        return fmt("{s}: fields cover {d} of {d} bytes", .{ e.name, at, e.sig.len });
    return null;
}

/// Whether a field of kind k can sit on these signature positions. Only the
/// kinds the static table uses are allowed; the dynamic ones (month names,
/// skips, tails) come from detectors that build their own fields.
fn classesFit(k: FieldKind, classes: []const CharClass) bool {
    switch (k) {
        .year4, .year2, .month2, .day2, .hour24, .hour12, .minute2, .second2, .frac_sec => {
            for (classes) |cc| if (cc != .digit) return false;
            return true;
        },
        .literal => return classes.len == 1 and classes[0] != .digit,
        .tz_z => return classes.len == 1 and classes[0] == .special,
        .tz_offset => {
            if (classes[0] != .special) return false;
            for (classes[1..]) |cc| if (cc != .digit and cc != .colon) return false;
            return true;
        },
        .tz_name, .ampm => {
            for (classes) |cc| if (cc != .letter) return false;
            return true;
        },
        else => return false,
    }
}

/// Why the table as a whole is unusable, or null. The trie keeps one entry
/// per signature, so a repeated one would silently shadow the other.
fn tableProblem(comptime entries: []const Format) ?[]const u8 {
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) return "repeated name " ++ a.name;
            if (std.mem.eql(CharClass, a.sig, b.sig))
                return "signature shared by " ++ a.name ++ " and " ++ b.name;
        }
    }
    return null;
}

comptime {
    @setEvalBranchQuota(100_000);
    for (table) |e| if (problem(e)) |p| @compileError(p);
    if (tableProblem(&table)) |p| @compileError(p);
}

pub const table = [_]Format{
    // 2024-03-15
    .{
        .name = "ISO8601_DATE",
        .sig = sig("DDDDSDDSDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
        },
    },
    // 2024-03-15T10:30:00
    .{
        .name = "ISO8601_DATETIME",
        .sig = sig("DDDDSDDSDDXDDCDDCDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
        },
    },
    // 2024-03-15T10:30:00Z
    .{
        .name = "ISO8601_DATETIME_Z",
        .sig = sig("DDDDSDDSDDXDDCDDCDDX"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.tz_z, 19, 1),
        },
    },
    // 2024-03-15T10:30:00+05:30
    .{
        .name = "RFC3339",
        .sig = sig("DDDDSDDSDDXDDCDDCDDXDDCDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.tz_offset, 19, 6),
        },
    },
    // 2024-03-15T10:30:00.123456789Z
    .{
        .name = "RFC3339_NANO",
        .sig = sig("DDDDSDDSDDXDDCDDCDDSDDDDDDDDDX"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.literal, 19, 1),
            field(.frac_sec, 20, 9),
            field(.tz_z, 29, 1),
        },
    },
    // 2024-03-15 10:30:00
    .{
        .name = "SQL_DATETIME",
        .sig = sig("DDDDSDDSDDWDDCDDCDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
        },
    },
    // 03/15/2024
    .{
        .name = "NUMERIC_SEP",
        .sig = sig("DDSDDSDDDD"),
        .ambiguous = true,
    },
    // 10:30
    .{
        .name = "TIME_HM",
        .sig = sig("DDCDD"),
        .fields = &.{
            field(.hour24, 0, 2),
            field(.literal, 2, 1),
            field(.minute2, 3, 2),
        },
    },
    // 10:30:00
    .{
        .name = "TIME_HMS",
        .sig = sig("DDCDDCDD"),
        .fields = &.{
            field(.hour24, 0, 2),
            field(.literal, 2, 1),
            field(.minute2, 3, 2),
            field(.literal, 5, 1),
            field(.second2, 6, 2),
        },
    },
    // 20240315
    .{
        .name = "COMPACT_DATE",
        .sig = sig("DDDDDDDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.month2, 4, 2),
            field(.day2, 6, 2),
        },
    },
    // 20240315T103000
    .{
        .name = "COMPACT_DATETIME",
        .sig = sig("DDDDDDDDXDDDDDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.month2, 4, 2),
            field(.day2, 6, 2),
            field(.literal, 8, 1),
            field(.hour24, 9, 2),
            field(.minute2, 11, 2),
            field(.second2, 13, 2),
        },
    },
    // 20240315103000
    .{
        .name = "COMPACT_DATETIME_NOSEP",
        .sig = sig("DDDDDDDDDDDDDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.month2, 4, 2),
            field(.day2, 6, 2),
            field(.hour24, 8, 2),
            field(.minute2, 10, 2),
            field(.second2, 12, 2),
        },
    },
    // 20240315T103000Z
    .{
        .name = "COMPACT_DATETIME_Z",
        .sig = sig("DDDDDDDDXDDDDDDX"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.month2, 4, 2),
            field(.day2, 6, 2),
            field(.literal, 8, 1),
            field(.hour24, 9, 2),
            field(.minute2, 11, 2),
            field(.second2, 13, 2),
            field(.tz_z, 15, 1),
        },
    },
    // 10:30 PM
    .{
        .name = "TIME_HM_AMPM",
        .sig = sig("DDCDDWLL"),
        .fields = &.{
            field(.hour12, 0, 2),
            field(.literal, 2, 1),
            field(.minute2, 3, 2),
            field(.literal, 5, 1),
            field(.ampm, 6, 2),
        },
    },
    // 10:30:00 PM
    .{
        .name = "TIME_HMS_AMPM",
        .sig = sig("DDCDDCDDWLL"),
        .fields = &.{
            field(.hour12, 0, 2),
            field(.literal, 2, 1),
            field(.minute2, 3, 2),
            field(.literal, 5, 1),
            field(.second2, 6, 2),
            field(.literal, 8, 1),
            field(.ampm, 9, 2),
        },
    },
    // 10:30:00.123
    .{
        .name = "TIME_HMS_FRAC3",
        .sig = sig("DDCDDCDDSDDD"),
        .fields = &.{
            field(.hour24, 0, 2),
            field(.literal, 2, 1),
            field(.minute2, 3, 2),
            field(.literal, 5, 1),
            field(.second2, 6, 2),
            field(.literal, 8, 1),
            field(.frac_sec, 9, 3),
        },
    },
    // 10:30:00.123456
    .{
        .name = "TIME_HMS_FRAC6",
        .sig = sig("DDCDDCDDSDDDDDD"),
        .fields = &.{
            field(.hour24, 0, 2),
            field(.literal, 2, 1),
            field(.minute2, 3, 2),
            field(.literal, 5, 1),
            field(.second2, 6, 2),
            field(.literal, 8, 1),
            field(.frac_sec, 9, 6),
        },
    },
    // 2024-03-15 10:30:00.000000
    .{
        .name = "SQL_DATETIME_FRAC6",
        .sig = sig("DDDDSDDSDDWDDCDDCDDSDDDDDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.literal, 19, 1),
            field(.frac_sec, 20, 6),
        },
    },
    // 2024-03-15 10:30:00.000
    .{
        .name = "SQL_DATETIME_FRAC3",
        .sig = sig("DDDDSDDSDDWDDCDDCDDSDDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.literal, 19, 1),
            field(.frac_sec, 20, 3),
        },
    },
    // 2024-03-15 10:30:00+00
    .{
        .name = "SQL_DATETIME_TZ_SHORT",
        .sig = sig("DDDDSDDSDDWDDCDDCDDXDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.tz_offset, 19, 3),
        },
    },
    // 2024-03-15 10:30:00+05:30
    .{
        .name = "SQL_DATETIME_TZ",
        .sig = sig("DDDDSDDSDDWDDCDDCDDXDDCDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.tz_offset, 19, 6),
        },
    },
    // 2024-03-15T10:30:00.123+05:30
    .{
        .name = "RFC3339_FRAC3_TZ",
        .sig = sig("DDDDSDDSDDXDDCDDCDDSDDDXDDCDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.literal, 19, 1),
            field(.frac_sec, 20, 3),
            field(.tz_offset, 23, 6),
        },
    },
    // 2014-05-11 08:20:13,787
    .{
        .name = "SQL_DATETIME_COMMA_FRAC3",
        .sig = sig("DDDDSDDSDDWDDCDDCDDXDDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.literal, 19, 1),
            field(.frac_sec, 20, 3),
        },
    },
    // 2014-04
    .{
        .name = "ISO_YEAR_MONTH",
        .sig = sig("DDDDSDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
        },
    },
    // 2014
    .{
        .name = "BARE_YEAR",
        .sig = sig("DDDD"),
        .fields = &.{
            field(.year4, 0, 4),
        },
    },
    // 2014-12-16 06:20:00 UTC
    .{
        .name = "SQL_DATETIME_TZ_NAME",
        .sig = sig("DDDDSDDSDDWDDCDDCDDWLLL"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.literal, 19, 1),
            field(.tz_name, 20, 3),
        },
    },
    // 2014-04-26 05:24:37 PM
    .{
        .name = "SQL_DATETIME_AMPM",
        .sig = sig("DDDDSDDSDDWDDCDDCDDWLL"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour12, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
            field(.literal, 19, 1),
            field(.ampm, 20, 2),
        },
    },
    // 2014:03:31
    .{
        .name = "EXIF_DATE",
        .sig = sig("DDDDCDDCDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
        },
    },
    // 2014:04:08 22:05
    .{
        .name = "EXIF_DATETIME_HM",
        .sig = sig("DDDDCDDCDDWDDCDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
        },
    },
    // 2014:04:08 22:05:13
    .{
        .name = "EXIF_DATETIME_HMS",
        .sig = sig("DDDDCDDCDDWDDCDDCDD"),
        .fields = &.{
            field(.year4, 0, 4),
            field(.literal, 4, 1),
            field(.month2, 5, 2),
            field(.literal, 7, 1),
            field(.day2, 8, 2),
            field(.literal, 10, 1),
            field(.hour24, 11, 2),
            field(.literal, 13, 1),
            field(.minute2, 14, 2),
            field(.literal, 16, 1),
            field(.second2, 17, 2),
        },
    },
    // 171113
    .{
        .name = "COMPACT_YYMMDD",
        .sig = sig("DDDDDD"),
        .fields = &.{
            field(.year2, 0, 2),
            field(.month2, 2, 2),
            field(.day2, 4, 2),
        },
    },
    // 171113 14:14:20
    .{
        .name = "COMPACT_YYMMDD_TIME",
        .sig = sig("DDDDDDWDDCDDCDD"),
        .fields = &.{
            field(.year2, 0, 2),
            field(.month2, 2, 2),
            field(.day2, 4, 2),
            field(.literal, 6, 1),
            field(.hour24, 7, 2),
            field(.literal, 9, 1),
            field(.minute2, 10, 2),
            field(.literal, 12, 1),
            field(.second2, 13, 2),
        },
    },
};

/// One input per entry, in table order: each one's signature is the entry's.
const examples = [_]struct { []const u8, []const u8 }{
    .{ "ISO8601_DATE", "2024-03-15" },
    .{ "ISO8601_DATETIME", "2024-03-15T10:30:00" },
    .{ "ISO8601_DATETIME_Z", "2024-03-15T10:30:00Z" },
    .{ "RFC3339", "2024-03-15T10:30:00+05:30" },
    .{ "RFC3339_NANO", "2024-03-15T10:30:00.123456789Z" },
    .{ "SQL_DATETIME", "2024-03-15 10:30:00" },
    .{ "NUMERIC_SEP", "03/15/2024" },
    .{ "TIME_HM", "10:30" },
    .{ "TIME_HMS", "10:30:00" },
    .{ "COMPACT_DATE", "20240315" },
    .{ "COMPACT_DATETIME", "20240315T103000" },
    .{ "COMPACT_DATETIME_NOSEP", "20240315103000" },
    .{ "COMPACT_DATETIME_Z", "20240315T103000Z" },
    .{ "TIME_HM_AMPM", "10:30 PM" },
    .{ "TIME_HMS_AMPM", "10:30:00 PM" },
    .{ "TIME_HMS_FRAC3", "10:30:00.123" },
    .{ "TIME_HMS_FRAC6", "10:30:00.123456" },
    .{ "SQL_DATETIME_FRAC6", "2024-03-15 10:30:00.000000" },
    .{ "SQL_DATETIME_FRAC3", "2024-03-15 10:30:00.000" },
    .{ "SQL_DATETIME_TZ_SHORT", "2024-03-15 10:30:00+00" },
    .{ "SQL_DATETIME_TZ", "2024-03-15 10:30:00+05:30" },
    .{ "RFC3339_FRAC3_TZ", "2024-03-15T10:30:00.123+05:30" },
    .{ "SQL_DATETIME_COMMA_FRAC3", "2014-05-11 08:20:13,787" },
    .{ "ISO_YEAR_MONTH", "2014-04" },
    .{ "BARE_YEAR", "2014" },
    .{ "SQL_DATETIME_TZ_NAME", "2014-12-16 06:20:00 UTC" },
    .{ "SQL_DATETIME_AMPM", "2014-04-26 05:24:37 PM" },
    .{ "EXIF_DATE", "2014:03:31" },
    .{ "EXIF_DATETIME_HM", "2014:04:08 22:05" },
    .{ "EXIF_DATETIME_HMS", "2014:04:08 22:05:13" },
    .{ "COMPACT_YYMMDD", "171113" },
    .{ "COMPACT_YYMMDD_TIME", "171113 14:14:20" },
};

test {
    std.testing.refAllDecls(@This());
}

test "the table has the Go table's 32 entries" {
    try std.testing.expectEqual(32, table.len);
}

test "each entry's signature is what scan makes of an input in that format" {
    try std.testing.expectEqual(table.len, examples.len);
    for (table, examples) |e, ex| {
        try std.testing.expectEqualStrings(e.name, ex[0]);
        const got = signature.scan(ex[1]);
        std.testing.expectEqualSlices(CharClass, e.sig, got.classes()) catch |err| {
            std.debug.print("{s}: scan(\"{s}\") disagrees with the entry\n", .{ e.name, ex[1] });
            return err;
        };
    }
}

fn entry(comptime name: []const u8, comptime s: []const u8, comptime fields: []const Field) Format {
    return .{ .name = name, .sig = sig(s), .fields = fields };
}

test "problem refuses the shapes the executor cannot survive" {
    const ym = comptime entry("T", "DDDDSDD", &.{
        field(.year4, 0, 4),
        field(.literal, 4, 1),
        field(.month2, 5, 2),
    });
    comptime std.debug.assert(problem(ym) == null);

    const refused = comptime [_]Format{
        // A gap: the separator is described by nothing.
        entry("gap", "DDDDSDD", &.{ field(.year4, 0, 4), field(.month2, 5, 2) }),
        // Out of order, which the executor's running delta gets wrong.
        entry("order", "DDDDSDD", &.{
            field(.literal, 4, 1),
            field(.year4, 0, 4),
            field(.month2, 5, 2),
        }),
        // Over-wide fixed field: detection would check bytes the op never reads.
        entry("width", "DDDSDDDD", &.{
            field(.day2, 0, 3),
            field(.literal, 3, 1),
            field(.year4, 4, 4),
        }),
        // Short of the signature.
        entry("short", "DDDDSDD", &.{ field(.year4, 0, 4), field(.literal, 4, 1) }),
        // A literal on a digit, and a number on a separator.
        entry("digit literal", "DDDDD", &.{ field(.year4, 0, 4), field(.literal, 4, 1) }),
        entry("sep number", "DDDDSD", &.{ field(.year4, 0, 4), field(.year2, 4, 2) }),
        // An ambiguous entry with fields, and an unambiguous one without.
        .{ .name = "ambiguous", .sig = ym.sig, .fields = ym.fields, .ambiguous = true },
        entry("empty", "DDDDSDD", &.{}),
        // A kind the static table never uses.
        entry("tail", "DDDDL", &.{ field(.year4, 0, 4), field(.tail, 4, 1) }),
    };
    inline for (refused) |e| {
        if (comptime problem(e) == null) {
            std.debug.print("problem accepted {s}\n", .{e.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "tableProblem refuses repeated names and shared signatures" {
    const a = comptime entry("A", "DDDD", &.{field(.year4, 0, 4)});
    const b = comptime entry("B", "DDDD", &.{field(.year4, 0, 4)});
    const a2 = comptime entry("A", "DDDDDD", &.{
        field(.year2, 0, 2),
        field(.month2, 2, 2),
        field(.day2, 4, 2),
    });
    try std.testing.expect(comptime tableProblem(&.{ a, b }) != null);
    try std.testing.expect(comptime tableProblem(&.{ a, a2 }) != null);
    try std.testing.expect(comptime tableProblem(&.{ a2, b }) == null);
}

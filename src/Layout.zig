//! A detected format, compiled: re-parses every value written the same way
//! with no detection and no allocation.
//!
//! The reuse contract, all of it carried by the program or by this type:
//!
//! - Padding does not break reuse: a layout from detection trims surrounding
//!   ASCII whitespace the same way detection did.
//! - A one-or-two-digit field widens, never narrows: a layout from
//!   "1 May 2024" reads "12 May 2024"; one from "12 May 2024" refuses
//!   "1 May 2024".
//! - Skipped words take any letters, spaces or accented bytes of the same
//!   width ("Fri" reads "Sat"); every other skipped byte must be the one the
//!   first value had there.
//! - Month names are read in the locales detection searched, and no others.
//! - The epoch and natural-language sentinels have no program and refuse to
//!   re-parse: "3 days ago" means a different day tomorrow.
//! - A format detection resolves per value (DD/MM against MM/DD, a day or a
//!   two-digit year) still parses, the first value's way, but reports
//!   reusable() false: which part is the month is decided per row.

const std = @import("std");
const DateTime = @import("DateTime.zig");
const compile = @import("compile.zig");
const detect = @import("detect.zig");
const formats = @import("formats.zig");
const signature = @import("signature.zig");

const Layout = @This();

source: Source = .program,
program: compile.Program = .{},
/// The format's name, a comptime string: "ISO8601_DATE", "NUMERIC_MDY".
label: []const u8,
/// The value this layout came from needed a guess.
ambiguous: bool = false,
/// The format can need a guess on some value, whether or not this one did.
ambiguity_prone: bool = false,
/// Trim surrounding padding before executing, as detection did. Only a
/// layout from detection does.
trims_padding: bool = false,

/// Where a layout came from: a compiled format, or one of the sentinels.
pub const Source = enum { program, epoch, natural_language };

/// What a Unix timestamp's result carries: there is no format to reuse.
pub const epoch: Layout = .{ .source = .epoch, .label = "UNIX_TIMESTAMP" };

/// What a natural-language result carries: the answer depends on the base
/// time, so re-running it is not re-parsing.
pub const natural_language: Layout = .{ .source = .natural_language, .label = "NATURAL_LANGUAGE" };

/// The layout for a detection result, compiled under config.
pub fn fromDetection(r: *const detect.Result, config: compile.Config) error{TooManyFields}!Layout {
    return .{
        .program = try compile.compile(r.def.fields(), config),
        .label = r.def.name,
        .ambiguous = r.ambiguous(),
        .ambiguity_prone = r.prone,
        .trims_padding = true,
    };
}

/// The order a numeric date writes its year, month and day in.
pub const Order = enum {
    /// "03/04/2024" is the 4th of March.
    month_first,
    /// "03/04/2024" is the 3rd of April.
    day_first,
    /// "24/03/04" is the 4th of March 2024.
    year_first,
};

/// The order this layout reads a numeric date's fields in, or null when it
/// reads no such date: a month name, a week or ordinal date, a time alone,
/// a timestamp or natural language.
pub fn dateOrder(l: *const Layout) ?Order {
    if (l.source != .program) return null;
    var roles: [3]u8 = undefined;
    var n: usize = 0;
    // The program reads its fields in input order.
    for (l.program.insts[0..l.program.n]) |inst| {
        const role: u8 = switch (inst.op) {
            .year4, .year2 => 'Y',
            .month2, .month1or2 => 'M',
            .day2, .day1or2, .day_space_pad => 'D',
            .month_name, .iso_week, .iso_week_day, .ordinal_day => return null,
            else => continue,
        };
        if (n == roles.len) return null;
        roles[n] = role;
        n += 1;
    }
    if (n != roles.len) return null;
    if (std.mem.eql(u8, &roles, "MDY")) return .month_first;
    if (std.mem.eql(u8, &roles, "DMY")) return .day_first;
    if (std.mem.eql(u8, &roles, "YMD")) return .year_first;
    return null;
}

/// Whether the rest of a column can be parsed with this layout: false for
/// the sentinels and for formats resolved per value.
pub fn reusable(l: *const Layout) bool {
    return l.source == .program and !l.ambiguity_prone;
}

/// s read with this layout's format. A sentinel refuses everything.
pub fn parse(l: *const Layout, s: []const u8) error{NoMatch}!DateTime {
    if (l.source != .program) return error.NoMatch;
    const value = if (l.trims_padding and signature.hasPadding(s)) signature.trimPadding(s) else s;
    return l.program.execute(value);
}

/// The layout every default-configuration parse of a trie format shares,
/// compiled at comptime: UTC, no locales, no base year needed. Null for a
/// trie entry that is ambiguous or needs a base year.
pub fn interned(trie_index: u8) ?*const Layout {
    if (interned_table[trie_index]) |*l| return l;
    return null;
}

const interned_table: [formats.table.len]?Layout = blk: {
    @setEvalBranchQuota(100_000);
    var out: [formats.table.len]?Layout = @splat(null);
    for (formats.table, 0..) |e, i| {
        if (e.ambiguous) continue;
        const fields = formats.stampedFields(e);
        if (compile.needsBaseYear(&fields)) continue;
        out[i] = .{
            .program = compile.compile(&fields, .{}) catch unreachable,
            .label = e.name,
            .trims_padding = true,
        };
    }
    break :blk out;
};

test {
    std.testing.refAllDecls(@This());
}

const locale = @import("locale.zig");

fn layoutOf(s: []const u8, cfg: detect.Config) !Layout {
    const r = detect.detect(s, cfg) orelse return error.NotDetected;
    return fromDetection(&r, .{ .locales = cfg.locales });
}

fn date(y: i32, m: u8, d: u8) DateTime {
    return .{ .year = y, .month = m, .day = d };
}

test "the sentinels refuse to re-parse" {
    try std.testing.expect(!epoch.reusable());
    try std.testing.expect(!natural_language.reusable());
    try std.testing.expectError(error.NoMatch, epoch.parse("1710504800"));
    try std.testing.expectError(error.NoMatch, natural_language.parse("3 days ago"));
    // An empty program describes the empty input; a sentinel still refuses it.
    try std.testing.expectError(error.NoMatch, epoch.parse(""));
    try std.testing.expectError(error.NoMatch, natural_language.parse(""));
}

test "each interned layout is what compiling its entry gives" {
    var interned_count: usize = 0;
    inline for (formats.table, 0..) |e, i| {
        errdefer std.debug.print("{s}\n", .{e.name});
        const got = interned(@intCast(i));
        if (e.ambiguous) {
            try std.testing.expectEqual(null, got);
            continue;
        }
        const fields = comptime formats.stampedFields(e);
        if (comptime compile.needsBaseYear(&fields)) {
            try std.testing.expectEqual(null, got);
            continue;
        }
        const want: Layout = .{
            .program = try compile.compile(&fields, .{}),
            .label = e.name,
            .trims_padding = true,
        };
        try std.testing.expectEqualDeep(want, got.?.*);
        // A trie format reads no month name, so no locale set can change it.
        for (got.?.program.insts[0..got.?.program.n]) |inst| try std.testing.expect(inst.op != .month_name);
        interned_count += 1;
    }
    try std.testing.expect(interned_count >= 20);
}

test "a trie hit names its interned layout, and the two agree" {
    for ([_][]const u8{ "2024-03-15", "2024-03-15T10:30:00Z", "20240315", "2024-03-15 10:30:00 UTC" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        const r = detect.detect(s, .{}).?;
        const shared = interned(r.trie_index.?).?;
        const fresh = try fromDetection(&r, .{});
        try std.testing.expectEqualDeep(fresh, shared.*);
        try std.testing.expectEqual(try fresh.parse(s), try shared.parse(s));
    }
    // A fallback detection has no trie entry and so nothing interned.
    try std.testing.expectEqual(null, detect.detect("March 15, 2024", .{}).?.trie_index);
}

test "padding does not break reuse" {
    const l = try layoutOf("2024-03-15", .{});
    try std.testing.expect(l.reusable());
    for ([_][]const u8{ "2024-03-16", " 2024-03-16", "2024-03-16 ", "\t2024-03-16\r\n" }) |row| {
        errdefer std.debug.print("\"{s}\"\n", .{row});
        try std.testing.expectEqual(date(2024, 3, 16), try l.parse(row));
    }
    // Unicode space is not padding.
    try std.testing.expectError(error.NoMatch, l.parse("\u{a0}2024-03-16"));
    // A layout not from detection keeps its input exactly.
    var raw = l;
    raw.trims_padding = false;
    try std.testing.expectError(error.NoMatch, raw.parse(" 2024-03-16"));
}

test "a one-or-two-digit day widens and never narrows" {
    const narrow = try layoutOf("1 May 2024", .{});
    try std.testing.expectEqual(date(2024, 5, 12), try narrow.parse("12 May 2024"));
    const textual = try layoutOf("May 1, 2024", .{});
    try std.testing.expectEqual(date(2024, 5, 12), try textual.parse("May 12, 2024"));
    const numeric = try layoutOf("3/1/2024", .{});
    try std.testing.expectEqual(date(2024, 3, 12), try numeric.parse("3/12/2024"));
    const wide = try layoutOf("12 May 2024", .{});
    try std.testing.expectError(error.NoMatch, wide.parse("1 May 2024"));
}

test "skipped words take any letters of their width, other bytes must match" {
    const rfc = try layoutOf("Fri, 15 Mar 2024 10:30:00 +0000", .{});
    const got = try rfc.parse("Sat, 16 Mar 2024 11:30:00 -0700");
    try std.testing.expectEqual(DateTime{ .year = 2024, .month = 3, .day = 16, .hour = 11, .minute = 30, .offset_seconds = -25200 }, got);
    const plain = try layoutOf("March 15, 2024", .{});
    try std.testing.expectEqual(date(2024, 3, 16), try plain.parse("March 16, 2024"));
    try std.testing.expectError(error.NoMatch, plain.parse("March 16; 2024"));
    // The month is verified, never assumed: April is as wide as March.
    try std.testing.expectError(error.NoMatch, plain.parse("April 16, 2024"));
}

test "a format resolved per value parses the first value's way and is not reusable" {
    const day_month = try layoutOf("25/12/2024", .{});
    try std.testing.expect(!day_month.ambiguous and day_month.ambiguity_prone and !day_month.reusable());
    try std.testing.expectEqual(date(2024, 2, 1), try day_month.parse("01/02/2024"));

    const settled = try layoutOf("13/01/2024", .{});
    try std.testing.expect(!settled.reusable());

    const guessed = try layoutOf("01/02/2024", .{});
    try std.testing.expect(guessed.ambiguous and !guessed.reusable());

    const year_day = try layoutOf("70MAY1", .{});
    try std.testing.expect(!year_day.reusable());
    try std.testing.expectEqual(date(2001, 5, 10), try year_day.parse("01MAY10"));

    try std.testing.expect((try layoutOf("2024-03-15", .{})).reusable());
    try std.testing.expect((try layoutOf("March 15, 2024", .{})).reusable());
}

test "a layout reads only the locales it was detected with" {
    const de = locale.only(locale.lookup("de") orelse return error.SkipZigTest);
    const l = try layoutOf("15 März 2024", .{ .locales = de });
    try std.testing.expectEqual(date(2025, 3, 20), try l.parse("20 März 2025"));
    try std.testing.expectEqual(date(2025, 3, 20), try l.parse("20 March 2025")); // English always
    if (locale.lookup("fr") != null) try std.testing.expectError(error.NoMatch, l.parse("20 mars 2025"));
    try std.testing.expectEqualStrings("DAY_MONTH_YEAR", l.label);
}

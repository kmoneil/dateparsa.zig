//! Locale data: month, weekday and relative-time words for the twenty
//! languages the Go original ships, generated from its CLDR-derived tables
//! by tools/locale_gen.zig into src/locale/.
//!
//! Which locales are compiled in is a build option, -Dlocales=fr,de,...,
//! default all twenty; English always is. Only compiled-in data reaches the
//! binary, and LocaleSet has a field for exactly those locales, so naming
//! an excluded one in a set literal is a compile error.

const std = @import("std");
const build_options = @import("build_options");

pub const Data = struct {
    tag: []const u8, // BCP 47, lowercase
    name: []const u8, // in English
    months_wide: [12][]const u8, // index 0 is January
    months_abbr: [12][]const u8,
    weekdays_wide: [7][]const u8, // index 0 is Sunday
    weekdays_abbr: [7][]const u8,
    am: []const u8,
    pm: []const u8,
    relative: Relative,
};

/// The words natural-language expressions are built from.
pub const Relative = struct {
    now: []const []const u8,
    today: []const []const u8,
    yesterday: []const []const u8,
    tomorrow: []const []const u8,
    ago: []const []const u8, // "3 days ago"
    in_future: []const []const u8, // "in 3 days"
    last: []const []const u8,
    next: []const []const u8,
    this: []const []const u8,
    seconds: []const []const u8,
    minutes: []const []const u8,
    hours: []const []const u8,
    days: []const []const u8,
    weeks: []const []const u8,
    months: []const []const u8,
    years: []const []const u8,
};

/// Every locale the generator writes, in tag order.
const available = .{
    .{ "ar", @import("locale/ar.zig") },
    .{ "da", @import("locale/da.zig") },
    .{ "de", @import("locale/de.zig") },
    .{ "en", @import("locale/en.zig") },
    .{ "es", @import("locale/es.zig") },
    .{ "fi", @import("locale/fi.zig") },
    .{ "fr", @import("locale/fr.zig") },
    .{ "hi", @import("locale/hi.zig") },
    .{ "it", @import("locale/it.zig") },
    .{ "ja", @import("locale/ja.zig") },
    .{ "ko", @import("locale/ko.zig") },
    .{ "nl", @import("locale/nl.zig") },
    .{ "no", @import("locale/no.zig") },
    .{ "pl", @import("locale/pl.zig") },
    .{ "pt", @import("locale/pt.zig") },
    .{ "ru", @import("locale/ru.zig") },
    .{ "sv", @import("locale/sv.zig") },
    .{ "tr", @import("locale/tr.zig") },
    .{ "uk", @import("locale/uk.zig") },
    .{ "zh", @import("locale/zh.zig") },
};

/// Whether -Dlocales asks for tag. A tag the option names that no locale
/// has is a compile error, not a silently smaller build.
fn wanted(comptime tag: []const u8) bool {
    @setEvalBranchQuota(10_000);
    const option = build_options.locales;
    if (std.mem.eql(u8, tag, "en") or std.mem.eql(u8, option, "all")) return true;
    var it = std.mem.tokenizeAny(u8, option, ", ");
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, tag)) return true;
    }
    return false;
}

comptime {
    @setEvalBranchQuota(10_000);
    if (!std.mem.eql(u8, build_options.locales, "all")) {
        var it = std.mem.tokenizeAny(u8, build_options.locales, ", ");
        outer: while (it.next()) |t| {
            for (available) |a| {
                if (std.mem.eql(u8, a[0], t)) continue :outer;
            }
            @compileError("-Dlocales names \"" ++ t ++ "\", which is not a locale");
        }
    }
}

/// The compiled-in locales, in tag order. A locale's index here is its bit
/// in LocaleSet.
pub const compiled: []const *const Data = blk: {
    @setEvalBranchQuota(10_000);
    var n: usize = 0;
    for (available) |a| {
        if (wanted(a[0])) n += 1;
    }
    var out: [n]*const Data = undefined;
    var i: usize = 0;
    for (available) |a| {
        if (wanted(a[0])) {
            out[i] = &a[1].data;
            i += 1;
        }
    }
    const final = out;
    break :blk &final;
};

const Backing = @Int(.unsigned, compiled.len);

/// A set of compiled-in locales, one bool field per locale named by its tag
/// (`.{ .fr = true, .de = true }`). The empty set means English month names
/// only, which the executor and detection always accept.
pub const LocaleSet = blk: {
    var names: [compiled.len][]const u8 = undefined;
    for (compiled, 0..) |d, i| names[i] = d.tag;
    break :blk @Struct(
        .@"packed",
        Backing,
        &names,
        &@splat(bool),
        &@splat(.{ .default_value_ptr = &false }),
    );
};

/// Whether set holds compiled[i].
pub fn contains(set: LocaleSet, i: usize) bool {
    const bits: Backing = @bitCast(set);
    return (bits >> @intCast(i)) & 1 == 1;
}

/// The set holding only compiled[i].
pub fn only(i: usize) LocaleSet {
    const one: Backing = 1;
    return @bitCast(one << @intCast(i));
}

pub fn isEmpty(set: LocaleSet) bool {
    return @as(Backing, @bitCast(set)) == 0;
}

/// The index in compiled of the locale a BCP 47 tag names, matched without
/// case, falling back to the base language ("fr-CA" is French). Null when
/// that locale is not compiled in.
pub fn lookup(tag: []const u8) ?usize {
    if (indexOf(tag)) |i| return i;
    const dash = std.mem.indexOfScalar(u8, tag, '-') orelse return null;
    if (dash == 0) return null;
    return indexOf(tag[0..dash]);
}

fn indexOf(tag: []const u8) ?usize {
    for (compiled, 0..) |d, i| {
        if (std.ascii.eqlIgnoreCase(d.tag, tag)) return i;
    }
    return null;
}

/// Whether name spells month (1..12) in one of set's locales, wide or
/// abbreviated, an abbreviation with or without its trailing dot.
///
/// Case folds for ASCII letters only, which is what detection does when it
/// finds a month name: verification has to accept exactly what detection
/// finds, or a reused layout reads a month detection would refuse. Go's
/// MatchesMonth folds Unicode, so there a layout from "15 марта 2024"
/// accepts "15 МАРТА 2024" while Parse refuses it; this does not.
pub fn matchesMonth(name: []const u8, month: u8, set: LocaleSet) bool {
    if (month < 1 or month > 12 or name.len == 0) return false;
    for (compiled, 0..) |d, i| {
        if (!contains(set, i)) continue;
        for ([_][]const u8{ d.months_wide[month - 1], d.months_abbr[month - 1] }) |spelling| {
            if (spelling.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(name, spelling)) return true;
            const bare = std.mem.trimEnd(u8, spelling, ".");
            if (bare.len != 0 and bare.len != spelling.len and std.ascii.eqlIgnoreCase(name, bare))
                return true;
        }
    }
    return false;
}

test {
    std.testing.refAllDecls(@This());
}

test "the compiled locales are in tag order and English is one" {
    for (compiled[1..], compiled[0 .. compiled.len - 1]) |b, a| {
        try std.testing.expect(std.mem.order(u8, a.tag, b.tag) == .lt);
    }
    try std.testing.expect(lookup("en") != null);
    if (std.mem.eql(u8, build_options.locales, "all")) try std.testing.expectEqual(20, compiled.len);
}

test "lookup by BCP 47 tag" {
    const en = lookup("en").?;
    try std.testing.expectEqualStrings("English", compiled[en].name);
    try std.testing.expectEqual(en, lookup("EN"));
    try std.testing.expectEqual(en, lookup("en-GB"));
    try std.testing.expectEqual(null, lookup("xx"));
    try std.testing.expectEqual(null, lookup(""));
    try std.testing.expectEqual(null, lookup("-en"));
    if (lookup("fr")) |fr| try std.testing.expectEqual(fr, lookup("fr-CA"));
}

test "every compiled locale's data has every part" {
    for (compiled) |d| {
        errdefer std.debug.print("locale {s}\n", .{d.tag});
        for (d.months_wide ++ d.months_abbr ++ d.weekdays_wide ++ d.weekdays_abbr) |s| {
            try std.testing.expect(s.len > 0);
            try std.testing.expect(std.unicode.utf8ValidateSlice(s));
        }
        const r = d.relative;
        for ([_][]const []const u8{ r.now, r.today, r.yesterday, r.tomorrow, r.days }) |words| {
            try std.testing.expect(words.len > 0);
        }
    }
}

test "every spelling of every month matches in its own locale" {
    for (compiled, 0..) |d, i| {
        errdefer std.debug.print("locale {s}\n", .{d.tag});
        const own = only(i);
        for (d.months_wide, d.months_abbr, 1..) |wide, abbr, month| {
            const m: u8 = @intCast(month);
            try std.testing.expect(matchesMonth(wide, m, own));
            try std.testing.expect(matchesMonth(abbr, m, own));
            try std.testing.expect(matchesMonth(std.mem.trimEnd(u8, abbr, "."), m, own));
            // Not without the locale, and not as another month (unless the
            // locale spells two months alike, which none does).
            try std.testing.expect(!matchesMonth(wide, m, .{}));
            try std.testing.expect(!matchesMonth(wide, @intCast(month % 12 + 1), own));
        }
    }
}

test "month names fold ASCII case, and only ASCII case" {
    if (lookup("de")) |de| {
        try std.testing.expect(matchesMonth("MAI", 5, only(de)));
        try std.testing.expect(matchesMonth("märz", 3, only(de)));
        try std.testing.expect(matchesMonth("MäRZ", 3, only(de)));
        // Ä is not folded, as detection does not fold it.
        try std.testing.expect(!matchesMonth("MÄRZ", 3, only(de)));
    }
    if (lookup("ru")) |ru| {
        try std.testing.expect(matchesMonth("марта", 3, only(ru)));
        try std.testing.expect(matchesMonth("янв", 1, only(ru)));
        try std.testing.expect(!matchesMonth("МАРТА", 3, only(ru)));
    }
}

test "a set literal names locales by tag" {
    if (!@hasField(LocaleSet, "fr") or !@hasField(LocaleSet, "de")) return error.SkipZigTest;
    const set: LocaleSet = .{ .fr = true, .de = true };
    try std.testing.expect(contains(set, lookup("fr").?));
    try std.testing.expect(contains(set, lookup("de").?));
    try std.testing.expect(!contains(set, lookup("en").?));
    try std.testing.expect(!isEmpty(set));
    try std.testing.expect(isEmpty(.{}));
    try std.testing.expect(matchesMonth("mai", 5, set));
}

test "the compiled locales are exactly the ones -Dlocales asks for, and English" {
    const option = build_options.locales;
    if (std.mem.eql(u8, option, "all")) return;
    for (compiled) |d| {
        if (std.mem.eql(u8, d.tag, "en")) continue;
        var it = std.mem.tokenizeAny(u8, option, ", ");
        const named = while (it.next()) |t| {
            if (std.mem.eql(u8, t, d.tag)) break true;
        } else false;
        try std.testing.expect(named);
    }
}

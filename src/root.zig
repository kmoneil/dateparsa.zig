//! dateparsa: date parsing for input whose format you do not control.
//!
//! A Zig port of dateparsa (github.com/kmoneil/dateparsa). Detection and
//! parsing are separate problems: parse detects the format once and hands
//! back a reusable Layout that re-parses the same format with no detection
//! and no allocation.
//!
//! Nothing here allocates, reads a clock, or touches the filesystem. All
//! detection tables are comptime data. An input that needs a base time
//! (relative words, a format with no year) and was not given one fails with
//! error.NoBaseTime rather than reading the clock.

const std = @import("std");
const compile = @import("compile.zig");
const detection = @import("detect.zig");
const ambiguity = @import("ambiguity.zig");
const epoch = @import("epoch.zig");
const natural = @import("natural.zig");
const signature = @import("signature.zig");
const locale = @import("locale.zig");

/// A civil date and time with a fixed UTC offset: what every parse returns.
pub const DateTime = @import("DateTime.zig");
/// A detected format, compiled, to re-parse the rest of a column with.
pub const Layout = @import("Layout.zig");
/// Parses a column, reusing the first value's layout where it can.
pub const Parser = @import("Parser.zig");
/// The locales whose words are read besides English, one field per locale
/// this build compiled in: `.{ .fr = true, .de = true }`.
pub const LocaleSet = locale.LocaleSet;

/// Why a parse failed. Diagnostics, when asked for, says more.
pub const ParseError = error{
    /// No format, timestamp or natural-language reading fits.
    NoMatch,
    /// Strict mode only: more than one reading fits.
    Ambiguous,
    /// The input needs a base time and Options carries none.
    NoBaseTime,
};

/// What sort of time a result is.
pub const Kind = enum {
    /// A structured date or a timestamp: "2024-03-15", "March 15, 2024".
    absolute,
    /// Relative to the base time: "3 days ago", "yesterday".
    relative,
    /// The base time itself, or its day: "now", "today".
    now,
};

/// A successful parse.
pub const Result = struct {
    time: DateTime,
    /// The format detected, to reuse on the rest of a column when
    /// layout.reusable() says so.
    layout: Layout,
    /// The input needed a guess: "01/02/2024" is the 2nd of January or the
    /// 1st of February, and the preferences picked one.
    ambiguous: bool,
    kind: Kind,
};

/// One way to read an input strict mode refused to choose for.
pub const Interpretation = struct {
    time: DateTime,
    layout: Layout,
    /// "MM/DD/YYYY", "DD/MM/YY", "MONTH_YEAR", or "NATURAL_LANGUAGE". A
    /// comptime string.
    label: []const u8,
};

/// What a failed parse can say beyond its error, when Options asks for it.
pub const Diagnostics = struct {
    /// On error.Ambiguous: the readings that fit, the preferred one first.
    /// Fewer than two means the input was ambiguous but no two readings of
    /// it are dates.
    interpretations: [3]Interpretation = undefined,
    interpretation_count: u8 = 0,
    /// What refused the input. A comptime string; no input bytes are kept.
    message: []const u8 = "",

    pub fn slice(d: *const Diagnostics) []const Interpretation {
        return d.interpretations[0..d.interpretation_count];
    }

    fn add(d: *Diagnostics, in: Interpretation) void {
        d.interpretations[d.interpretation_count] = in;
        d.interpretation_count += 1;
    }
};

/// How to read an input. The default reads English, assumes UTC for an
/// input that writes no zone, and has no base time.
pub const Options = struct {
    /// What relative expressions and year-less formats are read against.
    /// Null means such inputs fail with error.NoBaseTime.
    base_time: ?DateTime = null,
    /// UTC offset, seconds east, for an input that writes no zone.
    timezone_offset: i32 = 0,
    /// "01/02/2024" is the 1st of February.
    prefer_day_first: bool = false,
    /// "01/02/03" is 2001-02-03.
    prefer_year_first: bool = false,
    /// A bare weekday is the next one, not the last.
    prefer_future: bool = false,
    /// Refuse a guess with error.Ambiguous instead of taking it.
    strict: bool = false,
    /// Locales whose month names and relative words are read, besides
    /// English, which always is: `.{ .fr = true, .de = true }`.
    locales: LocaleSet = .{},
    /// Filled in when parsing fails.
    diagnostics: ?*Diagnostics = null,
};

/// The locale set holding the locale a BCP 47 tag names ("fr", "fr-CA"),
/// or null when the build did not compile it in.
pub fn localeSet(tag: []const u8) ?LocaleSet {
    return locale.only(locale.lookup(tag) orelse return null);
}

/// s parsed with the default options: English, UTC, no base time.
pub fn parse(s: []const u8) ParseError!Result {
    return parseWith(s, .{});
}

/// The layout s is written in, without its time.
pub fn detect(s: []const u8, opts: Options) ParseError!Layout {
    return (try parseWith(s, opts)).layout;
}

/// s parsed as a structured date, then as a Unix timestamp, then as a
/// natural-language expression. Surrounding ASCII whitespace is padding.
pub fn parseWith(input: []const u8, opts: Options) ParseError!Result {
    const s = signature.trimPadding(input);
    const cfg: detection.Config = .{
        .prefer_day_first = opts.prefer_day_first,
        .prefer_year_first = opts.prefer_year_first,
        .locales = opts.locales,
    };
    if (detection.detect(s, cfg)) |r| return structured(s, &r, opts);
    if (epoch.detect(s)) |e| {
        return .{ .time = e.time, .layout = Layout.epoch, .ambiguous = false, .kind = .absolute };
    }
    return naturalLanguage(s, opts);
}

fn fail(opts: Options, err: ParseError, message: []const u8) ParseError {
    if (opts.diagnostics) |d| d.* = .{ .message = message };
    return err;
}

const no_match = "no matching format found";
const no_base_time = "the input needs a base time and Options.base_time is null";

/// The compile configuration for fields under opts.
fn configFor(fields: []const compile.Field, opts: Options) ParseError!compile.Config {
    var c: compile.Config = .{ .offset_seconds = opts.timezone_offset, .locales = opts.locales };
    if (compile.needsBaseYear(fields)) {
        const base = opts.base_time orelse return fail(opts, error.NoBaseTime, no_base_time);
        c.base_year = base.year;
    }
    return c;
}

fn structured(s: []const u8, r: *const detection.Result, opts: Options) ParseError!Result {
    if (opts.strict and r.ambiguous()) return ambiguousError(s, r, opts);
    // A trie format under the default zone shares one comptime layout.
    if (opts.timezone_offset == 0 and !r.ambiguous() and !r.prone) {
        if (r.trie_index) |i| if (Layout.interned(i)) |l| {
            const t = l.program.execute(s) catch return fail(opts, error.NoMatch, no_match);
            return .{ .time = t, .layout = l.*, .ambiguous = false, .kind = .absolute };
        };
    }
    if (compile.needsBaseYear(r.def.fields()) and opts.base_time == null) {
        // NoBaseTime only for an input some base year would read; "February
        // 30" is no date in any year. A leap year is the most permissive
        // probe, since only the 29th of February depends on the year.
        var probe_config: compile.Config = .{ .base_year = 2000, .locales = opts.locales };
        probe_config.offset_seconds = opts.timezone_offset;
        const probe = Layout.fromDetection(r, probe_config) catch
            return fail(opts, error.NoMatch, no_match);
        _ = probe.program.execute(s) catch return fail(opts, error.NoMatch, no_match);
        return fail(opts, error.NoBaseTime, no_base_time);
    }
    const c = try configFor(r.def.fields(), opts);
    const layout = Layout.fromDetection(r, c) catch return fail(opts, error.NoMatch, no_match);
    const t = layout.program.execute(s) catch return fail(opts, error.NoMatch, no_match);
    return .{ .time = t, .layout = layout, .ambiguous = r.ambiguous(), .kind = .absolute };
}

/// Every reading of an ambiguous input that is a date, the chosen first.
/// Readings are re-kinded fields and are not checked: "31/12/24" offers a
/// thirty-first month, which executing refuses, so it is dropped here.
fn ambiguousError(s: []const u8, r: *const detection.Result, opts: Options) ParseError {
    var d: Diagnostics = .{};
    const readings = ambiguity.readings(r);
    for (readings.slice()) |rd| {
        const c = try configFor(rd.def.fields(), opts);
        const program = compile.compile(rd.def.fields(), c) catch continue;
        const t = program.execute(s) catch continue;
        d.add(.{
            .time = t,
            .layout = .{ .program = program, .label = rd.label, .trims_padding = true },
            .label = rd.label,
        });
    }
    if (d.interpretation_count < 2)
        return fail(opts, error.Ambiguous, "ambiguous date could not be interpreted");
    d.message = "ambiguous date";
    if (opts.diagnostics) |out| out.* = d;
    return error.Ambiguous;
}

/// Matching a natural-language expression does not depend on the base time,
/// only its answer does; this one asks whether an input would match.
const probe_base: DateTime = .{ .year = 2000, .month = 1, .day = 1 };

fn naturalLanguage(s: []const u8, opts: Options) ParseError!Result {
    const base = opts.base_time orelse {
        if (natural.parse(s, .{ .base = probe_base, .locales = opts.locales }) != null)
            return fail(opts, error.NoBaseTime, no_base_time);
        return fail(opts, error.NoMatch, no_match);
    };
    const r = natural.parse(s, .{
        .base = base,
        .prefer_future = opts.prefer_future,
        .locales = opts.locales,
    }) orelse return fail(opts, error.NoMatch, no_match);
    if (r.ambiguous and opts.strict) {
        if (opts.diagnostics) |d| {
            d.* = .{ .message = "ambiguous natural-language expression" };
            for ([_]DateTime{ r.time, r.alt_time.? }) |t| {
                const in: Interpretation = .{
                    .time = t,
                    .layout = Layout.natural_language,
                    .label = "NATURAL_LANGUAGE",
                };
                d.add(in);
            }
        }
        return error.Ambiguous;
    }
    return .{
        .time = r.time,
        .layout = Layout.natural_language,
        .ambiguous = r.ambiguous,
        .kind = if (r.kind == .now) .now else .relative,
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("signature.zig");
    _ = @import("compile.zig");
    _ = @import("fast.zig");
    _ = @import("trie.zig");
    _ = @import("detect.zig");
    _ = @import("ambiguity.zig");
    _ = @import("locale.zig");
    _ = @import("textual.zig");
    _ = @import("epoch.zig");
    _ = @import("unicode.zig");
    _ = @import("natural.zig");
    _ = @import("Layout.zig");
    _ = @import("formats.zig");
    _ = @import("Parser.zig");
    _ = @import("api_test.zig");
    _ = @import("golden_test.zig");
    _ = @import("readme_test.zig");
}

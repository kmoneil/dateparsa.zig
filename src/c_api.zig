//! The C ABI: include/dateparsa.h's functions, exported. `zig build lib`
//! builds libdateparsa from this file.
//!
//! The Zig API trusts its caller; a C caller's struct can hold anything. So
//! every value crossing in is checked here: a base time that is no date, an
//! offset of years, a locale bit this build lacks, a NULL, a layout or
//! parser the library never filled in. Each is DATEPARSA_INVALID_ARGUMENT,
//! never a safety check tripped somewhere inside.

const std = @import("std");
const build_options = @import("build_options");
const dp = @import("root.zig");
const locale = @import("locale.zig");

const assert = std.debug.assert;

pub const Status = enum(c_int) {
    ok = 0,
    no_match = 1,
    ambiguous = 2,
    no_base_time = 3,
    invalid_argument = 4,
    buffer_too_small = 5,
};

pub const DateTime = extern struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,
    offset_seconds: i32,
};

pub const Interpretation = extern struct {
    time: DateTime,
    label: [*]const u8,
    label_len: usize,
};

pub const Diagnostics = extern struct {
    interpretations: [3]Interpretation,
    interpretation_count: u8,
    message: [*]const u8,
    message_len: usize,
};

/// The header's bools are read as bytes, so a C caller's 2 is true rather
/// than a bool Zig may not load.
pub const Options = extern struct {
    base_time: ?*const DateTime = null,
    timezone_offset: i32 = 0,
    locales: u32 = 0,
    prefer_day_first: u8 = 0,
    prefer_year_first: u8 = 0,
    prefer_future: u8 = 0,
    strict: u8 = 0,
    diagnostics: ?*Diagnostics = null,
};

pub const layout_size = 256;
pub const parser_size = 384;

pub const LayoutBlob = extern union {
    bytes: [layout_size]u8,
    align_u64_: u64,
    align_ptr_: ?*anyopaque,
};

pub const ParserBlob = extern union {
    bytes: [parser_size]u8,
    align_u64_: u64,
    align_ptr_: ?*anyopaque,
};

pub const Result = extern struct {
    time: DateTime,
    unix_seconds: i64,
    kind: u8,
    ambiguous: bool,
    reusable: bool,
    label: [*]const u8,
    label_len: usize,
    layout: LayoutBlob,
};

/// The longest RFC 3339 form, its NUL included: an 11-character year,
/// nanoseconds, and an offset.
pub const rfc3339_max = 48;

/// What a blob holds. The magic number tells a layout or parser the library
/// filled in from a zeroed or stale one.
const LayoutState = struct {
    magic: u64,
    layout: dp.Layout,
};

const ParserState = struct {
    magic: u64,
    parser: dp.Parser,
    diagnostics: ?*Diagnostics,
};

const layout_magic: u64 = 0x6470_6c61_796f_7574; // "dplayout"
const parser_magic: u64 = 0x6470_7061_7273_6572; // "dpparser"

comptime {
    assert(@sizeOf(LayoutState) <= layout_size and @alignOf(LayoutState) <= @alignOf(LayoutBlob));
    assert(@sizeOf(ParserState) <= parser_size and @alignOf(ParserState) <= @alignOf(ParserBlob));
}

/// An offset must be under a day either way, as every real zone is.
const max_offset = 86_399;

/// A base time's year bound. Natural language moves a base time by at most
/// a few tens of millions of years (six-digit counts, 512 bytes of them),
/// so from inside this bound every result's year still fits an i32.
pub const max_base_year = 999_999_999;

const version = std.fmt.comptimePrint("{s}", .{build_options.version});

pub export fn dateparsa_version() [*:0]const u8 {
    return version.ptr;
}

pub export fn dateparsa_locales_compiled() u32 {
    var bits: u32 = 0;
    for (locale.every_tag, 0..) |tag, i| {
        if (compiledIndex(tag) != null) bits |= @as(u32, 1) << @intCast(i);
    }
    return bits;
}

pub export fn dateparsa_locale_lookup(tag: ?[*]const u8, len: usize, bit: ?*u32) Status {
    const out = bit orelse return .invalid_argument;
    const s = bytes(tag, len) orelse return .invalid_argument;
    const ci = locale.lookup(s) orelse return .no_match;
    for (locale.every_tag, 0..) |t, i| {
        if (std.mem.eql(u8, t, locale.compiled[ci].tag)) {
            out.* = @as(u32, 1) << @intCast(i);
            return .ok;
        }
    }
    unreachable; // every compiled locale is one of every_tag
}

pub export fn dateparsa_parse(input: ?[*]const u8, len: usize, options: ?*const Options, out: ?*Result) Status {
    const o = options orelse &Options{};
    const result = out orelse return refuse(o.diagnostics, "out is NULL");
    const s = bytes(input, len) orelse return refuse(o.diagnostics, null_input);
    const zo = toZig(o) catch |err| return refuse(o.diagnostics, refusal(err));
    var diag: dp.Diagnostics = .{};
    const r = dp.parseWith(s, withDiagnostics(zo, &diag, o.diagnostics)) catch |err|
        return failed(err, &diag, o.diagnostics);
    result.* = fromResult(&r);
    return .ok;
}

pub export fn dateparsa_detect(input: ?[*]const u8, len: usize, options: ?*const Options, out: ?*LayoutBlob) Status {
    const o = options orelse &Options{};
    const blob = out orelse return refuse(o.diagnostics, "out is NULL");
    const s = bytes(input, len) orelse return refuse(o.diagnostics, null_input);
    const zo = toZig(o) catch |err| return refuse(o.diagnostics, refusal(err));
    var diag: dp.Diagnostics = .{};
    const l = dp.detect(s, withDiagnostics(zo, &diag, o.diagnostics)) catch |err|
        return failed(err, &diag, o.diagnostics);
    blob.* = storeLayout(&l);
    return .ok;
}

pub export fn dateparsa_layout_parse(layout: ?*const LayoutBlob, input: ?[*]const u8, len: usize, out: ?*DateTime) Status {
    const l = loadLayout(layout) orelse return .invalid_argument;
    const t = out orelse return .invalid_argument;
    const s = bytes(input, len) orelse return .invalid_argument;
    t.* = fromZig(l.parse(s) catch return .no_match);
    return .ok;
}

pub export fn dateparsa_layout_reusable(layout: ?*const LayoutBlob) bool {
    const l = loadLayout(layout) orelse return false;
    return l.reusable();
}

pub export fn dateparsa_layout_label(layout: ?*const LayoutBlob, len: ?*usize) [*]const u8 {
    const label = if (loadLayout(layout)) |l| l.label else "";
    if (len) |n| n.* = label.len;
    return label.ptr;
}

pub export fn dateparsa_parser_init(parser: ?*ParserBlob, options: ?*const Options) Status {
    const o = options orelse &Options{};
    const blob = parser orelse return refuse(o.diagnostics, "parser is NULL");
    blob.* = .{ .bytes = @splat(0) };
    const zo = toZig(o) catch |err| return refuse(o.diagnostics, refusal(err));
    parserState(blob).* = .{
        .magic = parser_magic,
        .parser = .init(zo),
        .diagnostics = o.diagnostics,
    };
    return .ok;
}

pub export fn dateparsa_parser_parse(parser: ?*ParserBlob, input: ?[*]const u8, len: usize, out: ?*Result) Status {
    const blob = parser orelse return .invalid_argument;
    const st = parserState(blob);
    if (st.magic != parser_magic) return .invalid_argument;
    const result = out orelse return refuse(st.diagnostics, "out is NULL");
    const s = bytes(input, len) orelse return refuse(st.diagnostics, null_input);
    var diag: dp.Diagnostics = .{};
    st.parser.options.diagnostics = if (st.diagnostics != null) &diag else null;
    defer st.parser.options.diagnostics = null;
    const r = st.parser.parse(s) catch |err| return failed(err, &diag, st.diagnostics);
    result.* = fromResult(&r);
    return .ok;
}

pub export fn dateparsa_parser_reset(parser: ?*ParserBlob) void {
    const blob = parser orelse return;
    const st = parserState(blob);
    if (st.magic == parser_magic) st.parser.reset();
}

pub export fn dateparsa_format_rfc3339(time: ?*const DateTime, buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    const t = toZigTime(time orelse return .invalid_argument) orelse return .invalid_argument;
    var scratch: [rfc3339_max]u8 = undefined;
    var w: std.Io.Writer = .fixed(&scratch);
    t.format(&w) catch unreachable; // rfc3339_max holds the longest
    const text = w.buffered();
    if (cap < text.len + 1) return .buffer_too_small;
    const dst = buf orelse return .invalid_argument;
    @memcpy(dst[0..text.len], text);
    dst[text.len] = 0;
    if (len) |n| n.* = text.len;
    return .ok;
}

pub export fn dateparsa_to_unix(time: ?*const DateTime, seconds: ?*i64) Status {
    const t = toZigTime(time orelse return .invalid_argument) orelse return .invalid_argument;
    const out = seconds orelse return .invalid_argument;
    out.* = t.toEpoch().seconds;
    return .ok;
}

const null_input = "input is NULL and len is not 0";

/// len bytes at p; NULL is the empty string when len is 0.
fn bytes(p: ?[*]const u8, len: usize) ?[]const u8 {
    if (p) |ptr| return ptr[0..len];
    return if (len == 0) "" else null;
}

const OptionsError = error{ BaseTime, BaseYear, TimezoneOffset, Locales };

fn refusal(err: OptionsError) []const u8 {
    return switch (err) {
        error.BaseTime => "base_time is not a valid date and time",
        error.BaseYear => "base_time's year is more than 999999999 from year 0",
        error.TimezoneOffset => "timezone_offset is a day or more",
        error.Locales => "locales has a bit for a locale this build did not compile in",
    };
}

/// The Zig options a C caller's options ask for, diagnostics aside.
pub fn toZig(o: *const Options) OptionsError!dp.Options {
    var base: ?dp.DateTime = null;
    if (o.base_time) |b| {
        base = toZigTime(b) orelse return error.BaseTime;
        if (@abs(b.year) > max_base_year) return error.BaseYear;
    }
    if (@abs(o.timezone_offset) > max_offset) return error.TimezoneOffset;
    return .{
        .base_time = base,
        .timezone_offset = o.timezone_offset,
        .prefer_day_first = o.prefer_day_first != 0,
        .prefer_year_first = o.prefer_year_first != 0,
        .prefer_future = o.prefer_future != 0,
        .strict = o.strict != 0,
        .locales = localeSet(o.locales) orelse return error.Locales,
    };
}

const Backing = @typeInfo(dp.LocaleSet).@"struct".backing_integer.?;

/// The set of compiled-in locales bits names, or null when a bit names a
/// locale this build lacks or no locale at all.
fn localeSet(bits: u32) ?dp.LocaleSet {
    if (bits >> locale.every_tag.len != 0) return null;
    var set: Backing = 0;
    for (locale.every_tag, 0..) |tag, i| {
        if ((bits >> @intCast(i)) & 1 == 0) continue;
        const ci = compiledIndex(tag) orelse return null;
        set |= @as(Backing, 1) << @intCast(ci);
    }
    return @bitCast(set);
}

fn compiledIndex(tag: []const u8) ?usize {
    for (locale.compiled, 0..) |d, i| {
        if (std.mem.eql(u8, d.tag, tag)) return i;
    }
    return null;
}

fn withDiagnostics(zo: dp.Options, diag: *dp.Diagnostics, wanted: ?*Diagnostics) dp.Options {
    var o = zo;
    if (wanted != null) o.diagnostics = diag;
    return o;
}

/// A real date and time with an offset under a day, or null.
fn toZigTime(t: *const DateTime) ?dp.DateTime {
    const dt: dp.DateTime = .{
        .year = t.year,
        .month = t.month,
        .day = t.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
        .offset_seconds = t.offset_seconds,
    };
    if (!dt.isValid() or @abs(t.offset_seconds) > max_offset) return null;
    return dt;
}

fn fromZig(t: dp.DateTime) DateTime {
    return .{
        .year = t.year,
        .month = t.month,
        .day = t.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .nanosecond = t.nanosecond,
        .offset_seconds = t.offset_seconds,
    };
}

fn fromResult(r: *const dp.Result) Result {
    return .{
        .time = fromZig(r.time),
        .unix_seconds = r.time.toEpoch().seconds,
        .kind = switch (r.kind) {
            .absolute => 0,
            .relative => 1,
            .now => 2,
        },
        .ambiguous = r.ambiguous,
        .reusable = r.layout.reusable(),
        .label = r.layout.label.ptr,
        .label_len = r.layout.label.len,
        .layout = storeLayout(&r.layout),
    };
}

fn storeLayout(l: *const dp.Layout) LayoutBlob {
    var blob: LayoutBlob = .{ .bytes = @splat(0) };
    const st: *LayoutState = @ptrCast(@alignCast(&blob.bytes));
    st.* = .{ .magic = layout_magic, .layout = l.* };
    return blob;
}

fn loadLayout(blob: ?*const LayoutBlob) ?*const dp.Layout {
    const b = blob orelse return null;
    const st: *const LayoutState = @ptrCast(@alignCast(&b.bytes));
    return if (st.magic == layout_magic) &st.layout else null;
}

fn parserState(blob: *ParserBlob) *ParserState {
    return @ptrCast(@alignCast(&blob.bytes));
}

const no_interpretation: Interpretation = .{
    .time = std.mem.zeroes(DateTime),
    .label = "",
    .label_len = 0,
};

/// The status for err, with what diag says copied out when it was asked
/// for.
fn failed(err: dp.ParseError, diag: *const dp.Diagnostics, out: ?*Diagnostics) Status {
    if (out) |d| {
        d.* = .{
            .interpretations = @splat(no_interpretation),
            .interpretation_count = diag.interpretation_count,
            .message = diag.message.ptr,
            .message_len = diag.message.len,
        };
        for (diag.slice(), 0..) |in, i| d.interpretations[i] = .{
            .time = fromZig(in.time),
            .label = in.label.ptr,
            .label_len = in.label.len,
        };
    }
    return switch (err) {
        error.NoMatch => .no_match,
        error.Ambiguous => .ambiguous,
        error.NoBaseTime => .no_base_time,
    };
}

fn refuse(out: ?*Diagnostics, message: []const u8) Status {
    if (out) |d| d.* = .{
        .interpretations = @splat(no_interpretation),
        .interpretation_count = 0,
        .message = message.ptr,
        .message_len = message.len,
    };
    return .invalid_argument;
}

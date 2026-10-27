//! Numeric dates whose field order the bytes do not settle, and the
//! readings an ambiguous input offers.
//!
//! "01/02/2024" is the second of January or the first of February. The
//! rules, in order: a part over 12 must be the day; a dot separator means
//! day first; otherwise the caller's preference picks, and the result says
//! it was a guess. A leading year settles the rest (nothing writes YY/DD/MM),
//! and a trailing two-digit year leaves the year's own position open:
//! "31/12/24" is also the 24th of December 2031.

const std = @import("std");
const compile = @import("compile.zig");
const detect = @import("detect.zig");

const Field = compile.Field;
const FieldKind = compile.FieldKind;
const Def = detect.Def;
const Result = detect.Result;
const Config = detect.Config;
const Ambiguity = detect.Ambiguity;

/// A date part's value and where it sits.
const Part = struct { value: u16, offset: usize, len: usize };

/// The three parts of s split on sep, or null for any other count.
fn splitThree(s: []const u8, sep: u8) ?[3][]const u8 {
    var parts: [3][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, s, sep);
    for (&parts) |*p| p.* = it.next() orelse return null;
    if (it.next() != null) return null;
    return parts;
}

/// One to four digits, or null.
fn smallInt(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 4) return null;
    var v: u16 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

const MonthDay = struct { month: Part, day: Part, ambiguity: Ambiguity };

/// Which of three parts are the month and the day, given where the year
/// sits, and whether that took a guess.
fn resolveYearMonthDay(parts: [3][]const u8, values: [3]u16, cfg: Config) ?MonthDay {
    const first, const second, const third = values;
    var year_first_alt = false;
    if (third > 31 or parts[2].len == 4) {
        // ??/??/YYYY: the month and day are the first two, by value below.
    } else if (first > 31 or parts[0].len == 4) {
        // A leading year settles the other two: ISO order follows it.
        const md = isoOrderParts(parts, second, third) orelse return null;
        return .{ .month = md[0], .day = md[1], .ambiguity = .none };
    } else if (cfg.prefer_year_first and yearFirstReadingExists(parts, second, third)) {
        // All three small and the caller reads year-first data: YY/MM/DD.
        // Still a guess, one of three.
        const md = isoOrderParts(parts, second, third).?;
        return .{ .month = md[0], .day = md[1], .ambiguity = .year_position };
    } else {
        // All small, year last. Whether the bytes also read year-first is
        // a property of the input, asked whatever the preference.
        year_first_alt = yearFirstReadingExists(parts, second, third);
    }

    const p1: Part = .{ .value = first, .offset = 0, .len = parts[0].len };
    const p2: Part = .{ .value = second, .offset = parts[0].len + 1, .len = parts[1].len };
    var month: Part = p1;
    var day: Part = p2;
    var ambiguity: Ambiguity = .none;
    if (first > 12) {
        month, day = .{ p2, p1 };
    } else if (second > 12) {
        // As read.
    } else {
        ambiguity = .field_order;
        if (cfg.prefer_day_first) month, day = .{ p2, p1 };
    }
    // "17-1-01" is settled by value as the 17th of January 2001, and is
    // equally the 1st of January 2017: a guess about the year's position.
    if (ambiguity == .none and year_first_alt) ambiguity = .year_position;

    if (month.value < 1 or month.value > 12 or day.value < 1 or day.value > 31) return null;
    // One digit or two: the field kinds express no other width, and an "020"
    // day once validated the 20th while the program read the 2nd.
    if (month.len > 2 or day.len > 2) return null;
    return .{ .month = month, .day = day, .ambiguity = ambiguity };
}

/// Whether three small parts read as a two-digit year then ISO order.
fn yearFirstReadingExists(parts: [3][]const u8, second: u16, third: u16) bool {
    return parts[0].len == 2 and isoOrderParts(parts, second, third) != null;
}

/// The month and day after a leading year, when they can be read that way.
fn isoOrderParts(parts: [3][]const u8, second: u16, third: u16) ?[2]Part {
    if (second < 1 or second > 12 or third < 1 or third > 31) return null;
    if (parts[1].len > 2 or parts[2].len > 2) return null;
    const month_at = parts[0].len + 1;
    return .{
        .{ .value = second, .offset = month_at, .len = parts[1].len },
        .{ .value = third, .offset = month_at + parts[1].len + 1, .len = parts[2].len },
    };
}

/// Fields for a three-part date: year, month and day in input order with a
/// separator literal between each pair. The year is whichever part is not
/// the month or the day, and is written with two digits or four.
fn appendDateParts(def: *Def, parts: [3][]const u8, sep: u8, month: Part, day: Part) bool {
    const starts = [3]usize{ 0, parts[0].len + 1, parts[0].len + parts[1].len + 2 };
    const year_index = for (starts, 0..) |start, i| {
        if (start != month.offset and start != day.offset) break i;
    } else return false;
    const year_kind: FieldKind = switch (parts[year_index].len) {
        4 => .year4,
        2 => .year2,
        else => return false,
    };
    var placed = [3]Field{
        .{ .kind = year_kind, .offset = 0, .len = 0 },
        .{ .kind = if (month.len == 1) .month1or2 else .month2, .offset = 0, .len = 0 },
        .{ .kind = if (day.len == 1) .day1or2 else .day2, .offset = 0, .len = 0 },
    };
    const where = [3][2]usize{
        .{ starts[year_index], parts[year_index].len },
        .{ month.offset, month.len },
        .{ day.offset, day.len },
    };
    for (&placed, where) |*f, w| {
        f.offset = std.math.cast(u8, w[0]) orelse return false;
        f.len = @intCast(w[1]);
    }
    std.sort.insertion(Field, &placed, {}, byOffset);

    // The separator is the byte the parts were split on, one of - / . and
    // so a separator-class byte. The class rather than the byte, as for a
    // trie literal: a column read with another separator resolves the same.
    // While this asked only for a non-digit, a layout from "20-1-00" read
    // "10:01:00" as a date.
    const sep_aux = compile.auxFor(.sep);
    std.debug.assert(sep == '-' or sep == '/' or sep == '.');
    var end: usize = 0;
    for (placed) |f| {
        if (f.offset > end) {
            def.append(.{
                .kind = .literal,
                .offset = @intCast(end),
                .len = @intCast(f.offset - end),
                // A wider run needs a class per byte, and aux holds one.
                .aux = if (f.offset - end == 1) sep_aux else 0,
            }) catch return false;
        }
        def.append(f) catch return false;
        end = @as(usize, f.offset) + f.len;
    }
    return true;
}

fn byOffset(_: void, a: Field, b: Field) bool {
    return a.offset < b.offset;
}

/// The first of - / . in s.
fn findSep(s: []const u8) ?u8 {
    const i = std.mem.indexOfAny(u8, s, "-/.") orelse return null;
    return s[i];
}

/// Resolves a three-part numeric date into def, returning its name and the
/// guess it took.
fn resolveInto(def: *Def, s: []const u8, cfg_in: Config) ?struct { []const u8, Ambiguity } {
    const sep = findSep(s) orelse return null;
    var cfg = cfg_in;
    // A dot separator is the European day-first convention.
    if (sep == '.') cfg.prefer_day_first = true;
    const parts = splitThree(s, sep) orelse return null;
    var values: [3]u16 = undefined;
    for (&values, parts) |*v, p| v.* = smallInt(p) orelse return null;
    const md = resolveYearMonthDay(parts, values, cfg) orelse return null;
    if (!appendDateParts(def, parts, sep, md.month, md.day)) return null;
    // Go's naming, kept for the golden corpus: unambiguous dates are named
    // for the preference, not for the order their values settled.
    const name = if (md.ambiguity != .none)
        "NUMERIC_AMBIG"
    else if (cfg.prefer_day_first)
        "NUMERIC_DMY"
    else
        "NUMERIC_MDY";
    return .{ name, md.ambiguity };
}

/// The trie's NUMERIC_SEP entry: DD?DD?DDDD with separator-class bytes.
pub fn resolve(s: []const u8, cfg: Config) ?Result {
    var def: Def = .{ .name = "" };
    const name, const ambiguity = resolveInto(&def, s, cfg) orelse return null;
    def.name = name;
    return .{ .def = def, .ambiguity = ambiguity, .prone = true };
}

fn withTime(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "NUMERIC_MDY")) return "NUMERIC_MDY_TIME";
    if (std.mem.eql(u8, name, "NUMERIC_DMY")) return "NUMERIC_DMY_TIME";
    if (std.mem.eql(u8, name, "NUMERIC_AMBIG")) return "NUMERIC_AMBIG_TIME";
    unreachable; // resolveInto names nothing else
}

/// Numeric dates with parts of one to four digits, "3/15/2024",
/// "3/15/24", and a time after a space: "3/15/2024 10:30:00 AM".
pub fn detectVariableNumeric(s: []const u8, cfg: Config) ?Result {
    if (s.len < 3) return null;
    const sep_at = std.mem.indexOfAny(u8, s[0..@min(s.len, 4)], "/-") orelse return null;
    if (sep_at < 1) return null;
    const sep = s[sep_at];
    const date_end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    const head = s[0..date_end];
    const parts = splitThree(head, sep) orelse return null;
    for (parts) |p| _ = smallInt(p) orelse return null;
    // YYYY-MM-DD belongs to the trie.
    if (sep == '-' and parts[0].len == 4) return null;

    var def: Def = .{ .name = "" };
    var name, const ambiguity = resolveInto(&def, head, cfg) orelse return null;
    if (date_end < s.len) {
        var time: Def = .{ .name = "" };
        if (detect.appendTimeComponent(&time, s, date_end)) {
            name = withTime(name);
            for (time.fields()) |f| def.append(f) catch return null;
            detect.coverGaps(&def, s) catch return null;
        }
    }
    def.name = name;
    return .{ .def = def, .ambiguity = ambiguity, .prone = true };
}

/// One way to read an ambiguous input: the format reading it that way and
/// a label naming the order ("MM/DD/YYYY").
pub const Reading = struct { def: Def, label: []const u8 };

pub const Readings = struct {
    buf: [3]Reading = undefined,
    len: u8 = 0,

    pub fn slice(r: *const Readings) []const Reading {
        return r.buf[0..r.len];
    }
};

/// Every way r's input can be read, the chosen one first; empty when it
/// needed no guess. Built by re-kinding the fields detection produced, never
/// by detecting again: a second detection with a flipped preference can be
/// overruled by the dot heuristic and hand back the same reading twice.
pub fn readings(r: *const Result) Readings {
    return switch (r.ambiguity) {
        .none => .{},
        .field_order, .year_position => fieldOrderReadings(r),
        .day_or_year => dayOrYearReadings(r),
    };
}

const Role = enum(u8) { month = 'M', day = 'D', year = 'Y' };

/// A date field's index in the field list and the role a reading gives it.
const Slot = struct { index: usize, role: Role };

fn fieldOrderReadings(r: *const Result) Readings {
    const fields = r.def.fields();
    var at: [3]?usize = .{ null, null, null }; // month, day, year
    for (fields, 0..) |f, i| switch (f.kind) {
        .month2, .month1or2 => at[0] = i,
        .day2, .day1or2 => at[1] = i,
        .year4, .year2 => at[2] = i,
        else => {},
    };
    const month_at = at[0] orelse return .{};
    const day_at = at[1] orelse return .{};
    const year_at = at[2] orelse return .{};

    // The three field indices in input order, and the roles chosen for them.
    var slots = [3]Slot{
        .{ .index = month_at, .role = .month },
        .{ .index = day_at, .role = .day },
        .{ .index = year_at, .role = .year },
    };
    std.sort.insertion(Slot, &slots, fields, slotByOffset);
    const chosen = [3]Role{ slots[0].role, slots[1].role, slots[2].role };

    var out: Readings = .{};
    out.buf[0] = .{ .def = r.def, .label = numericLabel(fields, slots, chosen) };
    out.len = 1;
    const orders = [_][3]Role{
        .{ .month, .day, .year },
        .{ .day, .month, .year },
        .{ .year, .month, .day },
    };
    for (orders) |order| {
        if (std.mem.eql(Role, &order, &chosen)) continue;
        var def = r.def;
        const label = numericLabel(fields, slots, order);
        def.name = label;
        const ok = for (slots, order) |slot, role| {
            const f = &def.buf[slot.index];
            f.kind = kindForRole(role, f.len) orelse break false;
        } else true;
        if (!ok) continue;
        out.buf[out.len] = .{ .def = def, .label = label };
        out.len += 1;
    }
    return out;
}

fn slotByOffset(fields: []const Field, a: Slot, b: Slot) bool {
    return fields[a.index].offset < fields[b.index].offset;
}

fn kindForRole(role: Role, width: u8) ?FieldKind {
    return switch (role) {
        .year => switch (width) {
            2 => .year2,
            4 => .year4,
            else => null,
        },
        .month => switch (width) {
            1 => .month1or2,
            2 => .month2,
            else => null,
        },
        .day => switch (width) {
            1 => .day1or2,
            2 => .day2,
            else => null,
        },
    };
}

/// "MM/DD/YYYY", "DD/MM/YY", "YY/MM/DD": order gives the role of each slot
/// in input order, and the year is spelled at the width of the field that
/// takes the year role in this reading. Labels are comptime strings.
fn numericLabel(fields: []const Field, slots: [3]Slot, order: [3]Role) []const u8 {
    const year_slot = std.mem.indexOfScalar(Role, &order, .year).?;
    const two_digit = fields[slots[year_slot].index].len == 2;
    for (labels) |l| {
        if (l.two_digit == two_digit and std.mem.eql(Role, &l.order, &order)) return l.text;
    }
    unreachable; // every order of three roles is in labels
}

/// "March 15" is the 15th of March or March 2015: the number read as the
/// day, and the same bytes read as a two-digit year. With a two-digit year
/// already written the two numbers swap roles, so "01MAY10" is the 1st of
/// May 2010 or the 10th of May 2001; re-kinding the day alone would offer a
/// reading with two years and no day.
fn dayOrYearReadings(r: *const Result) Readings {
    const fields = r.def.fields();
    var day_at: ?usize = null;
    var month_at: ?usize = null;
    var year_at: ?usize = null;
    for (fields, 0..) |f, i| switch (f.kind) {
        .day2 => day_at = i,
        .month_name => month_at = i,
        .year2 => year_at = i,
        else => {},
    };
    const d = day_at orelse return .{};
    const m = month_at orelse return .{};

    var alt = r.def;
    alt.buf[d].kind = .year2;
    if (year_at) |y| alt.buf[y].kind = .day2;
    const label = textualLabel(fields, m, d, year_at);
    const alt_label = textualLabel(fields, m, year_at, d);
    alt.name = alt_label;

    var out: Readings = .{};
    out.buf[0] = .{ .def = r.def, .label = label };
    out.buf[1] = .{ .def = alt, .label = alt_label };
    out.len = 2;
    return out;
}

const LabelPart = enum { MONTH, DAY, YEAR };

const PartAt = struct { offset: u8, part: LabelPart };

fn partByOffset(_: void, a: PartAt, b: PartAt) bool {
    return a.offset < b.offset;
}

/// The parts a reading has, in the order the input writes them, joined:
/// "MONTH_DAY", "YEAR_MONTH_DAY". Built from offsets rather than the format
/// name, which counts numbers and can disagree with the reading offered.
fn textualLabel(fields: []const Field, month_at: usize, day_at: ?usize, year_at: ?usize) []const u8 {
    var parts: [3]PartAt = undefined;
    var n: usize = 0;
    parts[n] = .{ .offset = fields[month_at].offset, .part = .MONTH };
    n += 1;
    if (day_at) |i| {
        parts[n] = .{ .offset = fields[i].offset, .part = .DAY };
        n += 1;
    }
    if (year_at) |i| {
        parts[n] = .{ .offset = fields[i].offset, .part = .YEAR };
        n += 1;
    }
    std.sort.insertion(PartAt, parts[0..n], {}, partByOffset);
    var order: [3]?LabelPart = .{ null, null, null };
    for (parts[0..n], 0..) |p, i| order[i] = p.part;
    for (textual_labels) |l| {
        if (std.mem.eql(?LabelPart, &l.order, &order)) return l.text;
    }
    unreachable; // every ordered subset holding the month is in the table
}

const TextualLabel = struct { order: [3]?LabelPart, text: []const u8 };

/// Every ordering of MONTH with DAY, YEAR or both, as comptime strings.
const textual_labels = blk: {
    const orders = [_][3]?LabelPart{
        .{ .MONTH, null, null },
        .{ .MONTH, .DAY, null },
        .{ .DAY, .MONTH, null },
        .{ .MONTH, .YEAR, null },
        .{ .YEAR, .MONTH, null },
        .{ .MONTH, .DAY, .YEAR },
        .{ .MONTH, .YEAR, .DAY },
        .{ .DAY, .MONTH, .YEAR },
        .{ .DAY, .YEAR, .MONTH },
        .{ .YEAR, .MONTH, .DAY },
        .{ .YEAR, .DAY, .MONTH },
    };
    var out: [orders.len]TextualLabel = undefined;
    for (orders, 0..) |o, i| {
        var text: []const u8 = "";
        for (o) |p| {
            const part = p orelse break;
            if (text.len > 0) text = text ++ "_";
            text = text ++ @tagName(part);
        }
        out[i] = .{ .order = o, .text = text };
    }
    break :blk out;
};

const Label = struct { order: [3]Role, two_digit: bool, text: []const u8 };

const labels = blk: {
    const perms = [_][3]Role{
        .{ .month, .day, .year }, .{ .day, .month, .year }, .{ .year, .month, .day },
        .{ .year, .day, .month }, .{ .month, .year, .day }, .{ .day, .year, .month },
    };
    var out: [perms.len * 2]Label = undefined;
    for (perms, 0..) |p, i| {
        for ([_]bool{ false, true }, 0..) |two, j| {
            var text: []const u8 = "";
            for (p, 0..) |role, k| {
                if (k > 0) text = text ++ "/";
                text = text ++ switch (role) {
                    .month => "MM",
                    .day => "DD",
                    .year => if (two) "YY" else "YYYY",
                };
            }
            out[i * 2 + j] = .{ .order = p, .two_digit = two, .text = text };
        }
    }
    break :blk out;
};

const DateTime = @import("DateTime.zig");

test {
    std.testing.refAllDecls(@This());
}

const Parsed = struct { name: []const u8, time: DateTime, ambiguity: Ambiguity, prone: bool };

fn parseWith(s: []const u8, cfg: Config) !Parsed {
    const r = detect.detect(s, cfg) orelse return error.NotDetected;
    const fields = r.def.fields();
    const year: i32 = if (compile.needsBaseYear(fields)) 2026 else 0;
    const p = try compile.compile(fields, .{ .base_year = year });
    return .{
        .name = r.def.name,
        .time = try p.execute(s),
        .ambiguity = r.ambiguity,
        .prone = r.prone,
    };
}

/// A date and time with zero seconds, for compact tables.
fn moment(y: i32, mo: u8, d: u8, h: u8, mi: u8, ns: u32, offset: i32) DateTime {
    return .{
        .year = y,
        .month = mo,
        .day = d,
        .hour = h,
        .minute = mi,
        .nanosecond = ns,
        .offset_seconds = offset,
    };
}

fn date(y: i32, m: u8, d: u8) DateTime {
    return .{ .year = y, .month = m, .day = d };
}

test "the README's ambiguity rules" {
    const day_first: Config = .{ .prefer_day_first = true };
    const year_first: Config = .{ .prefer_year_first = true };
    const Case = struct { []const u8, Config, DateTime, Ambiguity };
    const cases = [_]Case{
        // Both parts fit a month: the preference picks, and says so.
        .{ "01/02/2024", .{}, date(2024, 1, 2), .field_order },
        .{ "01/02/2024", day_first, date(2024, 2, 1), .field_order },
        // A part over 12 is the day, whatever the preference.
        .{ "13/01/2024", .{}, date(2024, 1, 13), .none },
        .{ "01/13/2024", day_first, date(2024, 1, 13), .none },
        // A dot is day first, and it was still a guess.
        .{ "03.02.2024", .{}, date(2024, 2, 3), .field_order },
        .{ "15.03.2024", .{}, date(2024, 3, 15), .none },
        // Three small parts: the year's position is open too.
        .{ "01/02/03", .{}, date(2003, 1, 2), .field_order },
        .{ "01/02/03", year_first, date(2001, 2, 3), .year_position },
        // A value the year-first reading cannot use keeps the year last.
        .{ "01/13/03", year_first, date(2003, 1, 13), .none },
        // A leading year settles the rest.
        .{ "70/01/02", .{}, date(1970, 1, 2), .none },

        // A trailing two-digit year can be a leading one.
        .{ "31/12/24", .{}, date(2024, 12, 31), .year_position },
        .{ "17-1-01", .{}, date(2001, 1, 17), .year_position },
        // A part over 31 or a four-digit year settles where the year is.
        .{ "70-1-17", .{}, date(1970, 1, 17), .none },
        .{ "31/12/2024", .{}, date(2024, 12, 31), .none },
        // Variable widths.
        .{ "3/15/2024", .{}, date(2024, 3, 15), .none },
        .{ "1/2/2024", .{}, date(2024, 1, 2), .field_order },
        .{ "3/15/24", .{}, date(2024, 3, 15), .none },
    };
    for (cases) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        const got = try parseWith(c[0], c[1]);
        try std.testing.expectEqual(c[2], got.time);
        try std.testing.expectEqual(c[3], got.ambiguity);
        try std.testing.expect(got.prone);
    }
}

test "numeric dates nobody writes are refused" {
    for ([_][]const u8{
        "70/15/02", // YY/DD/MM
        "020/01/2024", // a three-digit day
        "1/2/003", // a three-digit year
        "13/13/2024",
        "00/01/2024",
        "1/2", // two parts
        "1/2/3/4",
    }) |s| {
        // Refused by detection, not left to the executor's coverage check.
        if (detect.detect(s, .{})) |r| {
            std.debug.print("\"{s}\" detected as {s}\n", .{ s, r.def.name });
            return error.TestUnexpectedResult;
        }
    }
}

test "a time after a numeric date" {
    const Case = struct { []const u8, []const u8, DateTime };
    const cases = [_]Case{
        .{ "03/15/2024 10:30:00", "NUMERIC_MDY_TIME", moment(2024, 3, 15, 10, 30, 0, 0) },
        .{ "3/15/2024 10:30:00 AM", "NUMERIC_MDY_TIME", moment(2024, 3, 15, 10, 30, 0, 0) },
        .{ "3/15/2024 10:30 PM", "NUMERIC_MDY_TIME", moment(2024, 3, 15, 22, 30, 0, 0) },
        .{ "3/15/2024 12:05 am", "NUMERIC_MDY_TIME", moment(2024, 3, 15, 0, 5, 0, 0) },
        .{ "1/2/2024 10:30:00.25", "NUMERIC_AMBIG_TIME", moment(2024, 1, 2, 10, 30, 250_000_000, 0) },
        .{ "3/15/2024 10:30:00 +0530", "NUMERIC_MDY_TIME", moment(2024, 3, 15, 10, 30, 0, 19800) },
        .{ "3/15/2024 10:30:00Z", "NUMERIC_MDY_TIME", moment(2024, 3, 15, 10, 30, 0, 0) },
        .{ "3/15/2024 10:30:00 EST", "NUMERIC_MDY_TIME", moment(2024, 3, 15, 10, 30, 0, -18000) },
        .{ "3/15/2024 10:30:00 GMT+0100", "NUMERIC_MDY_TIME", moment(2024, 3, 15, 10, 30, 0, 3600) },
    };
    for (cases) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        const got = try parseWith(c[0], .{});
        try std.testing.expectEqualStrings(c[1], got.name);
        try std.testing.expectEqual(c[2], got.time);
    }
    // AM/PM makes the hour a 12-hour field, which has no hour 0.
    try std.testing.expectError(error.NoMatch, parseWith("3/15/2024 00:30 AM", .{}));
    // PM on a 24-hour value is refused, not read as hour 25.
    try std.testing.expectError(error.NoMatch, parseWith("3/15/2024 13:30 PM", .{}));
    // A fraction past nanoseconds leaves no time, so the input is not covered.
    try std.testing.expectError(error.NoMatch, parseWith("3/15/2024 10:30:00.1234567890", .{}));
}

fn labelsOf(rs: *const Readings, out: *[3][]const u8) [][]const u8 {
    for (rs.slice(), 0..) |rd, i| out[i] = rd.label;
    return out[0..rs.len];
}

test "an ambiguous input offers its readings, the chosen one first" {
    const Case = struct { []const u8, Config, []const []const u8 };
    const cases = [_]Case{
        .{ "01/02/2024", .{}, &.{ "MM/DD/YYYY", "DD/MM/YYYY" } },
        .{ "01/02/2024", .{ .prefer_day_first = true }, &.{ "DD/MM/YYYY", "MM/DD/YYYY" } },
        .{ "03.02.2024", .{}, &.{ "DD/MM/YYYY", "MM/DD/YYYY" } },
        .{ "01/02/03", .{}, &.{ "MM/DD/YY", "DD/MM/YY", "YY/MM/DD" } },
        .{ "01/02/03", .{ .prefer_year_first = true }, &.{ "YY/MM/DD", "MM/DD/YY", "DD/MM/YY" } },
        .{ "31/12/24", .{}, &.{ "DD/MM/YY", "MM/DD/YY", "YY/MM/DD" } },
        .{ "1/2/2024 10:30:00", .{}, &.{ "MM/DD/YYYY", "DD/MM/YYYY" } },
    };
    for (cases) |c| {
        errdefer std.debug.print("case \"{s}\"\n", .{c[0]});
        const r = detect.detect(c[0], c[1]).?;
        const rs = readings(&r);
        var buf: [3][]const u8 = undefined;
        const got = labelsOf(&rs, &buf);
        try std.testing.expectEqual(c[2].len, got.len);
        for (c[2], got) |want, label| try std.testing.expectEqualStrings(want, label);

        // Every reading reads the same bytes, and differs from the chosen one
        // only in which kind a field is.
        const chosen = rs.slice()[0].def.fields();
        for (rs.slice()[1..]) |alt| {
            const fs = alt.def.fields();
            try std.testing.expectEqual(chosen.len, fs.len);
            var differ: usize = 0;
            for (chosen, fs) |a, b| {
                try std.testing.expectEqual(a.offset, b.offset);
                try std.testing.expectEqual(a.len, b.len);
                if (a.kind != b.kind) differ += 1;
            }
            try std.testing.expect(differ >= 2);
        }
    }
}

test "an alternative reading parses to the other date" {
    const r = detect.detect("01/02/03", .{}).?;
    const rs = readings(&r);
    const want = [_]DateTime{ date(2003, 1, 2), date(2003, 2, 1), date(2001, 2, 3) };
    for (rs.slice(), want) |rd, w| {
        const p = try compile.compile(rd.def.fields(), .{});
        try std.testing.expectEqual(w, try p.execute("01/02/03"));
    }
}

test "an input that needed no guess offers no readings" {
    for ([_][]const u8{ "13/01/2024", "2024-03-15", "70/01/02", "3/15/2024", "15.03.2024" }) |s| {
        errdefer std.debug.print("\"{s}\"\n", .{s});
        const r = detect.detect(s, .{}).?;
        try std.testing.expectEqual(Ambiguity.none, r.ambiguity);
        try std.testing.expectEqual(0, readings(&r).len);
    }
}

test "every order of three roles has a label" {
    try std.testing.expectEqual(12, labels.len);
    for (labels, 0..) |a, i| for (labels[i + 1 ..]) |b| {
        try std.testing.expect(!std.mem.eql(u8, a.text, b.text));
    };
}

test "a numeric date's layout does not read a time" {
    // The separator literals hold the separator class; while they asked only
    // for a non-digit, this layout read "10:01:00" as the 10th of January.
    const r = detect.detect("20-1-00", .{}).?;
    const p = try compile.compile(r.def.fields(), .{});
    try std.testing.expectEqual(date(2000, 1, 20), try p.execute("20-1-00"));
    try std.testing.expectEqual(date(2000, 1, 20), try p.execute("20/1/00"));
    try std.testing.expectError(error.NoMatch, p.execute("10:01:00"));
}

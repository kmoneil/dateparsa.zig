//! The fixed-slot path. A program whose fields all sit at fixed offsets
//! needs no interpreting: plan copies each instruction into the slot for
//! its field, and execute reads the slots as straight-line code after one
//! length check, where the interpreter pays a dispatch and a coverage sum
//! per instruction. The interpreter stays the reference; the tests run both
//! and require the same answer.

const std = @import("std");
const compile = @import("compile.zig");
const DateTime = @import("DateTime.zig");

const Error = compile.Error;
const Inst = compile.Inst;
const Program = compile.Program;

pub const Slot = enum(u4) { year, month, day, hour, minute, second, frac, ampm, zone };
pub const num_slots = @typeInfo(Slot).@"enum".field_names.len;

/// Slots live at the end of Program.insts, so insts[0..n] keeps the program
/// as compiled for the interpreter. A fast program has at most num_slots
/// instructions, so the regions cannot meet.
pub const slot_base = compile.max_instructions - num_slots;

comptime {
    std.debug.assert(num_slots <= slot_base);
}

/// The tiling proof below is a u64 bit per input byte.
const max_width = 64;

/// The slot an instruction claims and the bytes it reads, or null when it
/// has no slot: variable-width fields move what follows them, and month
/// names, skips, tails, ISO weeks and ordinal days need the interpreter.
fn slotOf(inst: Inst) ?struct { slot: Slot, width: usize } {
    const fused: usize = if (inst.aux != compile.sep_none) 1 else 0;
    return switch (inst.op) {
        .year4 => .{ .slot = .year, .width = 4 + fused },
        .year2 => .{ .slot = .year, .width = 2 + fused },
        .month2 => .{ .slot = .month, .width = 2 + fused },
        .day2, .day_space_pad => .{ .slot = .day, .width = 2 + fused },
        .hour24, .hour12 => .{ .slot = .hour, .width = 2 + fused },
        .minute2 => .{ .slot = .minute, .width = 2 + fused },
        .second2 => .{ .slot = .second, .width = 2 + fused },
        .ampm => .{ .slot = .ampm, .width = 2 },
        .tz_z => .{ .slot = .zone, .width = 1 },
        .frac_sec => .{ .slot = .frac, .width = inst.len },
        .tz_offset, .tz_name, .tz_z_or_offset => .{ .slot = .zone, .width = inst.len },
        else => null,
    };
}

/// Gives p a slot form when every instruction claims its own slot and the
/// instructions tile 0..width with no gap and no overlap, and reports
/// whether it did. A refused program is left as it was, width zero.
pub fn plan(p: *Program) bool {
    if (p.n == 0 or p.n > num_slots) return false;
    var slots: [num_slots]Inst = @splat(compile.nop);
    var used: u16 = 0;
    var mask: u64 = 0; // one bit per input byte some instruction claims
    var width: usize = 0;
    var zone: ?struct { off: usize, end: usize } = null;
    for (p.insts[0..p.n]) |inst| {
        const sw = slotOf(inst) orelse return false;
        const bit = @as(u16, 1) << @backingInt(sw.slot);
        if (sw.width == 0 or used & bit != 0) return false;
        const off: usize = inst.offset;
        if (off + sw.width > max_width) return false;
        const run: u64 = if (sw.width == 64)
            ~@as(u64, 0)
        else
            (@as(u64, 1) << @intCast(sw.width)) - 1;
        const bits = run << @intCast(off);
        if (mask & bits != 0) return false;
        mask |= bits;
        used |= bit;
        if (inst.op == .tz_z_or_offset) zone = .{ .off = off, .end = off + sw.width };
        width = @max(width, off + sw.width);
        slots[@backingInt(sw.slot)] = inst;
    }
    if (mask != ~@as(u64, 0) >> @intCast(64 - width)) return false;
    var width_alt = width;
    if (zone) |z| {
        // Anything after a zone whose width the input decides would move.
        if (z.end != width) return false;
        width_alt = z.off + 1; // the 'Z' form
    }
    p.insts[slot_base..][0..num_slots].* = slots;
    p.width = @intCast(width);
    p.width_alt = @intCast(width_alt);
    return true;
}

fn slot(p: *const Program, comptime s: Slot) Inst {
    return p.insts[slot_base + @backingInt(s)];
}

/// Whether the separator fused onto a field, if any, is at at.
fn sepOk(s: []const u8, at: usize, aux: u16) bool {
    return aux == compile.sep_none or (at < s.len and compile.litAccepts(aux, s[at]));
}

/// Runs a program plan accepted. The length check stands in for the
/// interpreter's coverage sum: the slots tile the input by construction.
pub fn execute(p: *const Program, s: []const u8) Error!DateTime {
    if (s.len != p.width and s.len != p.width_alt) return error.NoMatch;
    var r: compile.Reading = .{ .offset_seconds = p.offset_seconds };

    const year = slot(p, .year);
    if (year.op != .nop) {
        const off: usize = year.offset;
        if (year.op == .year4) {
            r.year = compile.parse4(s, off) orelse return error.NoMatch;
            if (!sepOk(s, off + 4, year.aux)) return error.NoMatch;
        } else {
            const v = compile.parse2Bounded(s, off, 0, 99) orelse return error.NoMatch;
            if (!sepOk(s, off + 2, year.aux)) return error.NoMatch;
            r.year = compile.normalizeTwoDigitYear(v);
        }
        r.year_set = true;
    }

    const month = slot(p, .month);
    if (month.op != .nop) {
        r.month = compile.parse2Bounded(s, month.offset, 1, 12) orelse return error.NoMatch;
        if (!sepOk(s, @as(usize, month.offset) + 2, month.aux)) return error.NoMatch;
    }

    const day = slot(p, .day);
    if (day.op != .nop) {
        r.day = if (day.op == .day2)
            compile.parse2Bounded(s, day.offset, 1, 31) orelse return error.NoMatch
        else
            compile.parseDaySpacePad(s, day.offset) orelse return error.NoMatch;
        if (!sepOk(s, @as(usize, day.offset) + 2, day.aux)) return error.NoMatch;
    }

    const hour = slot(p, .hour);
    if (hour.op != .nop) {
        r.hour = if (hour.op == .hour12)
            compile.parse2Bounded(s, hour.offset, 1, 12) orelse return error.NoMatch
        else
            compile.parse2Bounded(s, hour.offset, 0, 23) orelse return error.NoMatch;
        if (!sepOk(s, @as(usize, hour.offset) + 2, hour.aux)) return error.NoMatch;
    }

    const minute = slot(p, .minute);
    if (minute.op != .nop) {
        r.minute = compile.parse2Bounded(s, minute.offset, 0, 59) orelse return error.NoMatch;
        if (!sepOk(s, @as(usize, minute.offset) + 2, minute.aux)) return error.NoMatch;
    }

    const second = slot(p, .second);
    if (second.op != .nop) {
        r.second = compile.parse2Bounded(s, second.offset, 0, 59) orelse return error.NoMatch;
        if (!sepOk(s, @as(usize, second.offset) + 2, second.aux)) return error.NoMatch;
    }

    const frac = slot(p, .frac);
    if (frac.op != .nop) {
        if (@as(usize, frac.offset) + frac.len > s.len) return error.NoMatch;
        const digits = s[frac.offset..][0..frac.len];
        r.nanosecond = compile.parseFracSec(digits) orelse return error.NoMatch;
    }

    const ampm = slot(p, .ampm);
    if (ampm.op != .nop) r.ampm = compile.parseAmPm(s, ampm.offset) orelse return error.NoMatch;

    const zone = slot(p, .zone);
    if (zone.op != .nop) r.offset_seconds = try zoneOffset(s, zone);

    return r.finish(p.base_year);
}

fn zoneOffset(s: []const u8, inst: Inst) Error!i32 {
    const off: usize = inst.offset;
    if (off >= s.len) return error.NoMatch;
    if ((inst.op == .tz_z or inst.op == .tz_z_or_offset) and s[off] == 'Z') {
        // The 'Z' form has to end the input; anything after it is a byte no
        // slot describes.
        if (off + 1 != s.len) return error.NoMatch;
        return 0;
    }
    if (off + inst.len > s.len) return error.NoMatch;
    const t = s[off..][0..inst.len];
    return switch (inst.op) {
        .tz_offset, .tz_z_or_offset => compile.parseTzOffset(t) orelse error.NoMatch,
        .tz_name => compile.tz_abbreviations.get(t) orelse error.NoMatch,
        else => error.NoMatch, // tz_z whose byte is not 'Z'
    };
}

const formats = @import("formats.zig");

test {
    std.testing.refAllDecls(@This());
}

fn program(insts: []const Inst) Program {
    var p: Program = .{};
    for (insts, 0..) |inst, i| p.insts[i] = inst;
    p.n = @intCast(insts.len);
    return p;
}

/// p without its slot form, so execute interprets it.
fn interpreted(p: Program) Program {
    var slow = p;
    slow.width = 0;
    slow.width_alt = 0;
    return slow;
}

fn expectAgree(fast_p: *const Program, in: []const u8) !void {
    const slow = interpreted(fast_p.*);
    const want = slow.execute(in);
    const got = fast_p.execute(in);
    std.testing.expectEqual(want, got) catch |err| {
        std.debug.print("fast and interpreted disagree on \"{s}\"\n", .{in});
        return err;
    };
}

test "every structured format takes the fast path and agrees with the interpreter" {
    // The example, the empty input, one byte too many or too few, and every
    // position overwritten with each byte that can change a field's meaning.
    const subs = "09x-: Z+\x00";
    inline for (formats.table, formats.examples) |e, ex| {
        if (e.ambiguous) continue;
        const p = try compile.compile(&formats.stampedFields(e), .{ .base_year = 2026 });
        if (!p.isFast()) {
            std.debug.print("{s} did not take the fast path\n", .{e.name});
            return error.TestUnexpectedResult;
        }
        const valid = ex[1];
        var buf: [64]u8 = undefined;
        try expectAgree(&p, valid);
        try expectAgree(&p, "");
        try expectAgree(&p, valid[0 .. valid.len - 1]);
        for ("x0") |extra| {
            @memcpy(buf[0..valid.len], valid);
            buf[valid.len] = extra;
            try expectAgree(&p, buf[0 .. valid.len + 1]);
        }
        for (0..valid.len) |i| {
            for (subs) |c| {
                if (valid[i] == c) continue;
                @memcpy(buf[0..valid.len], valid);
                buf[i] = c;
                try expectAgree(&p, buf[0..valid.len]);
            }
        }
    }
}

test "the Z form of a conditional zone ends the input" {
    const p = try compile.compile(&.{
        .{ .kind = .hour24, .offset = 0, .len = 2 },
        .{ .kind = .literal, .offset = 2, .len = 1, .aux = ':' },
        .{ .kind = .minute2, .offset = 3, .len = 2 },
        .{ .kind = .tz_z_or_offset, .offset = 5, .len = 6 },
    }, .{});
    try std.testing.expect(p.isFast());
    try std.testing.expectEqual(6, p.width_alt);
    for ([_][]const u8{ "10:30Z", "10:30+05:30", "10:30Z+05:3", "10:30Z00000", "10:30+0530", "10:30" }) |in| {
        try expectAgree(&p, in);
    }
    try std.testing.expectEqual(0, (try p.execute("10:30Z")).offset_seconds);
    try std.testing.expectError(error.NoMatch, p.execute("10:30Z+05:3"));
}

test "slotOf claims the width the interpreter reads" {
    const Case = struct { []const u8, Inst, []const u8 };
    const cases = [_]Case{
        .{ "year4", .{ .op = .year4, .offset = 0, .len = 4 }, "2024" },
        .{ "year4+sep", .{ .op = .year4, .offset = 0, .len = 4, .aux = '-' }, "2024-" },
        .{ "year2", .{ .op = .year2, .offset = 0, .len = 2 }, "24" },
        .{ "year2+sep", .{ .op = .year2, .offset = 0, .len = 2, .aux = '/' }, "24/" },
        .{ "month2", .{ .op = .month2, .offset = 0, .len = 2 }, "03" },
        .{ "month2+sep", .{ .op = .month2, .offset = 0, .len = 2, .aux = compile.auxClass(.sep) }, "03-" },
        .{ "day2", .{ .op = .day2, .offset = 0, .len = 2 }, "15" },
        .{ "day2+sep", .{ .op = .day2, .offset = 0, .len = 2, .aux = 'T' }, "15T" },
        .{ "day_space_pad", .{ .op = .day_space_pad, .offset = 0, .len = 2 }, " 5" },
        .{ "day_space_pad+sep", .{ .op = .day_space_pad, .offset = 0, .len = 2, .aux = ' ' }, "15 " },
        .{ "hour24", .{ .op = .hour24, .offset = 0, .len = 2 }, "22" },
        .{ "hour24+sep", .{ .op = .hour24, .offset = 0, .len = 2, .aux = ':' }, "22:" },
        .{ "hour12", .{ .op = .hour12, .offset = 0, .len = 2 }, "11" },
        .{ "minute2", .{ .op = .minute2, .offset = 0, .len = 2 }, "30" },
        .{ "minute2+sep", .{ .op = .minute2, .offset = 0, .len = 2, .aux = ':' }, "30:" },
        .{ "second2", .{ .op = .second2, .offset = 0, .len = 2 }, "45" },
        .{ "second2+sep", .{ .op = .second2, .offset = 0, .len = 2, .aux = '.' }, "45." },
        .{ "frac3", .{ .op = .frac_sec, .offset = 0, .len = 3 }, "123" },
        .{ "frac9", .{ .op = .frac_sec, .offset = 0, .len = 9 }, "123456789" },
        .{ "ampm", .{ .op = .ampm, .offset = 0, .len = 2 }, "pm" },
        .{ "tz_z", .{ .op = .tz_z, .offset = 0, .len = 1 }, "Z" },
        .{ "tz_offset6", .{ .op = .tz_offset, .offset = 0, .len = 6 }, "+05:30" },
        .{ "tz_offset5", .{ .op = .tz_offset, .offset = 0, .len = 5 }, "-0800" },
        .{ "tz_name", .{ .op = .tz_name, .offset = 0, .len = 3 }, "UTC" },
        .{ "tz_z_or_offset", .{ .op = .tz_z_or_offset, .offset = 0, .len = 6 }, "+05:30" },
    };
    for (cases) |c| {
        errdefer std.debug.print("case {s}\n", .{c[0]});
        const sw = slotOf(c[1]) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(c[2].len, sw.width);
        const p = program(&.{c[1]});
        _ = try p.execute(c[2]);
        var buf: [16]u8 = undefined;
        @memcpy(buf[0..c[2].len], c[2]);
        buf[c[2].len] = 'x';
        try std.testing.expectError(error.NoMatch, p.execute(buf[0 .. c[2].len + 1]));
    }
}

test "plan refuses what it cannot run" {
    const Case = struct { []const u8, []const Inst };
    const cases = [_]Case{
        .{ "empty", &.{} },
        .{ "variable-width day", &.{.{ .op = .day1or2, .offset = 0, .len = 1 }} },
        .{ "variable-width month moves what follows", &.{
            .{ .op = .month1or2, .offset = 0, .len = 1 },
            .{ .op = .literal, .offset = 1, .len = 1, .aux = '/' },
            .{ .op = .year4, .offset = 2, .len = 4 },
        } },
        .{ "month name has no slot", &.{.{ .op = .month_name, .offset = 0, .len = 3, .aux = 3 }} },
        .{ "skip has no slot", &.{ .{ .op = .year4, .offset = 0, .len = 4 }, .{ .op = .skip, .offset = 4, .len = 2 } } },
        .{ "tail has no slot", &.{ .{ .op = .year4, .offset = 0, .len = 4 }, .{ .op = .tail, .offset = 4, .len = 0 } } },
        .{ "iso week needs finishing", &.{ .{ .op = .year4, .offset = 0, .len = 4 }, .{ .op = .iso_week, .offset = 4, .len = 2 } } },
        .{ "ordinal day needs finishing", &.{ .{ .op = .year4, .offset = 0, .len = 4 }, .{ .op = .ordinal_day, .offset = 4, .len = 3 } } },
        .{ "two fields want one slot", &.{ .{ .op = .year4, .offset = 0, .len = 4 }, .{ .op = .year4, .offset = 4, .len = 4 } } },
        .{ "a gap", &.{ .{ .op = .year4, .offset = 0, .len = 4 }, .{ .op = .month2, .offset = 5, .len = 2 } } },
        .{ "does not start at zero", &.{.{ .op = .year4, .offset = 1, .len = 4 }} },
        .{ "overlap", &.{ .{ .op = .year4, .offset = 0, .len = 4 }, .{ .op = .month2, .offset = 3, .len = 2 } } },
        .{ "a gap and an overlap that cancel in a sum", &.{
            .{ .op = .year4, .offset = 0, .len = 4 },
            .{ .op = .month2, .offset = 3, .len = 2 },
            .{ .op = .day2, .offset = 6, .len = 2 },
        } },
        .{ "a field after a conditional zone", &.{
            .{ .op = .tz_z_or_offset, .offset = 0, .len = 6 },
            .{ .op = .year4, .offset = 6, .len = 4 },
        } },
        .{ "wider than the tiling proof holds", &.{
            .{ .op = .year4, .offset = 0, .len = 4 },
            .{ .op = .frac_sec, .offset = 4, .len = 90 },
        } },
    };
    for (cases) |c| {
        var p = program(c[1]);
        if (plan(&p) or p.isFast()) {
            std.debug.print("plan accepted: {s}\n", .{c[0]});
            return error.TestUnexpectedResult;
        }
    }
}

test "plan never writes over the instructions" {
    var p: Program = .{};
    for (0..num_slots) |i| p.insts[i] = .{ .op = .literal, .offset = @intCast(i), .len = 1, .aux = 'x' };
    p.n = num_slots;
    try std.testing.expect(!plan(&p));
    for (p.insts[0..num_slots]) |inst| try std.testing.expectEqual(.literal, inst.op);
}

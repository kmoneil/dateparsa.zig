//! The Zig side of the natural-language oracle: reads what the Go
//! dateparsa's internal natural.Parse answered (tools/oracle/
//! natural_oracle_test.go.txt, run by tools/oracle.sh), answers the same
//! inputs with this port's natural.parse, and writes its answers in the
//! same format so the two files can be diffed.
//!
//!   zig build oracle-natural -- <go output> <zig output>

const std = @import("std");
const natural = @import("natural");

const Io = std.Io;
const locale = natural.locale;
const DateTime = @FieldType(natural.Config, "base");

const bases = [_]DateTime{
    .{ .year = 2024, .month = 3, .day = 15, .hour = 12 },
    .{ .year = 2024, .month = 1, .day = 31, .hour = 23, .minute = 30, .offset_seconds = 19800 },
    .{ .year = 2024, .month = 2, .day = 29, .offset_seconds = -28800 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: oracle-natural <go output> <zig output>\n", .{});
        std.process.exit(2);
    }
    const input = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    var file = try Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    var buf: [1 << 16]u8 = undefined;
    var fw = file.writer(io, &buf);
    try run(input, &fw.interface);
    try fw.interface.flush();
}

fn fmtTime(w: *Io.Writer, t: DateTime) !void {
    const sign = if (t.offset_seconds >= 0) "+" else "";
    try w.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}{s}{d}", .{
        t.year, t.month, t.day, t.hour, t.minute, t.second, t.nanosecond, sign, t.offset_seconds,
    });
}

fn run(input: []const u8, w: *Io.Writer) !void {
    const Backing = @typeInfo(locale.LocaleSet).@"struct".backing_integer.?;
    const all: locale.LocaleSet = @bitCast(~@as(Backing, 0));
    var lines = std.mem.splitScalar(u8, input, '\n');
    var in_buf: [4096]u8 = undefined;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, ' ');
        const bi = try std.fmt.parseInt(usize, it.next().?, 10);
        const pf = std.mem.eql(u8, it.next().?, "1");
        const spec = it.next().?;
        const hex = it.next().?;
        const s = try std.fmt.hexToBytes(&in_buf, hex);
        const set: locale.LocaleSet = if (std.mem.eql(u8, spec, "-"))
            .{}
        else if (std.mem.eql(u8, spec, "*"))
            all
        else
            locale.only(locale.lookup(spec) orelse return error.LocaleNotCompiledIn);
        try w.print("{d} {d} {s} {s} ", .{ bi, @intFromBool(pf), spec, hex });
        if (natural.parse(s, .{ .base = bases[bi], .prefer_future = pf, .locales = set })) |r| {
            try fmtTime(w, r.time);
            const kind: u8 = if (r.kind == .now) 1 else 2;
            try w.print(" kind={d} amb={} alt=", .{ kind, r.ambiguous });
            if (r.alt_time) |a| try fmtTime(w, a) else try w.writeAll("-");
            try w.writeAll("\n");
        } else try w.writeAll("nil\n");
    }
}

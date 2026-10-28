//! Writes, for each input below and each dialect, the format string the
//! input's layout gives, as tab-separated lines for tools/format_check.sh:
//!
//!   dialect  input  format  fields  year month day hour minute second ns offset
//!
//! format is "-" where the dialect cannot spell it. fields names what the
//! format sets (Y M D h m s f z), so a checker compares only those against
//! the time dateparsa read.

const std = @import("std");
const dateparsa = @import("dateparsa");

/// Every example in the README's format table, then variants of the shapes
/// a format string has to get right: widths, orders, separators, clocks,
/// fractions, zones and names.
const inputs = [_][]const u8{
    "2024-03-15",                      "2024-03-15T10:30:00Z",              "2024-03-15T10:30:00.123456+05:30",
    "2024-W11-5",                      "2024-074",                          "2020-07-20+08:00",
    "2024-03-15 10:30:00",             "2024-03-15 10:30:00.000000",        "2024-03-15 10:30:00+00",
    "2014-12-16 06:20:00 UTC",         "2014-05-11 08:20:13,787",           "20240315",
    "20240315T103000Z",                "20240315103000",                    "171113",
    "03/15/2024",                      "15.03.2024",                        "3/15/24",
    "3/15/2024 10:30 PM",              "March 15, 2024",                    "15 Mar 2024",
    "December 23rd",                   "March 2024",                        "the 15th of March 2024",
    "Fri, 15 Mar 2024 10:30:00 +0000", "Friday, 15-Mar-24 10:30:00 UTC",    "Mon Jan 2 15:04:05 2006",
    "15/Mar/2024:10:30:00 +0000",      "Fri Jul 03 2015 18:04:07 GMT+0100", "2015-02-08 03:02:00 +0300 MSK",
    "2014:04:08 22:05:13",
    "2014年04月08日",
    "10:30",                           "10:30:00",                          "10:30 PM",
    "10:30:00.123",                    "1710504800",                        "2024-03-15T10:30:00",
    "2024-03-15T10:30:00+05:30",       "2024-03-15T10:30:00.123456789Z",    "15/03/2024",
    "13/02/2024 10:30",                "2024/03/15",                        "Mon Jan  2 15:04:05 2006",
    "2014-04-26 05:24:37 PM",          "2014:04:08 22:05",                  "2014-04",
    "2014",                            "171113 14:14:20",                   "10:30:00 PM",
    "10:30:00.123456",                 "2024-03-15 10:30:00.000",           "Friday, March 15, 2024",
    "Mar 15 2024",                     "15 March 2024 10:30",               "2024-03-15T10:30:00-08:00",
    "1/2/2024",
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    const w = &out.interface;
    const base: dateparsa.DateTime = .{ .year = 2024, .month = 3, .day = 15, .hour = 12 };
    for (inputs) |s| {
        const r = dateparsa.parseWith(s, .{ .base_time = base }) catch continue;
        var fields: [8]u8 = undefined;
        var n: usize = 0;
        for (r.layout.program.insts[0..r.layout.program.n]) |inst| {
            const f: []const u8 = switch (inst.op) {
                .year4, .year2 => "Y",
                .month2, .month1or2, .month_name => "M",
                .day2, .day1or2, .day_space_pad => "D",
                .iso_week, .ordinal_day => "MD",
                .hour24, .hour12, .hour1or2 => "h",
                .minute2 => "m",
                .second2 => "s",
                .frac_sec => "f",
                .tz_z, .tz_offset, .tz_z_or_offset, .tz_name => "z",
                else => "",
            };
            for (f) |c| if (std.mem.indexOfScalar(u8, fields[0..n], c) == null) {
                fields[n] = c;
                n += 1;
            };
        }
        const t = r.time;
        for ([_]dateparsa.Layout.Dialect{ .strftime, .go, .java }) |d| {
            try w.print("{t}\t{s}\t", .{ d, s });
            var fmt_buf: [128]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&fmt_buf);
            if (r.layout.formatString(d, s, &fw)) |_| {
                try w.writeAll(fw.buffered());
            } else |err| switch (err) {
                error.Unsupported => try w.writeByte('-'),
                else => return err,
            }
            try w.print("\t{s}\t{d} {d} {d} {d} {d} {d} {d} {d}\n", .{
                if (n == 0) "-" else fields[0..n], t.year, t.month, t.day, t.hour, t.minute, t.second, t.nanosecond,
                t.offset_seconds,
            });
        }
    }
    try w.flush();
}

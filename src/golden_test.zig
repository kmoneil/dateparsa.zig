//! The Go dateparsa's golden corpus, checked row by row: 1377 inputs and
//! what the Go library parses each to. A row this port answers differently
//! fails the test unless it sits on the skip list below with its reason.

const std = @import("std");
const dp = @import("root.zig");
const corpus = @import("golden_corpus").text;

/// The golden file's base time.
const base: dp.DateTime = .{ .year = 2024, .month = 6, .day = 15, .hour = 12 };

/// Rows this port deliberately answers differently, with the reason. Empty:
/// every row agrees.
const skip = [_]struct { input: []const u8, reason: []const u8 }{};

/// Go's strconv.Unquote for the escapes %q writes.
fn unquote(out: []u8, q: []const u8) ![]u8 {
    if (q.len < 2 or q[0] != '"' or q[q.len - 1] != '"') return error.NotQuoted;
    const body = q[1 .. q.len - 1];
    var w: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] != '\\') {
            out[w] = body[i];
            w += 1;
            i += 1;
            continue;
        }
        i += 1;
        const e = body[i];
        i += 1;
        const simple: ?u8 = switch (e) {
            'a' => 0x07,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 0x0b,
            '\\' => '\\',
            '"' => '"',
            else => null,
        };
        if (simple) |c| {
            out[w] = c;
            w += 1;
            continue;
        }
        switch (e) {
            'x' => {
                out[w] = try std.fmt.parseInt(u8, body[i..][0..2], 16);
                w += 1;
                i += 2;
            },
            'u', 'U' => {
                const n: usize = if (e == 'u') 4 else 8;
                const cp = try std.fmt.parseInt(u21, body[i..][0..n], 16);
                w += try std.unicode.utf8Encode(cp, out[w..]);
                i += n;
            },
            '0'...'7' => {
                out[w] = try std.fmt.parseInt(u8, body[i - 1 ..][0..3], 8);
                w += 1;
                i += 2;
            },
            else => return error.BadEscape,
        }
    }
    return out[0..w];
}

/// A row as the Go golden test writes it.
fn line(w: *std.Io.Writer, quoted: []const u8, input: []const u8) !void {
    try w.writeAll(quoted);
    const r = dp.parseWith(input, .{ .base_time = base }) catch |err| return switch (err) {
        error.NoMatch => w.writeAll("\tnomatch"),
        error.Ambiguous => w.writeAll("\tambiguous"),
        error.NoBaseTime => w.writeAll("\tnobase"),
    };
    // The instant in UTC, Go's "2006-01-02T15:04:05.000000000Z": a
    // negative year is a sign and four digits.
    const utc = dp.DateTime.fromEpoch(r.time.toEpoch(), 0);
    try w.writeAll("\tok\t");
    if (utc.year < 0) try w.writeByte('-');
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
        @abs(utc.year), utc.month, utc.day, utc.hour, utc.minute, utc.second, utc.nanosecond,
    });
    const off = r.time.offset_seconds;
    const sign: u8 = if (off < 0) '-' else '+';
    try w.print("\t{c}{d:0>2}:{d:0>2}", .{ sign, @abs(off) / 3600, @abs(off) % 3600 / 60 });
    const kind = @tagName(r.kind);
    try w.print("\t{s}\tambiguous={}\tkind={s}", .{ r.layout.label, r.ambiguous, kind });
}

test "every golden row parses as it did in Go" {
    var rows: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var input_buf: [4096]u8 = undefined;
    var got_buf: [4096]u8 = undefined;
    while (lines.next()) |want| {
        if (want.len == 0 or want[0] == '#') continue;
        rows += 1;
        const quoted = want[0 .. std.mem.indexOfScalar(u8, want, '\t') orelse want.len];
        const input = try unquote(&input_buf, quoted);
        var w: std.Io.Writer = .fixed(&got_buf);
        try line(&w, quoted, input);
        const got = w.buffered();
        if (std.mem.eql(u8, got, want)) continue;
        const listed = for (skip) |s| {
            if (std.mem.eql(u8, s.input, input)) break true;
        } else false;
        if (listed) {
            skipped += 1;
            continue;
        }
        failed += 1;
        if (failed <= 20) std.debug.print("- {s}\n+ {s}\n", .{ want, got });
    }
    if (failed > 0) std.debug.print("{d} of {d} golden rows differ\n", .{ failed, rows });
    try std.testing.expectEqual(0, failed);
    try std.testing.expectEqual(skip.len, skipped); // a stale skip entry fails too
    try std.testing.expectEqual(1377, rows);
}

test unquote {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x00MAY1", try unquote(&buf, "\"\\x00MAY1\""));
    try std.testing.expectEqualStrings("a\"b\\c\td", try unquote(&buf, "\"a\\\"b\\\\c\\td\""));
    try std.testing.expectEqualStrings("\u{a0}x\u{1F600}", try unquote(&buf, "\"\\u00a0x\\U0001f600\""));
    try std.testing.expectEqualStrings("年", try unquote(&buf, "\"年\""));
}

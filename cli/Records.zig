//! The records of a CSV file, or the lines of any other, read one at a time,
//! and the field a column names in each.
//!
//! CSV is read as RFC 4180 has it and spreadsheets write it: a field in
//! double quotes may hold the delimiter, a line break, or a quote written
//! twice. And leniently, as most readers do: a quote inside an unquoted field
//! is a quote, and a quoted field with no closing quote runs to the end of
//! the input. A UTF-8 byte order mark before the first record is not part of
//! it. Each record keeps its bytes as read, line ending included, so a record
//! written back unchanged is the record that was read.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Records = @This();

reader: *Io.Reader,
/// Records split on the delimiter, with quotes; false reads lines.
csv: bool,
delimiter: u8,
buf: Io.Writer.Allocating,
/// The line the next record starts on.
line: usize = 1,

pub const Error = error{ ReadFailed, OutOfMemory };

pub const Record = struct {
    /// The record as read: its line ending, and any byte order mark.
    raw: []const u8,
    /// Where text starts in raw, past a byte order mark.
    offset: usize,
    /// The record without its line ending or byte order mark.
    text: []const u8,
    /// The line the record starts on, from 1.
    line: usize,
};

/// Where a field sits in a record's text, its quotes included.
pub const Span = struct { start: usize, end: usize };

pub fn init(gpa: Allocator, reader: *Io.Reader, csv: bool, delimiter: u8) Records {
    return .{ .reader = reader, .csv = csv, .delimiter = delimiter, .buf = .init(gpa) };
}

pub fn deinit(r: *Records) void {
    r.buf.deinit();
}

/// The next record, or null at the end of the input. It is valid until the
/// next call.
pub fn next(r: *Records) Error!?Record {
    r.buf.clearRetainingCapacity();
    const w = &r.buf.writer;
    var lines: usize = 0;
    while (true) {
        _ = r.reader.streamDelimiterEnding(w, '\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
        };
        const newline = if (r.reader.takeByte()) |_| true else |err| switch (err) {
            error.EndOfStream => false,
            error.ReadFailed => return error.ReadFailed,
        };
        if (!newline) break;
        w.writeByte('\n') catch return error.OutOfMemory;
        lines += 1;
        // A line break inside quotes is the field's, not the record's end.
        if (!r.csv or !openQuote(r.buf.written(), r.delimiter)) break;
    }
    const raw = r.buf.written();
    if (raw.len == 0) return null;
    const offset: usize = if (r.line == 1 and std.mem.startsWith(u8, raw, bom)) bom.len else 0;
    var text = raw[offset..];
    if (std.mem.endsWith(u8, text, "\n")) text = text[0 .. text.len - 1];
    if (std.mem.endsWith(u8, text, "\r")) text = text[0 .. text.len - 1];
    const line = r.line;
    r.line += lines;
    return .{ .raw = raw, .offset = offset, .text = text, .line = line };
}

const bom = "\xEF\xBB\xBF";

/// The fields of a CSV record, in order.
pub const Fields = struct {
    text: []const u8,
    delimiter: u8,
    pos: ?usize = 0,

    pub fn next(f: *Fields) ?Span {
        const start = f.pos orelse return null;
        const end = scan(f.text, start, f.delimiter).end;
        f.pos = if (end < f.text.len) end + 1 else null;
        return .{ .start = start, .end = end };
    }
};

pub fn fields(text: []const u8, delimiter: u8) Fields {
    return .{ .text = text, .delimiter = delimiter };
}

/// Where field index (from 0) sits in text, or null when the record has
/// fewer fields.
pub fn field(text: []const u8, delimiter: u8, index: usize) ?Span {
    var it = fields(text, delimiter);
    var i: usize = 0;
    while (it.next()) |span| : (i += 1) {
        if (i == index) return span;
    }
    return null;
}

/// The field starting at start: where it ends (the delimiter after it, or
/// the end of text), and whether a quote it opened is still open there.
fn scan(text: []const u8, start: usize, delimiter: u8) struct { end: usize, open: bool } {
    var quoted = false;
    var i = start;
    if (i < text.len and text[i] == '"') {
        quoted = true;
        i += 1;
    }
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quoted) {
            if (c != '"') continue;
            if (i + 1 < text.len and text[i + 1] == '"') i += 1 else quoted = false;
        } else if (c == delimiter) return .{ .end = i, .open = false };
    }
    return .{ .end = text.len, .open = quoted };
}

/// Whether text ends inside a quoted field.
fn openQuote(text: []const u8, delimiter: u8) bool {
    var start: usize = 0;
    while (true) {
        const s = scan(text, start, delimiter);
        if (s.end >= text.len) return s.open;
        start = s.end + 1;
    }
}

/// A field's value: its quotes taken off and each quote written twice made
/// one. A slice of the field when that changes nothing but the ends,
/// otherwise built in buf.
pub fn unquote(raw: []const u8, buf: *std.ArrayList(u8), gpa: Allocator) Allocator.Error![]const u8 {
    if (raw.len == 0 or raw[0] != '"') return raw;
    const inner = raw[1..];
    const q = std.mem.indexOfScalar(u8, inner, '"') orelse return inner; // never closed
    if (q == inner.len - 1) return inner[0..q];
    buf.clearRetainingCapacity();
    var quoted = true;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (quoted and c == '"') {
            if (i + 1 < raw.len and raw[i + 1] == '"') {
                try buf.append(gpa, '"');
                i += 1;
            } else quoted = false;
            continue;
        }
        try buf.append(gpa, c);
    }
    return buf.items;
}

const testing = std.testing;

fn readAll(input: []const u8, csv: bool) ![]const []const u8 {
    var reader: Io.Reader = .fixed(input);
    var r: Records = .init(testing.allocator, &reader, csv, ',');
    defer r.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| testing.allocator.free(s);
        out.deinit(testing.allocator);
    }
    while (try r.next()) |rec| try out.append(testing.allocator, try testing.allocator.dupe(u8, rec.text));
    return out.toOwnedSlice(testing.allocator);
}

fn expectRecords(input: []const u8, csv: bool, want: []const []const u8) !void {
    const got = try readAll(input, csv);
    defer {
        for (got) |s| testing.allocator.free(s);
        testing.allocator.free(got);
    }
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "records end at a line break outside quotes" {
    try expectRecords("a,b\nc,d\n", true, &.{ "a,b", "c,d" });
    try expectRecords("a,b\r\nc,d", true, &.{ "a,b", "c,d" });
    try expectRecords("a,\"two\nlines\"\nc,d\n", true, &.{ "a,\"two\nlines\"", "c,d" });
    try expectRecords("a,\"x\"\"\ny\"\n", true, &.{"a,\"x\"\"\ny\""});
    try expectRecords("\n\nx\n", true, &.{ "", "", "x" });
    try expectRecords("", true, &.{});
    // Lines alone: a quote is a byte like any other.
    try expectRecords("a,\"two\nlines\"\n", false, &.{ "a,\"two", "lines\"" });
    // A quote never closed runs to the end of the input.
    try expectRecords("a,\"open\nb\nc", true, &.{"a,\"open\nb\nc"});
}

test "a record keeps its bytes, and starts on its line" {
    var reader: Io.Reader = .fixed(bom ++ "date\r\n\"a\nb\",1\nlast");
    var r: Records = .init(testing.allocator, &reader, true, ',');
    defer r.deinit();
    const header = (try r.next()).?;
    try testing.expectEqualStrings(bom ++ "date\r\n", header.raw);
    try testing.expectEqualStrings("date", header.text);
    try testing.expectEqual(bom.len, header.offset);
    try testing.expectEqual(1, header.line);
    const two = (try r.next()).?;
    try testing.expectEqual(2, two.line);
    try testing.expectEqual(0, two.offset);
    const last = (try r.next()).?;
    try testing.expectEqual(4, last.line);
    try testing.expectEqualStrings("last", last.raw);
    try testing.expectEqual(null, try r.next());
}

test "fields, quoted and not" {
    const text = "1,\"a,b\",,\"say \"\"hi\"\"\",x\"y";
    const want = [_][]const u8{ "1", "\"a,b\"", "", "\"say \"\"hi\"\"\"", "x\"y" };
    var it = fields(text, ',');
    for (want) |w| {
        const span = it.next().?;
        try testing.expectEqualStrings(w, text[span.start..span.end]);
    }
    try testing.expectEqual(null, it.next());
    try testing.expectEqual(Span{ .start = 2, .end = 7 }, field(text, ',', 1).?);
    try testing.expectEqual(null, field(text, ',', 5));
    try testing.expectEqual(Span{ .start = 0, .end = 0 }, field("", ',', 0).?);
    try testing.expectEqual(Span{ .start = 2, .end = 3 }, field("a\tb", '\t', 1).?);
}

test unquote {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cases = [_][2][]const u8{
        .{ "plain", "plain" },
        .{ "\"a,b\"", "a,b" },
        .{ "\"say \"\"hi\"\"\"", "say \"hi\"" },
        .{ "\"\"", "" },
        .{ "\"open", "open" },
        .{ "\"a\"b", "ab" },
        .{ "x\"y", "x\"y" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try unquote(c[0], &buf, testing.allocator));
}

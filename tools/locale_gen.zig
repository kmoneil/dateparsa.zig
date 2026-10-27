//! Generates src/locale/<tag>.zig from the Go dateparsa's locale tables,
//! internal/locale/data/<tag>.go, which are themselves generated from CLDR.
//!
//!   zig build locales [-Dgo-locale-dir=<dir>]
//!
//! Deterministic: the same input gives byte-identical output, so a
//! regeneration diff shows only what the source changed. The Go files are
//! read as data, not compiled: each string literal belongs to the most
//! recent `Key:` before it, which is the shape every one of them has.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The locales the Go original ships, in tag order.
const tags = [_][]const u8{
    "ar", "da", "de", "en", "es", "fi", "fr", "hi", "it", "ja",
    "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh",
};

/// Every key a data file holds, its Zig field, and how many strings it
/// takes (null: a list of any length).
const Key = struct { go: []const u8, zig: []const u8, count: ?usize };

const keys = [_]Key{
    .{ .go = "Tag", .zig = "tag", .count = 1 },
    .{ .go = "Name", .zig = "name", .count = 1 },
    .{ .go = "MonthsWide", .zig = "months_wide", .count = 12 },
    .{ .go = "MonthsAbbr", .zig = "months_abbr", .count = 12 },
    .{ .go = "WeekdaysWide", .zig = "weekdays_wide", .count = 7 },
    .{ .go = "WeekdaysAbbr", .zig = "weekdays_abbr", .count = 7 },
    .{ .go = "AM", .zig = "am", .count = 1 },
    .{ .go = "PM", .zig = "pm", .count = 1 },
};

const relative_keys = [_]Key{
    .{ .go = "Now", .zig = "now", .count = null },
    .{ .go = "Today", .zig = "today", .count = null },
    .{ .go = "Yesterday", .zig = "yesterday", .count = null },
    .{ .go = "Tomorrow", .zig = "tomorrow", .count = null },
    .{ .go = "Ago", .zig = "ago", .count = null },
    .{ .go = "InFuture", .zig = "in_future", .count = null },
    .{ .go = "Last", .zig = "last", .count = null },
    .{ .go = "Next", .zig = "next", .count = null },
    .{ .go = "This", .zig = "this", .count = null },
    .{ .go = "Seconds", .zig = "seconds", .count = null },
    .{ .go = "Minutes", .zig = "minutes", .count = null },
    .{ .go = "Hours", .zig = "hours", .count = null },
    .{ .go = "Days", .zig = "days", .count = null },
    .{ .go = "Weeks", .zig = "weeks", .count = null },
    .{ .go = "Months", .zig = "months", .count = null },
    .{ .go = "Years", .zig = "years", .count = null },
};

const Values = std.StringHashMapUnmanaged(std.ArrayList([]const u8));

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: locale_gen <go internal/locale/data dir> <output dir>\n", .{});
        std.process.exit(2);
    }
    var in_dir = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer in_dir.close(io);
    var out_dir = try Io.Dir.cwd().openDir(io, args[2], .{});
    defer out_dir.close(io);

    inline for (tags) |tag| {
        const src = try in_dir.readFileAlloc(io, tag ++ ".go", arena, .limited(1 << 20));
        const values = parse(arena, src) catch |err| {
            std.debug.print("{s}.go: {t}\n", .{ tag, err });
            return err;
        };
        const out = render(arena, tag, &values) catch |err| {
            std.debug.print("{s}.go: {t}\n", .{ tag, err });
            return err;
        };
        try out_dir.writeFile(io, .{ .sub_path = tag ++ ".zig", .data = out });
    }
}

/// Each string literal in src, filed under the `Key:` most recently seen.
/// Literals before the first key (the import path) are ignored.
fn parse(gpa: Allocator, src: []const u8) !Values {
    var values: Values = .empty;
    var key: ?[]const u8 = null;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        } else if (c == '"') {
            const lit = try stringLiteral(gpa, src, &i);
            if (key) |k| {
                const entry = try values.getOrPut(gpa, k);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, lit);
            }
        } else if (std.ascii.isAlphabetic(c)) {
            const start = i;
            while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
            if (i < src.len and src[i] == ':') {
                key = src[start..i];
                // A key with no literal yet still exists: an empty list.
                const entry = try values.getOrPut(gpa, key.?);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
            }
        } else {
            i += 1;
        }
    }
    return values;
}

/// Decodes the Go string literal at src[i.*], which is a '"', and leaves
/// i.* past its closing quote.
fn stringLiteral(gpa: Allocator, src: []const u8, i: *usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var j = i.* + 1;
    while (true) : (j += 1) {
        if (j >= src.len or src[j] == '\n') return error.UnterminatedString;
        const c = src[j];
        if (c == '"') break;
        if (c != '\\') {
            try out.append(gpa, c);
            continue;
        }
        j += 1;
        if (j >= src.len) return error.UnterminatedString;
        switch (src[j]) {
            '\\', '"' => |e| try out.append(gpa, e),
            'n' => try out.append(gpa, '\n'),
            't' => try out.append(gpa, '\t'),
            'x' => {
                if (j + 2 >= src.len) return error.BadEscape;
                try out.append(gpa, try std.fmt.parseInt(u8, src[j + 1 .. j + 3], 16));
                j += 2;
            },
            'u', 'U' => |e| {
                const n: usize = if (e == 'u') 4 else 8;
                if (j + n >= src.len) return error.BadEscape;
                const cp = try std.fmt.parseInt(u21, src[j + 1 .. j + 1 + n], 16);
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(cp, &buf);
                try out.appendSlice(gpa, buf[0..len]);
                j += n;
            },
            else => return error.BadEscape,
        }
    }
    i.* = j + 1;
    return out.items;
}

fn render(gpa: Allocator, comptime tag: []const u8, values: *const Values) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try w.writeAll(
        "// Generated by tools/locale_gen.zig from the Go dateparsa's\n" ++
            "// internal/locale/data/" ++ tag ++ ".go, which is derived from CLDR\n" ++
            "// (Unicode License v3, see NOTICE). Do not edit; regenerate with\n" ++
            "// `zig build locales`.\n\n" ++
            "const Data = @import(\"../locale.zig\").Data;\n\n" ++
            "pub const data: Data = .{\n",
    );
    for (keys) |k| {
        const list = try expect(values, k);
        if (k.count == 1) {
            const is_tag = std.mem.eql(u8, k.go, "Tag");
            if (is_tag and !std.mem.eql(u8, list[0], tag)) return error.TagMismatch;
            try w.print("    .{s} = ", .{k.zig});
            try writeString(w, list[0]);
            try w.writeAll(",\n");
        } else {
            try w.print("    .{s} = .{{\n", .{k.zig});
            for (list) |s| {
                try w.writeAll("        ");
                try writeString(w, s);
                try w.writeAll(",\n");
            }
            try w.writeAll("    },\n");
        }
    }
    try w.writeAll("    .relative = .{\n");
    for (relative_keys) |k| {
        const list = try expect(values, k);
        if (list.len == 0) {
            try w.print("        .{s} = &.{{}},\n", .{k.zig});
            continue;
        }
        try w.print("        .{s} = &.{{\n", .{k.zig});
        for (list) |s| {
            try w.writeAll("            ");
            try writeString(w, s);
            try w.writeAll(",\n");
        }
        try w.writeAll("        },\n");
    }
    try w.writeAll("    },\n};\n");
    return out.written();
}

fn expect(values: *const Values, k: Key) ![]const []const u8 {
    const list = values.get(k.go) orelse {
        std.debug.print("missing key {s}\n", .{k.go});
        return error.MissingKey;
    };
    if (k.count) |n| if (list.items.len != n) {
        std.debug.print("{s}: {d} strings, want {d}\n", .{ k.go, list.items.len, n });
        return error.WrongCount;
    };
    return list.items;
}

/// A Zig string literal for s: UTF-8 written as is, except quotes,
/// backslashes, control bytes, and Unicode spaces and format characters,
/// which are escaped so the data's invisible bytes stay visible in review.
fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    try w.writeByte('"');
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch unreachable;
        switch (cp) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{cp}),
            0xa0, 0xad, 0x2000...0x200f, 0x2028...0x202f, 0x205f...0x206f, 0x3000, 0xfeff => {
                try w.print("\\u{{{x}}}", .{cp});
            },
            else => try w.writeAll(bytes),
        }
    }
    try w.writeByte('"');
}

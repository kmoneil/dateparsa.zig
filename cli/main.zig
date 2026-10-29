//! dateparsa, the command: which format a column of dates is written in,
//! and the column written back as RFC 3339.
//!
//!   dateparsa detect orders.csv --col ordered_at
//!   dateparsa normalize orders.csv --col 3 > out.csv
//!
//! A column's date order is settled from all of its values before any value
//! is read (dateparsa.Column), so the first row is read the way the last
//! one settles. That reads the input twice: a file is read again, and
//! standard input, or anything else that cannot be, is held in memory.
//! normalize --order fixes the order and reads the input once, as it comes.
//!
//! The library allocates nothing; this program does, for records of any
//! length and for that second pass.

const std = @import("std");
const dp = @import("dateparsa");
const build_options = @import("build_options");
const Records = @import("Records.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Order = dp.Layout.Order;

const usage =
    \\usage: dateparsa <command> [FILE] [options]
    \\
    \\Commands:
    \\  detect     the formats the values are written in, the order their
    \\             numeric dates are in, and the values that could not be read
    \\  normalize  the input again, with each value written as RFC 3339
    \\
    \\FILE is read as CSV when --col is given, and as one value a line when it
    \\is not. With no FILE, or -, standard input is read.
    \\
    \\Options:
    \\  -c, --col N|NAME   the column: 1 for the first, or its name in the header
    \\      --header       the first row is a header (implied by --col NAME)
    \\  -d, --delimiter C  the field separator: , (the default), ; | or tab
    \\      --order ORDER  read numeric dates month-first, day-first or
    \\                     year-first, instead of settling it from the column
    \\      --base TIME    what relative dates and dates with no year are read
    \\                     against: a date and time, or now
    \\      --tz OFFSET    the UTC offset of values that write no zone: +05:30,
    \\                     -0800 or Z (the default)
    \\      --locale TAGS  also read these languages: fr,de or all (English is
    \\                     always read)
    \\      --utc          normalize: write each time in UTC
    \\      --json         detect: write the report as JSON
    \\  -h, --help         show this help
    \\      --version      show the version
    \\
    \\Exit status: 0 when every value was read, 1 when some were not or the
    \\column's date order is not settled (normalize refuses to guess it), 2 on
    \\a usage or input error. detect exits as normalize would.
    \\
;

const Command = enum { detect, normalize };

const ColumnArg = union(enum) {
    /// From 0.
    index: usize,
    name: []const u8,
};

const Config = struct {
    command: Command,
    /// Null, or "-", reads standard input.
    path: ?[]const u8 = null,
    /// Null reads each line whole.
    column: ?ColumnArg = null,
    header: bool = false,
    delimiter: u8 = ',',
    /// Read in this order rather than the one the column settles.
    order: ?Order = null,
    options: dp.Options = .{},
    utc: bool = false,
    json: bool = false,
};

const Action = union(enum) { run: Config, help, version };

/// A usage error's message.
const Usage = struct {
    buf: [256]u8 = undefined,
    message: []const u8 = "",

    fn fail(u: *Usage, comptime fmt: []const u8, args: anytype) error{Usage} {
        var w: Io.Writer = .fixed(&u.buf);
        w.print(fmt, args) catch {};
        u.message = w.buffered();
        return error.Usage;
    }
};

const Flag = enum { col, header, delimiter, order, base, tz, locale, utc, json, help, version };

const flags: std.StaticStringMap(Flag) = .initComptime(.{
    .{ "-c", .col },
    .{ "--col", .col },
    .{ "--header", .header },
    .{ "-d", .delimiter },
    .{ "--delimiter", .delimiter },
    .{ "--order", .order },
    .{ "--base", .base },
    .{ "--tz", .tz },
    .{ "--locale", .locale },
    .{ "--utc", .utc },
    .{ "--json", .json },
    .{ "-h", .help },
    .{ "--help", .help },
    .{ "--version", .version },
});

const order_names: std.StaticStringMap(Order) = .initComptime(.{
    .{ "month-first", .month_first },
    .{ "mdy", .month_first },
    .{ "day-first", .day_first },
    .{ "dmy", .day_first },
    .{ "year-first", .year_first },
    .{ "ymd", .year_first },
});

/// What args, the program's name left off, ask for. now is the time
/// --base now names.
fn parseArgs(args: []const []const u8, now: dp.DateTime.Epoch, u: *Usage) error{Usage}!Action {
    var command: ?Command = null;
    var cfg: Config = .{ .command = .detect };
    var base: ?[]const u8 = null;
    var positional_only = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (positional_only or arg.len < 2 or arg[0] != '-') {
            if (command == null) {
                if (std.mem.eql(u8, arg, "help")) return .help;
                command = std.meta.stringToEnum(Command, arg) orelse
                    return u.fail("no command {s}: detect or normalize", .{arg});
            } else if (cfg.path == null) {
                cfg.path = arg;
            } else return u.fail("one file at a time: {s} and {s}", .{ cfg.path.?, arg });
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                inline_value = arg[eq + 1 ..];
            }
        }
        const flag = flags.get(name) orelse return u.fail("no option {s}", .{name});
        switch (flag) {
            .header, .utc, .json, .help, .version => {
                if (inline_value != null) return u.fail("{s} takes no value", .{name});
                switch (flag) {
                    .header => cfg.header = true,
                    .utc => cfg.utc = true,
                    .json => cfg.json = true,
                    .help => return .help,
                    .version => return .version,
                    else => unreachable,
                }
                continue;
            },
            else => {},
        }
        const value = inline_value orelse blk: {
            i += 1;
            if (i == args.len) return u.fail("{s} needs a value", .{name});
            break :blk args[i];
        };
        switch (flag) {
            .col => cfg.column = parseColumn(value) orelse
                return u.fail("--col {s}: 1 for the first column, or a name", .{value}),
            .delimiter => cfg.delimiter = parseDelimiter(value) orelse
                return u.fail("--delimiter {s}: one character, or tab", .{value}),
            .order => cfg.order = order_names.get(value) orelse
                return u.fail("--order {s}: month-first, day-first or year-first", .{value}),
            .base => base = value,
            .tz => cfg.options.timezone_offset = parseOffset(value) orelse
                return u.fail("--tz {s}: an offset such as +05:30, -0800 or Z", .{value}),
            .locale => {
                var bad: []const u8 = "";
                cfg.options.locales = parseLocales(value, &bad) orelse
                    return u.fail("--locale: {s} is no locale this build reads", .{bad});
            },
            else => unreachable,
        }
    }
    cfg.command = command orelse return u.fail("no command: detect or normalize", .{});
    if (cfg.json and cfg.command != .detect) return u.fail("--json is for detect", .{});
    if (cfg.utc and cfg.command != .normalize) return u.fail("--utc is for normalize", .{});
    if (cfg.column) |c| {
        if (c == .name) cfg.header = true;
    }
    if (base) |b| cfg.options.base_time = parseBase(b, cfg.options.timezone_offset, now) orelse
        return u.fail("--base {s}: a date and time, such as 2024-03-15T12:00:00Z, or now", .{b});
    return .{ .run = cfg };
}

fn parseColumn(s: []const u8) ?ColumnArg {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return .{ .name = s };
    const n = std.fmt.parseInt(usize, s, 10) catch return null;
    if (n == 0) return null;
    return .{ .index = n - 1 };
}

fn parseDelimiter(s: []const u8) ?u8 {
    if (std.mem.eql(u8, s, "tab") or std.mem.eql(u8, s, "\\t")) return '\t';
    if (s.len != 1) return null;
    return switch (s[0]) {
        '"', '\n', '\r' => null,
        else => s[0],
    };
}

/// Seconds east of UTC: Z, UTC or GMT, or a sign and hours with or without
/// minutes (+5, +05, +0530, +05:30). Under a day, as the library takes.
fn parseOffset(s: []const u8) ?i32 {
    for ([_][]const u8{ "Z", "UTC", "GMT" }) |zero| {
        if (std.ascii.eqlIgnoreCase(s, zero)) return 0;
    }
    if (s.len < 2 or (s[0] != '+' and s[0] != '-')) return null;
    const rest = s[1..];
    var hours: []const u8 = rest;
    var minutes: []const u8 = "0";
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        hours = rest[0..colon];
        minutes = rest[colon + 1 ..];
        if (minutes.len != 2) return null;
    } else if (rest.len == 4) {
        hours = rest[0..2];
        minutes = rest[2..];
    } else if (rest.len > 2) return null;
    if (hours.len == 0 or hours.len > 2) return null;
    for ([_][]const u8{ hours, minutes }) |part| {
        for (part) |c| if (!std.ascii.isDigit(c)) return null;
    }
    const h = std.fmt.parseInt(i32, hours, 10) catch return null;
    const m = std.fmt.parseInt(i32, minutes, 10) catch return null;
    if (h > 23 or m > 59) return null;
    const seconds = h * 3600 + m * 60;
    return if (s[0] == '-') -seconds else seconds;
}

const LocaleBits = @typeInfo(dp.LocaleSet).@"struct".backing_integer.?;

/// The locales comma-separated tags name, or all of them. Null, with the
/// tag in bad, for a tag this build did not compile in.
fn parseLocales(s: []const u8, bad: *[]const u8) ?dp.LocaleSet {
    if (std.mem.eql(u8, s, "all")) return @bitCast(~@as(LocaleBits, 0));
    var bits: LocaleBits = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const tag = std.mem.trim(u8, part, " ");
        if (tag.len == 0) continue;
        const set = dp.localeSet(tag) orelse {
            bad.* = tag;
            return null;
        };
        bits |= @as(LocaleBits, @bitCast(set));
    }
    return @bitCast(bits);
}

/// The base time s names: now, at offset, or a date and time any one way.
fn parseBase(s: []const u8, offset: i32, now: dp.DateTime.Epoch) ?dp.DateTime {
    if (std.ascii.eqlIgnoreCase(s, "now")) return dp.DateTime.fromEpoch(now, offset);
    const r = dp.parseWith(s, .{ .timezone_offset = offset, .strict = true }) catch return null;
    if (r.kind != .absolute) return null;
    return r.time;
}

pub fn main(init: std.process.Init) u8 {
    var out_buf: [1 << 16]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = Io.File.stderr().writerStreaming(init.io, &err_buf);
    const env: Env = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .now = nowEpoch(init.io),
    };
    const code = blk: {
        const args = init.minimal.args.toSlice(env.arena) catch |e| break :blk e;
        break :blk execute(env, args[1..], &out.interface, &err.interface);
    } catch |e| blk: {
        const cause: anyerror = switch (e) {
            error.WriteFailed => out.err orelse e,
            else => e,
        };
        err.interface.print("dateparsa: {s}\n", .{describe(cause)}) catch {};
        break :blk 2;
    };
    out.interface.flush() catch |e| {
        err.interface.print("dateparsa: cannot write the output: {s}\n", .{describe(out.err orelse e)}) catch {};
        err.interface.flush() catch {};
        return 2;
    };
    err.interface.flush() catch {};
    return code;
}

fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.OutOfMemory => "out of memory",
        error.BrokenPipe => "the output was closed",
        else => @errorName(e),
    };
}

/// What the process works with, apart from its arguments and output.
const Env = struct {
    io: Io,
    gpa: Allocator,
    /// For what lasts the whole run: the arguments, and the values a report
    /// points at.
    arena: Allocator,
    /// The time --base now names.
    now: dp.DateTime.Epoch,
    /// Standard input's bytes, in place of reading it: the tests'.
    stdin: ?[]const u8 = null,
};

/// The command args name (the program's name left off), run: what it
/// writes to out and err, and its exit status.
fn execute(env: Env, args: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    if (args.len == 0) {
        try err.writeAll(usage);
        return 2;
    }
    var u: Usage = .{};
    const action = parseArgs(args, env.now, &u) catch {
        try err.print("dateparsa: {s}\nRun dateparsa --help for the options.\n", .{u.message});
        return 2;
    };
    const cfg = switch (action) {
        .help => {
            try out.writeAll(usage);
            return 0;
        },
        .version => {
            try out.print("dateparsa {s}\n", .{build_options.version});
            return 0;
        },
        .run => |c| c,
    };

    var buf: [1 << 16]u8 = undefined;
    var source: Source = .{ .io = env.io, .gpa = env.gpa, .buf = &buf, .path = cfg.path, .stdin = env.stdin };
    defer source.deinit();
    const twice = cfg.command == .detect or cfg.order == null;
    source.open(twice) catch |e| return failInput(err, &source, e);
    var program: Program = .{ .cfg = cfg, .arena = env.arena, .gpa = env.gpa, .source = &source, .out = out, .err = err };
    return program.run(twice) catch |e| switch (e) {
        error.ReadFailed => try failInput(err, &source, e),
        error.NoHeader, error.NoSuchColumn => 2,
        else => |other| return other,
    };
}

fn failInput(err: *Io.Writer, source: *const Source, e: anyerror) !u8 {
    const cause = if (e == error.ReadFailed) source.reader.err orelse e else e;
    try err.print("dateparsa: cannot read {s}: {s}\n", .{ source.name(), describe(cause) });
    return 2;
}

fn nowEpoch(io: Io) dp.DateTime.Epoch {
    const ns = Io.Clock.real.now(io).nanoseconds;
    return .{
        .seconds = @intCast(@divFloor(ns, std.time.ns_per_s)),
        .nanosecond = @intCast(@mod(ns, std.time.ns_per_s)),
    };
}

/// The input, from its start, once a pass.
const Source = struct {
    io: Io,
    gpa: Allocator,
    buf: []u8,
    path: ?[]const u8,
    /// Standard input's bytes, when they are given rather than read.
    stdin: ?[]const u8 = null,
    file: ?Io.File = null,
    /// A regular file, read again from its start for a second pass.
    regular: bool = false,
    /// The whole input, for one that cannot be read twice.
    held: ?[]const u8 = null,
    /// held was read into memory here, and is freed with the source.
    owned: bool = false,
    reader: Io.File.Reader = undefined,
    fixed: Io.Reader = undefined,

    fn name(s: *const Source) []const u8 {
        return s.path orelse "standard input";
    }

    /// Opens the input, and holds it in memory when it is to be read twice
    /// and cannot be read again.
    fn open(s: *Source, twice: bool) !void {
        if (s.path) |p| {
            if (std.mem.eql(u8, p, "-")) {
                s.path = null;
            } else {
                const f = try Io.Dir.cwd().openFile(s.io, p, .{});
                s.file = f;
                s.regular = (try f.stat(s.io)).kind == .file;
            }
        }
        if (s.path == null) {
            if (s.stdin) |bytes| {
                s.held = bytes;
                return;
            }
        }
        if (twice and !s.regular) {
            s.reader = s.streaming();
            s.held = try s.reader.interface.allocRemaining(s.gpa, .unlimited);
            s.owned = true;
        }
    }

    fn deinit(s: *Source) void {
        if (s.owned) s.gpa.free(s.held.?);
        if (s.file) |f| f.close(s.io);
    }

    fn streaming(s: *Source) Io.File.Reader {
        return (s.file orelse Io.File.stdin()).readerStreaming(s.io, s.buf);
    }

    /// A reader at the start of the input.
    fn begin(s: *Source) *Io.Reader {
        if (s.held) |h| {
            s.fixed = .fixed(h);
            return &s.fixed;
        }
        s.reader = if (s.regular) s.file.?.reader(s.io, s.buf) else s.streaming();
        return &s.reader.interface;
    }
};

fn blank(s: []const u8) bool {
    for (s) |c| if (c != ' ' and (c < '\t' or c > '\r')) return false;
    return true;
}

/// A value to point at: the line it is on and, clipped, the value.
const Example = struct { line: usize, value: []const u8 };

const clip_len = 80;

fn example(arena: Allocator, line: usize, value: []const u8) !Example {
    if (value.len <= clip_len) return .{ .line = line, .value = try arena.dupe(u8, value) };
    var n: usize = clip_len;
    while (n > 0 and value[n] & 0xC0 == 0x80) n -= 1;
    return .{ .line = line, .value = try std.mem.concat(arena, u8, &.{ value[0..n], "..." }) };
}

/// The values of the column, one a record.
const Rows = struct {
    records: Records,
    /// The field, from 0; null reads each line whole.
    index: ?usize,
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,

    const Row = struct {
        record: Records.Record,
        /// Where the value sits in record.text, quotes included; null when
        /// the record has no such field.
        span: ?Records.Span,
        /// The value, its quotes taken off.
        value: []const u8,
    };

    fn deinit(rows: *Rows) void {
        rows.records.deinit();
        rows.buf.deinit(rows.gpa);
    }

    fn next(rows: *Rows) !?Row {
        const rec = (try rows.records.next()) orelse return null;
        const index = rows.index orelse
            return .{ .record = rec, .span = .{ .start = 0, .end = rec.text.len }, .value = rec.text };
        const span = Records.field(rec.text, rows.records.delimiter, index) orelse
            return .{ .record = rec, .span = null, .value = "" };
        const value = try Records.unquote(rec.text[span.start..span.end], &rows.buf, rows.gpa);
        return .{ .record = rec, .span = span, .value = value };
    }
};

/// What the first pass learns: what the column's values say about their
/// order, and where they said it.
const Settled = struct {
    column: dp.Column,
    /// Per order, the first value that cannot be read in it.
    first_against: [3]?Example = @splat(null),
    /// The value after which a single order was left.
    settled_by: ?Example = null,
};

/// How every value is read, and why.
const Decision = struct {
    options: dp.Options,
    order: ?Order,
    from: enum { option, column, none },
};

const Reason = enum { no_match, needs_base_time };

const Failure = struct { line: usize, value: []const u8, reason: Reason };

const max_failures = 5;

fn failure(arena: Allocator, line: usize, value: []const u8, e: dp.ParseError) !Failure {
    const ex = try example(arena, line, value);
    return .{ .line = ex.line, .value = ex.value, .reason = if (e == error.NoBaseTime) .needs_base_time else .no_match };
}

/// The first values a pass could not read, by line, and how many more. A
/// first line among them, with no --header, may well be a header.
fn writeFailures(w: *Io.Writer, indent: []const u8, failures: []const Failure, total: usize, header: bool) !void {
    for (failures) |f| {
        try w.print("{s}line {d}: \"{f}\"", .{ indent, f.line, std.zig.fmtString(f.value) });
        if (f.reason == .needs_base_time) try w.writeAll(", which needs --base");
        if (f.line == 1 and !header and f.reason == .no_match) try w.writeAll(", a header? (--header)");
        try w.writeByte('\n');
    }
    if (total > failures.len) try w.print("{s}and {d} more\n", .{ indent, total - failures.len });
}

/// One way the values are written, and how many are.
const Format = struct {
    /// The layout's label for the first of them.
    label: []const u8,
    values: usize,
    example: []const u8,
    line: usize,
    strftime: ?[]const u8,
    go: ?[]const u8,
    java: ?[]const u8,
};

/// --col as given, in a JSON report: its number, from 1, or its name; null
/// for lines.
const JsonColumn = struct {
    arg: ?ColumnArg,

    pub fn jsonStringify(c: JsonColumn, jws: anytype) !void {
        const arg = c.arg orelse return jws.write(null);
        switch (arg) {
            .index => |i| try jws.write(i + 1),
            .name => |n| try jws.write(n),
        }
    }
};

/// What the read pass of detect counts.
const Tally = struct {
    values: usize = 0,
    empty: usize = 0,
    /// Records with no field at the column.
    missing: usize = 0,
    read: usize = 0,
    ambiguous: usize = 0,
    not_read: usize = 0,
    failures: std.ArrayList(Failure) = .empty,
    formats: std.StringArrayHashMapUnmanaged(Format) = .empty,
    /// The formats, the most values first.
    sorted: []Format = &.{},
};

const Program = struct {
    cfg: Config,
    arena: Allocator,
    gpa: Allocator,
    source: *Source,
    out: *Io.Writer,
    err: *Io.Writer,
    /// The field, from 0, once the header has named it.
    index: ?usize = null,

    fn run(p: *Program, twice: bool) !u8 {
        p.index = if (p.cfg.column) |c| switch (c) {
            .index => |i| i,
            .name => null,
        } else null;
        var settled: ?Settled = null;
        if (twice) settled = try p.settle();
        const decision = p.decide(if (settled) |*s| s else null);
        return switch (p.cfg.command) {
            .detect => p.detect(&settled.?, decision),
            .normalize => p.normalize(if (settled) |*s| s else null, decision),
        };
    }

    /// A pass's rows, past the header, which it hands back.
    fn rows(p: *Program, header: *?Records.Record) !Rows {
        var r: Rows = .{
            .records = .init(p.gpa, p.source.begin(), p.cfg.column != null, p.cfg.delimiter),
            .index = p.index,
            .gpa = p.gpa,
        };
        errdefer r.deinit();
        header.* = null;
        if (!p.cfg.header) return r;
        header.* = try r.records.next();
        const name = switch (p.cfg.column orelse return r) {
            .name => |n| n,
            .index => return r,
        };
        if (p.index != null) return r;
        const h = header.* orelse {
            try p.err.print("dateparsa: {s} is empty: no header to find column {s} in\n", .{ p.source.name(), name });
            return error.NoHeader;
        };
        var it = Records.fields(h.text, p.cfg.delimiter);
        var i: usize = 0;
        while (it.next()) |span| : (i += 1) {
            const field = try Records.unquote(h.text[span.start..span.end], &r.buf, p.gpa);
            if (std.mem.eql(u8, field, name)) {
                p.index = i;
                r.index = i;
                return r;
            }
        }
        try p.err.print("dateparsa: no column {s} in the header of {s}:", .{ name, p.source.name() });
        it = Records.fields(h.text, p.cfg.delimiter);
        var sep: []const u8 = " ";
        while (it.next()) |span| {
            const field = try Records.unquote(h.text[span.start..span.end], &r.buf, p.gpa);
            try p.err.print("{s}\"{f}\"", .{ sep, std.zig.fmtString(field) });
            sep = ", ";
        }
        try p.err.writeByte('\n');
        return error.NoSuchColumn;
    }

    /// The first pass: what the values say about their order.
    fn settle(p: *Program) !Settled {
        var header: ?Records.Record = null;
        var r = try p.rows(&header);
        defer r.deinit();
        var s: Settled = .{ .column = .init(p.cfg.options) };
        while (try r.next()) |row| {
            if (blank(row.value)) continue;
            const was_settled = s.column.settled != null;
            s.column.add(row.value);
            for (&s.first_against, s.column.first_against) |*mine, theirs| {
                if (mine.* == null and theirs != null) mine.* = try example(p.arena, row.record.line, row.value);
            }
            if (!was_settled and s.column.settled != null)
                s.settled_by = try example(p.arena, row.record.line, row.value);
        }
        return s;
    }

    fn decide(p: *const Program, settled: ?*const Settled) Decision {
        if (p.cfg.order) |o| return .{ .options = dp.Column.readIn(p.cfg.options, o), .order = o, .from = .option };
        const report = settled.?.column.report();
        return .{
            .options = report.options,
            .order = report.order,
            .from = if (report.order != null) .column else .none,
        };
    }

    fn detect(p: *Program, s: *const Settled, d: Decision) !u8 {
        var header: ?Records.Record = null;
        var r = try p.rows(&header);
        defer r.deinit();
        var t: Tally = .{};
        var spelled_buf: [3][1024]u8 = undefined;
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(p.gpa);
        while (try r.next()) |row| {
            if (row.span == null) {
                t.missing += 1;
                continue;
            }
            if (blank(row.value)) {
                t.empty += 1;
                continue;
            }
            t.values += 1;
            const res = dp.parseWith(row.value, d.options) catch |e| {
                t.not_read += 1;
                if (t.failures.items.len < max_failures)
                    try t.failures.append(p.arena, try failure(p.arena, row.record.line, row.value, e));
                continue;
            };
            t.read += 1;
            if (res.ambiguous) t.ambiguous += 1;
            // Grouped by what each dialect spells: that tells apart what one
            // layout reads ("2024-03-15" and "2024/03/15"), and joins what
            // labels tell apart only by whether the value settled its order
            // (NUMERIC_AMBIG, NUMERIC_DMY). By the label when no dialect
            // spells it: a timestamp, natural language, an ordinal day.
            var spelled: [3]?[]const u8 = undefined;
            for (&spelled, &spelled_buf, dialects) |*out, *b, dialect| {
                var w: Io.Writer = .fixed(b);
                out.* = if (res.layout.formatString(dialect, row.value, &w)) |_| w.buffered() else |_| null;
            }
            key_buf.clearRetainingCapacity();
            if (spelled[0] == null and spelled[1] == null and spelled[2] == null) {
                try key_buf.appendSlice(p.gpa, res.layout.label);
            } else for (spelled) |sp| {
                try key_buf.append(p.gpa, 0);
                try key_buf.appendSlice(p.gpa, sp orelse "\x01");
            }
            const gop = try t.formats.getOrPut(p.arena, key_buf.items);
            if (!gop.found_existing) {
                gop.key_ptr.* = try p.arena.dupe(u8, key_buf.items);
                const ex = try example(p.arena, row.record.line, row.value);
                gop.value_ptr.* = .{
                    .label = res.layout.label,
                    .values = 0,
                    .example = ex.value,
                    .line = ex.line,
                    .strftime = if (spelled[0]) |x| try p.arena.dupe(u8, x) else null,
                    .go = if (spelled[1]) |x| try p.arena.dupe(u8, x) else null,
                    .java = if (spelled[2]) |x| try p.arena.dupe(u8, x) else null,
                };
            }
            gop.value_ptr.values += 1;
        }
        // The most values first, then the first seen.
        t.sorted = try p.arena.dupe(Format, t.formats.values());
        std.mem.sort(Format, t.sorted, {}, struct {
            fn before(_: void, a: Format, b: Format) bool {
                return a.values > b.values or (a.values == b.values and a.line < b.line);
            }
        }.before);
        if (p.cfg.json) try p.writeJson(s, d, &t) else try p.writeText(s, d, &t);
        const unsettled = d.from == .none and s.column.voted > 0;
        return if (t.not_read > 0 or unsettled) 1 else 0;
    }

    const dialects = [_]dp.Layout.Dialect{ .strftime, .go, .java };

    fn writeText(p: *Program, s: *const Settled, d: Decision, t: *const Tally) !void {
        const w = p.out;
        try w.print("values     {d}", .{t.values});
        if (t.empty > 0) try w.print(", and {d} empty", .{t.empty});
        if (t.missing > 0) try w.print(", and {d} {s} without the column", .{ t.missing, plural(t.missing, "row", "rows") });
        try w.writeByte('\n');
        try w.print("read       {d}\n", .{t.read});
        if (t.not_read > 0) {
            try w.print("not read   {d}\n", .{t.not_read});
            try writeFailures(w, "           ", t.failures.items, t.not_read, p.cfg.header);
        }
        try w.writeAll("order      ");
        try writeOrder(w, s, d);
        if (t.ambiguous > 0) {
            try w.print("ambiguous  {d}, ", .{t.ambiguous});
            switch (d.from) {
                .option => try w.print("read {s} as --order says\n", .{orderName(d.order.?)}),
                .column => try w.print("read {s} as the column settles\n", .{orderName(d.order.?)}),
                .none => try w.writeAll("read month first, a guess\n"),
            }
        }
        const formats = t.sorted;
        if (formats.len == 0) return;
        try w.writeByte('\n');
        const heads = [_][]const u8{ "values", "example", "strftime", "go", "java" };
        var widths: [heads.len]usize = undefined;
        for (heads, &widths) |h, *wd| wd.* = h.len;
        var num_buf: [24]u8 = undefined;
        for (formats) |f| {
            const cells = formatCells(f, &num_buf);
            for (cells, &widths) |c, *wd| wd.* = @max(wd.*, width(c));
        }
        try writeCells(w, heads, widths);
        for (formats) |f| try writeCells(w, formatCells(f, &num_buf), widths);
    }

    fn writeJson(p: *Program, s: *const Settled, d: Decision, t: *const Tally) !void {
        const report = s.column.report();
        var fits: [3]Order = undefined;
        var n_fits: usize = 0;
        for (std.enums.values(Order)) |o| {
            if (!report.fits.has(o)) continue;
            fits[n_fits] = o;
            n_fits += 1;
        }
        var conflicts: usize = 0;
        var first_conflict: ?Example = null;
        if (d.order) |o| {
            conflicts = s.column.against[@backingInt(o)];
            first_conflict = s.first_against[@backingInt(o)];
        }
        const settled_by = if (d.from == .column and report.settled_by != null) s.settled_by else null;
        try std.json.Stringify.value(.{
            .column = JsonColumn{ .arg = p.cfg.column },
            .values = t.values,
            .empty = t.empty,
            .missing = t.missing,
            .read = t.read,
            .not_read = t.not_read,
            .failures = t.failures.items,
            .ambiguous = t.ambiguous,
            .order = d.order,
            .order_from = switch (d.from) {
                .option => @as(?[]const u8, "--order"),
                .column => "column",
                .none => null,
            },
            .fits = fits[0..n_fits],
            .settled_by = settled_by,
            .conflicts = conflicts,
            .first_conflict = first_conflict,
            .formats = t.sorted,
        }, .{ .whitespace = .indent_2 }, p.out);
        try p.out.writeByte('\n');
    }

    fn normalize(p: *Program, s: ?*const Settled, d: Decision) !u8 {
        if (d.from == .none and s.?.column.voted > 0) {
            try p.err.writeAll("dateparsa: the column's date order is ");
            try writeOrder(p.err, s.?, d);
            try p.err.writeAll("Pass --order to choose one, or run dateparsa detect to see the values.\n");
            return 1;
        }
        if (d.from == .column) {
            const o = d.order.?;
            const n = s.?.column.against[@backingInt(o)];
            if (n > 0) {
                const ex = s.?.first_against[@backingInt(o)].?;
                try p.err.print("dateparsa: read {s}, though {d} {s} can only be read another way, first on line {d}: \"{f}\"\n", .{
                    orderName(o), n, plural(n, "value", "values"), ex.line, std.zig.fmtString(ex.value),
                });
            }
        }
        var header: ?Records.Record = null;
        var r = try p.rows(&header);
        defer r.deinit();
        if (header) |h| try p.out.writeAll(h.raw);
        var parser: dp.Parser = .init(d.options);
        var failures: [max_failures]Failure = undefined;
        var not_read: usize = 0;
        while (try r.next()) |row| {
            const span = row.span orelse {
                try p.out.writeAll(row.record.raw);
                continue;
            };
            if (blank(row.value)) {
                try p.out.writeAll(row.record.raw);
                continue;
            }
            const res = parser.parse(row.value) catch |e| {
                if (not_read < max_failures) failures[not_read] = try failure(p.arena, row.record.line, row.value, e);
                not_read += 1;
                try p.out.writeAll(row.record.raw);
                continue;
            };
            var time = res.time;
            if (p.cfg.utc) time = dp.DateTime.fromEpoch(time.toEpoch(), 0);
            var time_buf: [64]u8 = undefined;
            var tw: Io.Writer = .fixed(&time_buf);
            time.format(&tw) catch unreachable;
            try writeReplaced(p.out, row.record, span, tw.buffered(), p.cfg.column != null, p.cfg.delimiter);
        }
        if (not_read == 0) return 0;
        try p.err.print("dateparsa: {d} {s} not read, left as {s}:\n", .{
            not_read, plural(not_read, "value", "values"), plural(not_read, "it was", "they were"),
        });
        try writeFailures(p.err, "  ", failures[0..@min(not_read, max_failures)], not_read, p.cfg.header);
        return 1;
    }
};

/// The order line of a report, newline included: the order and what
/// decided it, or why nothing did.
fn writeOrder(w: *Io.Writer, s: *const Settled, d: Decision) !void {
    const c = &s.column;
    if (d.from == .option) {
        const o = d.order.?;
        try w.print("{s}, from --order\n", .{orderName(o)});
        const n = c.against[@backingInt(o)];
        if (n > 0) try writeAgainst(w, n, s.first_against[@backingInt(o)].?);
        return;
    }
    if (c.voted == 0) return w.writeAll("not in question: no value reads two ways\n");
    const report = c.report();
    if (report.order) |o| {
        if (report.fits.count() == 1) {
            const by = s.settled_by.?;
            return w.print("{s}, settled by line {d}: \"{f}\"\n", .{ orderName(o), by.line, std.zig.fmtString(by.value) });
        }
        try w.print("{s}, which the fewest values contradict\n", .{orderName(o)});
        return writeAgainst(w, report.conflicts, s.first_against[@backingInt(o)].?);
    }
    if (report.fits.count() > 1) {
        try w.writeAll("not settled: ");
        var left = report.fits.count();
        for (std.enums.values(Order)) |o| {
            if (!report.fits.has(o)) continue;
            try w.writeAll(orderName(o));
            left -= 1;
            try w.writeAll(switch (left) {
                0 => "",
                1 => " or ",
                else => ", ",
            });
        }
        return w.writeAll(" each read every value\n");
    }
    // As many values contradict one order as another.
    try w.writeAll("not settled: the values contradict each other\n");
    var fewest: usize = std.math.maxInt(usize);
    for (c.against) |n| fewest = @min(fewest, n);
    for (std.enums.values(Order), c.against, s.first_against) |o, n, first| {
        if (n != fewest) continue;
        try w.print("           {d} {s} cannot be read {s}, first on line {d}: \"{f}\"\n", .{
            n, plural(n, "value", "values"), orderName(o), first.?.line, std.zig.fmtString(first.?.value),
        });
    }
}

fn writeAgainst(w: *Io.Writer, n: usize, first: Example) !void {
    try w.print("           {d} {s} can only be read another way, first on line {d}: \"{f}\"\n", .{
        n, plural(n, "value", "values"), first.line, std.zig.fmtString(first.value),
    });
}

fn orderName(o: Order) []const u8 {
    return switch (o) {
        .month_first => "month first",
        .day_first => "day first",
        .year_first => "year first",
    };
}

fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// A format's row of the report's table.
fn formatCells(f: Format, num_buf: *[24]u8) [5][]const u8 {
    return .{
        std.fmt.bufPrint(num_buf, "{d}", .{f.values}) catch unreachable,
        f.example,
        f.strftime orelse "-",
        f.go orelse "-",
        f.java orelse "-",
    };
}

/// Code points, which is the width of the text a table holds.
fn width(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn writeCells(w: *Io.Writer, cells: [5][]const u8, widths: [5]usize) !void {
    // The count is right-aligned; the last cell takes no padding.
    try w.splatByteAll(' ', widths[0] - width(cells[0]));
    try w.writeAll(cells[0]);
    for (cells[1..], widths[1..], 1..) |c, wd, i| {
        try w.writeAll("  ");
        try w.writeAll(c);
        if (i + 1 < cells.len) try w.splatByteAll(' ', wd - width(c));
    }
    try w.writeByte('\n');
}

/// rec with the field at span replaced by value, quoted when the delimiter
/// is in it.
fn writeReplaced(w: *Io.Writer, rec: Records.Record, span: Records.Span, value: []const u8, csv: bool, delimiter: u8) !void {
    try w.writeAll(rec.raw[0 .. rec.offset + span.start]);
    const quote = csv and std.mem.indexOfScalar(u8, value, delimiter) != null;
    if (quote) try w.writeByte('"');
    try w.writeAll(value);
    if (quote) try w.writeByte('"');
    try w.writeAll(rec.raw[rec.offset + span.end ..]);
}

test {
    _ = Records;
}

const testing = std.testing;

/// 2024-06-15T12:00:00Z, what --base now reads in the tests.
const test_now: dp.DateTime.Epoch = .{ .seconds = 1718452800 };

/// The command run on args with input as standard input.
fn expectRun(args: []const []const u8, input: []const u8, out: []const u8, err: []const u8, code: u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out_w: Io.Writer.Allocating = .init(testing.allocator);
    defer out_w.deinit();
    var err_w: Io.Writer.Allocating = .init(testing.allocator);
    defer err_w.deinit();
    const env: Env = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = arena.allocator(),
        .now = test_now,
        .stdin = input,
    };
    const got = try execute(env, args, &out_w.writer, &err_w.writer);
    try testing.expectEqualStrings(out, out_w.written());
    try testing.expectEqualStrings(err, err_w.written());
    try testing.expectEqual(code, got);
}

test "detect reports the order the column settles and how each value is written" {
    const csv =
        \\id,ordered_at,note
        \\1,01/02/2024 10:30,"a, b"
        \\2,"13/02/2024 11:00",x
        \\3,,y
        \\4,TBD,z
        \\5
        \\
    ;
    try expectRun(&.{ "detect", "--col", "ordered_at" }, csv,
        \\values     3, and 1 empty, and 1 row without the column
        \\read       2
        \\not read   1
        \\           line 5: "TBD"
        \\order      day first, settled by line 3: "13/02/2024 11:00"
        \\ambiguous  1, read day first as the column settles
        \\
        \\values  example           strftime        go                java
        \\     2  01/02/2024 10:30  %d/%m/%Y %H:%M  02/01/2006 15:04  dd/MM/yyyy HH:mm
        \\
    , "", 1);
}

test "detect --json" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const env: Env = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .arena = arena.allocator(),
        .now = test_now,
        .stdin = "date\n05/06/2024\n2024-03-15\n13/02/2024\nyesterday\n",
    };
    try testing.expectEqual(1, try execute(env, &.{ "detect", "--json", "--col", "1", "--header" }, &out.writer, &err.writer));
    const Report = struct {
        column: usize,
        values: usize,
        read: usize,
        not_read: usize,
        failures: []const struct { line: usize, value: []const u8, reason: []const u8 },
        ambiguous: usize,
        order: ?[]const u8,
        order_from: ?[]const u8,
        fits: []const []const u8,
        settled_by: ?struct { line: usize, value: []const u8 },
        formats: []const struct { label: []const u8, values: usize, strftime: ?[]const u8, go: ?[]const u8 },
    };
    const r = try std.json.parseFromSliceLeaky(Report, arena.allocator(), out.written(), .{ .ignore_unknown_fields = true });
    try testing.expectEqual(1, r.column);
    try testing.expectEqual(4, r.values);
    try testing.expectEqual(3, r.read);
    try testing.expectEqual(1, r.failures.len);
    try testing.expectEqualStrings("needs_base_time", r.failures[0].reason);
    try testing.expectEqual(5, r.failures[0].line);
    try testing.expectEqualStrings("day_first", r.order.?);
    try testing.expectEqualStrings("column", r.order_from.?);
    try testing.expectEqual(4, r.settled_by.?.line);
    try testing.expectEqual(2, r.formats.len);
    try testing.expectEqualStrings("%d/%m/%Y", r.formats[0].strftime.?);
    try testing.expectEqualStrings("2006-01-02", r.formats[1].go.?);
    try testing.expectEqualStrings("", err.written());
}

test "detect says why no order is settled" {
    try expectRun(&.{"detect"}, "01/02/2024\n03/04/2024\n",
        \\values     2
        \\read       2
        \\order      not settled: month first or day first each read every value
        \\ambiguous  2, read month first, a guess
        \\
        \\values  example     strftime  go          java
        \\     2  01/02/2024  %m/%d/%Y  01/02/2006  MM/dd/yyyy
        \\
    , "", 1);
    try expectRun(&.{"detect"}, "13/02/2024\n02/13/2024\n",
        \\values     2
        \\read       2
        \\order      not settled: the values contradict each other
        \\           1 value cannot be read month first, first on line 1: "13/02/2024"
        \\           1 value cannot be read day first, first on line 2: "02/13/2024"
        \\
        \\values  example     strftime  go          java
        \\     1  13/02/2024  %d/%m/%Y  02/01/2006  dd/MM/yyyy
        \\     1  02/13/2024  %m/%d/%Y  01/02/2006  MM/dd/yyyy
        \\
    , "", 1);
    // No numeric date that reads two ways: nothing to settle, and that is
    // no failure.
    try expectRun(&.{"detect"}, "2024-03-15\nMarch 16, 2024\n1710504800\n",
        \\values     3
        \\read       3
        \\order      not in question: no value reads two ways
        \\
        \\values  example         strftime   go                java
        \\     1  2024-03-15      %Y-%m-%d   2006-01-02        yyyy-MM-dd
        \\     1  March 16, 2024  %B %d, %Y  January 02, 2006  MMMM dd, yyyy
        \\     1  1710504800      -          -                 -
        \\
    , "", 0);
    try expectRun(&.{"detect"}, "", "values     0\nread       0\norder      not in question: no value reads two ways\n", "", 0);
}

test "detect --order: the order given, and what contradicts it" {
    try expectRun(&.{ "detect", "--order", "day-first" }, "01/02/2024\n02/13/2024\n",
        \\values     2
        \\read       2
        \\order      day first, from --order
        \\           1 value can only be read another way, first on line 2: "02/13/2024"
        \\ambiguous  1, read day first as --order says
        \\
        \\values  example     strftime  go          java
        \\     1  01/02/2024  %d/%m/%Y  02/01/2006  dd/MM/yyyy
        \\     1  02/13/2024  %m/%d/%Y  01/02/2006  MM/dd/yyyy
        \\
    , "", 0);
}

test "normalize rewrites the column and leaves every other byte" {
    const csv = "\xEF\xBB\xBFid,when,note\r\n1,\"13/02/2024\",\"a,\r\nb\"\r\n2, 01/02/2024 ,x\r\n3,,y\r\n4\r\n5,TBD,z";
    try expectRun(&.{ "normalize", "--col", "when" }, csv, "\xEF\xBB\xBFid,when,note\r\n1,2024-02-13T00:00:00Z,\"a,\r\nb\"\r\n2,2024-02-01T00:00:00Z,x\r\n3,,y\r\n4\r\n5,TBD,z",
        \\dateparsa: 1 value not read, left as it was:
        \\  line 7: "TBD"
        \\
    , 1);
}

test "normalize lines, zones and the base time" {
    try expectRun(&.{ "normalize", "--tz", "+05:30" }, "2024-03-15 10:30:00\n2024-03-15T10:30:00Z\n\n", "2024-03-15T10:30:00+05:30\n2024-03-15T10:30:00Z\n\n", "", 0);
    try expectRun(&.{ "normalize", "--tz", "+05:30", "--utc" }, "2024-03-15 10:30:00\n", "2024-03-15T05:00:00Z\n", "", 0);
    try expectRun(&.{ "normalize", "--base", "now" }, "yesterday at 5pm\n3 days ago\n", "2024-06-14T17:00:00Z\n2024-06-12T12:00:00Z\n", "", 0);
    try expectRun(&.{ "normalize", "--base", "2024-01-01", "--tz", "-08:00" }, "tomorrow\nMarch 5\n", "2024-01-02T00:00:00-08:00\n2024-03-05T00:00:00-08:00\n", "", 0);
    try expectRun(&.{"normalize"}, "yesterday\n", "yesterday\n",
        \\dateparsa: 1 value not read, left as it was:
        \\  line 1: "yesterday", which needs --base
        \\
    , 1);
}

test "normalize refuses to guess a column's order" {
    try expectRun(&.{"normalize"}, "01/02/2024\n03/04/2024\n", "",
        \\dateparsa: the column's date order is not settled: month first or day first each read every value
        \\Pass --order to choose one, or run dateparsa detect to see the values.
        \\
    , 1);
    try expectRun(&.{ "normalize", "--order", "dmy" }, "01/02/2024\n03/04/2024\n", "2024-02-01T00:00:00Z\n2024-04-03T00:00:00Z\n", "", 0);
    try expectRun(&.{"normalize"}, "13/02/2024\n02/13/2024\n14/02/2024\n", "2024-02-13T00:00:00Z\n2024-02-13T00:00:00Z\n2024-02-14T00:00:00Z\n",
        \\dateparsa: read day first, though 1 value can only be read another way, first on line 2: "02/13/2024"
        \\
    , 0);
}

test "normalize quotes a value holding the delimiter" {
    try expectRun(&.{ "normalize", "-d", ":", "--col", "2" }, "a:\"2024-03-15T10:30:00\"\n", "a:\"2024-03-15T10:30:00Z\"\n", "", 0);
    try expectRun(&.{ "normalize", "-d", "tab", "--col", "2" }, "a\t2024-03-15\tb\n", "a\t2024-03-15T00:00:00Z\tb\n", "", 0);
}

test "a column name the header does not have" {
    try expectRun(&.{ "detect", "--col", "date" }, "id,\"when\"\n1,2024-03-15\n", "",
        \\dateparsa: no column date in the header of standard input: "id", "when"
        \\
    , 2);
    try expectRun(&.{ "normalize", "--col", "date" }, "", "",
        \\dateparsa: standard input is empty: no header to find column date in
        \\
    , 2);
}

test "usage errors" {
    const help = "\nRun dateparsa --help for the options.\n";
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{"parse"}, "no command parse: detect or normalize" },
        .{ &.{"--col=3"}, "no command: detect or normalize" },
        .{ &.{ "detect", "--colour" }, "no option --colour" },
        .{ &.{ "detect", "--col" }, "--col needs a value" },
        .{ &.{ "detect", "--col", "0" }, "--col 0: 1 for the first column, or a name" },
        .{ &.{ "detect", "--order", "dym" }, "--order dym: month-first, day-first or year-first" },
        .{ &.{ "detect", "--tz", "+25:00" }, "--tz +25:00: an offset such as +05:30, -0800 or Z" },
        .{ &.{ "detect", "--base", "01/02/2024" }, "--base 01/02/2024: a date and time, such as 2024-03-15T12:00:00Z, or now" },
        .{ &.{ "detect", "--locale", "xx" }, "--locale: xx is no locale this build reads" },
        .{ &.{ "detect", "--header=yes" }, "--header takes no value" },
        .{ &.{ "detect", "a.csv", "b.csv" }, "one file at a time: a.csv and b.csv" },
        .{ &.{ "normalize", "--json" }, "--json is for detect" },
        .{ &.{ "detect", "--utc" }, "--utc is for normalize" },
    };
    for (cases) |c| {
        errdefer std.debug.print("{s}\n", .{c[1]});
        var buf: [256]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "dateparsa: {s}{s}", .{ c[1], help });
        try expectRun(c[0], "", "", want, 2);
    }
    try expectRun(&.{}, "", "", usage, 2);
    try expectRun(&.{"--help"}, "", usage, "", 0);
    try expectRun(&.{ "normalize", "x.csv", "-h" }, "", usage, "", 0);
    try expectRun(&.{"--version"}, "", "dateparsa " ++ build_options.version ++ "\n", "", 0);
}

test parseArgs {
    var u: Usage = .{};
    const cfg = (try parseArgs(&.{ "normalize", "--col=3", "--delimiter=;", "--order", "ymd", "--tz", "-0800", "--", "-weird.csv" }, test_now, &u)).run;
    try testing.expectEqual(Command.normalize, cfg.command);
    try testing.expectEqual(2, cfg.column.?.index);
    try testing.expect(!cfg.header);
    try testing.expectEqual(';', cfg.delimiter);
    try testing.expectEqual(Order.year_first, cfg.order.?);
    try testing.expectEqual(-8 * 3600, cfg.options.timezone_offset);
    try testing.expectEqualStrings("-weird.csv", cfg.path.?);

    const named = (try parseArgs(&.{ "detect", "-", "-c", "when", "--base", "now", "--tz", "+02" }, test_now, &u)).run;
    try testing.expect(named.header);
    try testing.expectEqualStrings("when", named.column.?.name);
    try testing.expectEqualStrings("-", named.path.?);
    try testing.expectEqual(dp.DateTime{ .year = 2024, .month = 6, .day = 15, .hour = 14, .offset_seconds = 7200 }, named.options.base_time.?);
}

test parseOffset {
    const cases = [_]struct { []const u8, ?i32 }{
        .{ "Z", 0 },        .{ "utc", 0 },       .{ "+05:30", 19800 }, .{ "+0530", 19800 },
        .{ "-08", -28800 }, .{ "+5", 18000 },    .{ "-5:30", -19800 }, .{ "+23:59", 86340 },
        .{ "+24", null },   .{ "+05:3", null },  .{ "+053", null },    .{ "0530", null },
        .{ "+", null },     .{ "+05:60", null }, .{ "EST", null },     .{ "+0x10", null },
    };
    for (cases) |c| {
        errdefer std.debug.print("{s}\n", .{c[0]});
        try testing.expectEqual(c[1], parseOffset(c[0]));
    }
}

test parseLocales {
    var bad: []const u8 = "";
    try testing.expectEqual(dp.LocaleSet{}, parseLocales("", &bad).?);
    try testing.expectEqual(null, parseLocales("en,zz", &bad));
    try testing.expectEqualStrings("zz", bad);
    const all: LocaleBits = @bitCast(parseLocales("all", &bad).?);
    try testing.expectEqual(~@as(LocaleBits, 0), all);
    const fr = dp.localeSet("fr") orelse return error.SkipZigTest;
    const de = dp.localeSet("de") orelse return error.SkipZigTest;
    const both: LocaleBits = @as(LocaleBits, @bitCast(fr)) | @as(LocaleBits, @bitCast(de));
    try testing.expectEqual(both, @as(LocaleBits, @bitCast(parseLocales("fr, de-AT", &bad).?)));
    try expectRun(&.{ "normalize", "--locale", "fr" }, "15 mars 2024\n", "2024-03-15T00:00:00Z\n", "", 0);
}

test "a first line no format reads may be a header" {
    try expectRun(&.{ "normalize", "--col", "2" }, "id,date\n1,2024-03-15\n", "id,date\n1,2024-03-15T00:00:00Z\n",
        \\dateparsa: 1 value not read, left as it was:
        \\  line 1: "date", a header? (--header)
        \\
    , 1);
    try expectRun(&.{ "normalize", "--col", "2", "--header" }, "id,date\n1,2024-03-15\n", "id,date\n1,2024-03-15T00:00:00Z\n", "", 0);
}

test "the README's example" {
    const csv =
        \\id,ordered_at,total
        \\1,03/02/2024 09:15,12.50
        \\2,14/02/2024 17:40,8.00
        \\3,,3.20
        \\4,TBD,4.75
        \\
    ;
    try expectRun(&.{ "detect", "--col", "ordered_at" }, csv,
        \\values     3, and 1 empty
        \\read       2
        \\not read   1
        \\           line 5: "TBD"
        \\order      day first, settled by line 3: "14/02/2024 17:40"
        \\ambiguous  1, read day first as the column settles
        \\
        \\values  example           strftime        go                java
        \\     2  03/02/2024 09:15  %d/%m/%Y %H:%M  02/01/2006 15:04  dd/MM/yyyy HH:mm
        \\
    , "", 1);
    try expectRun(&.{ "normalize", "--col", "ordered_at" }, csv,
        \\id,ordered_at,total
        \\1,2024-02-03T09:15:00Z,12.50
        \\2,2024-02-14T17:40:00Z,8.00
        \\3,,3.20
        \\4,TBD,4.75
        \\
    ,
        \\dateparsa: 1 value not read, left as it was:
        \\  line 5: "TBD"
        \\
    , 1);
}

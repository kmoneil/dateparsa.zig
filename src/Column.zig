//! Settles which order a column writes its numeric dates in: month first,
//! day first, or year first.
//!
//! One value often cannot say: "01/02/2024" reads either way, and parse
//! takes the preferences' guess. A column usually can. One "13/02/2024"
//! anywhere in it means day first for all of it, and "13/02/03" and
//! "05/06/31" together leave only day first. Column notes every order parse
//! can read each value in, whatever the preferences, and keeps the orders
//! every value fits; the report's options then read each of those values in
//! the column's order. Values with no such question (an ISO date, a month
//! name, a timestamp, words) have no say. Only counts are kept, so it
//! allocates nothing and takes a column of any length one value at a time.
//!
//! Single-threaded, like Parser: add writes the counts.

const std = @import("std");
const root = @import("root.zig");

const Order = root.Layout.Order;
const Column = @This();

/// The options every value is read with, strict mode and diagnostics
/// aside.
options: root.Options,
/// Values added so far.
values: usize = 0,
/// Values with a say: they parsed in a format whose field order is decided
/// per value.
voted: usize = 0,
/// Values that did not parse under options.
failed: usize = 0,
/// The orders every value with a say fits.
fits: Orders = .all,
/// Per order: the values that do not fit it, and the first of them.
against: [3]usize = @splat(0),
first_against: [3]?usize = @splat(null),
/// The first value after which a single order was left, and that order.
settled: ?struct { order: Order, by: usize } = null,

/// A set of orders.
pub const Orders = packed struct(u3) {
    month_first: bool = false,
    day_first: bool = false,
    year_first: bool = false,

    pub const all: Orders = .{ .month_first = true, .day_first = true, .year_first = true };
    pub const none: Orders = .{};

    pub fn only(o: Order) Orders {
        return @bitCast(@as(u3, 1) << @backingInt(o));
    }

    pub fn has(s: Orders, o: Order) bool {
        return @as(u3, @bitCast(s)) & @as(u3, @bitCast(only(o))) != 0;
    }

    pub fn count(s: Orders) u2 {
        return @popCount(@as(u3, @bitCast(s)));
    }

    fn with(s: Orders, o: Order) Orders {
        return @bitCast(@as(u3, @bitCast(s)) | @as(u3, @bitCast(only(o))));
    }

    fn intersect(a: Orders, b: Orders) Orders {
        return @bitCast(@as(u3, @bitCast(a)) & @as(u3, @bitCast(b)));
    }
};

/// What a column's values say about its order.
pub const Report = struct {
    /// The order to read the column in: the one order every value with a
    /// say fits, or, when no order fits them all, the one the fewest
    /// values contradict. Null when more than one order still fits every
    /// value (nothing settled it) or the contradictions tie.
    order: ?Order,
    /// The orders every value with a say fits. Empty when values
    /// contradict each other: "13/02/2024" beside "02/13/2024".
    fits: Orders,
    /// The options given to init, with prefer_day_first and
    /// prefer_year_first set to read order. The options unchanged when
    /// order is null. Strict mode, if set, still refuses each ambiguous
    /// value: the column settles the order, not the value.
    options: root.Options,
    /// The index of the value after which order was the only one left.
    settled_by: ?usize,
    /// Values with a say that order does not fit, and the first of them.
    conflicts: usize,
    first_conflict: ?usize,
    values: usize,
    voted: usize,
    failed: usize,
};

/// A column with no values yet, read with options.
pub fn init(options: root.Options) Column {
    return .{ .options = options };
}

/// Notes what value says about the column's order.
pub fn add(c: *Column, value: []const u8) void {
    const index = c.values;
    c.values += 1;
    const say = orders(value, c.options) orelse {
        c.failed += 1;
        return;
    };
    if (say.count() == 0) return; // no order question
    c.voted += 1;
    for (std.enums.values(Order), 0..) |o, i| {
        if (say.has(o)) continue;
        c.against[i] += 1;
        if (c.first_against[i] == null) c.first_against[i] = index;
    }
    c.fits = c.fits.intersect(say);
    if (c.settled == null and c.fits.count() == 1) {
        c.settled = .{ .order = for (std.enums.values(Order)) |o| {
            if (c.fits.has(o)) break o;
        } else unreachable, .by = index };
    }
}

/// What the values added so far say.
pub fn report(c: *const Column) Report {
    const order = c.decided();
    var r: Report = .{
        .order = order,
        .fits = c.fits,
        .options = c.options,
        .settled_by = null,
        .conflicts = 0,
        .first_conflict = null,
        .values = c.values,
        .voted = c.voted,
        .failed = c.failed,
    };
    const o = order orelse return r;
    r.options = readIn(c.options, o);
    if (c.settled) |s| {
        if (s.order == o) r.settled_by = s.by;
    }
    r.conflicts = c.against[@backingInt(o)];
    r.first_conflict = c.first_against[@backingInt(o)];
    return r;
}

fn decided(c: *const Column) ?Order {
    if (c.voted == 0) return null;
    switch (c.fits.count()) {
        1 => return for (std.enums.values(Order)) |o| {
            if (c.fits.has(o)) break o;
        } else unreachable,
        0 => {
            // No order fits every value: the one the fewest contradict,
            // unless that ties.
            var best: ?Order = null;
            var tie = false;
            for (std.enums.values(Order), c.against) |o, n| {
                const b = best orelse {
                    best = o;
                    continue;
                };
                const m = c.against[@backingInt(b)];
                if (n < m) {
                    best = o;
                    tie = false;
                } else if (n == m) tie = true;
            }
            return if (tie) null else best;
        },
        else => return null,
    }
}

/// opts with the preferences that read an ambiguous value in order o.
pub fn readIn(opts: root.Options, o: Order) root.Options {
    var out = opts;
    out.prefer_day_first = o == .day_first;
    out.prefer_year_first = o == .year_first;
    return out;
}

/// The orders parse can read value in under opts, whatever the
/// preferences: one when the value settles it (a part over 12, a dot), two
/// or three when it is ambiguous, none when its format has no such
/// question. Null when it does not parse. Strict mode and diagnostics in
/// opts are set aside.
pub fn orders(value: []const u8, opts: root.Options) ?Orders {
    var plain = opts;
    plain.strict = false;
    plain.diagnostics = null;
    const r = root.parseWith(value, plain) catch return null;
    if (!r.layout.ambiguity_prone) return .none;
    const first = r.layout.dateOrder() orelse return .none;
    if (!r.ambiguous) return .only(first);
    // Each order's preferences, and the order each actually reads: a
    // reading the bytes rule out falls back to one they allow.
    var say: Orders = .only(first);
    for (std.enums.values(Order)) |o| {
        const other = root.parseWith(value, readIn(plain, o)) catch continue;
        if (other.layout.dateOrder()) |got| say = say.with(got);
    }
    return say;
}

/// What values say about their order, read with opts: Column over a slice.
pub fn detect(values: []const []const u8, opts: root.Options) Report {
    var c: Column = .init(opts);
    for (values) |v| c.add(v);
    return c.report();
}

const expectEqual = std.testing.expectEqual;

test "one value past 12 settles the whole column" {
    const r = detect(&.{ "01/02/2024", "05/06/2024", "13/02/2024", "03/04/2024" }, .{});
    try expectEqual(Order.day_first, r.order.?);
    try expectEqual(2, r.settled_by.?);
    try expectEqual(Orders.only(.day_first), r.fits);
    try expectEqual(4, r.voted);
    try expectEqual(0, r.conflicts);
    try std.testing.expect(r.options.prefer_day_first and !r.options.prefer_year_first);
    // Read with the report's options, every value is read day first.
    const t = try root.parseWith("01/02/2024", r.options);
    try expectEqual(2, t.time.month);

    const us = detect(&.{ "01/02/2024", "02/13/2024" }, .{});
    try expectEqual(Order.month_first, us.order.?);
    try expectEqual(1, us.settled_by.?);
}

test "a column nothing settles says which orders are left" {
    const r = detect(&.{ "01/02/2024", "03/04/2024", "2024-05-06" }, .{ .prefer_day_first = true });
    try expectEqual(null, r.order);
    try expectEqual(Orders{ .month_first = true, .day_first = true }, r.fits);
    try expectEqual(2, r.voted); // the ISO date has no say
    try expectEqual(null, r.settled_by);
    try std.testing.expect(r.options.prefer_day_first); // the caller's, unchanged

    const empty = detect(&.{}, .{});
    try expectEqual(null, empty.order);
    try expectEqual(Orders.all, empty.fits);
}

test "two-digit years narrow together what neither settles alone" {
    // 13/02/03 is day first or year first; 05/06/31 is month first or day
    // first (June 31st does not exist). Only day first reads both.
    try expectEqual(Orders{ .day_first = true, .year_first = true }, orders("13/02/03", .{}).?);
    try expectEqual(Orders{ .month_first = true, .day_first = true }, orders("05/06/31", .{}).?);
    const r = detect(&.{ "13/02/03", "05/06/31" }, .{});
    try expectEqual(Order.day_first, r.order.?);
    try expectEqual(1, r.settled_by.?);

    const ymd = detect(&.{ "32/01/02", "01/02/03" }, .{});
    try expectEqual(Order.year_first, ymd.order.?);
    try std.testing.expect(ymd.options.prefer_year_first);
    const t = (try root.parseWith("01/02/03", ymd.options)).time;
    try expectEqual(root.DateTime{ .year = 2001, .month = 2, .day = 3 }, t);
}

test "values that contradict each other: the order the fewest contradict" {
    const r = detect(&.{ "13/02/2024", "02/13/2024", "14/02/2024", "01/02/2024" }, .{});
    try expectEqual(Orders.none, r.fits);
    try expectEqual(Order.day_first, r.order.?);
    try expectEqual(1, r.conflicts);
    try expectEqual(1, r.first_conflict.?);
    try expectEqual(0, r.settled_by.?); // day first was the only one left after the first value

    const tie = detect(&.{ "13/02/2024", "02/13/2024" }, .{});
    try expectEqual(null, tie.order);
    try expectEqual(Orders.none, tie.fits);
}

test "a dot settles day first, as parse reads it, even where the parts would not" {
    // Strict mode calls "01.01.1946" ambiguous, but parse reads a dot as day
    // first under any preference, so that is the only order it can be read
    // in, and a month-first column could not read it month first.
    try expectEqual(Orders.only(.day_first), orders("01.01.1946", .{}).?);
    try expectEqual(Orders.only(.day_first), orders("01.01.1946", .{ .strict = true }).?);
}

test "values with no order question, and values that do not parse" {
    const r = detect(&.{ "2024-03-15", "March 5, 2024", "1710504800", "yesterday", "nonsense", "15.03.2024" }, .{});
    // "yesterday" needs a base time and "nonsense" is no date. The dotted
    // date settles day first: a dot means day first, as parse reads it.
    try expectEqual(2, r.failed);
    try expectEqual(1, r.voted);
    try expectEqual(Order.day_first, r.order.?);
    try expectEqual(5, r.settled_by.?);
}

test "a layout's date order" {
    const cases = [_]struct { []const u8, ?Order }{
        .{ "13/02/2024", .day_first },
        .{ "02/13/2024", .month_first },
        .{ "32/01/02", .year_first },
        .{ "2024-02-13", .year_first },
        .{ "2024-02-13T10:30:00Z", .year_first },
        .{ "13/02/2024 10:30", .day_first },
        .{ "15.03.2024", .day_first },
        .{ "March 15, 2024", null },
        .{ "2024-W11-5", null },
        .{ "2024-074", null },
        .{ "10:30", null },
        .{ "1710504800", null },
    };
    for (cases) |case| {
        errdefer std.debug.print("\"{s}\"\n", .{case[0]});
        const r = try root.parseWith(case[0], .{ .base_time = .{ .year = 2024, .month = 1, .day = 1 } });
        try expectEqual(case[1], r.layout.dateOrder());
    }
    var diag: root.Diagnostics = .{};
    try std.testing.expectError(error.Ambiguous, root.parseWith("01/02/03", .{ .strict = true, .diagnostics = &diag }));
    for (diag.slice(), [_]Order{ .month_first, .day_first, .year_first }) |in, want| {
        try expectEqual(want, in.layout.dateOrder().?);
    }
}

test "every order a golden row fits is the order its preferences read it in" {
    // Ties orders to parse: for each order a value is said to fit, reading
    // it with that order's preferences reads it in that order. Under every
    // locale, so the corpus's other languages parse too.
    const Backing = @typeInfo(root.LocaleSet).@"struct".backing_integer.?;
    const opts: root.Options = .{
        .base_time = .{ .year = 2024, .month = 6, .day = 15, .hour = 12 },
        .locales = @bitCast(~@as(Backing, 0)),
    };
    var lines = std.mem.splitScalar(u8, @import("golden_corpus").text, '\n');
    var buf: [4096]u8 = undefined;
    var with_say: usize = 0;
    while (lines.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        const quoted = row[0 .. std.mem.indexOfScalar(u8, row, '\t') orelse row.len];
        const s = try @import("golden_test.zig").unquote(&buf, quoted);
        const say = orders(s, opts) orelse continue;
        if (say.count() > 0) with_say += 1;
        for (std.enums.values(Order)) |o| {
            if (!say.has(o)) continue;
            errdefer std.debug.print("\"{f}\" {t}\n", .{ std.zig.fmtString(s), o });
            const r = try root.parseWith(s, readIn(opts, o));
            try expectEqual(o, r.layout.dateOrder().?);
        }
    }
    try std.testing.expect(with_say > 50);
}

test "add allocates nothing and keeps no input" {
    var c: Column = .init(.{});
    var buf = "01/02/2024".*;
    c.add(&buf);
    buf = "13/02/2024".*;
    c.add(&buf);
    @memset(&buf, 'x');
    try expectEqual(Order.day_first, c.report().order.?);
}

//! Civil date-time with a fixed UTC offset.
//!
//! The library's own time type: the standard library has no civil calendar
//! type carrying a zone. Fields are the civil reading (what the input said),
//! offset_seconds is how far east of UTC that reading is, and toEpoch is the
//! instant it names. Validation refuses impossible dates rather than
//! normalising them: 2024-02-30 is an error here, never the 1st of March.
//!
//! Calendar math is proleptic Gregorian with astronomical year numbering, so
//! year 0 exists and is a leap year. The epoch conversion is Howard Hinnant's
//! days-from-civil algorithm.

const std = @import("std");
const DateTime = @This();

year: i32,
month: u8, // 1..12
day: u8, // 1..31, must exist in (year, month)
hour: u8 = 0, // 0..23
minute: u8 = 0, // 0..59
second: u8 = 0, // 0..59, no leap seconds
nanosecond: u32 = 0, // 0..999_999_999
offset_seconds: i32 = 0, // UTC offset of the civil reading, seconds east

/// An instant: seconds since 1970-01-01T00:00:00Z plus a nanosecond part.
/// Seconds rather than i64 nanoseconds because the latter only spans
/// 1677..2262 and the corpus contains year 0000.
pub const Epoch = struct {
    seconds: i64,
    nanosecond: u32 = 0,
};

pub const Weekday = enum(u3) {
    sunday,
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
};

/// Full Gregorian rule. Divisibility by 4 alone gets 1900 and 2100 wrong,
/// and 1900 is inside the range this library parses.
pub fn isLeapYear(y: i32) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

pub fn daysInYear(y: i32) u16 {
    return if (isLeapYear(y)) 366 else 365;
}

/// Length of each month in a common year, indexed 1..12. February is the
/// only one the year changes.
const month_lengths = [13]u8{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

/// Asserts month is 1..12.
pub fn daysInMonth(y: i32, month: u8) u8 {
    std.debug.assert(month >= 1 and month <= 12);
    if (month == 2 and isLeapYear(y)) return 29;
    return month_lengths[month];
}

/// Whether day is a day of that month in that year. The first comparison
/// carries the common case: no month is shorter than 28 days, so everything
/// up to the 28th exists everywhere and the rest is off the hot path for all
/// but three days in twelve. Asserts month is 1..12.
pub fn dayExists(y: i32, month: u8, day: u8) bool {
    std.debug.assert(month >= 1 and month <= 12);
    if (day == 0) return false;
    if (day <= 28) return true;
    if (month == 2) return day == 29 and isLeapYear(y);
    return day <= month_lengths[month];
}

/// Whether every field is in range and the day exists. The executor
/// validates fields as it reads them; this is the whole-value check for
/// values built any other way.
pub fn isValid(dt: DateTime) bool {
    if (dt.month < 1 or dt.month > 12) return false;
    if (!dayExists(dt.year, dt.month, dt.day)) return false;
    if (dt.hour > 23 or dt.minute > 59 or dt.second > 59) return false;
    if (dt.nanosecond > 999_999_999) return false;
    return true;
}

/// Days since 1970-01-01 of the civil date (Hinnant's days_from_civil).
pub fn daysFromCivil(y_in: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, y_in) - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp: i64 = if (month > 2) @as(i64, month) - 3 else @as(i64, month) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const CivilDate = struct { year: i32, month: u8, day: u8 };

/// Civil date of a day count since 1970-01-01 (Hinnant's civil_from_days).
/// Asserts the resulting year fits an i32, which every input this library
/// accepts guarantees: the epoch detector refuses instants more than about
/// 3168 years from the epoch and every format writes the year in four
/// digits or fewer.
pub fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1); // [1, 31]
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9); // [1, 12]
    const year: i32 = @intCast(if (m <= 2) y + 1 else y);
    return .{ .year = year, .month = m, .day = d };
}

/// The instant this civil reading names.
pub fn toEpoch(dt: DateTime) Epoch {
    const days = daysFromCivil(dt.year, dt.month, dt.day);
    const civil_seconds = days * 86_400 +
        @as(i64, dt.hour) * 3_600 + @as(i64, dt.minute) * 60 + dt.second;
    return .{
        .seconds = civil_seconds - dt.offset_seconds,
        .nanosecond = dt.nanosecond,
    };
}

/// The civil reading of an instant at a fixed offset.
pub fn fromEpoch(e: Epoch, offset_seconds: i32) DateTime {
    const local = e.seconds + offset_seconds;
    const days = @divFloor(local, 86_400);
    const sod: u32 = @intCast(@mod(local, 86_400)); // second of day, [0, 86399]
    const date = civilFromDays(days);
    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = @intCast(sod / 3_600),
        .minute = @intCast(sod % 3_600 / 60),
        .second = @intCast(sod % 60),
        .nanosecond = e.nanosecond,
        .offset_seconds = offset_seconds,
    };
}

pub fn weekday(dt: DateTime) Weekday {
    const days = daysFromCivil(dt.year, dt.month, dt.day);
    // 1970-01-01 is a Thursday; +4 lands Sunday on 0.
    return @fromBackingInt(@intCast(@as(u3, @intCast(@mod(days + 4, 7)))));
}

/// Whether two values name the same instant. Two civil readings at
/// different offsets can be equal here; field-by-field equality is `==` on
/// the struct, which this deliberately is not.
pub fn eqlInstant(a: DateTime, b: DateTime) bool {
    const ea = a.toEpoch();
    const eb = b.toEpoch();
    return ea.seconds == eb.seconds and ea.nanosecond == eb.nanosecond;
}

/// Shifts by n calendar days, keeping the clock and offset.
pub fn addDays(dt: DateTime, n: i64) DateTime {
    const date = civilFromDays(daysFromCivil(dt.year, dt.month, dt.day) + n);
    var out = dt;
    out.year = date.year;
    out.month = date.month;
    out.day = date.day;
    return out;
}

/// Shifts the instant by n seconds and re-reads it at the same offset.
pub fn addSeconds(dt: DateTime, n: i64) DateTime {
    var e = dt.toEpoch();
    e.seconds += n;
    return fromEpoch(e, dt.offset_seconds);
}

/// Shifts by n calendar months, clamping the day to the last day of the
/// target month instead of letting it overflow into the next one: one month
/// before 2024-03-31 is 2024-02-29. Go's time.AddDate normalises instead,
/// which answers 2024-03-02, the right answer to a different question.
pub fn addMonthsClamped(dt: DateTime, n: i64) DateTime {
    const total = @as(i64, dt.month) - 1 + n;
    const ty: i32 = @intCast(dt.year + @divFloor(total, 12));
    const tm: u8 = @intCast(@mod(total, 12) + 1);
    var out = dt;
    out.year = ty;
    out.month = tm;
    out.day = @min(dt.day, daysInMonth(ty, tm));
    return out;
}

/// A year is twelve months, and it clamps for the same reason: one year
/// after 2024-02-29 is 2025-02-28, not the 1st of March.
pub fn addYearsClamped(dt: DateTime, n: i64) DateTime {
    return dt.addMonthsClamped(n * 12);
}

const testing = std.testing;

test "leap years: full Gregorian rule" {
    try testing.expect(isLeapYear(2024));
    try testing.expect(isLeapYear(2000));
    try testing.expect(isLeapYear(0)); // year 0 exists and is a leap year
    try testing.expect(!isLeapYear(1900));
    try testing.expect(!isLeapYear(2100));
    try testing.expect(!isLeapYear(2023));
}

test "dayExists refuses what the calendar refuses" {
    try testing.expect(dayExists(2024, 2, 29));
    try testing.expect(!dayExists(2023, 2, 29));
    try testing.expect(!dayExists(2024, 2, 30));
    try testing.expect(!dayExists(1900, 2, 29));
    try testing.expect(dayExists(2000, 2, 29));
    try testing.expect(!dayExists(2024, 4, 31));
    try testing.expect(dayExists(2024, 12, 31));
    try testing.expect(!dayExists(2024, 1, 0));
}

test "epoch round trip at known instants" {
    const cases = [_]struct { dt: DateTime, seconds: i64 }{
        .{ .dt = .{ .year = 1970, .month = 1, .day = 1 }, .seconds = 0 },
        .{
            .dt = .{ .year = 2024, .month = 3, .day = 15, .hour = 10, .minute = 30 },
            .seconds = 1_710_498_600,
        },
        // Year 0 is in the golden corpus ("0000-01-01" parses).
        .{ .dt = .{ .year = 0, .month = 1, .day = 1 }, .seconds = -62_167_219_200 },
        .{ .dt = .{ .year = 1, .month = 1, .day = 1 }, .seconds = -62_135_596_800 },
    };
    for (cases) |case| {
        const e = case.dt.toEpoch();
        try testing.expectEqual(case.seconds, e.seconds);
        const back = fromEpoch(e, case.dt.offset_seconds);
        try testing.expectEqual(case.dt, back);
    }
}

test "offset moves the instant, not the civil reading" {
    // 0000-01-01T00:00:00+01:00 is -0001-12-31T23:00:00Z, a corpus row.
    const dt: DateTime = .{ .year = 0, .month = 1, .day = 1, .offset_seconds = 3600 };
    try testing.expectEqual(@as(i64, -62_167_219_200 - 3600), dt.toEpoch().seconds);
    const utc = fromEpoch(dt.toEpoch(), 0);
    try testing.expectEqual(@as(i32, -1), utc.year);
    try testing.expectEqual(@as(u8, 12), utc.month);
    try testing.expectEqual(@as(u8, 31), utc.day);
    try testing.expectEqual(@as(u8, 23), utc.hour);
    try testing.expect(dt.eqlInstant(utc));
}

test "round trip across a wide day range" {
    // Every ~97th day across roughly 4400 years, through both era boundaries.
    var days: i64 = -720_000;
    while (days < 900_000) : (days += 97) {
        const date = civilFromDays(days);
        try testing.expectEqual(days, daysFromCivil(date.year, date.month, date.day));
        try testing.expect(dayExists(date.year, date.month, date.day));
    }
}

test "weekday" {
    const friday: DateTime = .{ .year = 2024, .month = 3, .day = 15 };
    try testing.expectEqual(Weekday.friday, friday.weekday());
    const thursday: DateTime = .{ .year = 1970, .month = 1, .day = 1 };
    try testing.expectEqual(Weekday.thursday, thursday.weekday());
    const saturday: DateTime = .{ .year = 0, .month = 1, .day = 1 };
    try testing.expectEqual(Weekday.saturday, saturday.weekday());
}

test "month arithmetic clamps to the end of the target month" {
    // The README's clamping table.
    const march31: DateTime = .{ .year = 2024, .month = 3, .day = 31 };
    const feb29 = march31.addMonthsClamped(-1);
    try testing.expectEqual(DateTime{ .year = 2024, .month = 2, .day = 29 }, feb29);

    const leap_day: DateTime = .{ .year = 2024, .month = 2, .day = 29 };
    const next_year = leap_day.addYearsClamped(1);
    try testing.expectEqual(DateTime{ .year = 2025, .month = 2, .day = 28 }, next_year);

    const oct31: DateTime = .{ .year = 2024, .month = 10, .day = 31 };
    try testing.expectEqual(
        DateTime{ .year = 2024, .month = 11, .day = 30 },
        oct31.addMonthsClamped(1),
    );

    // January minus one month crosses the year: floored division, not Go's
    // truncating operators, is what moves the year.
    const jan15: DateTime = .{ .year = 2024, .month = 1, .day = 15 };
    try testing.expectEqual(
        DateTime{ .year = 2023, .month = 12, .day = 15 },
        jan15.addMonthsClamped(-1),
    );

    // A shift that needs no clamp keeps the day.
    const may5: DateTime = .{ .year = 2024, .month = 5, .day = 5, .hour = 12 };
    try testing.expectEqual(
        DateTime{ .year = 2024, .month = 8, .day = 5, .hour = 12 },
        may5.addMonthsClamped(3),
    );
}

test "addDays and addSeconds" {
    const dt: DateTime = .{ .year = 2024, .month = 2, .day = 28, .hour = 23 };
    try testing.expectEqual(
        DateTime{ .year = 2024, .month = 2, .day = 29, .hour = 23 },
        dt.addDays(1),
    );
    try testing.expectEqual(
        DateTime{ .year = 2024, .month = 2, .day = 29 },
        dt.addSeconds(3600),
    );
    const pre: DateTime = .{ .year = 2024, .month = 1, .day = 1 };
    try testing.expectEqual(
        DateTime{ .year = 2023, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 },
        pre.addSeconds(-1),
    );
}

test "isValid" {
    try testing.expect(isValid(.{ .year = 2024, .month = 2, .day = 29 }));
    try testing.expect(!isValid(.{ .year = 2023, .month = 2, .day = 29 }));
    try testing.expect(!isValid(.{ .year = 2024, .month = 13, .day = 1 }));
    try testing.expect(!isValid(.{ .year = 2024, .month = 0, .day = 1 }));
    try testing.expect(!isValid(.{ .year = 2024, .month = 1, .day = 1, .hour = 24 }));
    try testing.expect(!isValid(.{ .year = 2024, .month = 1, .day = 1, .nanosecond = 1_000_000_000 }));
}

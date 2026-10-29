//! dateparsa, through its C interface, against Rust's date parsers: chrono,
//! jiff, time and speedate, which are told the format, and dateparser, which
//! works it out as dateparsa does. tools/bench_others.sh runs it.
//!
//!   cargo run --release -- [-count N] [-benchtime MS]
//!
//! Prints two Markdown tables. The first is the time per parse, the median
//! of -count rounds; a round times every parser on every input, in an order
//! that turns by one each round. The second is the heap allocations per
//! parse, counted by the global allocator, for the Rust parsers: a C
//! library's allocations would not pass through it, so dateparsa has no
//! column there.
//!
//! Before timing, each parser reads each input once, and an answer that is
//! not the instant the input names is reported instead of timed. A parser
//! that keeps microseconds is held to the microsecond.

use std::alloc::{GlobalAlloc, Layout, System};
use std::hint::black_box;
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::time::Instant;

use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, Utc};

/// The C interface, as include/dateparsa.h declares it.
mod ffi {
    use std::ffi::{c_char, c_int, c_void};

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct DateTime {
        pub year: i32,
        pub month: u8,
        pub day: u8,
        pub hour: u8,
        pub minute: u8,
        pub second: u8,
        pub nanosecond: u32,
        pub offset_seconds: i32,
    }

    #[repr(C, align(8))]
    #[derive(Clone, Copy)]
    pub struct Layout {
        pub bytes: [u8; 256],
    }

    #[repr(C)]
    pub struct Result {
        pub time: DateTime,
        pub unix_seconds: i64,
        pub kind: u8,
        pub ambiguous: bool,
        pub reusable: bool,
        pub label: *const c_char,
        pub label_len: usize,
        pub layout: Layout,
    }

    pub const OK: c_int = 0;

    unsafe extern "C" {
        // NULL options are the defaults.
        pub fn dateparsa_parse(input: *const u8, len: usize, options: *const c_void, out: *mut Result) -> c_int;
        pub fn dateparsa_layout_parse(layout: *const Layout, input: *const u8, len: usize, out: *mut DateTime) -> c_int;
        pub fn dateparsa_to_unix(time: *const DateTime, seconds: *mut i64) -> c_int;
    }
}

/// Counts allocations while COUNTING is set.
struct Counting;

static COUNTING: AtomicBool = AtomicBool::new(false);
static ALLOCS: AtomicU64 = AtomicU64::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if COUNTING.load(Relaxed) {
            ALLOCS.fetch_add(1, Relaxed);
        }
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if COUNTING.load(Relaxed) {
            ALLOCS.fetch_add(1, Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

#[derive(Clone, Copy, PartialEq)]
enum Format {
    Rfc3339,
    Sql,
    Date,
    Compact,
    Rfc2822,
    UsSlash,
    Textual,
    /// No date: what a parser is given that reads the most like one.
    Miss,
}

struct Case {
    input: &'static str,
    /// Nanoseconds since 1970-01-01T00:00:00Z, or None when the input is
    /// no date and every parser should refuse it.
    want: Option<i128>,
    format: Format,
}

const S: i128 = 1_000_000_000;

const CASES: &[Case] = &[
    Case { input: "2024-03-15T10:30:00Z", want: Some(1710498600 * S), format: Format::Rfc3339 },
    Case { input: "2024-03-15T10:30:00+05:30", want: Some(1710478800 * S), format: Format::Rfc3339 },
    Case { input: "2024-03-15T10:30:00.123456789Z", want: Some(1710498600 * S + 123456789), format: Format::Rfc3339 },
    Case { input: "2024-03-15 10:30:00", want: Some(1710498600 * S), format: Format::Sql },
    Case { input: "2024-03-15", want: Some(1710460800 * S), format: Format::Date },
    Case { input: "20240315T103000Z", want: Some(1710498600 * S), format: Format::Compact },
    Case { input: "Fri, 15 Mar 2024 10:30:00 +0000", want: Some(1710498600 * S), format: Format::Rfc2822 },
    Case { input: "03/15/2024", want: Some(1710460800 * S), format: Format::UsSlash },
    Case { input: "March 15, 2024", want: Some(1710460800 * S), format: Format::Textual },
    Case { input: "not a date at all", want: None, format: Format::Miss },
];

/// One parser on one case's input.
struct Entry {
    /// Parses the input, keeping the result from the optimizer.
    run: Box<dyn Fn(&str)>,
    /// What the input reads as, or None when the parser refuses it.
    answer: Box<dyn Fn(&str) -> Option<i128>>,
    /// The parser keeps microseconds, not nanoseconds.
    micros: bool,
}

/// An entry from a parse function and the instant its result names.
fn entry<T: 'static>(parse: fn(&str) -> Option<T>, nanos: fn(T) -> i128) -> Option<Entry> {
    Some(Entry {
        run: Box::new(move |s| {
            black_box(parse(black_box(s)));
        }),
        answer: Box::new(move |s| parse(s).map(nanos)),
        micros: false,
    })
}

fn micros(e: Option<Entry>) -> Option<Entry> {
    e.map(|e| Entry { micros: true, ..e })
}

struct Impl {
    name: &'static str,
    /// Its entry for a case, or None when it has no way to read the format.
    entry: fn(&Case) -> Option<Entry>,
    /// Allocations are counted for it.
    rust: bool,
}

fn dp_parse(s: &str, out: &mut MaybeUninit<ffi::Result>) -> bool {
    unsafe { ffi::dateparsa_parse(s.as_ptr(), s.len(), std::ptr::null(), out.as_mut_ptr()) == ffi::OK }
}

fn dp_nanos(t: &ffi::DateTime) -> i128 {
    let mut seconds = 0i64;
    unsafe { ffi::dateparsa_to_unix(t, &mut seconds) };
    seconds as i128 * S + t.nanosecond as i128
}

fn chrono_nanos<Tz: chrono::TimeZone>(t: DateTime<Tz>) -> i128 {
    t.timestamp() as i128 * S + t.timestamp_subsec_nanos() as i128
}

fn date_nanos(d: NaiveDate) -> i128 {
    chrono_nanos(d.and_time(NaiveTime::MIN).and_utc())
}

fn jiff_utc(t: jiff::civil::DateTime) -> i128 {
    t.to_zoned(jiff::tz::TimeZone::UTC).unwrap().timestamp().as_nanosecond()
}

fn speedate_nanos(t: speedate::DateTime) -> i128 {
    t.timestamp_tz() as i128 * S + t.time.microsecond as i128 * 1000
}

static RFC2822: jiff::fmt::rfc2822::DateTimeParser = jiff::fmt::rfc2822::DateTimeParser::new();

const IMPLS: &[Impl] = &[
    Impl {
        name: "dateparsa parse",
        rust: false,
        entry: |_| {
            Some(Entry {
                run: Box::new(|s| {
                    let mut out = MaybeUninit::uninit();
                    black_box(dp_parse(black_box(s), &mut out));
                    black_box(&out);
                }),
                answer: Box::new(|s| {
                    let mut out = MaybeUninit::uninit();
                    if !dp_parse(s, &mut out) {
                        return None;
                    }
                    let r = unsafe { out.assume_init() };
                    Some(r.unix_seconds as i128 * S + r.time.nanosecond as i128)
                }),
                micros: false,
            })
        },
    },
    Impl {
        name: "dateparsa layout",
        rust: false,
        entry: |c| {
            let mut out = MaybeUninit::uninit();
            if !dp_parse(c.input, &mut out) {
                return None;
            }
            let r = unsafe { out.assume_init() };
            if !r.reusable {
                return None;
            }
            let layout = r.layout;
            let read = move |s: &str, t: &mut MaybeUninit<ffi::DateTime>| unsafe {
                ffi::dateparsa_layout_parse(&layout, s.as_ptr(), s.len(), t.as_mut_ptr()) == ffi::OK
            };
            Some(Entry {
                run: Box::new(move |s| {
                    let mut t = MaybeUninit::uninit();
                    black_box(read(black_box(s), &mut t));
                    black_box(&t);
                }),
                answer: Box::new(move |s| {
                    let mut t = MaybeUninit::uninit();
                    read(s, &mut t).then(|| dp_nanos(unsafe { t.assume_init_ref() }))
                }),
                micros: false,
            })
        },
    },
    Impl {
        name: "chrono",
        rust: true,
        entry: |c| match c.format {
            Format::Rfc3339 | Format::Miss => entry(|s| DateTime::parse_from_rfc3339(s).ok(), chrono_nanos),
            Format::Rfc2822 => entry(|s| DateTime::parse_from_rfc2822(s).ok(), chrono_nanos),
            Format::Sql => entry(
                |s| NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S").ok(),
                |t| chrono_nanos(t.and_utc()),
            ),
            Format::Compact => entry(
                |s| NaiveDateTime::parse_from_str(s, "%Y%m%dT%H%M%SZ").ok(),
                |t| chrono_nanos(t.and_utc()),
            ),
            Format::Date => entry(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok(), date_nanos),
            Format::UsSlash => entry(|s| NaiveDate::parse_from_str(s, "%m/%d/%Y").ok(), date_nanos),
            Format::Textual => entry(|s| NaiveDate::parse_from_str(s, "%B %d, %Y").ok(), date_nanos),
        },
    },
    Impl {
        name: "jiff",
        rust: true,
        entry: |c| match c.format {
            Format::Rfc3339 | Format::Compact | Format::Miss => {
                entry(|s| s.parse::<jiff::Timestamp>().ok(), |t| t.as_nanosecond())
            }
            Format::Rfc2822 => entry(|s| RFC2822.parse_timestamp(s).ok(), |t| t.as_nanosecond()),
            Format::Sql => entry(|s| s.parse::<jiff::civil::DateTime>().ok(), jiff_utc),
            Format::Date => entry(|s| s.parse::<jiff::civil::Date>().ok(), |d| jiff_utc(d.at(0, 0, 0, 0))),
            Format::UsSlash => entry(
                |s| jiff::fmt::strtime::parse("%m/%d/%Y", s).and_then(|t| t.to_date()).ok(),
                |d| jiff_utc(d.at(0, 0, 0, 0)),
            ),
            Format::Textual => entry(
                |s| jiff::fmt::strtime::parse("%B %d, %Y", s).and_then(|t| t.to_date()).ok(),
                |d| jiff_utc(d.at(0, 0, 0, 0)),
            ),
        },
    },
    Impl {
        name: "time",
        rust: true,
        entry: |c| {
            use time::format_description::well_known::{Iso8601, Rfc2822, Rfc3339};
            use time::macros::format_description;
            use time::{Date, OffsetDateTime, PrimitiveDateTime};
            let date = |d: Date| d.midnight().assume_utc().unix_timestamp_nanos();
            match c.format {
                Format::Rfc3339 | Format::Miss => {
                    entry(|s| OffsetDateTime::parse(s, &Rfc3339).ok(), |t| t.unix_timestamp_nanos())
                }
                Format::Compact => {
                    entry(|s| OffsetDateTime::parse(s, &Iso8601::DEFAULT).ok(), |t| t.unix_timestamp_nanos())
                }
                Format::Rfc2822 => {
                    entry(|s| OffsetDateTime::parse(s, &Rfc2822).ok(), |t| t.unix_timestamp_nanos())
                }
                Format::Sql => entry(
                    |s| {
                        PrimitiveDateTime::parse(s, format_description!("[year]-[month]-[day] [hour]:[minute]:[second]"))
                            .ok()
                    },
                    |t| t.assume_utc().unix_timestamp_nanos(),
                ),
                Format::Date => entry(|s| Date::parse(s, format_description!("[year]-[month]-[day]")).ok(), date),
                Format::UsSlash => entry(|s| Date::parse(s, format_description!("[month]/[day]/[year]")).ok(), date),
                Format::Textual => entry(
                    |s| Date::parse(s, format_description!("[month repr:long] [day], [year]")).ok(),
                    date,
                ),
            }
        },
    },
    Impl {
        name: "speedate",
        rust: true,
        entry: |c| match c.format {
            Format::Rfc3339 | Format::Sql | Format::Compact | Format::Miss => {
                micros(entry(|s| speedate::DateTime::parse_str(s).ok(), speedate_nanos))
            }
            Format::Date => entry(|s| speedate::Date::parse_str(s).ok(), |d| d.timestamp() as i128 * S),
            Format::Rfc2822 | Format::UsSlash | Format::Textual => None,
        },
    },
    Impl {
        name: "dateparser",
        rust: true,
        // UTC for an input with no zone, and midnight for one with no time,
        // as dateparsa reads them: the defaults read the local zone and the
        // clock.
        entry: |_| entry(|s| dateparser::parse_with(s, &Utc, NaiveTime::MIN).ok(), chrono_nanos),
    },
];

enum Cell {
    /// Nanoseconds a parse: a run's iteration count while timing, the
    /// median of the rounds after.
    Timed(u64, f64),
    /// The parser has no way to read the format.
    Unsupported,
    /// Refused an input it should read.
    Refused,
    /// Read the input as another instant.
    Wrong(i128),
}

fn check(c: &Case, e: &Entry) -> Option<Cell> {
    let got = (e.answer)(c.input);
    let unit = if e.micros { 1000 } else { 1 };
    match (c.want, got) {
        (None, None) => None,
        (Some(_), None) => Some(Cell::Refused),
        (Some(want), Some(t)) if want / unit == t / unit => None,
        (_, Some(t)) => Some(Cell::Wrong(t)),
    }
}

fn elapsed(e: &Entry, input: &str, n: u64) -> u64 {
    let start = Instant::now();
    for _ in 0..n {
        (e.run)(input);
    }
    (start.elapsed().as_nanos() as u64).max(1)
}

/// The iteration count whose run takes at least goal_ns, grown as Go's
/// testing package grows b.N: from a prediction, by at most 100x a step.
fn calibrate(e: &Entry, input: &str, goal_ns: u64) -> u64 {
    let mut n = 1u64;
    let mut ns = elapsed(e, input, n);
    while ns < goal_ns && n < 1_000_000_000 {
        let predicted = goal_ns as u128 * n as u128 / ns as u128 * 6 / 5;
        n = (predicted as u64).min(n * 100).max(n + 1);
        ns = elapsed(e, input, n);
    }
    n
}

fn allocs_per_parse(e: &Entry, input: &str) -> f64 {
    const N: u64 = 1000;
    ALLOCS.store(0, Relaxed);
    COUNTING.store(true, Relaxed);
    for _ in 0..N {
        (e.run)(input);
    }
    COUNTING.store(false, Relaxed);
    ALLOCS.load(Relaxed) as f64 / N as f64
}

fn usage() -> ! {
    eprintln!("usage: bench-rust [-count N] [-benchtime MS]");
    std::process::exit(2);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut count = 10usize;
    let mut benchtime_ms = 200u64;
    for pair in args.chunks(2) {
        let [flag, value] = pair else { usage() };
        let value: u64 = value.parse().unwrap_or_else(|_| usage());
        match flag.as_str() {
            "-count" => count = value as usize,
            "-benchtime" => benchtime_ms = value,
            _ => usage(),
        }
    }
    if count == 0 {
        usage();
    }

    let entries: Vec<Vec<Option<Entry>>> = CASES.iter().map(|c| IMPLS.iter().map(|i| (i.entry)(c)).collect()).collect();
    let mut cells: Vec<Vec<Cell>> = CASES
        .iter()
        .zip(&entries)
        .map(|(c, row)| {
            row.iter()
                .map(|e| match e {
                    None => Cell::Unsupported,
                    Some(e) => check(c, e)
                        .unwrap_or_else(|| Cell::Timed(calibrate(e, c.input, benchtime_ms * 1_000_000), 0.0)),
                })
                .collect()
        })
        .collect();
    let allocs: Vec<Vec<Option<f64>>> = CASES
        .iter()
        .zip(&entries)
        .zip(&cells)
        .map(|((c, row), cell_row)| {
            row.iter()
                .zip(cell_row)
                .zip(IMPLS)
                .map(|((e, cell), i)| match (e, cell) {
                    (Some(e), Cell::Timed(..)) if i.rust => Some(allocs_per_parse(e, c.input)),
                    _ => None,
                })
                .collect()
        })
        .collect();

    let mut runs = vec![vec![vec![0f64; IMPLS.len()]; CASES.len()]; count];
    for (r, round) in runs.iter_mut().enumerate() {
        eprintln!("round {} of {}", r + 1, count);
        for (ci, c) in CASES.iter().enumerate() {
            for k in 0..IMPLS.len() {
                let ii = (k + r) % IMPLS.len();
                if let (Cell::Timed(n, _), Some(e)) = (&cells[ci][ii], &entries[ci][ii]) {
                    round[ci][ii] = elapsed(e, c.input, *n) as f64 / *n as f64;
                }
            }
        }
    }
    for (ci, row) in cells.iter_mut().enumerate() {
        for (ii, cell) in row.iter_mut().enumerate() {
            if let Cell::Timed(n, _) = cell {
                let mut samples: Vec<f64> = runs.iter().map(|round| round[ci][ii]).collect();
                samples.sort_by(f64::total_cmp);
                let mid = samples.len() / 2;
                let median = if samples.len() % 2 == 1 { samples[mid] } else { (samples[mid - 1] + samples[mid]) / 2.0 };
                *cell = Cell::Timed(*n, median);
            }
        }
    }

    print_header(IMPLS.iter().map(|i| i.name));
    for (c, row) in CASES.iter().zip(&cells) {
        let cols: Vec<String> = row.iter().map(cell_text).collect();
        println!("| `{}` | {} |", c.input, cols.join(" | "));
    }
    for (c, row) in CASES.iter().zip(&cells) {
        for (i, cell) in IMPLS.iter().zip(row) {
            if let Cell::Wrong(t) = cell {
                println!("\n{} read `{}` as {} ns since the epoch.", i.name, c.input, t);
            }
        }
    }

    println!("\nHeap allocations per parse:\n");
    print_header(IMPLS.iter().filter(|i| i.rust).map(|i| i.name));
    for ((c, row), cell_row) in CASES.iter().zip(&allocs).zip(&cells) {
        let cols: Vec<String> = IMPLS
            .iter()
            .zip(row)
            .zip(cell_row)
            .filter(|((i, _), _)| i.rust)
            .map(|((_, a), cell)| match a {
                Some(a) if a.fract() == 0.0 => format!("{a:.0}"),
                Some(a) => format!("{a:.1}"),
                // Not timed, so not counted: what the time table says.
                None => cell_text(cell),
            })
            .collect();
        println!("| `{}` | {} |", c.input, cols.join(" | "));
    }
}

fn print_header<'a>(names: impl Iterator<Item = &'a str>) {
    let names: Vec<&str> = names.collect();
    println!("| Input | {} |", names.join(" | "));
    println!("|---|{}", "--:|".repeat(names.len()));
}

/// ns as bench.sh writes it, in ns below a microsecond and µs or ms above.
fn cell_text(cell: &Cell) -> String {
    match cell {
        Cell::Timed(_, ns) if *ns >= 1e6 => format!("{:.2} ms", ns / 1e6),
        Cell::Timed(_, ns) if *ns >= 1e3 => format!("{:.2} µs", ns / 1e3),
        Cell::Timed(_, ns) if *ns >= 100.0 => format!("{ns:.0} ns"),
        Cell::Timed(_, ns) => format!("{ns:.1} ns"),
        Cell::Unsupported => "no".to_string(),
        Cell::Refused => "refuses".to_string(),
        Cell::Wrong(_) => "wrong".to_string(),
    }
}

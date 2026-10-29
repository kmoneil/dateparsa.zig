# Performance

How fast this port is, on one machine: first against the Go dateparsa it was
ported from, by the Go library's own benchmarks, and then
[against other parsers](#against-other-parsers) in Zig, Rust and Python.

## How it is measured

`bench/main.zig` is the Go library's benchmark matrix (`bench_test.go` and
`phase2_test.go` to `phase4_test.go` there) on this port, under the same
names, built ReleaseFast. It prints Go's benchmark format, one line per run.

`tools/bench.sh` builds the Go test binary from a checkout of the Go library
and runs ten rounds. A round runs every benchmark on both sides back to back,
Go first in odd rounds and Zig first in even ones, so the two halves of each
pair see the same machine. The ns/op columns are each side's median over the
rounds. The ratio is the median of the ten per-round Zig / Go ratios, and the
range beside it runs from the second smallest to the second largest of them.

Pairs, because the machine is a busy laptop. The two halves of a pair run
seconds apart rather than a minute, so a change in what else the machine is
doing lands on both. It steadies the ratio less than that suggests: in the
run below, the middle eight of each benchmark's ten runs spread by 14.5% of
the median on the Go side and 8.5% on the Zig side, and the middle eight
ratios by 9.4%. So the ratio is about as steady as the steadier side, and a
difference of a few percent in it is not a result. A ratio whose range is
wider than 0.2 is marked wide. The raw runs are kept in `_bench/` in Go's
format, for benchstat.

```sh
tools/bench.sh                         # every benchmark, ten runs a side
COUNT=5 BENCHTIME=200 BENCH=Layout tools/bench.sh
zig build bench -- -bench NL           # this port alone
```

## Reading the numbers

**Same machine, same run, or nothing.** The ratio column is the result. A
ns/op here means nothing next to one measured on another machine, including
the figures in the Go README, which come from a rented `c4-standard-8`.
This table was taken on a laptop, which is quick and not quiet: the load
average is in the header, and the Go README explains at length why a
laptop's numbers are for shape and a rented machine's are for reference.

**Allocations are zero by construction.** No API takes an allocator and no
file under `src/` outside the tests names one, so the B/op and allocs/op
columns the harness prints are not measurements. The Go library allocates on
an error (a `*ParseError` per miss) and in `ParseColumn`'s result slice; its
hot paths allocate nothing either.

**What differs in what is measured:**

- `Detect_*`: Go's `Detect` stops after detection. This port's `detect` is
  `parseWith(...).layout`, so the row is a whole parse.
- `10M_Parser_ParseColumn`: there is no `ParseColumn` here. The row calls
  `Parser.parse` on each of ten million rows and keeps no results, where Go's
  allocates and fills a ten-million-entry result slice.
- `Parse_TimeAMPM`: Go's `Parse` reads the clock for the year of a time with
  no date. This port has no clock and takes `base_time` instead.
- Left out: `VsStdlib` and the `Compile` benchmarks (no Go layout strings
  here), and `flextime`'s (the std.json glue is not written yet).

## Results

Go v0.2.0 (go1.26.4) against dateparsa.zig 73880c4 (Zig 0.17.0)  
Apple M5 Max, Darwin arm64, 2026-10-28, 10 rounds of 350ms runs  
Load averages at the start 5.54 4.88 6.15, at the end 7.68 6.70 6.46  

| Benchmark | Go ns/op | Zig ns/op | Zig / Go | middle range |
|---|--:|--:|--:|--:|
| Parse_ISO8601 | 49.0 | 44.0 | 0.91 | 0.88 to 0.97 |
| Parse_ISO8601_DateTime | 67.2 | 64.0 | 0.94 | 0.92 to 0.96 |
| Parse_RFC3339 | 77.8 | 81.8 | 1.05 | 1.01 to 1.07 |
| Parse_SQLDatetime | 64.8 | 60.5 | 0.94 | 0.92 to 0.97 |
| Parse_TextualMonth | 256 | 142 | 0.55 | 0.48 to 0.57 |
| Parse_RFC2822_Locales | 840 | 512 | 0.63 | 0.56 to 0.68 |
| Parse_AmbiguousSlash | 164 | 85.2 | 0.51 | 0.48 to 0.55 |
| Parse_Miss_Short | 234 | 45.7 | 0.19 | 0.18 to 0.21 |
| Parse_Miss_Text | 295 | 153 | 0.52 | 0.49 to 0.53 |
| Parse_Miss_Long | 1166 | 527 | 0.46 | 0.41 to 0.50 |
| Parse_Miss_Locales | 1026 | 769 | 0.76 | 0.70 to 0.78 |
| Parse_Miss_Locales_NonLatin | 1276 | 892 | 0.70 | 0.64 to 0.73 |
| Layout_Parse | 15.2 | 10.3 | 0.68 | 0.67 to 0.70 |
| Layout_Parse_ISODate | 11.2 | 7.6 | 0.70 | 0.67 to 0.72 |
| Layout_Parse_TextualMonth | 23.6 | 13.7 | 0.58 | 0.57 to 0.60 |
| Detect_Only | 49.0 | 64.7 | 1.31 | 1.28 to 1.34 |
| Detect_TrieMiss_Fallback | 221 | 143 | 0.65 | 0.58 to 0.66 |
| Detect_NoMatch | 104 | 152 | 1.42 | 1.38 to 1.54 |
| Parser_Cached | 16.7 | 16.1 | 0.95 | 0.88 to 0.98 |
| 10M_Layout_Parse | 151.0 ms | 102.8 ms | 0.68 | 0.67 to 0.70 |
| 10M_Parser_ParseColumn | 194.2 ms | 164.2 ms | 0.83 | 0.78 to 0.86 |
| Layout_Parse_TZName_CET | 17.7 | 14.4 | 0.80 | 0.80 to 0.85 |
| Layout_Parse_TZOffset_OffGrid | 20.2 | 12.6 | 0.63 | 0.61 to 0.65 |
| Layout_Parse_TZOffset_OnGrid | 19.5 | 12.8 | 0.65 | 0.62 to 0.69 |
| Parse_Compact | 41.8 | 44.3 | 1.05 | 1.00 to 1.10 |
| Parse_CompactDateTime | 58.9 | 50.6 | 0.88 | 0.84 to 0.92 |
| Parse_UnixTimestamp | 58.0 | 36.5 | 0.63 | 0.60 to 0.65 |
| Parse_ISOWeekDate | 166 | 77.2 | 0.47 | 0.43 to 0.49 |
| Parse_ISOOrdinal | 107 | 67.9 | 0.63 | 0.55 to 0.65 |
| Parse_TimeAMPM | 126 | 74.2 | 0.58 | 0.52 to 0.61 |
| Parse_SQLFrac6 | 76.5 | 79.9 | 1.03 | 1.00 to 1.13 |
| Layout_Parse_Compact | 10.5 | 7.3 | 0.70 | 0.69 to 0.72 |
| Parse_NL_Yesterday | 226 | 74.6 | 0.33 | 0.31 to 0.37 |
| Parse_NL_3DaysAgo | 257 | 112 | 0.44 | 0.41 to 0.46 |
| Parse_NL_NextFriday | 253 | 102 | 0.41 | 0.39 to 0.42 |
| Parse_NL_YesterdayAt5pm | 303 | 120 | 0.40 | 0.38 to 0.43 |
| Parse_NL_BeginningOfMonth | 265 | 100 | 0.39 | 0.36 to 0.41 |
| Parse_NL_In10Minutes | 247 | 104 | 0.43 | 0.41 to 0.45 |
| Parse_Locale_FrenchMonth | 281 | 147 | 0.52 | 0.46 to 0.56 |
| Parse_Locale_FrenchNL | 342 | 138 | 0.41 | 0.38 to 0.44 |
| Parse_Locale_GermanMonth | 300 | 151 | 0.51 | 0.45 to 0.53 |
| Parse_Locale_RussianNL | 788 | 390 | 0.49 | 0.46 to 0.52 |

**Faster than Go:** natural language (0.33 to 0.49 of Go's time, English,
French and Russian alike), misses (0.19 to 0.76), textual dates with or
without locales (0.51 to 0.63), reusing a layout (0.63 to 0.80, the ten
million row column included), and the first parse of most other formats:
an ambiguous numeric date, an ISO week date, a Unix timestamp, a time with
AM or PM.

**About even:** ISO and SQL date-times, compact dates, and a parse with a
zone offset or a fraction (0.88 to 1.05). The rows above 1 have ranges
that reach 1 or straddle it.

**Not comparable:** `Detect_Only` and `Detect_NoMatch`. Go's `Detect` stops
after structured detection; this port's is a whole parse, and on a miss
that includes natural language. `Parse_Miss_Text` is the like-for-like miss.

## Changes measured with this harness

The first table, in the commit that added this file (82a9edd), had natural
language at 1.4 to 1.9 times Go, misses up to 2.2 and a textual date with
three locales at 3.2. Two changes account for the difference: the first
came from reading how Go finds month names, the second from profiling the
slowest row with `sample`, and `tools/oracle.sh` showed neither changed an
answer. Ratios are Zig / Go, before and after.

| Change | Rows it moved |
|---|---|
| Month names found from a word list, Go's `wordMatcher`, rather than scanning the input once per spelling (2663658) | textual date with locales 3.19 to 0.65; English natural language 1.41-1.89 to 0.98-1.11; `Miss_Text` 1.68 to 1.05; French and German months 1.08 to 0.54 |
| Natural-language tokens filled in place rather than returned by value, several kilobytes copied per scan (73880c4) | English natural language 0.98-1.11 to 0.33-0.44; French 1.50 to 0.41; Russian 0.98 to 0.49; misses 0.93-1.20 to 0.19-0.76 |

Not done, and not needed by any row here: the per-format comptime fast path
and Go's day-count table in front of `daysFromCivil` (the reuse rows are
already 0.63 to 0.80), a SIMD signature scan, and bucketing locale words by
first byte (`Miss_Locales` is 0.76).

## Against other parsers

`tools/bench_others.sh` runs a harness per language on the same inputs and
prints the tables below:

- `bench/others/zig`: dateparsa and [zeit](https://github.com/rockorager/zeit),
  a build of its own, so the library's manifest names no dependency.
- `bench/others/rust`: dateparsa through the C interface, the ReleaseFast
  static library, against chrono, jiff, time, speedate and dateparser,
  pinned by its `Cargo.lock`.
- `bench/others/python`: dateparsa through its Python package, against
  `datetime.fromisoformat`, `datetime.strptime`, ciso8601, dateutil,
  dateparser and pandas, pinned by its `requirements.txt`, on Python 3.13.

```sh
tools/bench_others.sh                  # all three: needs zig, cargo and uv
COUNT=3 BENCHTIME=100 tools/bench_others.sh rust
```

### What is compared

dateparsa appears twice in each table. **dateparsa parse** works the format
out on every call, as `parse` does: set it beside the parsers that also work
it out, which are Rust's dateparser, dateutil's `parse`, dateparser, and
pandas without `format=`. **dateparsa layout** reads with the layout
detected from the input, as the rest of a column is read: set it beside the
parsers that are told the format. Those are told it the way their
documentation says to: zeit's `fromISO8601` and `fromRFC5322`; chrono's
`parse_from_rfc3339` and `parse_from_rfc2822`, and `parse_from_str` with a
format string for the rest; jiff's ISO 8601 and RFC 2822 parsers, and
`strtime` for the rest; time's well-known formats, and format descriptions
for the rest; speedate's `DateTime` and `Date` parsers; `strptime` and pandas
with a format string. `fromisoformat`, ciso8601 and dateutil's `isoparse`
read ISO 8601 alone.

Before timing, each parser reads each input once, and its answer is checked
against the instant the input names, to the microsecond for a parser that
keeps no more. An input with no zone is read as UTC, and one with no time as
midnight. A cell says **no** when the parser has no way to read the format,
and **refuses** when it was given one and turned the input down. A wrong
answer would be reported instead of timed; there were none. The last row is
no date, and its cells are the time each parser takes to say so.

Each cell is the median of ten rounds of 200 ms runs. A round runs every
parser on every input, in an order that turns by one each round, so drift in
the machine reaches every column. The Rust harness also counts heap
allocations through its global allocator, which covers the Rust parsers
alone: a C library's allocations would not pass through it.

### Results

dateparsa.zig c1e122b with these harnesses added, no library code changed (Zig 0.17.0)  
Apple M5 Max, Darwin arm64, 2026-10-29, 10 rounds of 200ms runs  
Load averages at the start 10.17 9.99 9.70, at the end 6.82 10.24 10.19  

Zig, zeit 0.10.0 (06bb7b4):

| Input | dateparsa parse | dateparsa layout | zeit |
|---|--:|--:|--:|
| `2024-03-15T10:30:00Z` | 61.2 ns | 10.3 ns | 14.2 ns |
| `2024-03-15T10:30:00+05:30` | 81.6 ns | 12.6 ns | 17.3 ns |
| `2024-03-15T10:30:00.123456789Z` | 80.0 ns | 13.4 ns | 23.1 ns |
| `2024-03-15 10:30:00` | 60.2 ns | 9.4 ns | 13.7 ns |
| `2024-03-15` | 43.4 ns | 7.6 ns | 9.6 ns |
| `20240315T103000Z` | 52.0 ns | 9.6 ns | 14.1 ns |
| `Fri, 15 Mar 2024 10:30:00 +0000` | 343 ns | 25.4 ns | 18.1 ns |
| `03/15/2024` | 79.5 ns | no | no |
| `March 15, 2024` | 140 ns | 13.6 ns | no |
| `not a date at all` | 143 ns | no | 4.6 ns |

Rust, chrono 0.4.45, dateparser 0.3.1, jiff 0.2.38, speedate 0.18.0, time
0.3.55 (rustc 1.99.1):

| Input | dateparsa parse | dateparsa layout | chrono | jiff | time | speedate | dateparser |
|---|--:|--:|--:|--:|--:|--:|--:|
| `2024-03-15T10:30:00Z` | 87.1 ns | 12.4 ns | 8.2 ns | 10.0 ns | 6.2 ns | 6.3 ns | 30.0 ns |
| `2024-03-15T10:30:00+05:30` | 117 ns | 15.7 ns | 10.5 ns | 12.8 ns | 8.0 ns | 8.2 ns | 32.1 ns |
| `2024-03-15T10:30:00.123456789Z` | 116 ns | 16.7 ns | 12.3 ns | 19.8 ns | 10.1 ns | refuses | 37.2 ns |
| `2024-03-15 10:30:00` | 85.0 ns | 12.2 ns | 76.3 ns | 7.5 ns | 39.6 ns | 6.1 ns | 382 ns |
| `2024-03-15` | 72.1 ns | 9.9 ns | 39.7 ns | 4.3 ns | 22.8 ns | 3.7 ns | 94.0 ns |
| `20240315T103000Z` | 76.3 ns | 12.0 ns | 61.9 ns | 10.3 ns | 11.3 ns | refuses | refuses |
| `Fri, 15 Mar 2024 10:30:00 +0000` | 388 ns | 27.9 ns | 46.5 ns | 16.1 ns | 11.5 ns | no | 48.8 ns |
| `03/15/2024` | 106 ns | no | 37.7 ns | 20.3 ns | 21.6 ns | no | 157 ns |
| `March 15, 2024` | 171 ns | 16.2 ns | 45.5 ns | 25.8 ns | 24.1 ns | no | 231 ns |
| `not a date at all` | 172 ns | no | 2.4 ns | 23.3 ns | 1.6 ns | 2.6 ns | 124 ns |

Heap allocations per parse, Rust parsers:

| Input | chrono | jiff | time | speedate | dateparser |
|---|--:|--:|--:|--:|--:|
| `2024-03-15T10:30:00Z` | 0 | 0 | 0 | 0 | 0 |
| `2024-03-15T10:30:00+05:30` | 0 | 0 | 0 | 0 | 0 |
| `2024-03-15T10:30:00.123456789Z` | 0 | 0 | 0 | refuses | 0 |
| `2024-03-15 10:30:00` | 0 | 0 | 0 | 0 | 0 |
| `2024-03-15` | 0 | 0 | 0 | 0 | 0 |
| `20240315T103000Z` | 0 | 0 | 0 | refuses | refuses |
| `Fri, 15 Mar 2024 10:30:00 +0000` | 0 | 0 | 0 | no | 0 |
| `03/15/2024` | 0 | 0 | 0 | no | 0 |
| `March 15, 2024` | 0 | 0 | 0 | no | 3 |
| `not a date at all` | 0 | 2 | 0 | 0 | 2 |

Python, ciso8601 2.3.3, dateparser 1.4.3, pandas 3.1.0, python-dateutil
3.0.0 (Python 3.13.16), one value at a time:

| Input | dateparsa parse | dateparsa layout | fromisoformat | strptime | ciso8601 | dateutil isoparse | dateutil parse | dateparser |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| `2024-03-15T10:30:00Z` | 3.45 µs | 856 ns | 27.6 ns | 2.33 µs | 21.4 ns | 1.55 µs | 11.26 µs | 691.95 µs |
| `2024-03-15T10:30:00+05:30` | 3.47 µs | 873 ns | 44.9 ns | 2.74 µs | 22.1 ns | 2.10 µs | 12.79 µs | 542.20 µs |
| `2024-03-15T10:30:00.123456789Z` | 3.51 µs | 885 ns | 32.1 ns | refuses | 23.1 ns | 2.02 µs | 12.75 µs | 827.38 µs |
| `2024-03-15 10:30:00` | 3.45 µs | 848 ns | 26.1 ns | 1.90 µs | 20.2 ns | 1.38 µs | 9.89 µs | 431.25 µs |
| `2024-03-15` | 3.38 µs | 847 ns | 20.7 ns | 1.37 µs | 18.3 ns | 478 ns | 6.02 µs | 342.19 µs |
| `20240315T103000Z` | 3.49 µs | 848 ns | 26.5 ns | 2.32 µs | 21.8 ns | 1.48 µs | 8.21 µs | refuses |
| `Fri, 15 Mar 2024 10:30:00 +0000` | 3.78 µs | 876 ns | no | 2.98 µs | no | no | 17.89 µs | 689.49 µs |
| `03/15/2024` | 3.44 µs | no | no | 1.38 µs | no | no | 6.09 µs | 318.31 µs |
| `March 15, 2024` | 3.53 µs | 850 ns | no | 1.47 µs | no | no | 9.96 µs | 407.20 µs |
| `3 days ago` | 4.13 µs | no | no | no | no | no | refuses | 215.44 µs |
| `not a date at all` | 1.75 µs | no | 156 ns | 1.02 µs | 214 ns | 1.08 µs | 5.42 µs | 129.16 µs |

Python, a column of 10,000 different values, per value (dateparser left
out: at about a millisecond a value, a loop over the column says what its
row above says):

| Input | dateparsa Parser | dateparsa layout | fromisoformat | strptime | ciso8601 | dateutil parse | pandas | pandas format= |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| RFC 3339, `2000-01-01T00:00:00Z` on by minutes | 2.87 µs | 855 ns | 28.3 ns | 1.87 µs | 22.5 ns | 11.23 µs | 81.0 ns | 505 ns |
| US dates, `01/01/2000` on by days | 3.00 µs | no | no | 1.39 µs | no | 6.10 µs | 330 ns | 324 ns |

What the shared library imports, `nm -u`:

    _bzero
    _memcpy
    _memset
    dyld_stub_binder

### Reading the numbers

The load average stayed near 10 through the run, so a cell is good to 10 to
20%, and a difference smaller than that is not a result.

**Told the format.** In Zig, a reused layout reads every ISO 8601 and RFC
3339 form in 0.58 to 0.79 of zeit's time, and RFC 5322 in 1.40 of it. In
Rust, through the C interface, the fastest parser of each ISO 8601, RFC
3339 and RFC 2822 form (time, speedate or jiff) takes 0.37 to 0.86 of a
layout's time. Parsers that follow a format string at run time take longer
than a layout: chrono's `parse_from_str` 2.8 to 6.3 times as long, and
time's format descriptions 1.5 to 3.2 times. A month name reads faster from
a layout (16.2 ns) than from any Rust parser. From Python, ciso8601 and
`fromisoformat` take 18 to 45 ns where a layout takes 850 ns, nearly all of
it the binding (below); the layout is still 1.6 to 3.4 times as fast as
`strptime`.

**Working the format out.** Against Rust's dateparser, through the C
interface, dateparsa takes 0.22 to 0.77 of its time on a SQL date-time, a
date, a US date and a month name, and reads the compact form dateparser
refuses. It takes 2.9 to 3.6 times as long on RFC 3339 and 8 times on RFC
2822: dateparser tries chrono's RFC 2822 and RFC 3339 parsers before any of
its patterns, so those are its fastest inputs, and dateparsa's slowest
structured input is RFC 2822. From Python, dateutil's `parse` takes 1.8 to
4.7 times as long as dateparsa's, and dateparser 52 to 236 times. pandas
without `format=` is the exception: it infers a column's format from its
first value and reads the rest in compiled code, 81 ns a value of RFC 3339
and 330 ns of US dates, where dateparsa's `Parser` through Python takes 2.87
and 3.00 µs.

**The Python binding.** A parse takes 3.4 µs from Python, 87 ns from Rust
through the same C interface and 61 ns from Zig, so over 97% of the Python
figure is the binding: the ctypes structs and the result objects it builds
on every call.

**The C interface.** In the same run, a reused layout costs 2 to 3 ns more
called from Rust than from Zig, and a parse 24 to 45 ns more.

**A non-date.** A parser told the format turns one down within its first few
bytes, in 1.6 to 23 ns. dateparsa takes 143 to 172 ns, because it has tried
every structured format, a Unix timestamp and natural language before it
says no; dateparser takes 124 ns and dateutil 5.4 µs.

**Allocations.** The Rust parsers allocate nothing when they read a date
either, apart from dateparser on a month name, three times a parse; jiff and
dateparser allocate twice to refuse one. So allocating
nothing is not what sets dateparsa apart from them: working the format out
without allocating is. dateparsa allocates on no path, a refusal included,
and the shared library shows it: it imports `bzero`, `memcpy` and `memset`,
and `dyld_stub_binder` is the dynamic loader's own. On macOS every system
call goes through libSystem, so a library that imports none cannot ask the
system for memory. On Linux Zig makes system calls without libc, and `nm`
there cannot show the same.

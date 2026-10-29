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

Go v0.2.0 (go1.26.4) against dateparsa.zig with email and HTTP dates read
by their shape (Zig 0.17.0)  
Apple M5 Max, Darwin arm64, 2026-10-29, 10 rounds of 350ms runs  
Load averages at the start 8.35 7.97 7.59, at the end 7.13 7.86 7.75  

| Benchmark | Go ns/op | Zig ns/op | Zig / Go | middle range |
|---|--:|--:|--:|--:|
| Parse_ISO8601 | 48.7 | 25.8 | 0.53 | 0.51 to 0.54 |
| Parse_ISO8601_DateTime | 66.3 | 39.0 | 0.59 | 0.57 to 0.64 |
| Parse_RFC3339 | 76.4 | 54.1 | 0.72 | 0.66 to 0.83 |
| Parse_SQLDatetime | 64.2 | 37.9 | 0.59 | 0.57 to 0.60 |
| Parse_TextualMonth | 255 | 130 | 0.51 | 0.49 to 0.51 |
| Parse_RFC2822_Locales | 795 | 77.1 | 0.10 | 0.09 to 0.10 |
| Parse_AmbiguousSlash | 152 | 72.3 | 0.48 | 0.44 to 0.48 |
| Parse_Miss_Short | 220 | 44.7 | 0.20 | 0.19 to 0.21 |
| Parse_Miss_Text | 289 | 152 | 0.52 | 0.51 to 0.56 |
| Parse_Miss_Long | 1104 | 508 | 0.46 | 0.43 to 0.49 |
| Parse_Miss_Locales | 1009 | 757 | 0.77 | 0.71 to 0.79 |
| Parse_Miss_Locales_NonLatin | 1236 | 887 | 0.71 | 0.68 to 0.73 |
| Layout_Parse | 15.4 | 10.2 | 0.68 | 0.65 to 0.69 |
| Layout_Parse_ISODate | 11.2 | 7.6 | 0.69 | 0.67 to 0.70 |
| Layout_Parse_TextualMonth | 23.3 | 13.5 | 0.58 | 0.57 to 0.61 |
| Detect_Only | 48.8 | 43.5 | 0.87 | 0.82 to 0.94 |
| Detect_TrieMiss_Fallback | 226 | 133 | 0.59 | 0.58 to 0.61 |
| Detect_NoMatch | 105 | 151 | 1.45 | 1.39 to 1.47 |
| Parser_Cached | 16.8 | 16.4 | 0.98 | 0.95 to 1.06 |
| 10M_Layout_Parse | 152.1 ms | 104.3 ms | 0.69 | 0.67 to 0.72 |
| 10M_Parser_ParseColumn | 198.2 ms | 166.9 ms | 0.83 | 0.80 to 0.92 |
| Layout_Parse_TZName_CET | 17.9 | 14.7 | 0.82 | 0.78 to 0.89 |
| Layout_Parse_TZOffset_OffGrid | 20.6 | 13.4 | 0.65 | 0.62 to 0.67 |
| Layout_Parse_TZOffset_OnGrid | 20.1 | 13.5 | 0.67 | 0.64 to 0.69 |
| Parse_Compact | 42.5 | 24.8 | 0.58 | 0.57 to 0.59 |
| Parse_CompactDateTime | 59.1 | 36.1 | 0.61 | 0.56 to 0.63 |
| Parse_UnixTimestamp | 58.2 | 30.2 | 0.52 | 0.50 to 0.55 |
| Parse_ISOWeekDate | 172 | 70.3 | 0.41 | 0.37 to 0.43 |
| Parse_ISOOrdinal | 108 | 60.0 | 0.55 | 0.48 to 0.58 |
| Parse_TimeAMPM | 126 | 63.1 | 0.50 | 0.45 to 0.52 |
| Parse_SQLFrac6 | 78.7 | 52.7 | 0.68 | 0.64 to 0.78 |
| Layout_Parse_Compact | 10.5 | 7.4 | 0.70 | 0.69 to 0.72 |
| Parse_NL_Yesterday | 231 | 74.7 | 0.33 | 0.30 to 0.35 |
| Parse_NL_3DaysAgo | 255 | 112 | 0.44 | 0.40 to 0.46 |
| Parse_NL_NextFriday | 268 | 104 | 0.39 | 0.36 to 0.43 |
| Parse_NL_YesterdayAt5pm | 291 | 127 | 0.42 | 0.38 to 0.46 |
| Parse_NL_BeginningOfMonth | 245 | 96.8 | 0.39 | 0.36 to 0.40 |
| Parse_NL_In10Minutes | 239 | 102 | 0.43 | 0.39 to 0.46 |
| Parse_Locale_FrenchMonth | 277 | 137 | 0.50 | 0.44 to 0.51 |
| Parse_Locale_FrenchNL | 326 | 138 | 0.44 | 0.40 to 0.45 |
| Parse_Locale_GermanMonth | 288 | 138 | 0.48 | 0.47 to 0.49 |
| Parse_Locale_RussianNL | 774 | 399 | 0.51 | 0.48 to 0.53 |

**Faster than Go on every row but one:** the first parse of every
structured format (0.41 to 0.72 of Go's time: ISO 8601 and RFC 3339, SQL,
compact, ISO week and ordinal dates, an ambiguous numeric date, a Unix
timestamp, a time with AM or PM), textual dates with or without locales
(0.48 to 0.51, and an RFC 2822 date 0.10), natural language (0.33 to 0.51,
English, French and Russian alike), misses (0.20 to 0.77), and reusing a
layout (0.58 to 0.82, the ten million row column included).

**Not comparable:** `Detect_Only` and `Detect_NoMatch`, the one row above 1.
Go's `Detect` stops after structured detection; this port's is a whole
parse, and on a miss that includes natural language. `Parse_Miss_Text` is
the like-for-like miss.

## Changes measured with this harness

The first table, in the commit that added this file (82a9edd), had natural
language at 1.4 to 1.9 times Go, misses up to 2.2 and a textual date with
three locales at 3.2, and the second had the first parse of ISO and SQL
date-times and compact dates at 0.88 to 1.05 and RFC 2822 at 0.62. Four
changes account for the
difference: the first came from reading how Go finds month names, the
second from profiling the slowest row with `sample`, the third and fourth
from timing detection's stages one by one, and `tools/oracle.sh` showed
none of them changed an answer. Ratios are Zig / Go, before and after.

| Change | Rows it moved |
|---|---|
| Month names found from a word list, Go's `wordMatcher`, rather than scanning the input once per spelling (2663658) | textual date with locales 3.19 to 0.65; English natural language 1.41-1.89 to 0.98-1.11; `Miss_Text` 1.68 to 1.05; French and German months 1.08 to 0.54 |
| Natural-language tokens filled in place rather than returned by value, several kilobytes copied per scan (73880c4) | English natural language 0.98-1.11 to 0.33-0.44; French 1.50 to 0.41; Russian 0.98 to 0.49; misses 0.93-1.20 to 0.19-0.76 |
| A trie format handed back by its index rather than in a copied 168-byte Def, which detection and parse then copied again on the way up; a CJK date looked for only when 年 is the fifth byte | ISO dates 0.91 to 0.54; ISO and SQL date-times 0.94 to 0.61 and 0.54; RFC 3339 1.05 to 0.62; compact dates 1.05 and 0.88 to 0.58 and 0.57; a fraction 1.03 to 0.66; a Unix timestamp 0.63 to 0.51; `Detect_Only` 1.31 to 0.83 |
| Email and HTTP dates read by their shape, with each shape's fields and a layout a month built at comptime, rather than by the textual detector's search; and the gaps between a textual date's fields covered by a merge rather than a sort | RFC 2822 with three locales 0.62 to 0.10 |

Not done, and not needed by any row here: the per-format comptime fast path
and Go's day-count table in front of `daysFromCivil` (the reuse rows are
already 0.58 to 0.82), and bucketing locale words by first byte
(`Miss_Locales` is 0.76).

Tried and left out: the signature scan a vector at a time, 64 lanes at
once, or 16 with each lane's neighbours loaded rather than shuffled in. On
its own the 16-lane scan classified `2024-03-15T10:30:00Z` in 9.4 ns where
the scalar scan takes 11.0, and RFC 2822 in 9.2 against 17.2, but inside
`parse` either one made ISO and SQL date-times 1.4 to 1.7 times as slow, for
a reason not yet found. The scan is a quarter of an ISO date-time's parse
now, so the most it could save is a few nanoseconds.

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

Zig, from a run after detection stopped copying a format's definition and
began reading email and HTTP dates by their shape:

dateparsa.zig with both changes (Zig 0.17.0)  
Apple M5 Max, Darwin arm64, 2026-10-29, 10 rounds of 200ms runs  
Load averages at the start 7.13 7.86 7.75, at the end 10.50 8.35 7.93  

zeit 0.10.0 (06bb7b4):

| Input | dateparsa parse | dateparsa layout | zeit |
|---|--:|--:|--:|
| `2024-03-15T10:30:00Z` | 37.4 ns | 10.2 ns | 14.2 ns |
| `2024-03-15T10:30:00+05:30` | 55.2 ns | 12.4 ns | 16.8 ns |
| `2024-03-15T10:30:00.123456789Z` | 50.6 ns | 13.2 ns | 22.8 ns |
| `2024-03-15 10:30:00` | 39.2 ns | 9.5 ns | 13.6 ns |
| `2024-03-15` | 27.2 ns | 7.6 ns | 9.5 ns |
| `20240315T103000Z` | 31.4 ns | 9.6 ns | 14.0 ns |
| `Fri, 15 Mar 2024 10:30:00 +0000` | 77.9 ns | 25.2 ns | 18.2 ns |
| `03/15/2024` | 68.4 ns | no | no |
| `March 15, 2024` | 127 ns | 13.4 ns | no |
| `not a date at all` | 139 ns | no | 4.5 ns |

Rust, from the first run, before both changes: its dateparsa parse column
took about 0.6 of these times after the first, as the Zig one did, and an
RFC 2822 date about a quarter after the second; the other columns did not
move.

dateparsa.zig c1e122b with these harnesses added, no library code changed (Zig 0.17.0)  
Apple M5 Max, Darwin arm64, 2026-10-29, 10 rounds of 200ms runs  
Load averages at the start 10.17 9.99 9.70, at the end 6.82 10.24 10.19  

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

Python, from a later run on the same machine, after the binding was cut
down and `parse_column` added (see
[Changes measured](#changes-measured-with-these-harnesses) for the first
run's Python figures):

dateparsa.zig with `parse_column` (Zig 0.17.0)  
Apple M5 Max, Darwin arm64, 2026-10-29, 10 rounds of 200ms runs  
Load averages at the start 3.46 5.44 7.32, at the end 4.71 4.88 6.62  

ciso8601 2.3.3, dateparser 1.4.3, pandas 3.1.0, python-dateutil 3.0.0
(Python 3.13.16), one value at a time:

| Input | dateparsa parse | dateparsa layout | fromisoformat | strptime | ciso8601 | dateutil isoparse | dateutil parse | dateparser |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| `2024-03-15T10:30:00Z` | 983 ns | 504 ns | 27.0 ns | 2.16 µs | 20.8 ns | 1.45 µs | 10.66 µs | 656.86 µs |
| `2024-03-15T10:30:00+05:30` | 1.02 µs | 511 ns | 44.0 ns | 2.56 µs | 21.5 ns | 1.98 µs | 12.13 µs | 511.38 µs |
| `2024-03-15T10:30:00.123456789Z` | 1.05 µs | 511 ns | 31.6 ns | refuses | 22.6 ns | 1.83 µs | 11.94 µs | 769.86 µs |
| `2024-03-15 10:30:00` | 1.02 µs | 511 ns | 25.5 ns | 1.76 µs | 19.6 ns | 1.28 µs | 9.34 µs | 401.73 µs |
| `2024-03-15` | 965 ns | 506 ns | 20.7 ns | 1.31 µs | 18.1 ns | 491 ns | 5.80 µs | 326.15 µs |
| `20240315T103000Z` | 1.03 µs | 511 ns | 26.4 ns | 2.17 µs | 21.5 ns | 1.41 µs | 7.93 µs | refuses |
| `Fri, 15 Mar 2024 10:30:00 +0000` | 1.34 µs | 518 ns | no | 2.77 µs | no | no | 17.14 µs | 664.30 µs |
| `03/15/2024` | 1.02 µs | no | no | 1.35 µs | no | no | 5.84 µs | 298.88 µs |
| `March 15, 2024` | 1.09 µs | 502 ns | no | 1.42 µs | no | no | 9.59 µs | 393.71 µs |
| `3 days ago` | 1.47 µs | no | no | no | no | no | refuses | 203.91 µs |
| `not a date at all` | 1.41 µs | no | 140 ns | 952 ns | 190 ns | 1.04 µs | 5.21 µs | 125.72 µs |

Python, a column of 10,000 different values, per value. `parse_column`
reads the column in one call into the library, then builds a datetime for
each value or a numpy `datetime64[ns]` array. dateparser is left out: at
about a millisecond a value, a loop over the column says what its row above
says.

| Input | dateparsa Parser | dateparsa layout | parse_column datetimes | parse_column datetime64 | fromisoformat | strptime | ciso8601 | dateutil parse | pandas | pandas format= |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| RFC 3339, `2000-01-01T00:00:00Z` on by minutes | 1.12 µs | 531 ns | 169 ns | 32.9 ns | 28.4 ns | 1.83 µs | 22.8 ns | 11.03 µs | 78.2 ns | 484 ns |
| US dates, `01/01/2000` on by days | 1.28 µs | no | 238 ns | 100 ns | no | 1.36 µs | no | 6.02 µs | 329 ns | 321 ns |

What the shared library imports, `nm -u`:

    _bzero
    _memcpy
    _memset
    dyld_stub_binder

### Reading the numbers

The load average stayed near 8 to 10 through the Zig and Rust runs, and near 4
through the Python one. A cell is good to 10 to 20%, and a difference
smaller than that is not a result.

**Told the format.** In Zig, a reused layout reads every ISO 8601 and RFC
3339 form in 0.58 to 0.80 of zeit's time, and RFC 5322 in 1.38 of it. In
Rust, through the C interface, the fastest parser of each ISO 8601, RFC
3339 and RFC 2822 form (time, speedate or jiff) takes 0.37 to 0.86 of a
layout's time. Parsers that follow a format string at run time take longer
than a layout: chrono's `parse_from_str` 2.8 to 6.3 times as long, and
time's format descriptions 1.5 to 3.2 times. A month name reads faster from
a layout (16.2 ns) than from any Rust parser. From Python, ciso8601 and
`fromisoformat` take 18 to 44 ns where a layout takes 502 to 518 ns, most
of it the binding (below), and the layout is 2.6 to 5.3 times as fast as
`strptime`.

**Working the format out.** Against Rust's dateparser, through the C
interface, dateparsa takes 0.22 to 0.77 of its time on a SQL date-time, a
date, a US date and a month name, and reads the compact form dateparser
refuses. It takes 2.9 to 3.6 times as long on RFC 3339 and 8 times on RFC
2822: dateparser tries chrono's RFC 2822 and RFC 3339 parsers before any of
its patterns, so those are its fastest inputs, and in that run RFC 2822 was
dateparsa's slowest structured input. The Zig table's 78 ns since, plus
the C interface's 24 to 45, would put dateparsa at about twice dateparser's
time on RFC 2822, though the Rust run has not been repeated to show it. From Python, dateutil's `parse` takes 5.7 to
12.8 times as long as dateparsa's on a date, and dateparser 139 to 733
times, and dateparsa working the format out is 1.3 to 2.5 times as fast as
`strptime` told it.

**A column from Python.** pandas without `format=` infers a column's format
from its first value and reads the rest in compiled code: 78.2 ns a value of
RFC 3339 and 329 ns of US dates, where a `Parser` called once a value takes
1.12 and 1.28 µs. `parse_column` reads the column in one call into the
library instead, and into a numpy `datetime64[ns]` array takes 32.9 and 100
ns a value: 0.42 and 0.30 of pandas' time working the format out, and less
than pandas told it (484 and 321 ns). Building a datetime for each value
instead takes 169 and 238 ns. `fromisoformat` and ciso8601 in a loop are a
little faster than the numpy path, 23 to 28 ns, on the one format they read.

**The Python binding.** A parse took 983 ns from Python and 87 ns from
Rust through the same C interface, both before detection's change, so the
binding was over 90% of the Python figure: a ctypes call alone costs about a quarter of
a microsecond, and the Python objects a result is made of most of the rest.
It was 3.4 µs, and slower than `strptime`, before the change below.

**The C interface.** In the first run, before detection's change, a reused
layout cost 2 to 3 ns more called from Rust than from Zig, and a parse 24
to 45 ns more.

**A non-date.** A parser told the format turns one down within its first few
bytes, in 1.6 to 23 ns. dateparsa takes 139 ns, because it has tried
every structured format, a Unix timestamp and natural language before it
says no; dateparser takes 124 ns and dateutil 5.2 µs.

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

### Changes measured with these harnesses

| Change | Rows it moved, Python |
|---|---|
| The binding does less per call: the default options go as NULL and others are built once and shared, a result's fields come out of one `struct` unpack, `Time` and `Result` are built without the dataclass `__init__`, and a result's layout is a view of it rather than a copy and two more C calls | `parse` 3.38-4.13 µs to 1.07-1.64; a layout 847-885 ns to 555-592; `Parser` down a column 2.87-3.00 µs to 1.28-1.49; a non-date 1.75 µs to 1.57 |
| `parse_column`: a column in one call into the library, through the C interface's `dateparsa_parse_column` | Down a 10,000-value column, against a `Parser` once a value in the same run: RFC 3339 1.12 µs a value to 169 ns as datetimes and 32.9 ns into numpy; US dates 1.28 µs to 238 and 100 ns |

The binding's row compares two runs, both on this machine with load
averages near 10: the first run's Python figures are the left side of each
pair, and `strptime`, which did not change, took 5 to 9% longer in the
second, so the machine was if anything slower for it. The Python tables
above are a third run, quieter, after both changes.

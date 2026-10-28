# Performance

How fast this port is, measured against the Go dateparsa it was ported from,
on one machine, by the Go library's own benchmarks.

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

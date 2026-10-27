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

Go v0.2.0 (go1.26.4) against dateparsa.zig 08911e7, library as committed, harness not yet (Zig 0.17.0)  
Apple M5 Max, Darwin arm64, 2026-10-27, 10 rounds of 350ms runs  
Load averages at the start 8.03 8.71 8.90, at the end 7.87 8.66 8.69  

| Benchmark | Go ns/op | Zig ns/op | Zig / Go | middle range |
|---|--:|--:|--:|--:|
| Parse_ISO8601 | 48.4 | 41.2 | 0.86 | 0.83 to 0.87 |
| Parse_ISO8601_DateTime | 66.0 | 64.6 | 0.98 | 0.94 to 1.01 |
| Parse_RFC3339 | 76.2 | 88.2 | 1.15 | 1.11 to 1.22 |
| Parse_SQLDatetime | 64.0 | 60.9 | 0.94 | 0.89 to 0.99 |
| Parse_TextualMonth | 267 | 168 | 0.63 | 0.61 to 0.66 |
| Parse_RFC2822_Locales | 802 | 2558 | 3.19 | 3.06 to 3.22 |
| Parse_AmbiguousSlash | 153 | 83.7 | 0.54 | 0.49 to 0.57 |
| Parse_Miss_Short | 227 | 205 | 0.91 | 0.88 to 0.97 |
| Parse_Miss_Text | 288 | 487 | 1.68 | 1.62 to 1.75 |
| Parse_Miss_Long | 1054 | 1397 | 1.32 | 1.22 to 1.38 |
| Parse_Miss_Locales | 966 | 2137 | 2.20 (wide) | 2.05 to 2.29 |
| Parse_Miss_Locales_NonLatin | 1246 | 1768 | 1.38 | 1.31 to 1.44 |
| Layout_Parse | 15.3 | 10.3 | 0.68 | 0.66 to 0.70 |
| Layout_Parse_ISODate | 11.1 | 7.5 | 0.68 | 0.66 to 0.71 |
| Layout_Parse_TextualMonth | 23.3 | 13.6 | 0.59 | 0.57 to 0.59 |
| Detect_Only | 48.7 | 63.0 | 1.30 | 1.26 to 1.35 |
| Detect_TrieMiss_Fallback | 223 | 171 | 0.77 | 0.70 to 0.80 |
| Detect_NoMatch | 106 | 488 | 4.58 (wide) | 4.13 to 4.82 |
| Parser_Cached | 16.9 | 15.3 | 0.90 | 0.90 to 0.92 |
| 10M_Layout_Parse | 148.1 ms | 103.8 ms | 0.70 | 0.69 to 0.72 |
| 10M_Parser_ParseColumn | 191.9 ms | 161.5 ms | 0.83 | 0.79 to 0.85 |
| Layout_Parse_TZName_CET | 17.7 | 14.5 | 0.82 | 0.80 to 0.82 |
| Layout_Parse_TZOffset_OffGrid | 20.0 | 12.6 | 0.63 | 0.63 to 0.64 |
| Layout_Parse_TZOffset_OnGrid | 19.6 | 12.7 | 0.65 | 0.64 to 0.66 |
| Parse_Compact | 41.6 | 39.4 | 0.95 | 0.94 to 0.96 |
| Parse_CompactDateTime | 57.0 | 48.2 | 0.84 | 0.83 to 0.90 |
| Parse_UnixTimestamp | 57.5 | 36.3 | 0.64 | 0.62 to 0.65 |
| Parse_ISOWeekDate | 165 | 76.7 | 0.46 | 0.41 to 0.48 |
| Parse_ISOOrdinal | 103 | 66.8 | 0.63 | 0.58 to 0.66 |
| Parse_TimeAMPM | 122 | 70.4 | 0.57 | 0.52 to 0.60 |
| Parse_SQLFrac6 | 75.3 | 86.6 | 1.15 | 1.06 to 1.21 |
| Layout_Parse_Compact | 10.6 | 7.2 | 0.70 | 0.68 to 0.72 |
| Parse_NL_Yesterday | 208 | 296 | 1.41 (wide) | 1.22 to 1.47 |
| Parse_NL_3DaysAgo | 241 | 344 | 1.43 | 1.34 to 1.50 |
| Parse_NL_NextFriday | 249 | 352 | 1.41 (wide) | 1.32 to 1.57 |
| Parse_NL_YesterdayAt5pm | 277 | 468 | 1.67 | 1.52 to 1.71 |
| Parse_NL_BeginningOfMonth | 244 | 457 | 1.89 | 1.75 to 1.95 |
| Parse_NL_In10Minutes | 236 | 386 | 1.67 (wide) | 1.48 to 1.75 |
| Parse_Locale_FrenchMonth | 270 | 291 | 1.08 | 0.98 to 1.13 |
| Parse_Locale_FrenchNL | 324 | 484 | 1.49 (wide) | 1.38 to 1.59 |
| Parse_Locale_GermanMonth | 282 | 307 | 1.07 | 0.97 to 1.11 |
| Parse_Locale_RussianNL | 752 | 1173 | 1.56 | 1.41 to 1.60 |

**Faster than Go:** reusing a layout (0.6 to 0.8 of Go's time, the ten
million row column included), and the first parse of most structured
formats: a textual month, an ambiguous numeric date, an ISO week date, a
Unix timestamp, a time with AM or PM.

**About even:** an ISO date-time with `Z`, SQL date-times, compact dates,
the short miss, and a month name in a configured locale.

**Slower:** everything that reaches natural language, which every miss does
on its way to failing: 1.4 to 1.9 times Go for an English expression, about
1.5 for one in a locale. Misses cost 1.3 to 2.2 times Go, and a textual
date with locales configured 3.2 times. Two first parses with a zone
offset or a fraction (`Parse_RFC3339`, `Parse_SQLFrac6`) are 1.15.

**Not comparable:** `Detect_Only` and `Detect_NoMatch`. Go's `Detect` stops
after structured detection; this port's is a whole parse, and on a miss
that includes natural language. `Parse_Miss_Text` is the like-for-like miss.

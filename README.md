<div align="center">

# dateparsa.zig

**Date parsing for input whose format you do not control.**

CSV imports, log lines, third-party APIs, user-typed strings: dateparsa works out
the format, parses the value, and hands you a compiled layout that reads the
rest of the column with no detection and no allocation.

[![Zig 0.17.0](https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![Allocations: none](https://img.shields.io/badge/allocations-none-2ea44f)](#design)
[![Locales: 20](https://img.shields.io/badge/locales-20-8a2be2)](#locales)
[![Matches Go on 158,631 answers](https://img.shields.io/badge/matches%20Go-158%2C631%20answers-2ea44f)](#how-its-checked)

</div>

```zig
const dateparsa = @import("dateparsa");

const r = try dateparsa.parse("2024-03-15T10:30:00Z");
// r.time        2024-03-15 10:30:00 +00:00
// r.layout      ISO8601_DATETIME_Z, ready to reuse on the next row
// r.ambiguous   false
```

A Zig port of [dateparsa](https://github.com/kmoneil/dateparsa) for Go, and
checked against it: every row of its golden corpus and more than 150,000
generated cases give the same answer here, byte for byte. Where the Zig version
does something differently, it is on purpose and [listed below](#differences-from-the-go-original).

## Why dateparsa

- **Detect once, parse millions.** Detection and parsing are separate problems.
  `parse` detects the format and returns a `Layout`; `layout.parse(row)` reads
  every following row with no detection at all.
- **Nothing allocates.** No function takes an allocator, because none needs one.
  Every input is bounded, so fixed buffers cover every path, not just the hot
  one.
- **Nothing reads a clock.** "3 days ago" is relative to the base time you pass,
  and an input that needs one fails with `error.NoBaseTime` rather than quietly
  using now.
- **Ambiguity is reported, never hidden.** `01/02/2024` is a guess, and the
  result says so. Strict mode refuses the guess and hands you every reading.
- **Built at comptime.** The detection trie, the 32 structured formats, the
  locale tables and the shared layouts are compile-time data in read-only
  memory: no init step, no startup cost.
- **20 locales, chosen at build time.** Month names and relative expressions in
  twenty languages. Leave out the ones you do not need with `-Dlocales`.

## Install

```sh
zig fetch --save git+https://github.com/kmoneil/dateparsa.zig
```

Then in `build.zig`:

```zig
const dateparsa = b.dependency("dateparsa", .{
    .target = target,
    .optimize = optimize,
    // .locales = "fr,de",   // optional: compile in only these, English always
});
exe.root_module.addImport("dateparsa", dateparsa.module("dateparsa"));
```

Requires Zig 0.17.0.

## How it works

```mermaid
flowchart LR
    in([input]) --> trim[trim surrounding<br/>ASCII whitespace]
    trim --> s{structured<br/>format?}
    s -- "trie, textual,<br/>numeric, ISO..." --> layout[DateTime +<br/>reusable Layout]
    s -- no --> e{Unix<br/>timestamp?}
    e -- yes --> utc[DateTime in UTC]
    e -- no --> nl{natural<br/>language?}
    nl -- yes --> rel[DateTime relative<br/>to base_time]
    nl -- no --> err([error.NoMatch])
```

Structured detection starts with a one-pass scan that turns each byte into a
character class (`2024-03-15` becomes `DDDDSDDSDD`) and walks a comptime trie of
those signatures. What the trie cannot hold, such as month names, variable-width
numbers and fractions of any length, falls to dedicated detectors. The
format found compiles to a short instruction program, and a program whose fields
sit at fixed offsets runs as straight-line code after a single length check.

## Usage

### Reuse the detected layout

```zig
const first = try dateparsa.parse(rows[0]);
if (first.layout.reusable()) {
    for (rows[1..]) |row| {
        const t = try first.layout.parse(row); // no detection, no allocation
        // ...
    }
}
```

`reusable()` is false for two kinds of result. A Unix timestamp and "3 days ago"
have no format to reuse, so they carry layouts that refuse to re-parse. And a
format whose reading is decided per value, such as `25/12/2024` against
`01/02/2024`, still parses the next row but reads it the first row's way, so it
says it should not be cached.

What a reused layout tolerates, and what it does not:

| Row 1 | Row *n* | |
|---|---|---|
| `2024-03-15` | ` 2024-03-16\r\n` | padding is trimmed, as detection trimmed it |
| `1 May 2024` | `12 May 2024` | a one-digit day widens to two |
| `12 May 2024` | `1 May 2024` | refused: a two-digit day never narrows |
| `Fri, 15 Mar 2024 10:30:00 +0000` | `Sat, 16 Mar 2024 11:30:00 -0700` | a skipped weekday takes any letters of its width |
| `March 15, 2024` | `March 16; 2024` | refused: other skipped bytes must match |
| `March 15, 2024` | `April 16, 2024` | refused: the month is checked, never assumed |

### Parse a column

`Parser` caches the first value's layout and re-detects any value the layout
cannot answer, so the result is always what `parse` would say; only the cost
differs.

```zig
var p = dateparsa.Parser.init(.{});
for (column) |value| {
    const r = try p.parse(value); // detects once, re-detects when the format changes
    // ...
}
```

### Ambiguity

```zig
const r = try dateparsa.parse("01/02/2024");
// r.ambiguous == true: read as January 2nd, and that was a guess

const eu = try dateparsa.parseWith("01/02/2024", .{ .prefer_day_first = true });
// February 1st

var diag: dateparsa.Diagnostics = .{};
const strict = dateparsa.parseWith("01/02/2024", .{ .strict = true, .diagnostics = &diag });
// error.Ambiguous, and diag.slice() holds both readings:
//   "MM/DD/YYYY"  2024-01-02
//   "DD/MM/YYYY"  2024-02-01
```

The rules, in order:

1. **Where the year sits.** A part over 31 or of four digits is the year. A
   leading year settles the rest (`70/01/02` is 2 January 1970), because nothing
   writes `YY/DD/MM`.
2. **Value range.** A part over 12 is the day: `13/01/2024` is unambiguous.
3. **Separator.** A dot means day first: `03.02.2024` is 3 February.
4. **Preference.** `prefer_day_first`, and `prefer_year_first` for three small
   parts (`01/02/03` is 2001-02-03 with it).
5. **Report.** Whatever a preference decided is flagged `ambiguous`.

Three small parts have three readings (`01/02/03`), and a trailing two-digit
year can also be a leading one: `31/12/24` is also 24 December 2031. A month
name beside a bare number asks the same kind of question: `March 15` is the
15th or March 2015, and `01MAY10` is 1 May 2010 or 10 May 2001. Strict mode
offers every reading that is a real date, the preferred one first.

### Natural language

```zig
const base: dateparsa.DateTime = .{ .year = 2024, .month = 3, .day = 15, .hour = 12 };

const r = try dateparsa.parseWith("next friday at 5pm", .{ .base_time = base });
// 2024-03-22 17:00:00, r.kind == .relative

// No base time means no guess at "now": the library never reads a clock.
_ = dateparsa.parse("3 days ago"); // error.NoBaseTime
```

`now`, `today`, `tonight`, `yesterday at 5pm`, `3 days ago`, `in 2 hours`,
`a week from now`, `2 days and 3 hours ago`, `half an hour ago`, `next friday`,
`last month`, `this morning`, `end of month`, `beginning of year`, `March 5`, and
their counterparts in each configured locale. Month and year arithmetic clamps
to the end of the month: one month before 2024-03-31 is 2024-02-29.

### Locales

```zig
const opts: dateparsa.Options = .{ .base_time = base, .locales = .{ .fr = true, .de = true } };
const fr = try dateparsa.parseWith("15 mars 2024", opts);
const de = try dateparsa.parseWith("vor 3 Tagen", opts);

// Or by BCP 47 tag, when the tag arrives at run time.
const es = dateparsa.localeSet("es-MX") orelse return error.NotCompiledIn;
const r = try dateparsa.parseWith("hace 2 horas", .{ .base_time = base, .locales = es });
```

Arabic, Chinese, Danish, Dutch, English, Finnish, French, German, Hindi,
Italian, Japanese, Korean, Norwegian, Polish, Portuguese, Russian, Spanish,
Swedish, Turkish and Ukrainian, generated from the Go library's CLDR-derived
tables. English is always read; the others are read when `Options.locales`
names them. Hindi कल means both yesterday and tomorrow, and the result says it
is ambiguous.

`-Dlocales=fr,de` compiles in only the locales named. The others' data never
reaches your binary, and a set naming one is a compile error rather than a
silent miss:

```
error: no field named 'es' in struct 'locale.LocaleSet__struct_...'
```

### Zones and timestamps

```zig
// An input that writes no zone is read at timezone_offset (seconds east).
const ist = try dateparsa.parseWith("2024-03-15 10:30:00", .{ .timezone_offset = 5 * 3600 + 30 * 60 });
const instant = ist.time.toEpoch(); // seconds since 1970-01-01T00:00:00Z

// Unix timestamps: the digit count is the precision.
const ms = try dateparsa.parse("1710504800123"); // milliseconds
```

Offsets are fixed: `Z`, `+05:30`, `-0800`, `+00`, and sixteen abbreviations
(`UTC`, `GMT`, `EST`, `CET` and so on) each read as the offset it names.

## Formats

| Family | Examples |
|---|---|
| ISO 8601 / RFC 3339 | `2024-03-15` · `2024-03-15T10:30:00Z` · `2024-03-15T10:30:00.123456+05:30` · `2024-W11-5` · `2024-074` · `2020-07-20+08:00` |
| SQL and logs | `2024-03-15 10:30:00` · `2024-03-15 10:30:00.000000` · `2024-03-15 10:30:00+00` · `2014-12-16 06:20:00 UTC` · `2014-05-11 08:20:13,787` |
| Compact | `20240315` · `20240315T103000Z` · `20240315103000` · `171113` |
| Numeric | `03/15/2024` · `15.03.2024` · `3/15/24` · `3/15/2024 10:30 PM` |
| Textual | `March 15, 2024` · `15 Mar 2024` · `December 23rd` · `March 2024` · `the 15th of March 2024` |
| RFC 2822, 850, ANSI C | `Fri, 15 Mar 2024 10:30:00 +0000` · `Friday, 15-Mar-24 10:30:00 UTC` · `Mon Jan 2 15:04:05 2006` |
| Elsewhere | `15/Mar/2024:10:30:00 +0000` (CLF) · `Fri Jul 03 2015 18:04:07 GMT+0100` (JavaScript) · `2015-02-08 03:02:00 +0300 MSK` (Go) · `2014:04:08 22:05:13` (EXIF) · `2014年04月08日` |
| Times | `10:30` · `10:30:00` · `10:30 PM` · `10:30:00.123` |
| Timestamps | `1710504800` · `1710504800123` · `1710504800123456` · `1710504800.123` |

A time with no date takes 1 January of the base time's year, and a date with no
time is midnight. Validation refuses rather than normalises: `2024-02-30` is
`error.NoMatch`, never 1 March.

## Design

- **No allocation.** No API takes an allocator. Inputs are bounded (a format
  addresses at most 510 bytes, a natural-language expression 512), so fixed
  buffers serve every path.
- **No hidden I/O.** The library reads no clock, file, environment or network.
- **Values, not pointers.** `Layout` and `DateTime` are plain values you can
  copy, store and compare.
- **Thread safety.** Everything is immutable except `Parser`'s cache: use one
  `Parser` per thread, or share layouts, which are read-only.
- **Comptime data.** Trie, formats, compiled layouts, locale tables and the
  Unicode case tables the natural-language scanner uses are all built at
  compile time.

## Differences from the Go original

Each is deliberate.

| Go | Zig |
|---|---|
| A missing base time means `time.Now()` | `error.NoBaseTime`, only for input some base time would read |
| `*time.Location` with daylight-saving rules | Fixed UTC offsets (`timezone_offset`), abbreviations as fixed offsets |
| `GoLayout()` and `Compile` from Go layout strings | Not ported: there is no `time.Parse` to interoperate with |
| `ParseColumn` | `Parser.parse` in your own loop |
| Error structs with formatted messages | An error set plus optional `Diagnostics`; no input bytes are copied |
| Natural-language readings labelled with their dates | Labelled `NATURAL_LANGUAGE`; the times tell them apart |
| A reused layout folds month names with Unicode case rules | ASCII case, as detection already does ([kmoneil/dateparsa#36](https://github.com/kmoneil/dateparsa/issues/36)) |
| All locales always linked | Chosen at build time with `-Dlocales` |

## How it's checked

| Check | What it covers |
|---|---|
| `zig build test` | The full suite, including every row of the Go library's golden corpus (`testdata/golden.txt`, 1,377 inputs) and every example in this README, format table included |
| `tools/oracle.sh` | Runs the Go library and this port side by side: 33,186 public-API answers under nine option sets, including a first row's layout reused on 3,522 other rows, and 124,068 natural-language answers across every locale. All identical. |
| Unicode tables | Lowercasing and word boundaries match Go's `unicode` package on all 1,114,112 code points |
| Deliberate breaks | Each feature's tests were run against seeded bugs, and every bug that could change an answer was caught |

Performance numbers will land with the benchmarks; until they are measured on a
named machine against the Go version, this README makes no speed claims.

## Development

```sh
zig build test          # unit, golden corpus and README tests
zig build fmt-check     # formatting
zig build vet           # zigvet, github.com/kmoneil/zigvet
zig build docs          # API documentation into zig-out/docs
zig build locales       # regenerate src/locale/ from the Go repository's tables
zig build unicode       # regenerate src/unicode_data.zig (needs go)
tools/oracle.sh         # diff against the Go library (needs go and a Go checkout)
```

## License

Apache-2.0, see [LICENSE](LICENSE). The locale data is derived from the Unicode
CLDR and carries the Unicode License v3, reproduced in [NOTICE](NOTICE).

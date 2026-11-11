# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
As in the Go library, a change to what any input parses to counts as breaking
even when no signature moves, because the caller's stored data is what records
the difference. Before 1.0 a breaking change is a minor bump.

## [Unreleased]

### Fixed

- `findFirst` and `findAll` with no `base_time` read a piece of a date
  that needs one as another date: in `Nov 18 10:00:05 host sshd[1]: ...`
  they found `Nov 18 10`, the 10th of November **2018**, and in
  `Mar 15 10:00` the 10th of March 2015, so every syslog line from the
  13th of a month on gave a date years off. A date that needs a base time
  the options lack is now passed over whole: no shorter span at its start
  is taken, and the search goes on after it, so with no base time a date
  is found where it is with one, or nothing is. Found by pawl-cli.
- `15 Mar 10:00`, a day, a month name and a time with no year, found no
  format: the time was looked for straight after the day and met the
  month. It reads now as `Mar 15 10:00` does, the base year's 15th of
  March at 10:00, with the same day-or-year question; before, `findFirst`
  took `15 Mar 10` from it, 15 March 2010, with a base time or without.
  This changes what that input parses to. The Go library refuses it
  (kmoneil/dateparsa#44).

## [0.9.0] - 2026-11-11

A found or detected layout now follows a log through its days and months:
syslog's `Nov  8` reads `Nov 10`, and a month name reads any month written
the same way, so `Nov 30 23:59:59` reads `Dec  1 00:00:00` and the common
log format's `30/Nov` reads `01/Dec`. What every input parses to alone is
unchanged. What a reused layout answers is not: it now reads rows it
refused, through the library, its C interface and the Python package
alike, so this is a minor release.

### Changed

- A layout with a month name reads any month written in the same form,
  so a log's layout follows it into the next month: the layout of
  `Nov 30 23:59:59` reads `Dec  1 00:00:00`, and the common log format's
  `30/Nov/2024` reads `01/Dec/2024`. An abbreviation reads any
  abbreviation (`Mar` reads `Sep` and `Sept`), a full name any full name
  (`March` reads `April`), and a name that is both, as `May` is, either,
  in the locales detection searched. It read only the month it was
  detected from before, as the Go library's still does
  (kmoneil/dateparsa#43); a month written with a digit (`11월`) still
  does. `Layout.find`, `Layout.parse` and a `Parser`'s cached layout
  read those rows; what every input parses to alone is unchanged.
- For the month change, a two-digit day after a month name and a space
  with a time after it (`Nov 30 23:59:59`, `Fri Nov 29 23:59:59 2024`)
  reads as a day padded with a space too, so it reads `Dec  1`. Its Go
  layout becomes `Jan _2` and its Java pattern `MMM ppd`; strftime keeps
  `%d`. `Mar 15, 2024` keeps a two-digit day.

- A layout from a day padded with a space, as syslog and asctime write a
  day under 10 (`Nov  8 10:00:05`, `Fri Nov  8 10:00:05 2024`), now reads
  the days from the 10th on (`Nov 10 23:59:59`). It read the two spaces
  as text and refused every two-digit day, so `Layout.find` lost a syslog
  log on the 10th of the month. The day reads as a space and a digit or
  two digits, after a month name and two spaces. What every input parses
  to is unchanged. Its Go layout is now `Jan _2 15:04:05` and its Java
  pattern `MMM ppd HH:mm:ss`, which read the whole month; its strftime
  format stays `%b  %d %H:%M:%S`, since Python's `strptime` has no `%e`
  before 3.13.x. The Go library refuses these days too
  (kmoneil/dateparsa#42).

## [0.8.0] - 2026-11-11

Dates are found inside text, times with a one-digit hour and dotted dates
with a time read, and an hour with am or pm is no longer read as a day.
The last three change what those inputs parse to, through the library,
its C interface and the Python package alike, so this is a minor release.
Finding dates is in the Zig API only for now.

### Added

- Dates inside text. `findFirst` finds the first date in a log line or a
  sentence and says where it is (`Match.start`, `Match.end`) and what it
  reads as; `findAll` finds every one into a buffer the caller gives; and
  `Layout.find` finds a found layout's format on the next lines of a log
  with no detection. By default only structured dates with a separator or
  a word in them are found; `FindAlso.natural` adds natural language and
  `FindAlso.numbers` lone numbers (a bare year, a compact date, a Unix
  timestamp). Nothing allocates. The C interface and the Python package do
  not have it yet.
- A time with a one-digit hour: `1:30 PM`, `9:05 am`, `9:30`,
  `3/15/2024 1:30 PM`, `2024-03-15 1:30:00`, `March 15, 2024 1:30 PM`.
  Each reads as its zero-padded form does, under the same label, and its
  layout reads a one- or two-digit hour down a column. Each was refused
  before, as the Go library still refuses them (kmoneil/dateparsa#38), so
  this changes what those inputs parse to; every input that read before
  reads as it did. An hour straight after ISO 8601's `T` still takes two
  digits.
- A dotted date with a time: `15.03.2024 10:30`, `15.03.2024 10:30:00`,
  `15.03.2024 1:30 PM`. Each reads day first, as `15.03.2024` does, with
  the same guess for `01.02.2024 10:30` as for `01.02.2024`. Refused
  before, as the Go library still refuses them (kmoneil/dateparsa#37). A
  dotted date reads with a time only in the shape it reads in alone,
  DD.DD.YYYY, so `1.2.3 10:30` is still no date.

### Fixed

- An hour with am or pm after it is never a day or a year. `at 3pm, was
  March` read as 3 March, and `5pm March 15` as 5 March 2015; both are now
  refused, as `at noon, was March` was. The Go library reads them as it
  did. A time with minutes (`10:30 PM`) and an ordinal (`March 3rd`) read
  as before.

## [0.7.0] - 2026-11-11

A time alone reads on the base time's day, not on 1 January. That changes
what those inputs parse to, so this is a minor release, through the
library, its C interface and the Python package alike.

### Changed

- A time with no date (`10:42`, `10:42:05`, `10:30 PM`, `10:30:00.123`)
  reads on the base time's day, where it read on 1 January of the base
  time's year: as `today 10:42` reads, and as journalctl and GNU date read
  a bare time. The day is the base time's as seen at `timezone_offset`, the
  zone the input is read in, so 22:00 on the 8th at UTC-5 reads `10:42` on
  the 9th in UTC. A date with no year (`March 15`) takes that day's year,
  which differs from before only when the base time's offset is not
  `timezone_offset` and the two sides of it fall in different years. A
  layout reused down a column keeps the day it was made with. The Go
  library still reads 1 January (kmoneil/dateparsa#40).

### Fixed

- `today 10:42:03`, a clock time with seconds after a relative day, reads;
  it was refused, as the Go library refuses it. `yesterday at 5:30:15pm`
  reads too.

## [0.6.0] - 2026-11-10

ISO 8601 date-times to the minute read. That changes what those inputs
parse to, from refused to a time, so this is a minor release; every input
that read in 0.5.2 reads as it did, through the library, its C interface
and the Python package alike.

### Added

- ISO 8601 date-times to the minute: `2024-03-15T10:30`, `2024-03-15 10:30`,
  and either with a `Z` or a numeric offset (`+05:30`, `-0800`) straight
  after. They read with the seconds at zero, in the zone given when the
  input names none, and their layout reuses down a column. Each was
  refused before, as the Go library still refuses them
  (kmoneil/dateparsa#37), so this changes what those inputs parse to; every
  input that read before reads as it did, `2020-07-20+08:00` included,
  whose signature is the same. `tools/oracle.sh` counts the 189 answers
  where Go refuses and this port reads apart from the rest, which agree.

### Changed

- The nightly fuzz run is held to half an hour, not 10M runs a target.
  The count grew with the targets: with thirteen it passed the job's
  180-minute timeout, and four nights in a row, 1 to 4 November, were
  cancelled with no issue opened. `tools/fuzz.sh` now takes a round size
  and a deadline (`FUZZ_DEADLINE`, a Unix time): it runs rounds while the
  next one will end in time, and cuts one still running as the deadline
  nears, failing the run as a hang. A fuzz run that is cancelled or times
  out now opens an issue too. Longer campaigns are meant for a spot VM, not
  a GitHub runner.

## [0.5.2] - 2026-11-05

Nothing a dependent sees: the library, its C interface and the Python
package are as they were in 0.5.1, and every input parses as it did. What
changed is the fuzzing and CI around them.

### Changed

- `tools/fuzz.sh` looks for a find in the fuzzer's output before it looks at
  `zig build`'s exit status. Zig 0.17.1 exits 1 after some finds (a seed
  that fails), and the script used to stop there without printing the
  input. On GitHub Actions it also writes the find, the target and the
  input in hex, to the job's summary.
- The fuzz workflow retries its `gh` calls. On 2026-11-05 the nightly run
  found the `%f%j` failure fixed in 0.5.1 and opened no issue for it,
  because one call met one GitHub API error. If every try fails, the
  report job says so and points at the fuzz job's summary.
- A CI or release run whose only failures are jobs GitHub found no runner
  for is re-run once, automatically (`.github/workflows/rerun.yml`). macOS
  arm64 runners went short three times on 2026-11-05, and each run was
  re-run by hand.

## [0.5.1] - 2026-11-05

Zig 0.17.1, and two fixes: a strftime format string whose fraction cannot
say where it stops, and formatting a `DateTime` no parse returns. Every
input parses to what it did in 0.5.0; the one change is that a format
string such as `%f%j`, which no layout reads faithfully, is refused.

### Fixed

- `Layout.fromFormatString` refuses a strftime `%f` with a number right
  after it (`%f%j`) with `error.Unsupported`, and `formatString` no longer
  spells one. `%f` takes one to nine digits, so it cannot say where it
  stops: a layout read from Java's `SDDD` spelled `%f%j`, which read
  `1121`, a tenth of a second on day 121, as no time at all, and Python
  reads it as .112 on day 1. Found by the nightly fuzz run.
- Formatting a `DateTime` whose `nanosecond` is past 999,999,999, which
  `isValid` refuses and no parse returns, no longer panics (or, in
  ReleaseFast, writes past a buffer). The nanosecond is written with all
  ten of its digits, `2024-01-01T00:00:00.1000000000Z`, so it cannot pass
  for a fraction it is not. Found by zigvet 0.25.1.

### Changed

- Zig 0.17.1, a release of bug fixes only, is the version required
  (`minimum_zig_version`), tested in CI and used to build the released
  libraries, command and Python wheels. Nothing here needs 0.17.1's fixes,
  but 0.17.0 is no longer tested. Every input parses as it did.
- `tools/fuzz.sh` prints the failing input from the file the fuzzer names
  (`.zig-cache/f/crash`), which 0.17.1 writes whole; its bytes are a seed
  as they stand. 0.17.0 left that file empty, and the script dug the input
  out of the fuzzer's input buffers instead.
- `zig build test` runs zigvet and gnarl too, and CI installs both on
  every runner. gnarl holds each function to the complexity limits of its
  class in `complexity.zon`, against `complexity.baseline`, so no function
  gets more complex unseen. `zig build complexity` runs it alone.

## [0.5.0] - 2026-10-30

Layouts from a format string. Every input parses to what it did in 0.4.2.

### Added

- `Layout.fromFormatString(dialect, format, opts)`, the inverse of
  `formatString`: a layout from a strftime, Go or Java format string, for a
  column whose format is known, so that no value is detected. The order is
  the format's, so `%d/%m/%Y` gives a reusable layout where one detected
  from `13/02/2024` is decided per value. Each dialect reads as its own
  parser does, within what a layout holds: a one-or-two-digit field takes
  either, `%f` one to nine digits, `%z` `Z` or either offset form, and a
  month or weekday name any month or weekday in English and the options'
  locales. `error.Unsupported` for a field no layout reads,
  `error.InvalidFormat` for a string that is no date format, and
  `error.NoBaseTime` for one with no year and no base time. Through C as
  `dateparsa_layout_from_format` and through Python as
  `Layout.from_format`. Two fuzz targets hold it: a layout's format string
  read back reads the value it was spelled from to the same time, and
  agrees with the layout wherever both read; and a layout from any format
  string spells formats that read back to the same time. (#27)

### Changed

- A reused layout whose fields all have fixed widths (ISO 8601, RFC 3339,
  SQL, compact dates) reads a value in about 0.9 of the time it did: an ISO
  date-time in 9.7 ns where it took 10.3, an ISO date in 6.8 where it took
  7.8, on an M5 Max. The fixed-slot path is inlined into `execute` by hand.
- `formatString` spells from any value the layout reads, not only the one
  it was detected from at the same widths: a layout from `1/2/2024` spells
  `11/12/2024` as `%m/%d/%Y` where it gave `error.NotDetectedFrom`. Python's
  `Layout.format_string` takes the value as `value=`.
- `formatString` writes text between two fields as one run, so Java quotes
  it once; refuses a NUL, which no C format string holds; spells a literal
  `T` after a one-or-two-digit day rather than refusing it; spells a
  weekday only in English and the locales the layout reads, and only as a
  whole word, as a format string reads one; and refuses any format
  `fromFormatString` would not read back, such as one with more runs of
  text than a layout has fields.

## [0.4.2] - 2026-10-29

Faster email and HTTP dates. Every input parses to what it did in 0.4.1.

### Changed

- An email or HTTP date ("Fri, 15 Mar 2024 10:30:00 +0000", "Sun, 06 Nov
  1994 08:49:37 GMT") parses in about a quarter of the time it did, whatever
  locales are on: 79 ns where it took 324, on an M5 Max. The textual
  detector they went through finds a month name anywhere in any input; the
  shapes email and HTTP write now have their fields and a layout for each
  month built at comptime, from the detector's own answer, and an input of
  one of them is checked against its shape instead. A fuzz target holds the
  two to the same answer.

## [0.4.1] - 2026-10-29

Faster detection. Every input parses to what it did in 0.4.0.

### Changed

- A first parse of a format the signature trie knows takes about 0.6 of
  the time it did, and so does everything built on parse (`Parser` on a
  value its cached layout cannot read, the C interface, Python, the
  command): detection hands the format back by its table index instead of
  copying its 168-byte definition out of the trie and twice more on the
  way up, and looks for a CJK date only when 年 is the fifth byte. Against
  the Go library's benchmarks, ISO 8601, RFC 3339, SQL and compact forms
  now take 0.54 to 0.66 of Go's time, where they took 0.88 to 1.05.

## [0.4.0] - 2026-10-29

A column in one call, from C and from Python. Every input parses to what it
did in 0.3.3.

### Added

- `dateparsa_parse_column`: every value in a buffer, each ending at a
  separator byte, parsed down one parser in one call, into an array of the
  new `dateparsa_value` (the time, Unix seconds, kind, whether it was a
  guess, and a status saying why a value did not parse). It allocates
  nothing; every array is the caller's. For a language where a call into C
  costs more than a parse does.
- `dateparsa.parse_column(values, **options)` in Python, on top of it: one
  call into the library for the whole column, with `None` read as a value
  that does not parse. Down 10,000 RFC 3339 values on Python 3.13
  (docs/PERF.md) it takes 169 ns a value to datetimes, where a `Parser`
  called once a value takes 1.12 µs, and 32.9 ns into numpy, where pandas
  working out the format takes 78.2. What it returns gives `datetimes()`,
  `times()`, `failed` and `ambiguous`, and `datetime64()` for a numpy array
  pandas takes, `NaT` where a value did not parse; numpy is not a
  dependency.
- A fuzz target: the column call, on any bytes split at any separator,
  answers for each value what a `Parser` answers parsing them in turn.

## [0.3.3] - 2026-10-29

A faster Python package. No library code changed, and every input parses
to what it did in 0.3.2.

### Changed

- The Python package spends far less of each call in Python: `parse`
  takes a quarter to a third of the time it did (3.5 µs to 1.1 on Python
  3.13, in docs/PERF.md), `Parser.parse` about half, and `Layout.parse`
  and `detect` a half to two thirds, with the same answers. From Python,
  `parse` is now faster than `strptime` given the format. The
  default options go to the library as NULL and other options are built
  once and shared; a result's fields are read in one `struct` unpack, its
  `Time` and `Result` built without the dataclass `__init__`, and its
  layout is a view of the result rather than a copy. A failed call is
  run again with diagnostics, for its message, so a parse that succeeds
  never pays for them.

## [0.3.2] - 2026-10-29

Benchmarks against other parsers. No library code changed, and every input
parses to what it did in 0.3.1.

### Added

- `tools/bench_others.sh`: dateparsa against other date parsers on one
  machine. In Zig, against zeit. In Rust, through the C interface, against
  chrono, jiff, time, speedate and dateparser, with heap allocations per
  parse counted. In Python, through the package, against `fromisoformat`,
  `strptime`, ciso8601, dateutil, dateparser and pandas, one value at a time
  and down a column. Every parser's answer is checked before it is timed,
  and each harness pins the versions it compares against. `docs/PERF.md`
  has the first run and what it shows, including what the shared library
  imports: on macOS, `bzero`, `memcpy` and `memset`, and nothing that could
  ask the system for memory.

## [0.3.1] - 2026-10-29

The `dateparsa` command, prebuilt. No library code changed, and every input
parses to what it did in 0.3.0.

### Added

- The `dateparsa` command. `dateparsa detect` reports how a column is
  written: the formats its values take, each spelled for strftime, Go and
  Java, the order its numeric dates are in and the value that settled it, the
  values that needed the column's order, and the values it could not read, by
  line. `dateparsa normalize` writes the input back with the column as RFC
  3339, changing no other byte, and refuses to guess an order nothing in the
  column settles. CSV with `--col N` or `--col NAME` (quoted fields, any
  one-byte separator), or one value a line, from a file or standard input;
  `--order`, `--base`, `--tz`, `--utc`, `--locale` and `detect --json`. The
  release archives carry it in `bin/` for every platform, and each release
  runs it on Linux, macOS and Windows before publishing.

## [0.3.0] - 2026-10-28

A column's date order, format strings for other tools, and a Python
package. All of it is new API: nothing that existed changed, and every input
parses to what it did in 0.2.1.

### Added

- `detectColumn` and `Column`: which order a column writes its numeric dates
  in, month, day or year first, from all of its values where one value
  cannot say. One `13/02/2024` settles day first for the whole column, and
  two-digit years narrow it together. The report gives the order, the value
  that settled it, any values that contradict it, and the `Options` that read
  the column in it. `Column` takes values one at a time and allocates
  nothing. In C: `dateparsa_column_init`, `dateparsa_column_add` and
  `dateparsa_column_summarize`.
- `Layout.dateOrder()`: the order a numeric layout reads year, month and day
  in.
- `Layout.formatString(dialect, detected_from, writer)`: a detected format as
  another tool's format string, in strftime (C, Python, pandas, Ruby), Go or
  Java (also Kotlin and Spark) form, such as `%d/%m/%Y %H:%M`. A field a
  dialect cannot spell is `error.Unsupported`, never a string that reads
  something else. Every example in the format table is checked in Python, Go
  and Java by `tools/format_check.sh`. In C: `dateparsa_format_string` and
  the new status `DATEPARSA_UNSUPPORTED`.
- A Python package, `pip install dateparsa`: wheels for Linux (glibc and musl),
  macOS 13 and later, and Windows, on x86_64 and arm64, for Python 3.9 and
  later, wrapping the release libraries with `ctypes`. `parse`, `detect`,
  `Parser`, `Layout` (with `format_string`), `detect_column` and `Column`,
  with options as keyword arguments, results as `datetime`s, and `NoMatch`,
  `Ambiguous` and `NoBaseTime` as `ValueError`s. Every release installs each
  wheel on its platform and runs the tests before publishing to PyPI as a
  trusted publisher.

## [0.2.1] - 2026-10-28

The C library, prebuilt. No library code changed, and every input parses to
what it did in 0.2.0.

### Added

- Prebuilt `libdateparsa` on every release, for Linux, macOS 13 and later, and
  Windows, each on x86_64 and arm64: one archive per platform with the static
  and the shared library, the header and the licences, plus `SHA256SUMS` and
  build provenance. Before a release publishes them, each runner OS links the
  C tests against its own platform's archive with the compiler it already
  has, and runs them.

## [0.2.0] - 2026-10-28

The C interface. Nothing a Zig caller sees changed, and every input parses to
what it did in 0.1.0.

### Added

- A C interface, for every language that can call C. `zig build lib` builds
  `libdateparsa`, static or with `-Dlinkage=dynamic` shared, and installs
  `include/dateparsa.h`. It covers `parse`, `detect`, layout reuse, `Parser`,
  strict mode and its diagnostics, locales by bit or by BCP 47 tag, RFC 3339
  output and Unix seconds, and allocates nothing: every struct is the
  caller's. What a C caller passes in is checked, not trusted: a base time
  that is no date, an offset of a day or more, a base year more than
  999,999,999 from year 0, a locale bit the build left out, a `NULL`, or a
  layout or parser the library never filled in is
  `DATEPARSA_INVALID_ARGUMENT`.

## [0.1.0] - 2026-10-28

The first release: the Go library
[dateparsa v0.2.0](https://github.com/kmoneil/dateparsa/releases/tag/v0.2.0),
ported to Zig 0.17.0. It gives Go's answer on every input the two were compared
on, 158,631 of them: the Go library's golden corpus, and both libraries run side
by side through the public API under nine option sets and through natural
language in every locale. The README's "Differences from the Go original" lists
what was changed on purpose.

### Added

- `parse`, `parseWith` and `detect`, which work out the format: 32 structured
  formats, dates written around a month name, Unix timestamps by their digit
  count, and natural-language expressions, tried in that order.
- `Layout`, the detected format compiled into a program that reads the rest of
  a column with no detection and no allocation. `reusable()` says when a layout
  may be reused.
- `Parser`, a column cache that re-detects when a row's format changes.
- Ambiguity reported, never hidden: `Result.ambiguous`, the `prefer_day_first`
  and `prefer_year_first` options, and `strict` mode, which refuses with
  `error.Ambiguous` and puts the competing readings in `Diagnostics`.
- Month names and relative expressions in 20 locales, chosen at build time with
  `-Dlocales` and at run time by BCP 47 tag with `localeSet`.
- `FlexTime`, a `std.json` field type that reads date strings, numeric
  timestamps and null, and writes RFC 3339.
- `DateTime`, a civil time with a fixed UTC offset, epoch conversion and RFC
  3339 formatting.
- No allocation on any path and no clock: an input that needs a base time and
  was given none fails with `error.NoBaseTime`.

[Unreleased]: https://github.com/kmoneil/dateparsa.zig/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/kmoneil/dateparsa.zig/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/kmoneil/dateparsa.zig/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/kmoneil/dateparsa.zig/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/kmoneil/dateparsa.zig/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/kmoneil/dateparsa.zig/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/kmoneil/dateparsa.zig/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/kmoneil/dateparsa.zig/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/kmoneil/dateparsa.zig/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kmoneil/dateparsa.zig/releases/tag/v0.1.0

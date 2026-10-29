# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
As in the Go library, a change to what any input parses to counts as breaking
even when no signature moves, because the caller's stored data is what records
the difference. Before 1.0 a breaking change is a minor bump.

## [Unreleased]

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
  call into the library for the whole column, several times as fast as a
  `Parser` called once a value (10,000 RFC 3339 values to datetimes took
  234 ns a value, against 1.9 µs through a `Parser`, on Python 3.9 on an M5
  Max), with `None` read as a value that does not parse. What it returns
  gives `datetimes()`, `times()`,
  `failed` and `ambiguous`, and `datetime64()` for a numpy array pandas
  takes, `NaT` where a value did not parse; numpy is not a dependency.
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

[Unreleased]: https://github.com/kmoneil/dateparsa.zig/compare/v0.3.3...HEAD
[0.3.3]: https://github.com/kmoneil/dateparsa.zig/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/kmoneil/dateparsa.zig/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/kmoneil/dateparsa.zig/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/kmoneil/dateparsa.zig/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kmoneil/dateparsa.zig/releases/tag/v0.1.0

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
As in the Go library, a change to what any input parses to counts as breaking
even when no signature moves, because the caller's stored data is what records
the difference. Before 1.0 a breaking change is a minor bump.

## [Unreleased]

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

[Unreleased]: https://github.com/kmoneil/dateparsa.zig/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/kmoneil/dateparsa.zig/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/kmoneil/dateparsa.zig/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kmoneil/dateparsa.zig/releases/tag/v0.1.0

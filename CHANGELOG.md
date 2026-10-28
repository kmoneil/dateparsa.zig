# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
As in the Go library, a change to what any input parses to counts as breaking
even when no signature moves, because the caller's stored data is what records
the difference. Before 1.0 a breaking change is a minor bump.

## [Unreleased]

Nothing yet.

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

[Unreleased]: https://github.com/kmoneil/dateparsa.zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kmoneil/dateparsa.zig/releases/tag/v0.1.0

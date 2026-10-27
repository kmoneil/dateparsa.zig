# dateparsa

Date parsing for Zig, for input whose format you do not control.

A port of [dateparsa](https://github.com/kmoneil/dateparsa) (Go), which is the
source of truth for semantics while this port is underway: trie-based format
detection, reusable compiled layouts, explicit ambiguity reporting, 20 locales,
and natural language expressions ("3 days ago", "next friday at 2pm").

Where the port aims to improve on the original:

- Detection tries, interned layouts, and locale tables are built at comptime
  and live in read-only data. There is no init cost.
- Zero allocation on every path, not only the hot one. The public API takes no
  allocator.
- No ambient clock reads: the base time for relative dates is explicit.
- Locales are selected at build time (`-Dlocales=...`), all 20 by default.

Status: early. The work is tracked on the project's karte board.

Requires Zig 0.17.0.

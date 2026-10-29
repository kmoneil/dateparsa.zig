# dateparsa

Date parsing for input whose format you do not control.

CSV imports, log lines, third-party APIs, user-typed strings: dateparsa works
out the format, parses the value, and tells you when it had to guess. It reads
32 structured formats, Unix timestamps by their digit count, dates written
around a month name in 20 languages, and natural language ("next friday at
5pm"). It never reads a clock: an input that needs a base time is an error
unless you pass one.

```sh
pip install dateparsa
```

Wheels for Linux (glibc and musl), macOS 13+ and Windows, on x86_64 and arm64,
for Python 3.9 and later. No dependencies, and nothing to compile.

```python
import dateparsa

r = dateparsa.parse("March 15, 2024")
r.datetime   # datetime(2024, 3, 15, 0, 0, tzinfo=timezone.utc)
r.label      # 'MONTH_DAY_YEAR'

# Ambiguity is reported, never hidden.
dateparsa.parse("01/02/2024").ambiguous                      # True: January 2nd was a guess
dateparsa.parse("01/02/2024", prefer_day_first=True)         # February 1st
try:
    dateparsa.parse("01/02/2024", strict=True)
except dateparsa.Ambiguous as e:
    e.interpretations                                         # the MM/DD/YYYY and DD/MM/YYYY readings

# A column settles what one value cannot.
column = ["01/02/2024", "05/06/2024", "13/02/2024"]
report = dateparsa.detect_column(column)
report.order                                                  # 'day_first', settled by row 2
[dateparsa.parse(v, **report.preferences) for v in column]   # each read day first

# A whole column in one call, each value as parse reads it.
col = dateparsa.parse_column(["2024-03-15", "N/A", "2024-03-17T10:30:00Z"])
col.failed                                                    # [1]
col.datetimes()                                               # [datetime(2024, 3, 15, ...), None, datetime(...)]

# Hand the format to pandas, Go or Java.
dateparsa.parse("13/02/2024 10:30").layout.format_string()   # '%d/%m/%Y %H:%M'

# Natural language and other languages, against a base time you choose.
from datetime import datetime, timezone
dateparsa.parse("vor 3 Tagen", base_time=datetime(2024, 3, 15, tzinfo=timezone.utc), locales=["de"])
```

`parse` takes keyword options: `base_time`, `timezone_offset`,
`prefer_day_first`, `prefer_year_first`, `prefer_future`, `strict` and
`locales`. A failed parse raises `NoMatch`, `Ambiguous` or `NoBaseTime`, all
`ValueError`s. `Parser` reads a column, reusing the first value's layout, and
`Layout.parse` reads a value with no detection at all. `parse_column` reads a
whole column in one call into the library, several times as fast as one call
a value: `datetimes()`, `times()` and `failed` on what it returns, and
`datetime64()` for a numpy array pandas takes, with `NaT` where a value did not
parse (numpy is not a dependency).

This package is a thin `ctypes` binding to libdateparsa, the C interface of the
Zig library [dateparsa.zig](https://github.com/kmoneil/dateparsa.zig), whose
README has the full format table and how its answers are checked: they match
the Go original on 158,631 inputs. Apache-2.0; the locale data is derived from
the Unicode CLDR under the Unicode License v3 (see NOTICE).

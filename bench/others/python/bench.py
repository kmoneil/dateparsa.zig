"""dateparsa, through its Python package, against Python's date parsers.

tools/bench_others.sh runs it with requirements.txt installed and
DATEPARSA_LIB naming a ReleaseFast libdateparsa:

    python bench.py [-count N] [-benchtime MS]

Prints two Markdown tables. The first is the time to parse one value, the
second the time per value to parse a column of 10,000 different values. Each
cell is the median of -count rounds; a round times every parser on every
input, in an order that turns by one each round.

Before timing, each parser reads each input once, and an answer that is not
the instant the input names, to the microsecond a datetime keeps, is
reported instead of timed. An input with no zone is read as UTC.

strptime and pandas with format= are told the format. fromisoformat,
ciso8601 and dateutil's isoparse read ISO 8601 alone. dateparsa, dateutil's
parse, dateparser and pandas without format= work it out. dateparser is
given English, as dateparsa reads English unless told otherwise.
"""

import datetime as dt
import os
import platform
import statistics
import sys
import timeit
from importlib import metadata

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../python/src"))

import ciso8601  # noqa: E402
import dateparser  # noqa: E402
import dateutil.parser  # noqa: E402
import pandas  # noqa: E402

import dateparsa  # noqa: E402

UTC = dt.timezone.utc
EPOCH = dt.datetime(1970, 1, 1, tzinfo=UTC)
BASE = dt.datetime(2024, 3, 15, 12, tzinfo=UTC)
S = 1_000_000_000


def micros(t):
    """t as microseconds since the epoch, read as UTC when it has no zone."""
    if t is None:
        raise ValueError("no answer")
    if t.tzinfo is None:
        t = t.replace(tzinfo=UTC)
    return (t - EPOCH) // dt.timedelta(microseconds=1)


class Case:
    def __init__(self, text, want, strptime=None, iso=False, base=False):
        self.text = text
        #: Nanoseconds since the epoch, or None when the input is no date.
        self.want = want
        self.strptime = strptime
        #: ISO 8601, which the ISO parsers read.
        self.iso = iso
        #: Relative, read against BASE.
        self.base = base


CASES = [
    Case("2024-03-15T10:30:00Z", 1710498600 * S, "%Y-%m-%dT%H:%M:%S%z", iso=True),
    Case("2024-03-15T10:30:00+05:30", 1710478800 * S, "%Y-%m-%dT%H:%M:%S%z", iso=True),
    Case("2024-03-15T10:30:00.123456789Z", 1710498600 * S + 123456789, "%Y-%m-%dT%H:%M:%S.%f%z", iso=True),
    Case("2024-03-15 10:30:00", 1710498600 * S, "%Y-%m-%d %H:%M:%S", iso=True),
    Case("2024-03-15", 1710460800 * S, "%Y-%m-%d", iso=True),
    Case("20240315T103000Z", 1710498600 * S, "%Y%m%dT%H%M%S%z", iso=True),
    Case("Fri, 15 Mar 2024 10:30:00 +0000", 1710498600 * S, "%a, %d %b %Y %H:%M:%S %z"),
    Case("03/15/2024", 1710460800 * S, "%m/%d/%Y"),
    Case("March 15, 2024", 1710460800 * S, "%B %d, %Y"),
    Case("3 days ago", 1710244800 * S, base=True),
    Case("not a date at all", None, "%Y-%m-%dT%H:%M:%S%z", iso=True),
]

DATEPARSER_SETTINGS = {"RELATIVE_BASE": BASE.replace(tzinfo=None)}


def dateparser_parse(s):
    return dateparser.parse(s, languages=["en"], settings=DATEPARSER_SETTINGS)


def dateparsa_parse(c):
    if c.base:
        return lambda s: dateparsa.parse(s, base_time=BASE), lambda r: micros(r.datetime)
    return dateparsa.parse, lambda r: micros(r.datetime)


def dateparsa_layout(c):
    try:
        layout = dateparsa.detect(c.text)
    except ValueError:
        return None
    return (layout.parse, lambda t: micros(t.to_datetime())) if layout.reusable else None


def strptime(c):
    if c.strptime is None:
        return None
    fmt = c.strptime
    return (lambda s: dt.datetime.strptime(s, fmt)), micros


def iso(parse):
    return lambda c: (parse, micros) if c.iso else None


# A parser's name, and what it is given for a case: (parse, answer), the
# function timed and what its result names in microseconds, or None when
# it has no way to read the format.
IMPLS = [
    ("dateparsa parse", dateparsa_parse),
    ("dateparsa layout", dateparsa_layout),
    ("fromisoformat", iso(dt.datetime.fromisoformat)),
    ("strptime", strptime),
    ("ciso8601", iso(ciso8601.parse_datetime)),
    ("dateutil isoparse", iso(dateutil.parser.isoparse)),
    ("dateutil parse", lambda c: (dateutil.parser.parse, micros)),
    ("dateparser", lambda c: (dateparser_parse, micros)),
]


def verdict(want, got):
    """None when an answer is right, else what its cell says instead."""
    if want is None:
        return None if got is None else "wrong"
    if got is None:
        return "refuses"
    return None if got == want else "wrong"


def answer(parse, read, arg):
    try:
        return read(parse(arg))
    except (ValueError, OverflowError, TypeError):
        return None


def refusing(parse):
    """parse, returning None where it raises: the time a refusal takes."""

    def f(s):
        try:
            return parse(s)
        except (ValueError, OverflowError, TypeError):
            return None

    return f


def calibrate(timer, goal_s):
    """The iteration count whose run takes at least goal_s."""
    n = 1
    while True:
        t = timer.timeit(n)
        if t >= goal_s or n >= 1_000_000_000:
            return n
        n = max(n + 1, min(n * 100, int(goal_s * n / max(t, 1e-9) * 1.2)))


def ns_text(ns):
    """ns as bench.sh writes it, in ns below a microsecond and µs or ms above."""
    if ns >= 1e6:
        return "%.2f ms" % (ns / 1e6)
    if ns >= 1e3:
        return "%.2f µs" % (ns / 1e3)
    if ns >= 100:
        return "%.0f ns" % ns
    return "%.1f ns" % ns


def run(cells, count, per):
    """Times the cells that are (timer, n) pairs, count rounds, and replaces
    each with its median time, divided by per, as text."""
    samples = {}
    width = len(cells[0])
    for r in range(count):
        print("round %d of %d" % (r + 1, count), file=sys.stderr)
        for ri, row in enumerate(cells):
            for k in range(width):
                ii = (k + r) % width
                if isinstance(row[ii], tuple):
                    timer, n = row[ii]
                    samples.setdefault((ri, ii), []).append(timer.timeit(n) / n / per * 1e9)
    for (ri, ii), ns in samples.items():
        cells[ri][ii] = ns_text(statistics.median(ns))


def table(names, labels, cells):
    print("| Input | %s |" % " | ".join(names))
    print("|---|%s" % ("--:|" * len(names)))
    for label, row in zip(labels, cells):
        print("| %s | %s |" % (label, " | ".join(row)))


def values_table(count, goal_s):
    cells = []
    for c in CASES:
        row = []
        want = None if c.want is None else c.want // 1000
        for name, make in IMPLS:
            entry = make(c)
            if entry is None:
                row.append("no")
                continue
            parse, read = entry
            v = verdict(want, answer(parse, read, c.text))
            if v == "wrong":
                print("%s read %r as %s" % (name, c.text, answer(parse, read, c.text)), file=sys.stderr)
            if v is not None:
                row.append(v)
                continue
            timer = timeit.Timer("f(s)", globals={"f": refusing(parse) if c.want is None else parse, "s": c.text})
            row.append((timer, calibrate(timer, goal_s)))
        cells.append(row)
    run(cells, count, 1)
    table([n for n, _ in IMPLS], ["`%s`" % c.text for c in CASES], cells)


ROWS = 10_000
START = dt.datetime(2000, 1, 1, tzinfo=UTC)
# A label, the column's format, and the step between its values.
COLUMNS = [
    ("RFC 3339, `2000-01-01T00:00:00Z` on by minutes", "%Y-%m-%dT%H:%M:%SZ", dt.timedelta(minutes=1)),
    ("US dates, `01/01/2000` on by days", "%m/%d/%Y", dt.timedelta(days=1)),
]


def each(parse):
    return lambda values: [parse(v) for v in values], lambda got: [micros(t) for t in got]


def dateparsa_column_parser(values):
    parse = dateparsa.Parser().parse
    return [parse(v) for v in values]


def dateparsa_column_layout(fmt):
    # None for a format whose month and day are decided per value, as the
    # US dates' are: a layout from one value does not read the column.
    if not dateparsa.detect(START.strftime(fmt)).reusable:
        return None

    def parse_column(values):
        parse = dateparsa.detect(values[0]).parse
        return [parse(v) for v in values]

    return parse_column, lambda got: [micros(t.to_datetime()) for t in got]


def pandas_read(got):
    return [int(x) for x in got.as_unit("us").asi8]


# As IMPLS, for a column: what each is given for a column's format.
COLUMN_IMPLS = [
    ("dateparsa Parser", lambda fmt: (dateparsa_column_parser, lambda got: [micros(r.datetime) for r in got])),
    ("dateparsa layout", dateparsa_column_layout),
    ("fromisoformat", lambda fmt: each(dt.datetime.fromisoformat) if fmt.startswith("%Y-") else None),
    ("strptime", lambda fmt: each(lambda s: dt.datetime.strptime(s, fmt))),
    ("ciso8601", lambda fmt: each(ciso8601.parse_datetime) if fmt.startswith("%Y-") else None),
    ("dateutil parse", lambda fmt: each(dateutil.parser.parse)),
    # Not dateparser: about a millisecond a value, ten seconds a column, and
    # a loop over it says what its row in the first table says.
    ("pandas", lambda fmt: (pandas.to_datetime, pandas_read)),
    ("pandas format=", lambda fmt: ((lambda values: pandas.to_datetime(values, format=fmt)), pandas_read)),
]


def column_table(count, goal_s):
    cells = []
    for label, fmt, step in COLUMNS:
        times = [START + i * step for i in range(ROWS)]
        values = [t.strftime(fmt) for t in times]
        want = [micros(t) for t in times]
        row = []
        for name, make in COLUMN_IMPLS:
            entry = make(fmt)
            if entry is None:
                row.append("no")
                continue
            parse, read = entry
            got = answer(parse, read, values)
            v = "refuses" if got is None else None if got == want else "wrong"
            if v == "wrong":
                print("%s read the column %s wrongly" % (name, label), file=sys.stderr)
            if v is not None:
                row.append(v)
                continue
            timer = timeit.Timer("f(v)", globals={"f": parse, "v": values})
            row.append((timer, calibrate(timer, goal_s)))
        cells.append(row)
    run(cells, count, ROWS)
    table([n for n, _ in COLUMN_IMPLS], [c[0] for c in COLUMNS], cells)


def main():
    usage = "usage: bench.py [-count N] [-benchtime MS]"
    args = sys.argv[1:]
    if len(args) % 2:
        sys.exit(usage)
    count, benchtime_ms = 10, 200
    for flag, value in zip(args[::2], args[1::2]):
        if flag == "-count":
            count = int(value)
        elif flag == "-benchtime":
            benchtime_ms = int(value)
        else:
            sys.exit(usage)
    if count < 1:
        sys.exit(usage)
    packages = ("ciso8601", "dateparser", "pandas", "python-dateutil")
    print("### Python: %s (Python %s)\n" % (
        ", ".join("%s %s" % (p, metadata.version(p)) for p in packages), platform.python_version(),
    ))
    values_table(count, benchtime_ms / 1000)
    print("\nA column of %s values, per value:\n" % format(ROWS, ","))
    column_table(count, benchtime_ms / 1000)


if __name__ == "__main__":
    main()

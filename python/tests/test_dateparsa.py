"""The Python package against the library it wraps: the README's examples,
in Python. Runs with the standard library alone:

    python -m unittest discover -s python/tests

against an installed wheel, or with PYTHONPATH=python/src and DATEPARSA_LIB
naming a libdateparsa built by `zig build lib -Dlinkage=dynamic`.
"""

import dataclasses
import datetime as dt
import gc
import os
import threading
import unittest

import dateparsa

UTC = dt.timezone.utc
BASE = dt.datetime(2024, 3, 15, 12, tzinfo=UTC)


class Parse(unittest.TestCase):
    def test_quick_start(self):
        r = dateparsa.parse("2024-03-15T10:30:00Z")
        self.assertEqual(r.datetime, dt.datetime(2024, 3, 15, 10, 30, tzinfo=UTC))
        self.assertEqual(r.label, "ISO8601_DATETIME_Z")
        self.assertEqual(r.kind, "absolute")
        self.assertFalse(r.ambiguous)
        self.assertEqual(r.unix_seconds, 1710498600)

    def test_reuse_the_layout(self):
        first = dateparsa.parse("2024-03-15")
        self.assertTrue(first.layout.reusable)
        t = first.layout.parse(" 2024-03-16 ")
        self.assertEqual((t.year, t.month, t.day), (2024, 3, 16))
        with self.assertRaises(dateparsa.NoMatch):
            first.layout.parse("March 17, 2024")
        self.assertEqual(dateparsa.detect("15.03.2024").parse("16.04.2025").month, 4)

    def test_parse_a_column(self):
        p = dateparsa.Parser()
        for value in ["2024-01-01", "2024-06-15", "March 3, 2024", "2024-12-31"]:
            self.assertEqual(p.parse(value).time.year, 2024)
        p.reset()
        with self.assertRaises(dateparsa.NoMatch):
            p.parse("nonsense")

    def test_ambiguity(self):
        r = dateparsa.parse("01/02/2024")
        self.assertTrue(r.ambiguous)
        self.assertEqual(r.time.month, 1)
        self.assertEqual(dateparsa.parse("01/02/2024", prefer_day_first=True).time.month, 2)
        with self.assertRaises(dateparsa.Ambiguous) as e:
            dateparsa.parse("01/02/2024", strict=True)
        self.assertEqual([i.label for i in e.exception.interpretations], ["MM/DD/YYYY", "DD/MM/YYYY"])
        self.assertEqual(e.exception.interpretations[1].time.month, 2)
        self.assertIsInstance(e.exception, ValueError)

    def test_natural_language(self):
        with self.assertRaises(dateparsa.NoBaseTime):
            dateparsa.parse("3 days ago")
        r = dateparsa.parse("next friday at 5pm", base_time=BASE)
        self.assertEqual(r.datetime, dt.datetime(2024, 3, 22, 17, tzinfo=UTC))
        self.assertEqual(r.kind, "relative")
        self.assertFalse(r.layout.reusable)

    def test_locales(self):
        self.assertIn("en", dateparsa.LOCALES)
        if "fr" not in dateparsa.LOCALES:
            self.skipTest("built without fr")
        self.assertEqual(dateparsa.parse("15 mars 2024", locales=["fr"]).time.month, 3)
        self.assertEqual(dateparsa.parse("15 mars 2024", locales="fr-CA").time.month, 3)
        with self.assertRaises(dateparsa.NoMatch):
            dateparsa.parse("15 mars 2024")
        with self.assertRaises(ValueError):
            dateparsa.parse("15 mars 2024", locales=["xx"])

    def test_zones_and_timestamps(self):
        r = dateparsa.parse("2024-03-15 10:30:00", timezone_offset=dt.timedelta(hours=5, minutes=30))
        self.assertEqual(r.time.offset_seconds, 19800)
        self.assertEqual(r.unix_seconds, 1710478800)
        ms = dateparsa.parse("1710504800123")
        self.assertEqual(ms.time.nanosecond, 123000000)
        self.assertEqual(ms.datetime.microsecond, 123000)
        self.assertFalse(ms.layout.reusable)

    def test_years_datetime_cannot_hold(self):
        r = dateparsa.parse("0000-01-01")
        self.assertEqual(r.time.year, 0)
        with self.assertRaises(ValueError):
            r.datetime

    def test_bad_arguments(self):
        with self.assertRaises(ValueError):
            dateparsa.parse("2024-03-15", timezone_offset=86400)
        with self.assertRaises(TypeError):
            dateparsa.parse("2024-03-15", prefer_dayfirst=True)

    def test_results_are_plain_dataclasses(self):
        # Time and Result are built without their __init__, for speed: they
        # must be what __init__ would have made.
        t = dateparsa.parse("2024-03-15T10:30:00.5+05:30").time
        same = dateparsa.Time(2024, 3, 15, 10, 30, 0, 500000000, 19800)
        self.assertEqual(t, same)
        self.assertEqual(hash(t), hash(same))
        self.assertEqual(repr(t), repr(same))
        self.assertEqual(dataclasses.asdict(t), dataclasses.asdict(same))
        with self.assertRaises(dataclasses.FrozenInstanceError):
            t.year = 2025
        r = dateparsa.parse("2024-03-15")
        self.assertEqual([f.name for f in dataclasses.fields(r)], [f.name for f in dataclasses.fields(dateparsa.Result)])
        self.assertIs(dateparsa.parse("2024-03-15T10:30:00Z").datetime.tzinfo, UTC)

    def test_a_layout_outlives_its_result(self):
        layout = dateparsa.parse("15.03.2024").layout
        gc.collect()
        self.assertEqual(layout.parse("16.04.2025").month, 4)
        self.assertEqual(layout.format_string(), "%d.%m.%Y")
        self.assertEqual(layout.label, dateparsa.detect("15.03.2024").label)

    def test_options_are_shared_and_never_written(self):
        # Equal options share one C struct, which carries no diagnostics:
        # a failure under them still says why, and leaves them as they were.
        shared = dateparsa._options({"strict": True})
        self.assertIs(shared, dateparsa._options({"strict": True}))
        self.assertFalse(shared.diagnostics, "a struct every thread passes must give the library nothing to write")
        for _ in range(2):
            with self.assertRaises(dateparsa.Ambiguous) as e:
                dateparsa.parse("01/02/2024", strict=True)
            self.assertEqual(len(e.exception.interpretations), 2)
            with self.assertRaisesRegex(dateparsa.NoMatch, "nonsense"):
                dateparsa.parse("nonsense", strict=True)
        self.assertEqual(dateparsa.parse("02/01/2024", strict=False).time.month, 2)
        self.assertEqual(dateparsa.parse("3 days ago", base_time=BASE).time.day, 12)
        later = BASE + dt.timedelta(days=1)
        self.assertEqual(dateparsa.parse("3 days ago", base_time=later).time.day, 13)
        east = dt.datetime(2024, 3, 15, 12, tzinfo=dt.timezone(dt.timedelta(hours=1)))
        self.assertEqual(dateparsa.parse("now", base_time=east).time.offset_seconds, 3600)

    def test_threads(self):
        # The C calls release the GIL and share nothing but their inputs.
        errors = []

        # A failure's message comes from diagnostics the library writes, so
        # threads failing for different reasons must each read their own.
        def work(text, error, reason):
            try:
                for _ in range(500):
                    assert dateparsa.parse("2024-03-15T10:30:00Z").unix_seconds == 1710498600
                    try:
                        dateparsa.parse(text)
                    except error as e:
                        assert reason in str(e), str(e)
            except Exception as e:  # pragma: no cover
                errors.append(e)

        reasons = [
            ("no date", dateparsa.NoMatch, "no matching format"),
            ("3 days ago", dateparsa.NoBaseTime, "needs a base time"),
        ]
        threads = [threading.Thread(target=work, args=reasons[i % 2]) for i in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])


class ParseColumn(unittest.TestCase):
    VALUES = [
        "2024-01-01", "2024-06-15", "nonsense", "March 3, 2024", "", None, "2024-12-31T23:59:59.5+05:30",
        "01/02/2024", "13/02/2024", "3 days ago", "1710504800", "15.03.2024",
    ]

    def expect_as_parse(self, values, **options):
        col = dateparsa.parse_column(values, **options)
        self.assertEqual(len(col), len(values))
        want, failed, ambiguous = [], [], []
        for i, v in enumerate(values):
            try:
                r = dateparsa.parse("" if v is None else v, **options)
            except dateparsa.Error:
                want.append(None)
                failed.append(i)
                continue
            want.append(r.time)
            if r.ambiguous:
                ambiguous.append(i)
        self.assertEqual(col.times(), want)
        self.assertEqual(col.datetimes(), [t and t.to_datetime() for t in want])
        self.assertEqual(col.failed, failed)
        self.assertEqual(col.ambiguous, ambiguous)
        return col

    def test_each_value_as_parse_gives_it(self):
        col = self.expect_as_parse(self.VALUES)
        self.assertEqual(col.failed, [2, 4, 5, 9])
        self.expect_as_parse(self.VALUES, base_time=BASE)
        self.expect_as_parse(self.VALUES, base_time=BASE, prefer_day_first=True, timezone_offset=3600)
        col = self.expect_as_parse(self.VALUES, base_time=BASE, strict=True)
        self.assertIn(7, col.failed)  # 01/02/2024, ambiguous, refused
        self.expect_as_parse(["2024-03-15T10:30:00Z"] * 1000 + ["March 3, 2024"])
        days = ["2024-03-%02d" % d for d in range(1, 29)]
        self.expect_as_parse(days)
        self.assertEqual(dateparsa.parse_column(iter(days)).times(), dateparsa.parse_column(days).times())

    def test_edges(self):
        self.assertEqual(len(dateparsa.parse_column([])), 0)
        self.assertEqual(dateparsa.parse_column([""]).failed, [0])
        self.assertEqual(dateparsa.parse_column(["2024-03-15", ""]).failed, [1])
        # A value holding the NUL that separates values goes one call each.
        self.expect_as_parse(["2024-03-15", "2024\x00-03-15", "2024-03-16"])
        self.assertEqual(repr(dateparsa.parse_column(["2024-03-15", "x"])), "ParsedColumn(2 values, 1 failed)")
        col = dateparsa.parse_column(["0000-01-01"])
        self.assertEqual(col.times()[0].year, 0)
        with self.assertRaises(ValueError):
            col.datetimes()

    def test_bad_arguments(self):
        with self.assertRaisesRegex(ValueError, "timezone_offset"):
            dateparsa.parse_column(["2024-03-15"], timezone_offset=86400)
        with self.assertRaises(TypeError):
            dateparsa.parse_column(["2024-03-15"], prefer_dayfirst=True)
        with self.assertRaises(TypeError):
            dateparsa.parse_column(["2024-03-15", 20240315])

    def test_datetime64(self):
        try:
            import numpy
        except ImportError:
            # CI installs numpy and sets this, so the test cannot skip there.
            if os.environ.get("DATEPARSA_TEST_NUMPY"):
                raise
            self.skipTest("no numpy")
        col = dateparsa.parse_column(self.VALUES, base_time=BASE)
        got = col.datetime64()
        self.assertEqual(got.dtype, numpy.dtype("datetime64[ns]"))
        for i, t in enumerate(col.times()):
            if t is None:
                self.assertTrue(numpy.isnat(got[i]))
            else:
                r = dateparsa.parse(self.VALUES[i], base_time=BASE)
                self.assertEqual(int(got[i].astype("int64")), r.unix_seconds * 10**9 + r.time.nanosecond)
        with self.assertRaises(ValueError):
            dateparsa.parse_column(["2300-01-01"]).datetime64()


class Columns(unittest.TestCase):
    def test_settle_a_column(self):
        column = ["01/02/2024", "05/06/2024", "13/02/2024", "03/04/2024"]
        report = dateparsa.detect_column(column)
        self.assertEqual(report.order, "day_first")
        self.assertEqual(report.settled_by, 2)
        self.assertEqual(report.conflicts, 0)
        self.assertEqual(report.fits, frozenset({"day_first"}))
        self.assertEqual(dateparsa.parse(column[0], **report.preferences).time.month, 2)

    def test_nothing_settles_it(self):
        report = dateparsa.detect_column(["01/02/2024", "03/04/2024"])
        self.assertIsNone(report.order)
        self.assertEqual(report.fits, frozenset({"month_first", "day_first"}))
        self.assertIsNone(report.settled_by)

    def test_contradictions(self):
        c = dateparsa.Column()
        for v in ["13/02/2024", "02/13/2024", "14/02/2024"]:
            c.add(v)
        report = c.report()
        self.assertEqual(report.order, "day_first")
        self.assertEqual((report.conflicts, report.first_conflict), (1, 1))
        self.assertEqual(report.fits, frozenset())


class FormatStrings(unittest.TestCase):
    def test_dialects(self):
        layout = dateparsa.parse("13/02/2024 10:30").layout
        self.assertEqual(layout.format_string(), "%d/%m/%Y %H:%M")
        self.assertEqual(layout.format_string("go"), "02/01/2006 15:04")
        self.assertEqual(layout.format_string("java"), "dd/MM/yyyy HH:mm")
        with self.assertRaises(ValueError):
            layout.format_string("cobol")

    def test_python_reads_its_string(self):
        for s in ["2024-03-15T10:30:00.123+05:30", "Fri, 15 Mar 2024 10:30:00 +0000", "3/15/2024 10:30 PM"]:
            r = dateparsa.parse(s)
            got = dt.datetime.strptime(s, r.layout.format_string())
            want = r.datetime
            self.assertEqual(got.replace(tzinfo=got.tzinfo or UTC), want, s)

    def test_unsupported(self):
        with self.assertRaises(dateparsa.Unsupported):
            dateparsa.parse("December 23rd", base_time=BASE).layout.format_string()

    def test_parser_keeps_the_detected_value(self):
        # 1/2/2024 detects a one-digit layout; 1/3/2024 reuses it, and its
        # format string is still the one detected from 1/2/2024.
        p = dateparsa.Parser()
        p.parse("1/2/2024")
        self.assertEqual(p.parse("1/3/2024").layout.format_string("go"), "1/2/2006")


class Readme(unittest.TestCase):
    def test_the_example_runs(self):
        # python/README.md is the PyPI page: its example has to run.
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "README.md")
        with open(path, encoding="utf-8") as f:
            text = f.read()
        code = text.split("```python\n", 1)[1].split("```", 1)[0]
        scope = {}
        exec(compile(code, "python/README.md", "exec"), scope)
        self.assertEqual(scope["report"].order, "day_first")
        self.assertEqual(scope["r"].label, "MONTH_DAY_YEAR")
        self.assertEqual(scope["col"].failed, [1])


if __name__ == "__main__":
    unittest.main()

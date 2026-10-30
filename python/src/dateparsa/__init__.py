"""Date parsing for input whose format you do not control.

CSV imports, log lines, third-party APIs, user-typed strings: dateparsa works
out the format, parses the value, and hands you a layout that reads the rest
of the column with no detection.

    >>> import dateparsa
    >>> r = dateparsa.parse("March 15, 2024")
    >>> r.datetime
    datetime.datetime(2024, 3, 15, 0, 0, tzinfo=datetime.timezone.utc)
    >>> r.layout.format_string("strftime")
    '%B %d, %Y'

These are bindings to libdateparsa, the C interface of the Zig library
(https://github.com/kmoneil/dateparsa.zig), which ships inside this package.
Nothing here reads a clock: an input that needs a base time ("3 days ago")
raises NoBaseTime unless you pass base_time.
"""

from __future__ import annotations

import ctypes
import datetime as _dt
import functools
import os
import struct
import sys
import threading
from dataclasses import dataclass
from typing import Dict, FrozenSet, Iterable, List, NoReturn, Optional, Tuple, Union

__all__ = [
    "Ambiguous",
    "Column",
    "ColumnReport",
    "Error",
    "Interpretation",
    "LOCALES",
    "Layout",
    "NoBaseTime",
    "NoMatch",
    "ParsedColumn",
    "Parser",
    "Result",
    "Time",
    "Unsupported",
    "detect",
    "detect_column",
    "parse",
    "parse_column",
]

# Every locale there is, in the order of the C header's DATEPARSA_LOCALE_*
# bits.
_ALL_LOCALES = (
    "ar", "da", "de", "en", "es", "fi", "fr", "hi", "it", "ja",
    "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh",
)
_ORDERS = ("month_first", "day_first", "year_first")
_KINDS = ("absolute", "relative", "now")
_DIALECTS = ("strftime", "go", "java")

_OK, _NO_MATCH, _AMBIGUOUS, _NO_BASE_TIME, _INVALID, _TOO_SMALL, _UNSUPPORTED = range(7)


class _DateTime(ctypes.Structure):
    _fields_ = [
        ("year", ctypes.c_int32),
        ("month", ctypes.c_uint8),
        ("day", ctypes.c_uint8),
        ("hour", ctypes.c_uint8),
        ("minute", ctypes.c_uint8),
        ("second", ctypes.c_uint8),
        ("nanosecond", ctypes.c_uint32),
        ("offset_seconds", ctypes.c_int32),
    ]


class _Interpretation(ctypes.Structure):
    _fields_ = [("time", _DateTime), ("label", ctypes.c_void_p), ("label_len", ctypes.c_size_t)]


class _Diagnostics(ctypes.Structure):
    _fields_ = [
        ("interpretations", _Interpretation * 3),
        ("interpretation_count", ctypes.c_uint8),
        ("message", ctypes.c_void_p),
        ("message_len", ctypes.c_size_t),
    ]


class _Options(ctypes.Structure):
    _fields_ = [
        ("base_time", ctypes.POINTER(_DateTime)),
        ("timezone_offset", ctypes.c_int32),
        ("locales", ctypes.c_uint32),
        ("prefer_day_first", ctypes.c_bool),
        ("prefer_year_first", ctypes.c_bool),
        ("prefer_future", ctypes.c_bool),
        ("strict", ctypes.c_bool),
        ("diagnostics", ctypes.POINTER(_Diagnostics)),
    ]


def _opaque(size: int) -> type:
    return type(
        "_Opaque%d" % size,
        (ctypes.Union,),
        {"_fields_": [("bytes", ctypes.c_ubyte * size), ("align_u64_", ctypes.c_uint64), ("align_ptr_", ctypes.c_void_p)]},
    )


_LayoutBlob = _opaque(256)
_ParserBlob = _opaque(384)
_ColumnBlob = _opaque(256)


class _Result(ctypes.Structure):
    _fields_ = [
        ("time", _DateTime),
        ("unix_seconds", ctypes.c_int64),
        ("kind", ctypes.c_uint8),
        ("ambiguous", ctypes.c_bool),
        ("reusable", ctypes.c_bool),
        ("label", ctypes.c_void_p),
        ("label_len", ctypes.c_size_t),
        ("layout", _LayoutBlob),
    ]


class _Value(ctypes.Structure):
    _fields_ = [
        ("time", _DateTime),
        ("unix_seconds", ctypes.c_int64),
        ("kind", ctypes.c_uint8),
        ("ambiguous", ctypes.c_bool),
        ("status", ctypes.c_uint8),
    ]


# _DateTime, _Result up to its layout, and _Value as struct formats,
# natively aligned as ctypes lays the structs out: one unpack reads every
# field a result needs, where reading them one by one through ctypes costs
# four times as much. _VALUE's 0q pads it to _Value's size, as an array of
# them is laid out.
_DATETIME = struct.Struct("@iBBBBBIi")
_RESULT = struct.Struct("@iBBBBBIiqB??PN")
_VALUE = struct.Struct("@iBBBBBIiqB?B0q")
if (
    _DATETIME.size != ctypes.sizeof(_DateTime)
    or _RESULT.size != _Result.layout.offset
    or _VALUE.size != ctypes.sizeof(_Value)
    or _Value.status.offset != struct.calcsize("@iBBBBBIiqB?")
):
    raise ImportError("dateparsa: the struct formats do not match the C structs on this platform")


class _ColumnReport(ctypes.Structure):
    _fields_ = [
        ("order", ctypes.c_int32),
        ("fits", ctypes.c_uint32),
        ("prefer_day_first", ctypes.c_bool),
        ("prefer_year_first", ctypes.c_bool),
        ("values", ctypes.c_uint64),
        ("voted", ctypes.c_uint64),
        ("failed", ctypes.c_uint64),
        ("conflicts", ctypes.c_uint64),
        ("settled_by", ctypes.c_int64),
        ("first_conflict", ctypes.c_int64),
    ]


def _load() -> ctypes.CDLL:
    path = os.environ.get("DATEPARSA_LIB")
    if not path:
        if sys.platform == "win32":
            name = "dateparsa.dll"
        elif sys.platform == "darwin":
            name = "libdateparsa.dylib"
        else:
            name = "libdateparsa.so"
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    lib = ctypes.CDLL(path)
    P = ctypes.POINTER
    text = (ctypes.c_char_p, ctypes.c_size_t)
    sigs = {
        "dateparsa_version": ([], ctypes.c_char_p),
        "dateparsa_locales_compiled": ([], ctypes.c_uint32),
        "dateparsa_locale_lookup": ([*text, P(ctypes.c_uint32)], ctypes.c_int),
        "dateparsa_parse": ([*text, P(_Options), P(_Result)], ctypes.c_int),
        "dateparsa_detect": ([*text, P(_Options), P(_LayoutBlob)], ctypes.c_int),
        "dateparsa_layout_parse": ([P(_LayoutBlob), *text, P(_DateTime)], ctypes.c_int),
        "dateparsa_layout_reusable": ([P(_LayoutBlob)], ctypes.c_bool),
        "dateparsa_layout_label": ([P(_LayoutBlob), P(ctypes.c_size_t)], ctypes.c_void_p),
        "dateparsa_format_string": (
            [P(_LayoutBlob), ctypes.c_int, *text, ctypes.c_char_p, ctypes.c_size_t, P(ctypes.c_size_t)],
            ctypes.c_int,
        ),
        "dateparsa_layout_from_format": ([ctypes.c_int, *text, P(_Options), P(_LayoutBlob)], ctypes.c_int),
        "dateparsa_parser_init": ([P(_ParserBlob), P(_Options)], ctypes.c_int),
        "dateparsa_parser_parse": ([P(_ParserBlob), *text, P(_Result)], ctypes.c_int),
        "dateparsa_parser_reset": ([P(_ParserBlob)], None),
        "dateparsa_parse_column": (
            [*text, ctypes.c_ubyte, P(_Options), P(_Value), ctypes.c_size_t, P(ctypes.c_size_t)],
            ctypes.c_int,
        ),
        "dateparsa_column_init": ([P(_ColumnBlob), P(_Options)], ctypes.c_int),
        "dateparsa_column_add": ([P(_ColumnBlob), *text], ctypes.c_int),
        "dateparsa_column_summarize": ([P(_ColumnBlob), P(_ColumnReport)], ctypes.c_int),
    }
    for name, (args, res) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = args
        fn.restype = res
    return lib


_lib = _load()

__version__: str = _lib.dateparsa_version().decode()

#: The locales this build reads, by BCP 47 tag. English always.
LOCALES: Tuple[str, ...] = tuple(
    tag for i, tag in enumerate(_ALL_LOCALES) if _lib.dateparsa_locales_compiled() >> i & 1
)


class Error(ValueError):
    """Why an input did not parse."""


class NoMatch(Error):
    """No format, timestamp or natural-language reading fits the input."""


class NoBaseTime(Error):
    """The input needs a base time ("3 days ago", "10:30") and none was given."""


class Ambiguous(Error):
    """Strict mode: more than one reading fits. interpretations lists them,
    the preferred one first."""

    def __init__(self, message: str, interpretations: List["Interpretation"]):
        super().__init__(message)
        self.interpretations = interpretations


class Unsupported(Error):
    """A format string dialect cannot spell one of the format's fields."""


@dataclass(frozen=True)
class Time:
    """A civil date and time with a fixed UTC offset. year is astronomical
    (year 0 is 1 BC) and may lie outside what datetime holds."""

    year: int
    month: int
    day: int
    hour: int
    minute: int
    second: int
    nanosecond: int
    offset_seconds: int

    @property
    def tzinfo(self) -> _dt.timezone:
        return _zone(self.offset_seconds)

    def to_datetime(self) -> _dt.datetime:
        """An aware datetime, to the microsecond. ValueError for a year
        outside 1 to 9999."""
        return _dt.datetime(
            self.year, self.month, self.day, self.hour, self.minute, self.second,
            self.nanosecond // 1000, tzinfo=_zone(self.offset_seconds),
        )

    @classmethod
    def _from(cls, t: _DateTime) -> "Time":
        return _time(_DATETIME.unpack_from(t))


def _frozen(cls: type, fields: Dict[str, object]):
    """An instance of the frozen dataclass cls with these fields, which must
    be all of its own. A frozen dataclass's __init__ sets each field through
    object.__setattr__, and building a parse's Time and Result that way was
    a fifth of the call; this sets them in one step. eq, hash and repr read
    the same fields."""
    o = object.__new__(cls)
    object.__setattr__(o, "__dict__", fields)
    return o


def _time(f: Tuple) -> Time:
    """A Time from _DATETIME's fields, the first eight of f."""
    return _frozen(Time, {
        "year": f[0], "month": f[1], "day": f[2], "hour": f[3], "minute": f[4], "second": f[5],
        "nanosecond": f[6], "offset_seconds": f[7],
    })


_ZONES: Dict[int, _dt.timezone] = {0: _dt.timezone.utc}


def _zone(offset_seconds: int) -> _dt.timezone:
    """The timezone offset_seconds east of UTC, one object per offset."""
    zone = _ZONES.get(offset_seconds)
    if zone is None:
        zone = _dt.timezone(_dt.timedelta(seconds=offset_seconds))
        if len(_ZONES) < 256:
            _ZONES[offset_seconds] = zone
    return zone


@dataclass(frozen=True)
class Interpretation:
    """One way to read an input strict mode refused to choose for."""

    label: str
    time: Time


def _str(ptr: Optional[int], n: int) -> str:
    return ctypes.string_at(ptr, n).decode("utf-8") if n else ""


_LABELS: Dict[Tuple[int, int], str] = {}


def _label(ptr: int, n: int) -> str:
    """A format's name. The library's names are constants in its own memory,
    so a pointer and length always name the same one, and each is decoded
    once."""
    label = _LABELS.get((ptr, n))
    if label is None:
        label = _LABELS[(ptr, n)] = _str(ptr, n)
    return label


class Layout:
    """A detected format, compiled, to read the rest of a column with; or
    one read from a format string, with Layout.from_format."""

    __slots__ = ("_blob", "_sample", "label", "reusable")

    def __init__(self, blob, sample: Optional[bytes]):
        self._blob = blob
        self._sample = sample
        n = ctypes.c_size_t()
        self.label: str = _label(_lib.dateparsa_layout_label(blob, ctypes.byref(n)), n.value)
        #: Whether the rest of a column can be read with this layout: false
        #: for timestamps, natural language, and formats whose month and day
        #: are decided per value.
        self.reusable: bool = bool(_lib.dateparsa_layout_reusable(blob))

    @classmethod
    def _of(cls, r: _Result, sample: bytes, label: str, reusable: bool) -> "Layout":
        """The layout in a result, which already says its label and whether
        it is reusable: a view of the result's bytes, with no copy and no
        call."""
        layout = object.__new__(cls)
        layout._blob = r.layout
        layout._sample = sample
        layout.label = label
        layout.reusable = reusable
        return layout

    @classmethod
    def from_format(cls, format: str, dialect: str = "strftime", **options) -> "Layout":
        """The layout a format string reads, the inverse of format_string,
        for a column whose format is known: Layout.from_format("%d/%m/%Y")
        reads "01/02/2024" as the 1st of February, and is always reusable.

        Options: base_time, for a format with no year; timezone_offset, for
        one with no zone; locales, whose month and weekday names it reads
        besides English. Unsupported for a field no layout reads, such as
        %U; NoBaseTime for a format with no year and no base_time; and
        ValueError for a string that is no date format ("%d %Y")."""
        if dialect not in _DIALECTS:
            raise ValueError("dialect must be one of %s" % ", ".join(_DIALECTS))
        b = format.encode("utf-8")
        call = _Call(**options)
        blob = _LayoutBlob()
        status = _lib.dateparsa_layout_from_format(_DIALECTS.index(dialect), b, len(b), call.opts, blob)
        if status == _OK:
            return cls(blob, None)
        message = "%r: %s" % (format, _str(call.diag.message, call.diag.message_len))
        if status == _UNSUPPORTED:
            raise Unsupported(message)
        if status == _NO_BASE_TIME:
            raise NoBaseTime(message)
        raise ValueError(message)

    def parse(self, text: str) -> Time:
        """text read in this layout's format, with no detection. NoMatch
        when it is not written that way."""
        b = text.encode("utf-8")
        t = _DateTime()
        if _lib.dateparsa_layout_parse(self._blob, b, len(b), t) != _OK:
            raise NoMatch("%r is not written as %s" % (text, self.label))
        return _time(_DATETIME.unpack_from(t))

    def format_string(self, dialect: str = "strftime", value: Optional[str] = None) -> str:
        """The format as another tool's format string: "strftime" (C,
        Python, pandas), "go", or "java" (Java, Kotlin, Spark). Its
        separators and words are value's, a value the layout reads; by
        default the one it was detected from, which a layout from
        from_format does not have. Unsupported when the dialect cannot spell
        a field, such as an ordinal suffix."""
        if dialect not in _DIALECTS:
            raise ValueError("dialect must be one of %s" % ", ".join(_DIALECTS))
        sample = self._sample if value is None else value.encode("utf-8")
        if sample is None:
            raise ValueError("a layout from a format string spells it from a value it reads: pass value")
        buf = ctypes.create_string_buffer(1024)
        n = ctypes.c_size_t()
        status = _lib.dateparsa_format_string(
            self._blob, _DIALECTS.index(dialect), sample, len(sample),
            buf, len(buf), ctypes.byref(n),
        )
        if status == _UNSUPPORTED:
            raise Unsupported("%s cannot spell the format %s" % (dialect, self.label))
        if status != _OK:
            raise ValueError("this layout does not read %r" % sample.decode("utf-8", "replace"))
        return buf.raw[: n.value].decode("utf-8")

    def __repr__(self) -> str:
        return "Layout(%r)" % self.label


@dataclass(frozen=True)
class Result:
    """A successful parse."""

    time: Time
    #: Seconds since 1970-01-01T00:00:00Z; time.nanosecond is the rest.
    unix_seconds: int
    #: "absolute" ("2024-03-15", a timestamp), "relative" ("3 days ago") or
    #: "now" ("now", "today").
    kind: str
    #: The input needed a guess ("01/02/2024"), and the preferences made it.
    ambiguous: bool
    #: The format's name: "ISO8601_DATE", "NUMERIC_MDY", "NATURAL_LANGUAGE".
    label: str
    layout: Layout

    @property
    def datetime(self) -> _dt.datetime:
        """time as an aware datetime, to the microsecond."""
        return self.time.to_datetime()


def _bits(locales: Union[str, Iterable[str]]) -> int:
    return _locale_bits((locales,) if isinstance(locales, str) else tuple(locales))


@functools.lru_cache(maxsize=64)
def _locale_bits(tags: Tuple[str, ...]) -> int:
    bits = 0
    for tag in tags:
        b = tag.encode("utf-8")
        bit = ctypes.c_uint32()
        if _lib.dateparsa_locale_lookup(b, len(b), ctypes.byref(bit)) != _OK:
            raise ValueError("locale %r is not one this build reads (%s)" % (tag, ", ".join(LOCALES)))
        bits |= bit.value
    return bits


def _normalize(
    base_time: Optional[_dt.datetime] = None,
    timezone_offset: Union[int, _dt.timedelta] = 0,
    prefer_day_first: bool = False,
    prefer_year_first: bool = False,
    prefer_future: bool = False,
    strict: bool = False,
    locales: Union[str, Iterable[str]] = (),
) -> Tuple:
    """The keyword options as what _Options holds, in its order, with
    base_time as _DateTime's fields: a key for _shared_options."""
    base = None
    if base_time is not None:
        off = base_time.utcoffset()
        base = (
            base_time.year, base_time.month, base_time.day, base_time.hour, base_time.minute,
            base_time.second, base_time.microsecond * 1000, int(off.total_seconds()) if off else 0,
        )
    if isinstance(timezone_offset, _dt.timedelta):
        timezone_offset = int(timezone_offset.total_seconds())
    return (
        base, timezone_offset, _bits(locales),
        bool(prefer_day_first), bool(prefer_year_first), bool(prefer_future), bool(strict),
    )


def _make_options(key: Tuple, diag: Optional[_Diagnostics]) -> _Options:
    # A pointer stored in a field keeps what it points at alive.
    base, offset, bits, day_first, year_first, future, strict = key
    return _Options(
        ctypes.pointer(_DateTime(*base)) if base is not None else None,
        offset, bits, day_first, year_first, future, strict,
        ctypes.pointer(diag) if diag is not None else None,
    )


@functools.lru_cache(maxsize=64)
def _shared_options(key: Tuple) -> _Options:
    """The options for key, built once. They point at no diagnostics, so the
    library only reads them, and every call and thread may share them."""
    return _make_options(key, None)


def _options(options: dict) -> Optional[_Options]:
    """parse's and detect's keyword options for the C call: NULL for the
    defaults, else the shared struct for them."""
    return _shared_options(_normalize(**options)) if options else None


class _Call:
    """Options with diagnostics of their own to fill in: for a Parser or a
    Column, which keep their options, and for saying why a call failed."""

    def __init__(self, **options):
        self.diag = _Diagnostics()
        self.opts = _make_options(_normalize(**options), self.diag)

    def raise_for(self, status: int, text: str) -> NoReturn:
        d = self.diag
        message = _str(d.message, d.message_len)
        if status == _NO_MATCH:
            raise NoMatch("cannot parse %r: %s" % (text, message))
        if status == _NO_BASE_TIME:
            raise NoBaseTime("cannot parse %r: %s" % (text, message))
        if status == _AMBIGUOUS:
            ins = [
                Interpretation(_str(i.label, i.label_len), Time._from(i.time))
                for i in d.interpretations[: d.interpretation_count]
            ]
            raise Ambiguous("%r is ambiguous: %s" % (text, ", ".join(i.label for i in ins)), ins)
        raise ValueError(message or "invalid argument")


def _fail(fn, b: bytes, text: str, options: dict, out) -> NoReturn:
    """Raises for a parse or detect that failed. The first call passes no
    diagnostics, since a parse that succeeds has no use for them: this one
    runs it again with them, for the message and any readings. The library
    keeps no state, so it fails again the same way."""
    if options:
        call = _Call(**options)
    else:
        # The default options' diagnostics, one set a thread, since the
        # library writes them.
        call = getattr(_default_calls, "call", None)
        if call is None:
            call = _default_calls.call = _Call()
    call.raise_for(fn(b, len(b), call.opts, out), text)


_default_calls = threading.local()


def _result(r: _Result, sample: bytes) -> Result:
    f = _RESULT.unpack_from(r)
    label = _label(f[12], f[13])
    return _frozen(Result, {
        "time": _time(f),
        "unix_seconds": f[8],
        "kind": _KINDS[f[9]],
        "ambiguous": f[10],
        "label": label,
        "layout": Layout._of(r, sample, label, f[11]),
    })


def parse(text: str, **options) -> Result:
    """text parsed as a structured date, then a Unix timestamp, then natural
    language. Surrounding ASCII whitespace is padding.

    Options: base_time (a datetime, for relative and year-less inputs),
    timezone_offset (seconds or a timedelta, for inputs that write no zone),
    prefer_day_first, prefer_year_first, prefer_future, strict (raise
    Ambiguous instead of guessing), locales (BCP 47 tags besides English).
    """
    b = text.encode("utf-8")
    r = _Result()
    if _lib.dateparsa_parse(b, len(b), _options(options), r) != _OK:
        _fail(_lib.dateparsa_parse, b, text, options, r)
    return _result(r, b)


def detect(text: str, **options) -> Layout:
    """The layout text is written in, without its time."""
    b = text.encode("utf-8")
    blob = _LayoutBlob()
    if _lib.dateparsa_detect(b, len(b), _options(options), blob) != _OK:
        _fail(_lib.dateparsa_detect, b, text, options, blob)
    return Layout(blob, b)


class Parser:
    """Parses a column: caches the first value's layout and re-detects any
    value it cannot read, so each answer is what parse would give. Not for
    use by two threads at once."""

    def __init__(self, **options):
        self._call = _Call(**options)
        self._blob = _ParserBlob()
        self._layout = b""
        self._sample = b""
        status = _lib.dateparsa_parser_init(self._blob, self._call.opts)
        if status != _OK:
            self._call.raise_for(status, "")

    def parse(self, text: str) -> Result:
        b = text.encode("utf-8")
        r = _Result()
        status = _lib.dateparsa_parser_parse(self._blob, b, len(b), r)
        if status != _OK:
            self._call.raise_for(status, text)
        # The layout a format string is spelled from is the value it was
        # detected from: the earlier one, when this answer came from the cache.
        layout = bytes(r.layout.bytes)
        if layout != self._layout:
            self._layout, self._sample = layout, b
        return _result(r, self._sample)

    def reset(self) -> None:
        """Forgets the cached layout."""
        _lib.dateparsa_parser_reset(ctypes.byref(self._blob))
        self._layout = b""


class ParsedColumn:
    """A column parsed in one call: entry i is what values[i] parsed to.
    Each value has the answer parse gives it."""

    __slots__ = ("_data", "_n")

    def __init__(self, data: bytearray, n: int):
        # n _Values, as the C call wrote them.
        self._data = data
        self._n = n

    def __len__(self) -> int:
        return self._n

    def __repr__(self) -> str:
        return "ParsedColumn(%d values, %d failed)" % (self._n, len(self.failed))

    @property
    def failed(self) -> List[int]:
        """The indexes of the values that did not parse. parse on one of
        them raises the error that says why."""
        return [i for i, v in enumerate(_VALUE.iter_unpack(self._data)) if v[11] != _OK]

    @property
    def ambiguous(self) -> List[int]:
        """The indexes of the values that needed a guess ("01/02/2024")."""
        return [i for i, v in enumerate(_VALUE.iter_unpack(self._data)) if v[10]]

    def times(self) -> List[Optional[Time]]:
        """Each value's Time, or None where it did not parse."""
        return [_time(v) if v[11] == _OK else None for v in _VALUE.iter_unpack(self._data)]

    def datetimes(self) -> List[Optional[_dt.datetime]]:
        """Each value as an aware datetime, to the microsecond, or None
        where it did not parse. ValueError for a year outside 1 to 9999."""
        zone, datetime = _zone, _dt.datetime
        return [
            datetime(y, mo, d, h, mi, s, ns // 1000, zone(off)) if st == _OK else None
            for y, mo, d, h, mi, s, ns, off, _, _, _, st in _VALUE.iter_unpack(self._data)
        ]

    def datetime64(self):
        """The column as a numpy array of datetime64[ns] in UTC, NaT where a
        value did not parse: pandas reads it as a datetime column. Needs
        numpy, which this package does not depend on. ValueError for a time
        outside what datetime64[ns] holds (1677 to 2262)."""
        import numpy

        fields = numpy.frombuffer(self._data, dtype=_value_dtype(numpy))
        ok = fields["status"] == _OK
        seconds = numpy.where(ok, fields["unix_seconds"], 0)
        if seconds.size and (seconds.min() < -9_223_372_035 or seconds.max() > 9_223_372_035):
            raise ValueError("a time in the column is outside what datetime64[ns] holds")
        out = (seconds * 1_000_000_000 + fields["nanosecond"]).astype("datetime64[ns]")
        out[~ok] = numpy.datetime64("NaT", "ns")
        return out


def _value_dtype(numpy):
    """_Value as a numpy structured dtype, the fields datetime64 reads."""
    return numpy.dtype({
        "names": ["nanosecond", "unix_seconds", "status"],
        "formats": ["=u4", "=i8", "u1"],
        "offsets": [_DateTime.nanosecond.offset, _Value.unix_seconds.offset, _Value.status.offset],
        "itemsize": ctypes.sizeof(_Value),
    })


def parse_column(values: Iterable[Optional[str]], **options) -> ParsedColumn:
    """values parsed in one call, each as parse would parse it with these
    options, reusing one value's layout for the next where it can. A None
    is a value that does not parse. Takes the options parse takes.

    For a column, this is several times as fast as calling parse or a
    Parser once a value: the values cross into the library together."""
    values = list(values)
    n = len(values)
    data = bytearray(n * ctypes.sizeof(_Value))
    if n == 0:
        return ParsedColumn(data, 0)
    try:
        text = "\0".join(values)
    except TypeError:
        text = "\0".join("" if v is None else v for v in values)
    if text.count("\0") != n - 1:
        # A value holds the NUL that splits them: one call each instead.
        return _parse_each(values, options, data)
    b = (text + "\0").encode("utf-8")
    out = (_Value * n).from_buffer(data)
    count = ctypes.c_size_t()
    if _lib.dateparsa_parse_column(b, len(b), 0, _options(options), out, n, ctypes.byref(count)) != _OK:
        # Only the arguments fail a column call: run it again with
        # diagnostics, for why.
        call = _Call(**options)
        call.raise_for(_lib.dateparsa_parse_column(b, len(b), 0, call.opts, out, n, ctypes.byref(count)), "")
    return ParsedColumn(data, n)


def _parse_each(values: List[Optional[str]], options: dict, data: bytearray) -> ParsedColumn:
    """values parsed down a parser one call each, into data as
    parse_column fills it: for the column no separator can split."""
    call = _Call(**options)
    p = _ParserBlob()
    status = _lib.dateparsa_parser_init(p, call.opts)
    if status != _OK:
        call.raise_for(status, "")
    out = (_Value * len(values)).from_buffer(data)
    r = _Result()
    for i, v in enumerate(values):
        b = b"" if v is None else v.encode("utf-8")
        status = _lib.dateparsa_parser_parse(p, b, len(b), r)
        out[i].status = status
        if status == _OK:
            out[i].time = r.time
            out[i].unix_seconds = r.unix_seconds
            out[i].kind = r.kind
            out[i].ambiguous = r.ambiguous
    return ParsedColumn(data, len(values))


@dataclass(frozen=True)
class ColumnReport:
    """What a column's values say about the order of their numeric dates."""

    #: "month_first", "day_first" or "year_first": the one order every value
    #: with a say fits, or, when none fits them all, the one the fewest
    #: contradict. None when nothing settled it.
    order: Optional[str]
    #: The orders every value with a say fits; empty when they contradict.
    fits: FrozenSet[str]
    values: int
    #: Values in a format whose field order is decided per value.
    voted: int
    failed: int
    #: Values with a say that order does not fit, and the first of them.
    conflicts: int
    first_conflict: Optional[int]
    #: The index of the value after which order was the only one left.
    settled_by: Optional[int]
    prefer_day_first: bool
    prefer_year_first: bool

    @property
    def preferences(self) -> dict:
        """The options that read the column in order: parse(v, **report.preferences)."""
        return {"prefer_day_first": self.prefer_day_first, "prefer_year_first": self.prefer_year_first}


class Column:
    """Settles which order a column writes its numeric dates in, from all of
    its values: one "13/02/2024" means day first for all of it. Takes values
    one at a time and keeps only counts."""

    def __init__(self, **options):
        self._call = _Call(**options)
        self._blob = _ColumnBlob()
        status = _lib.dateparsa_column_init(ctypes.byref(self._blob), ctypes.byref(self._call.opts))
        if status != _OK:
            self._call.raise_for(status, "")

    def add(self, value: str) -> None:
        b = value.encode("utf-8")
        _lib.dateparsa_column_add(self._blob, b, len(b))

    def report(self) -> ColumnReport:
        r = _ColumnReport()
        _lib.dateparsa_column_summarize(ctypes.byref(self._blob), ctypes.byref(r))
        return ColumnReport(
            order=_ORDERS[r.order] if r.order >= 0 else None,
            fits=frozenset(o for i, o in enumerate(_ORDERS) if r.fits >> i & 1),
            values=r.values,
            voted=r.voted,
            failed=r.failed,
            conflicts=r.conflicts,
            first_conflict=r.first_conflict if r.first_conflict >= 0 else None,
            settled_by=r.settled_by if r.settled_by >= 0 else None,
            prefer_day_first=bool(r.prefer_day_first),
            prefer_year_first=bool(r.prefer_year_first),
        )


def detect_column(values: Iterable[str], **options) -> ColumnReport:
    """What a column's values say about the order of their numeric dates."""
    c = Column(**options)
    for v in values:
        c.add(v)
    return c.report()

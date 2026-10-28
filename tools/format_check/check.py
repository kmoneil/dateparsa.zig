"""Parses each strftime row of `zig build format-strings` with Python's
datetime.strptime and compares the fields the format sets with what
dateparsa read. Exits 1 on any difference."""
import sys
from datetime import datetime


def main():
    checked = failed = 0
    for line in sys.stdin:
        dialect, text, fmt, fields, want = line.rstrip("\n").split("\t")
        if dialect != "strftime" or fmt == "-":
            continue
        checked += 1
        y, mo, d, h, mi, s, ns, off = map(int, want.split())
        try:
            t = datetime.strptime(text, fmt)
        except ValueError as e:
            print(f"strftime: {text!r} with {fmt!r}: {e}")
            failed += 1
            continue
        # %Z reads UTC and GMT without setting a zone: their offset is 0.
        # Any other format that sets no zone has read none.
        utc = t.utcoffset()
        zone = int(utc.total_seconds()) if utc is not None else (0 if "%Z" in fmt else None)
        got = {"Y": t.year, "M": t.month, "D": t.day, "h": t.hour, "m": t.minute,
               "s": t.second, "f": t.microsecond, "z": zone}
        exp = {"Y": y, "M": mo, "D": d, "h": h, "m": mi, "s": s, "f": ns // 1000, "z": off}
        diff = [f"{c} {got[c]} != {exp[c]}" for c in fields if c in got and got[c] != exp[c]]
        if diff:
            print(f"strftime: {text!r} with {fmt!r}: {', '.join(diff)}")
            failed += 1
    print(f"strftime (Python {sys.version.split()[0]}): {checked} checked, {failed} failed")
    return 1 if failed or not checked else 0


sys.exit(main())

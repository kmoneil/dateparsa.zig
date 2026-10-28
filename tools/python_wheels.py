"""Builds the Python wheels from the release libraries in zig-out/dist: one
wheel per platform, holding python/src/dateparsa and that platform's shared
library. ctypes needs no CPython ABI, so each is tagged py3-none-<platform>.
The Linux library links no libc, so its wheel is tagged for glibc and musl
alike. The wheels are written byte for byte the same on every run.

    tools/dist.sh && python3 -I tools/python_wheels.py
"""

import base64
import hashlib
import io
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "zig-out", "dist")
OUT = os.path.join(ROOT, "zig-out", "wheels")

# Release platform: the wheel's platform tags, and where the archive keeps
# the shared library and the name the package loads it by.
PLATFORMS = {
    "x86_64-linux": ("manylinux_2_17_x86_64.manylinux2014_x86_64.musllinux_1_1_x86_64", "lib/libdateparsa.so.{v}", "libdateparsa.so"),
    "aarch64-linux": ("manylinux_2_17_aarch64.manylinux2014_aarch64.musllinux_1_1_aarch64", "lib/libdateparsa.so.{v}", "libdateparsa.so"),
    "x86_64-macos": ("macosx_13_0_x86_64", "lib/libdateparsa.{v}.dylib", "libdateparsa.dylib"),
    "aarch64-macos": ("macosx_13_0_arm64", "lib/libdateparsa.{v}.dylib", "libdateparsa.dylib"),
    "x86_64-windows": ("win_amd64", "bin/dateparsa.dll", "dateparsa.dll"),
    "aarch64-windows": ("win_arm64", "bin/dateparsa.dll", "dateparsa.dll"),
}

SUMMARY = (
    "Date parsing for input whose format you do not control: format detection, "
    "ambiguity reported, 20 locales, natural language, column order, format strings."
)


def metadata(version: str) -> str:
    with open(os.path.join(ROOT, "python", "README.md"), encoding="utf-8") as f:
        readme = f.read()
    headers = [
        "Metadata-Version: 2.1",
        "Name: dateparsa",
        "Version: " + version,
        "Summary: " + SUMMARY,
        "Author: Kevin O'Neil",
        "License: Apache-2.0",
        "Project-URL: Source, https://github.com/kmoneil/dateparsa.zig",
        "Project-URL: Changelog, https://github.com/kmoneil/dateparsa.zig/blob/main/CHANGELOG.md",
        "Keywords: date,datetime,parser,dateparser,natural-language,locales,csv,format-detection",
        "Classifier: Development Status :: 4 - Beta",
        "Classifier: Intended Audience :: Developers",
        "Classifier: License :: OSI Approved :: Apache Software License",
        "Classifier: Operating System :: MacOS",
        "Classifier: Operating System :: Microsoft :: Windows",
        "Classifier: Operating System :: POSIX :: Linux",
        "Classifier: Programming Language :: Python :: 3",
        "Classifier: Topic :: Text Processing",
        "Classifier: Typing :: Typed",
        "Requires-Python: >=3.9",
        "Description-Content-Type: text/markdown",
    ]
    return "\n".join(headers) + "\n\n" + readme


def wheel(tags: str) -> str:
    lines = ["Wheel-Version: 1.0", "Generator: dateparsa tools/python_wheels.py", "Root-Is-Purelib: false"]
    lines += ["Tag: py3-none-" + t for t in tags.split(".")]
    return "\n".join(lines) + "\n"


def record_hash(data: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return "sha256=" + digest.decode()


def build(archive_dir: str, version: str, platform: str) -> str:
    tags, lib_path, lib_name = PLATFORMS[platform]
    with open(os.path.join(archive_dir, lib_path.format(v=version)), "rb") as f:
        lib = f.read()
    src = os.path.join(ROOT, "python", "src", "dateparsa")
    info = "dateparsa-%s.dist-info" % version
    files = []
    for name in sorted(os.listdir(src)):
        if name.endswith(".py") or name == "py.typed":
            with open(os.path.join(src, name), "rb") as f:
                files.append(("dateparsa/" + name, f.read(), 0o644))
    files.append(("dateparsa/" + lib_name, lib, 0o755))
    for name in ("LICENSE", "NOTICE"):
        with open(os.path.join(ROOT, name), "rb") as f:
            files.append(("%s/%s" % (info, name), f.read(), 0o644))
    files.append((info + "/METADATA", metadata(version).encode(), 0o644))
    files.append((info + "/WHEEL", wheel(tags).encode(), 0o644))
    record = "".join("%s,%s,%d\n" % (p, record_hash(d), len(d)) for p, d, _ in files)
    record += info + "/RECORD,,\n"
    files.append((info + "/RECORD", record.encode(), 0o644))

    name = "dateparsa-%s-py3-none-%s.whl" % (version, tags)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for path, data, mode in files:
            zi = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            zi.external_attr = (0o100000 | mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(buf.getvalue())
    return name


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    built = 0
    for entry in sorted(os.listdir(DIST)):
        m = re.fullmatch(r"dateparsa-(\d+\.\d+\.\d+)-(.+)", entry)
        if not m or not os.path.isdir(os.path.join(DIST, entry)):
            continue
        version, platform = m.groups()
        print(build(os.path.join(DIST, entry), version, platform))
        built += 1
    if built != len(PLATFORMS):
        print("built %d wheels, expected %d: run tools/dist.sh first" % (built, len(PLATFORMS)), file=sys.stderr)
        return 1
    return 0


sys.exit(main())

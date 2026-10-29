#!/bin/sh
# Runs dateparsa against other date parsers on this machine, and prints a
# table per language: zeit in Zig; chrono, jiff, time, speedate and
# dateparser in Rust, through the C interface; and fromisoformat, strptime,
# ciso8601, dateutil, dateparser and pandas in Python, through the package.
#
#   tools/bench_others.sh [zig] [rust] [python]    default: all three
#
# COUNT rounds (default 10), BENCHTIME milliseconds a run (default 200).
# Needs zig, and cargo for Rust and uv for Python; uv fetches Python 3.13 and
# the pinned bench/others/python/requirements.txt. What is built lands in
# _bench/others.
#
# Same-machine comparison only, as with tools/bench.sh: how two cells of a
# table compare holds for this machine, and a time from one means nothing
# next to a time measured elsewhere.
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
out=$root/_bench/others
count=${COUNT:-10}
benchtime=${BENCHTIME:-200}
langs=${*:-zig rust python}
mkdir -p "$out"
load_start=$(uptime | sed 's/.*load averages*: //')

for lang in $langs; do
    case "$lang" in
    zig | rust | python) ;;
    *)
        echo "usage: tools/bench_others.sh [zig] [rust] [python]" >&2
        exit 2
        ;;
    esac
done

# The shared library, as a release archive and the Python package carry
# it: the Python harness loads it, and what it imports is printed last.
zig build lib -Dlinkage=dynamic -Doptimize=ReleaseFast -p "$out/shared"
case "$(uname -s)" in
Darwin) lib=$out/shared/lib/libdateparsa.dylib ;;
MINGW* | MSYS* | CYGWIN*) lib=$out/shared/bin/dateparsa.dll ;;
*) lib=$out/shared/lib/libdateparsa.so ;;
esac

cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null ||
    sed -n 's/^model name[^:]*: //p' /proc/cpuinfo | head -1)
echo "dateparsa.zig $(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo ' (uncommitted changes)') (Zig $(zig version))"
echo "$cpu, $(uname -sm), $(date -u +%Y-%m-%d), $count rounds of ${benchtime}ms runs"
echo "Load averages at the start $load_start"

for lang in $langs; do
    echo
    case "$lang" in
    zig)
        zeit=$(sed -n 's/.*zeit#\([0-9a-f]\{7\}\).*/\1/p' bench/others/zig/build.zig.zon)
        echo "### Zig: zeit $(sed -n 's/.*"\(zeit-[0-9.]*\)-.*/\1/p' bench/others/zig/build.zig.zon | sed 's/zeit-//') ($zeit)"
        echo
        (cd bench/others/zig && zig build run --pkg-dir "$out/zig-pkg" --cache-dir "$out/zig-cache" \
            -p "$out/zig-out" -- -count "$count" -benchtime "$benchtime")
        ;;
    rust)
        crates=$(awk '/^name = / { name = $3 } /^version = / && name ~ /^"(chrono|dateparser|jiff|speedate|time)"$/ {
            gsub(/"/, "", name); gsub(/"/, "", $3); printf "%s%s %s", sep, name, $3; sep = ", " }' \
            bench/others/rust/Cargo.lock)
        echo "### Rust: $crates ($(rustc --version | cut -d' ' -f1-2))"
        echo
        CARGO_TARGET_DIR="$out/cargo-target" cargo run --quiet --release --locked \
            --manifest-path bench/others/rust/Cargo.toml -- -count "$count" -benchtime "$benchtime"
        ;;
    python)
        DATEPARSA_LIB=$lib uv run --quiet --no-project --python 3.13 \
            --with-requirements bench/others/python/requirements.txt \
            python bench/others/python/bench.py -count "$count" -benchtime "$benchtime"
        ;;
    esac
done

echo
echo "### What libdateparsa imports"
echo
# Its undefined symbols: the functions it calls that it does not hold.
if command -v nm >/dev/null 2>&1; then
    nm -u "$lib" | sort -u | sed 's/^/    /'
else
    echo "    (no nm here)"
fi
echo
echo "Load averages at the end $(uptime | sed 's/.*load averages*: //')"

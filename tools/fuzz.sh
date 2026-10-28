#!/bin/sh
# Runs the fuzz targets in src/fuzz_test.zig under Zig's fuzzer and fails if
# one of them found an input it fails on.
#
#   tools/fuzz.sh [LIMIT]    LIMIT as zig build --fuzz takes it (default 1M)
#
# Zig 0.17.0's `zig build --fuzz` exits 0 when a fuzz test fails, so the
# failure is read from its output instead. The file it names as the saved
# input comes out empty (it is never flushed), so the input is read from the
# fuzzer's own input files, .zig-cache/f/in<N>: a 20-byte header whose last
# u32 is the length, then the input. Each is printed in hex. An input is
# what the target's Smith read: each string a four-byte little-endian length
# and its bytes, then the options byte as eight. Add its strings to the seeds
# in src/fuzz_test.zig before fixing what it found.
set -eu

limit=${1:-1M}
cd "$(dirname "$0")/.."
log=$(mktemp)
trap 'rm -f "$log" "$log.status"' EXIT

# The status is caught rather than left to set -e, which would end the
# group before it is written.
{
    status=0
    zig build fuzz --fuzz="$limit" 2>&1 || status=$?
    echo "$status" >"$log.status"
} | tee "$log"

status=$(cat "$log.status")
if [ "$status" -ne 0 ]; then
    exit "$status"
fi
if grep -q "input saved to" "$log"; then
    for f in .zig-cache/f/in*; do
        test_i=$(od -A n -t u4 -j 12 -N 4 "$f" | tr -d ' ')
        len=$(od -A n -t u4 -j 16 -N 4 "$f" | tr -d ' ')
        echo "last input of $f, fuzz test $test_i, $len bytes:"
        od -A d -t x1 -j 20 -N "$len" "$f"
    done
    exit 1
fi

#!/bin/sh
# Runs the fuzz targets in src/fuzz_test.zig under Zig's fuzzer and fails if
# one of them found an input it fails on.
#
#   tools/fuzz.sh [LIMIT]    LIMIT as zig build --fuzz takes it (default 1M)
#
# Zig 0.17.1's `zig build --fuzz` exits 0 when a fuzz test fails, whether it
# returned an error ("exited with code 1") or panicked ("terminated with
# signal ABRT"), so the failure is read from its output instead: the line
# ending "; input saved to '<file>'". That file (.zig-cache/f/crash) holds
# the whole failing input, printed here in hex. An input is what the
# target's Smith read: each string a four-byte little-endian length and its
# bytes, each value eight bytes. The bytes as they stand are a seed: add
# them to the seeds in src/fuzz_test.zig before fixing what it found.
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
# Found by the phrase alone, so a change in the rest of the line cannot turn
# a find into a pass; the file is then read from it where it can be.
if grep -q "input saved to" "$log"; then
    sed -n "s/.*input saved to '\([^']*\)'.*/\1/p" "$log" | while IFS= read -r f; do
        if [ -s "$f" ]; then
            echo "failing input, $f, $(wc -c <"$f" | tr -d ' ') bytes:"
            od -A d -t x1 "$f"
        else
            echo "the runner named $f for the failing input, but it is missing or empty"
        fi
    done
    exit 1
fi

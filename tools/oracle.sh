#!/bin/sh
# Runs the Go dateparsa and this port on the same inputs and diffs their
# answers: the public API under nine option sets with layout reuse, and the
# natural-language parser across every locale. Needs `go` and the Go
# repository; nothing here runs in `zig build test`.
#
#   tools/oracle.sh [path to the Go dateparsa checkout]
#
# The Go repository is copied to a scratch directory and the harnesses in
# tools/oracle are dropped into the copy, so the checkout is never written.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
go_repo=${1:-$repo/../../golang/go-dateparser}
go_repo=$(cd "$go_repo" && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Go checkout: $go_repo ($(git -C "$go_repo" describe --tags --always 2>/dev/null || echo unknown))"
rsync -a --exclude .git "$go_repo"/ "$work/go/"
cp "$repo/tools/oracle/api_oracle_test.go.txt" "$work/go/zz_api_oracle_test.go"
cp "$repo/tools/oracle/natural_oracle_test.go.txt" "$work/go/internal/natural/zz_oracle_test.go"

(cd "$work/go" && ORACLE_OUT="$work/go_api.txt" go test -run TestZZAPIOracle -count=1 . >/dev/null)
(cd "$work/go" && ORACLE_OUT="$work/go_natural.txt" go test -run TestZZOracle -count=1 ./internal/natural >/dev/null)

cd "$repo"
zig build oracle-api -- "$work/go_api.txt" "$work/zig_api.txt"
zig build oracle-natural -- "$work/go_natural.txt" "$work/zig_natural.txt"

status=0
for mode in api natural; do
    lines=$(wc -l < "$work/go_$mode.txt" | tr -d ' ')
    if diff "$work/go_$mode.txt" "$work/zig_$mode.txt" > "$work/$mode.diff"; then
        echo "$mode: $lines answers, identical"
    else
        status=1
        echo "$mode: $(grep -c '^<' "$work/$mode.diff") of $lines answers differ; first ten:"
        head -20 "$work/$mode.diff"
    fi
done
exit $status

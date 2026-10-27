#!/bin/sh
# Runs the Go dateparsa's benchmarks and this port's, which carry the same
# names, on this machine, and prints a table comparing them.
#
#   tools/bench.sh [GO_DIR]    GO_DIR defaults to ../../golang/go-dateparser
#
# COUNT rounds (default 10), BENCHTIME milliseconds a run (default 350), BENCH
# a name fragment (default all). Raw runs land in _bench/go.txt and
# _bench/zig.txt in Go's format, for benchstat.
#
# Each round runs every benchmark on both sides back to back, Go first in odd
# rounds and Zig first in even ones, so the two halves of a pair see the same
# machine. The ratio reported is the median of the per-round Zig / Go ratios,
# with the range of the middle ones, which drift in the machine moves far less
# than it moves either side's own times: on a busy laptop a side's runs spread
# by 20% and more while the pairs agree. A ratio whose range is wider than 0.2
# is marked; it says less than its median suggests.
#
# Same-machine comparison only. A ratio from this table holds for this
# machine; a ns/op from it means nothing next to one measured elsewhere.
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
go_dir=${1:-../../golang/go-dateparser}
count=${COUNT:-10}
benchtime=${BENCHTIME:-350}
out=$root/_bench
mkdir -p "$out"
load_start=$(uptime | sed 's/.*load averages*: //')

(cd "$go_dir" && go test -c -o "$out/go.test" .)
zig build bench-install -p "$out/zig-out"
zig_bench=$out/zig-out/bin/bench
names=$("$zig_bench" -list -bench "${BENCH:-}" | tr '\n' ' ')

go_run() {
    (cd "$go_dir" && "$out/go.test" -test.run '^$' -test.bench "^Benchmark$1\$" \
        -test.count 1 -test.benchtime "${benchtime}ms" -test.benchmem) |
        grep '^Benchmark' | sed "s/\$/	round=$2/" >>"$out/go.txt"
}
zig_run() {
    "$zig_bench" -count 1 -benchtime "$benchtime" -bench "^$1\$" |
        grep '^Benchmark' | sed "s/\$/	round=$2/" >>"$out/zig.txt"
}

: >"$out/go.txt"
: >"$out/zig.txt"
round=1
while [ "$round" -le "$count" ]; do
    echo "round $round of $count" >&2
    for name in $names; do
        if [ $((round % 2)) -eq 1 ]; then
            go_run "$name" "$round"
            zig_run "$name" "$round"
        else
            zig_run "$name" "$round"
            go_run "$name" "$round"
        fi
    done
    round=$((round + 1))
done

load_end=$(uptime | sed 's/.*load averages*: //')
go_rev=$(git -C "$go_dir" describe --tags --always 2>/dev/null || echo unknown)
cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null ||
    sed -n 's/^model name[^:]*: //p' /proc/cpuinfo | head -1)
echo "Go $go_rev ($(go version | cut -d' ' -f3)) against dateparsa.zig $(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo ' (uncommitted changes)') (Zig $(zig version))"
echo "$cpu, $(uname -sm), $(date -u +%Y-%m-%d), $count rounds of ${benchtime}ms runs"
echo "Load averages at the start $load_start, at the end $load_end"
echo

# One line per benchmark and round: name round go zig. Then per name the
# median of each side and of the ratios, and the ratios' middle range.
for side in go zig; do
    awk -v side="$side" '/^Benchmark/ {
        name = $1; sub(/^Benchmark/, "", name); sub(/-[0-9]+$/, "", name)
        round = $NF; sub(/^round=/, "", round)
        for (f = 2; f < NF; f++) if ($(f + 1) == "ns/op") print name, round, side, $f
    }' "$out/$side.txt"
done | awk -v order="$names" '
    function median(a, n,    i, j, t) {
        for (i = 2; i <= n; i++) for (j = i; j > 1 && a[j - 1] > a[j]; j--) {
            t = a[j]; a[j] = a[j - 1]; a[j - 1] = t
        }
        return n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
    }
    function fmt(x) { return x >= 1e6 ? sprintf("%.1f ms", x / 1e6) : x >= 100 ? sprintf("%.0f", x) : sprintf("%.1f", x) }
    { t[$1, $2, $3] = $4; if ($2 > rounds) rounds = $2 }
    END {
        print "| Benchmark | Go ns/op | Zig ns/op | Zig / Go | middle range |"
        print "|---|--:|--:|--:|--:|"
        n = split(order, names, " ")
        for (k = 1; k <= n; k++) {
            name = names[k]; m = 0
            for (r = 1; r <= rounds; r++) {
                if (!((name, r, "go") in t) || !((name, r, "zig") in t)) continue
                m++; g[m] = t[name, r, "go"]; z[m] = t[name, r, "zig"]; q[m] = z[m] / g[m]
            }
            if (m == 0) continue
            mg = median(g, m); mz = median(z, m); mq = median(q, m)
            lo = m > 2 ? q[2] : q[1]; hi = m > 2 ? q[m - 1] : q[m]
            mark = hi - lo > 0.2 ? " (wide)" : ""
            printf "| %s | %s | %s | %.2f%s | %.2f to %.2f |\n", name, fmt(mg), fmt(mz), mq, mark, lo, hi
        }
    }'
if command -v benchstat >/dev/null 2>&1; then
    echo
    benchstat "go=$out/go.txt" "zig=$out/zig.txt"
fi

#!/bin/sh
# Runs the fuzz targets in src/fuzz_test.zig under Zig's fuzzer and fails if
# one of them found an input it fails on.
#
#   tools/fuzz.sh [LIMIT [ROUND]]    LIMIT as zig build --fuzz takes it
#                                    (default 1M), ROUND at a time
#                                    (default all of it at once)
#   FUZZ_DEADLINE=T tools/fuzz.sh 1G 200K
#                                    rounds until the Unix time T nears
#
# Both counts are per target: `--fuzz=N` gives every target N inputs, so a
# round of 200K over 13 targets is 2.6M inputs.
#
# Rounds: each is a fresh `zig build fuzz` that starts from the corpus the
# last one kept in .zig-cache/f, and the first round that finds something
# ends the run. Zig 0.17's fuzzer grows its memory for as long as one
# process runs, so a long run is better as rounds anyway.
#
# The deadline is the time this script must have exited by, so whatever
# comes after it (saving the corpus) has the time that is left. A round
# starts only if half again the last round's time still fits 240 s before
# it, so a run with a deadline stops on time however many targets there are
# and however fast the machine is. A round still running 240 s before the
# deadline is cut, with its whole process group (the fuzzer too, which
# would otherwise outlive `zig build` and change the corpus while it is
# saved), and the script exits 124: a round that far past the last one is a
# hang the fuzzer found, or something as wrong. FUZZ_DEADLINE defaults to
# VMRUN_DEADLINE, the time a vmrun VM deletes itself at.
#
# Zig 0.17.1's `zig build --fuzz` cannot be trusted to fail when a fuzz test
# does, whether the test returned an error ("exited with code 1") or
# panicked ("terminated with signal ABRT"): it has exited 0 after one find,
# and 1 after another, a seed that failed. So a find is read from its output
# first, whatever it exited with: the line ending
# "; input saved to '<file>'". That file (.zig-cache/f/crash) holds
# the whole failing input, printed here in hex. An input is what the
# target's Smith read: each string a four-byte little-endian length and its
# bytes, each value eight bytes. The bytes as they stand are a seed: add
# them to the seeds in src/fuzz_test.zig before fixing what it found.
#
# On GitHub Actions, where GITHUB_STEP_SUMMARY is set, the job's summary
# says what the run did, and a find is written there too, so the run's page
# says what was found without the log, and does so even when no issue could
# be opened for it.
set -eu

limit=${1:-1M}
round=${2:-$limit}
deadline=${FUZZ_DEADLINE:-${VMRUN_DEADLINE:-}}
margin=240
cd "$(dirname "$0")/.."
log=$(mktemp)
trap 'rm -f "$log" "$log.status" "$log.find"' EXIT

summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$1" >>"$GITHUB_STEP_SUMMARY"
    fi
}

# A count as zig build --fuzz writes it (10K, 1M, 2G), as a number.
count() {
    case "$1" in
    *K) echo $((${1%K} * 1000)) ;;
    *M) echo $((${1%M} * 1000000)) ;;
    *G) echo $((${1%G} * 1000000000)) ;;
    *) echo "$1" ;;
    esac
}

left=$(count "$limit")
step=$(count "$round")
if [ "$step" -le 0 ] || [ "$left" -le 0 ]; then
    echo "fuzz.sh: LIMIT and ROUND must be counts above 0, as zig build --fuzz takes them (50K, 1M)" >&2
    exit 2
fi
if [ -n "$deadline" ] && ! command -v timeout >/dev/null; then
    echo "fuzz.sh: a deadline needs timeout(1) to cut a round that runs past it" >&2
    exit 2
fi

start=$(date +%s)
last=0
ran=0
i=1
stopped=""
while [ "$left" -gt 0 ]; do
    runs=$step
    if [ "$runs" -gt "$left" ]; then
        runs=$left
    fi
    cap=""
    if [ -n "$deadline" ]; then
        now=$(date +%s)
        cap=$((deadline - now - margin))
        if [ $((now + last * 3 / 2 + margin)) -gt "$deadline" ] || [ "$cap" -lt 60 ]; then
            stopped="at the deadline"
            echo "fuzz.sh: stopping before round $i: it might not end ${margin}s before the deadline"
            break
        fi
    fi

    echo "fuzz.sh: round $i, $runs runs per target"
    t0=$(date +%s)
    # The status is caught rather than left to set -e, which would end the
    # group before it is written.
    {
        status=0
        if [ -n "$cap" ]; then
            timeout -k 30 "$cap" zig build fuzz --fuzz="$runs" 2>&1 || status=$?
        else
            zig build fuzz --fuzz="$runs" 2>&1 || status=$?
        fi
        echo "$status" >"$log.status"
    } | tee "$log"
    status=$(cat "$log.status")

    # Found by the phrase alone, so a change in the rest of the line cannot
    # turn a find into a pass; the file is then read from it where it can be.
    if grep -q "input saved to" "$log"; then
        sed -n "s/.*input saved to '\([^']*\)'.*/\1/p" "$log" | while IFS= read -r f; do
            if [ -s "$f" ]; then
                echo "failing input, $f, $(wc -c <"$f" | tr -d ' ') bytes:"
                od -A d -t x1 "$f"
            else
                echo "the runner named $f for the failing input, but it is missing or empty"
            fi
        done | tee "$log.find"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            {
                echo "## A fuzz target found a failing input"
                echo
                echo "In round $i, after $ran earlier runs per target."
                echo
                echo '```'
                grep "input saved to" "$log"
                cat "$log.find"
                echo '```'
                echo
                echo "Its bytes as they stand are a seed for that target in src/fuzz_test.zig."
                echo "The run's fuzz-failure artifact keeps the log and the input."
            } >>"$GITHUB_STEP_SUMMARY"
        fi
        exit 1
    fi
    if [ -n "$cap" ] && { [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; }; then
        took=$(($(date +%s) - t0))
        # The first round has no earlier one to be measured against, and it
        # also builds the fuzz tests and loads the corpus: cut, it says
        # the deadline is too near as much as that something hung.
        if [ "$i" -eq 1 ]; then
            why="The first round, which also builds the fuzz tests and loads the corpus, did not fit: give it more time or a smaller ROUND, unless it hung"
        else
            why="The last round took ${last}s: a hang the fuzzer found, or something as wrong"
        fi
        echo "fuzz.sh: round $i was still running ${took}s in, ${margin}s before the deadline, and was cut. $why. The in<N> files under .zig-cache/f hold what each fuzzer was last running."
        summary "## Fuzzing was cut: round $i was still running ${took}s in, ${margin}s before the deadline ($why)"
        exit 124
    fi
    if [ "$status" -ne 0 ]; then
        exit "$status"
    fi
    last=$(($(date +%s) - t0))
    echo "fuzz.sh: round $i took ${last}s"
    ran=$((ran + runs))
    left=$((left - runs))
    i=$((i + 1))
done

rounds=$((i - 1))
if [ "$rounds" -eq 0 ]; then
    echo "fuzz.sh: no round fitted before the deadline" >&2
    summary "## Nothing was fuzzed: no round fitted before the deadline"
    exit 2
fi
took=$(($(date +%s) - start))
echo "fuzz.sh: $rounds round(s), $ran runs per target in ${took}s${stopped:+, stopped $stopped}; nothing found"
summary "Fuzzing found nothing: $rounds round(s), $ran runs per target, in $((took / 60)) min${stopped:+, stopped $stopped}."

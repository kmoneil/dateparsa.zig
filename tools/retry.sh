# Sourced, not run: defines `retry`, which runs a command until it succeeds,
# up to RETRY_ATTEMPTS times (default 4), pausing RETRY_PAUSE seconds
# (default 15) times the attempt number between tries: 15, 30, 45.
#
#   . tools/retry.sh
#   retry gh issue list ...
#
# For a call to a service that fails now and then, such as gh: on 2026-11-05
# the nightly fuzz run found a real failure and opened no issue, because one
# `gh issue list` met one GraphQL error. The command can be a shell function,
# so a redirect, or a read and the write that depends on it, goes inside one
# and is retried whole. Only for what is safe to run again.
#
# Its own variables are named so no command it runs shares one: a shell
# function sees, and can change, the locals of the function that called it.
retry() {
    local _retry_max=${RETRY_ATTEMPTS:-4} _retry_n=1 _retry_status _retry_pause
    while :; do
        "$@" && return 0
        _retry_status=$?
        if [ "$_retry_n" -ge "$_retry_max" ]; then
            echo "retry: $1 failed $_retry_n times, the last with exit $_retry_status" >&2
            return "$_retry_status"
        fi
        _retry_pause=$((${RETRY_PAUSE:-15} * _retry_n))
        echo "retry: $1 failed with exit $_retry_status (attempt $_retry_n of $_retry_max), again in ${_retry_pause}s" >&2
        sleep "$_retry_pause"
        _retry_n=$((_retry_n + 1))
    done
}

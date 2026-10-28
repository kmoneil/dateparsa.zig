#!/bin/sh
# Checks the format strings layouts give in the tools that read them. Python's
# strptime, Go's time.Parse and Java's DateTimeFormatter each parse every
# example in tools/format_strings.zig with that dialect's format string and
# must read the fields it sets as dateparsa did. Needs python3, go and java.
#
#   tools/format_check.sh
set -eu

cd "$(dirname "$0")/.."
table=$(mktemp)
trap 'rm -f "$table"' EXIT
zig build format-strings >"$table"

status=0
python3 -I tools/format_check/check.py <"$table" || status=1
go run tools/format_check/check.go <"$table" || status=1
java tools/format_check/Check.java <"$table" || status=1
exit "$status"

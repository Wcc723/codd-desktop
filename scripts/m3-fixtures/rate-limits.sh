#!/bin/bash
# Writes the `rate_limits` object fake-claude-m3.sh puts into its status line input
# (FAKE_RATE_LIMITS_FILE; re-read on every status line run), in Claude Code's shape:
#   {"five_hour":{"used_percentage":<n>,"resets_at":<epoch s>},"seven_day":{…}}
#
#   scripts/m3-fixtures/rate-limits.sh <file> <5h used> <5h reset epoch s|-> <7d used> <7d reset epoch s|->
#   -> prints <file>
#
# `-` as the used value or the reset omits that window (both omitted -> `{}`, which the fake claude
# treats like Claude Code: no `rate_limits` key at all). Used values are written as given (any JSON
# number, no clamping); a reset may also be epoch ms or an ISO 8601 string, for CODD's tolerant
# decoding. The write is atomic (temp file + rename). Refusals exit 1, bad arguments exit 2.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PY="${PYTHON3:-}"
if [[ -z "$PY" ]]; then
    if [[ -x /usr/bin/python3 ]]; then PY=/usr/bin/python3; else PY=python3; fi
fi
exec "$PY" -I "$HERE/_m3fix.py" rate-limits "$@"

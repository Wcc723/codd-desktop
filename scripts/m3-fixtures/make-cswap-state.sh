#!/bin/bash
# Writes a fake cswap 0.26 state root for CODD's M3 tests (docs/M3-PLAN.md C9, §1, §3), in exactly
# the formats cswap itself writes: sequence.json, cache/usage.json (schemaVersion 2),
# configs/.claude-config-<n>-<email>.json, the `cswap run` profile sessions/2-north_example.com/ and the
# matching <claudeDir>/../.claude.json (active login = #3). E-mails are *@example.com only.
#
#   scripts/m3-fixtures/make-cswap-state.sh <tmp>/home/.claude-swap-backup <tmp>/home/.claude \
#       [--now <iso>] [--accounts 3|4] [--stale <n>]
#   -> prints the root
#
# <cswapRoot> must end in .claude-swap-backup; <claudeDir>'s parent must be a dedicated folder (not
# $TMPDIR, /tmp or /private/tmp itself). On a root that already has sequence.json only --stale <n> is
# applied (cswap's stale marker for profile n, the profile created when missing); anything else is
# refused. Refusals (also any target inside ~ outside $TMPDIR, ~/Library, ~/.claude, ~/.claude.json,
# ~/.claude-swap-backup) exit 1, bad arguments exit 2. Starts no process. README.md has the details.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PY="${PYTHON3:-}"
if [[ -z "$PY" ]]; then
    if [[ -x /usr/bin/python3 ]]; then PY=/usr/bin/python3; else PY=python3; fi
fi
exec "$PY" -I "$HERE/_m3fix.py" cswap-state "$@"

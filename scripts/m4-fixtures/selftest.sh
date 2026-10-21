#!/bin/bash
# Self test of the M4 fixtures (docs/M4-PLAN.md C11). Everything happens in one fresh mktemp folder,
# which is also this run's TMPDIR; every process it starts carries that folder in its argv (the fake
# claude copies, mock-codd.py, mcp-client.py, git) and is gone at the end (`pkill -f <tmp>/` only as
# the safety net); the folder is removed unless KEEP=1. No CODD, no real claude, no network: the only
# sockets are mock-codd.py on 127.0.0.1 and refused connections to 127.0.0.1:9.
#
#   scripts/m4-fixtures/selftest.sh        # KEEP=1 keeps the temp folder
#
# Prints "M4FIXTURES pass=N fail=M" (and "M4FIXTURES number …" lines); exit 1 when a check failed,
# 2 on bad arguments.
set -euo pipefail
# Launched CODDs stay in the background (App/AppActivation.swift); this test launches none.
export CODD_BACKGROUND=1

if [[ $# -ne 0 ]]; then
    echo "usage: selftest.sh   (KEEP=1 keeps the temp folder)" >&2
    exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
PY=/usr/bin/python3
[[ -x "$PY" ]] || { echo "M4FIXTURES needs /usr/bin/python3" >&2; exit 2; }

# Short and normalized (`pkill -f` matches it verbatim). Only a folder this run created is removed.
T="$(mktemp -d "${TMPDIR:-/tmp}/codd-m4fx.XXXXXX")" || { echo "M4FIXTURES mktemp failed" >&2; exit 2; }
[[ -n "$T" && -d "$T" ]] || { echo "M4FIXTURES mktemp gave no folder" >&2; exit 2; }
T="$(cd "$T" && pwd -P)"
case "$T" in
    /*/codd-m4fx.??????) ;;
    *) echo "M4FIXTURES unexpected temp folder '$T'" >&2; exit 2 ;;
esac
export TMPDIR="$T/"
PASS=0
FAIL=0

cleanup() {
    pkill -TERM -f "$T/" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$T/" >/dev/null || break
        sleep 0.3
    done
    pkill -KILL -f "$T/" 2>/dev/null || true
    if [[ "${KEEP:-0}" == 1 ]]; then echo "M4FIXTURES kept $T"; else rm -rf -- "$T"; fi
}
trap cleanup EXIT

check() {
    local what="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "M4FIXTURES ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "M4FIXTURES FAIL $what"
    fi
}

# Runs one _selftest.py command and counts its CHECK lines (a missing CHECKS-DONE is a failure).
pychecks() {
    local line done=0
    while IFS= read -r line; do
        case "$line" in
            "CHECK ok "*) PASS=$((PASS + 1)); echo "M4FIXTURES ok   ${line#CHECK ok }" ;;
            "CHECK FAIL "*) FAIL=$((FAIL + 1)); echo "M4FIXTURES FAIL ${line#CHECK FAIL }" ;;
            "NUMBER "*) echo "M4FIXTURES number ${line#NUMBER }" ;;
            "CHECKS-DONE "*) done=1 ;;
            *) echo "           $line" ;;
        esac
    done < <("$PY" -I -B "$HERE/_selftest.py" "$@" 2>&1)
    if [[ $done != 1 ]]; then
        FAIL=$((FAIL + 1)); echo "M4FIXTURES FAIL $1 checker did not finish"
    fi
}

no_pycache() { [[ ! -e "$HERE/__pycache__" ]]; }

echo "M4FIXTURES tmp=$T python=$("$PY" --version 2>&1)"
pychecks png "$HERE" "$T"
pychecks notes "$HERE" "$T"
pychecks git "$HERE" "$T"
pychecks claude-json "$HERE" "$T"
pychecks age-layout "$HERE" "$T" "$REPO/scripts/m2-fixtures/seed-layout.sh"
pychecks mcp-client "$HERE" "$T"
pychecks fake-claude "$HERE" "$T"
pychecks fake-print "$HERE" "$T"
pychecks secrets "$T"

# Syntax and hygiene.
for f in "$HERE"/*.sh; do
    check "bash -n $(basename "$f")" bash -n "$f"
done
pychecks compile "$HERE/_m4fix.py" "$HERE/_selftest.py" "$HERE/make-png.py" "$HERE/mcp-client.py" "$HERE/mock-codd.py" \
    "$HERE/age-layout.py" "$HERE/fake-claude-m4.sh"
check "fake-claude-m4.sh still runs under bash (re-execs python)" \
    bash -c "cd '$T' && printf 'FAKE-EXIT\r' | bash '$HERE/fake-claude-m4.sh' --fake-marker '$T/bash-run' 2>/dev/null | grep -qx 'FAKE-CLAUDE-EXITING'"
check "no __pycache__ left next to the fixtures" no_pycache

# Every check stopped what it started; cleanup's pkill is only the safety net.
sleep 0.5
check "no process of the self test is left running" bash -c "! pgrep -f '$T/' >/dev/null"
pgrep -fl "$T/" 2>/dev/null | sed 's/^/           left: /' || true
echo "M4FIXTURES pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

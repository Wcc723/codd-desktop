#!/bin/bash
# Self test of the M3 fixtures (docs/M3-PLAN.md C9). Everything happens in one fresh mktemp folder;
# every process it starts carries that folder in its argv and is killed at the end (`pkill -f <tmp>/`
# only); the folder is removed unless KEEP=1. No CODD, no real claude, no real cswap, no network
# (the only sockets are a hook sink on 127.0.0.1 and refused connections to 127.0.0.1:9).
#
#   scripts/m3-fixtures/selftest.sh
#
# Prints "M3FIXTURES pass=N fail=M"; exit 1 when a check failed, 2 on bad arguments.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

if [[ $# -ne 0 ]]; then
    echo "usage: selftest.sh   (KEEP=1 keeps the temp folder; PYTHON3=<python> picks the checker's python)" >&2
    exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PY="${PYTHON3:-}"
if [[ -z "$PY" ]]; then
    if [[ -x /usr/bin/python3 ]]; then PY=/usr/bin/python3; else PY=python3; fi
fi
command -v "$PY" >/dev/null || { echo "M3FIXTURES needs python3" >&2; exit 2; }

# Short and normalized (`pkill -f` matches it verbatim). Only a folder this run created is removed.
T="$(mktemp -d "${TMPDIR:-/tmp}/codd-m3fx.XXXXXX")" || { echo "M3FIXTURES mktemp failed" >&2; exit 2; }
[[ -n "$T" && -d "$T" ]] || { echo "M3FIXTURES mktemp gave no folder" >&2; exit 2; }
T="$(cd "$T" && pwd -P)" || exit 2
case "$T" in
    /*/codd-m3fx.??????) ;;
    *) echo "M3FIXTURES unexpected temp folder '$T'" >&2; exit 2 ;;
esac
# The fixtures only write under $TMPDIR: give them this run's folder.
export TMPDIR="$T/"
PASS=0
FAIL=0
SHARED_PROBE="/tmp/codd-m3fx-probe-$$-$RANDOM"

cleanup() {
    pkill -TERM -f "$T/" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$T/" >/dev/null || break
        sleep 0.3
    done
    pkill -KILL -f "$T/" 2>/dev/null
    rm -rf -- "$SHARED_PROBE" 2>/dev/null
    if [[ "${KEEP:-0}" == 1 ]]; then echo "M3FIXTURES kept $T"; else rm -rf -- "$T"; fi
}
trap cleanup EXIT

check() {
    local what="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "M3FIXTURES ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "M3FIXTURES FAIL $what"
    fi
}

# Runs one _selftest.py command and counts its CHECK lines (a missing CHECKS-DONE is a failure).
pychecks() {
    local line done=0
    while IFS= read -r line; do
        case "$line" in
            "CHECK ok "*) PASS=$((PASS + 1)); echo "M3FIXTURES ok   ${line#CHECK ok }" ;;
            "CHECK FAIL "*) FAIL=$((FAIL + 1)); echo "M3FIXTURES FAIL ${line#CHECK FAIL }" ;;
            "CHECKS-DONE "*) done=1 ;;
            *) echo "           $line" ;;
        esac
    done < <("$PY" -I "$HERE/_selftest.py" "$@" 2>&1)
    if [[ $done != 1 ]]; then
        FAIL=$((FAIL + 1)); echo "M3FIXTURES FAIL $1 checker did not finish"
    fi
}

status_of() { [[ "$("$1" "${@:3}" >/dev/null 2>&1; echo $?)" == "$2" ]]; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
same_file() { cmp -s "$1" "$2"; }

echo "M3FIXTURES tmp=$T python=$PY"
NOW=2026-10-17T02:00:00Z

# ---------------------------------------------------------------------------------------------
# make-cswap-state.sh
ROOT="$T/home/.claude-swap-backup"
CD="$T/home/.claude"
OUT="$("$HERE/make-cswap-state.sh" "$ROOT" "$CD" --now "$NOW")"
check "make-cswap-state.sh prints the root" test "$OUT" == "$ROOT"
pychecks state "$ROOT" "$CD" "$NOW" 3
cp "$ROOT/sequence.json" "$T/seq.before"
check "make-cswap-state.sh refuses an existing root without --stale (exit 1)" status_of "$HERE/make-cswap-state.sh" 1 "$ROOT" "$CD"
check "existing sequence.json unchanged after the refusal" same_file "$ROOT/sequence.json" "$T/seq.before"
check "--stale 2 on the existing root prints the root" test "$("$HERE/make-cswap-state.sh" "$ROOT" "$CD" --stale 2)" == "$ROOT"
pychecks stale "$ROOT" 2 2-north_example.com
"$HERE/make-cswap-state.sh" "$ROOT" "$CD" --stale 1 >/dev/null
pychecks stale "$ROOT" 1 1-personal_example.com
check "--stale 1 left the state files alone" same_file "$ROOT/sequence.json" "$T/seq.before"
check "--stale 9 (no such account) exits 2" status_of "$HERE/make-cswap-state.sh" 2 "$ROOT" "$CD" --stale 9
FRESH="$T/fresh/.claude-swap-backup"
"$HERE/make-cswap-state.sh" "$FRESH" "$T/fresh/.claude" --stale 2 >/dev/null
pychecks stale "$FRESH" 2 2-north_example.com
FOUR="$T/four/.claude-swap-backup"
"$HERE/make-cswap-state.sh" "$FOUR" "$T/four/.claude" --accounts 4 --now "$NOW" >/dev/null
pychecks state "$FOUR" "$T/four/.claude" "$NOW" 4
check "make-cswap-state.sh usage errors exit 2" bash -c "
    s='$HERE/make-cswap-state.sh'
    \"\$s\" >/dev/null 2>&1; [[ \$? == 2 ]] || exit 1
    \"\$s\" '$T/u/.claude-swap-backup' '$T/u/.claude' --accounts 5 >/dev/null 2>&1; [[ \$? == 2 ]] || exit 1
    \"\$s\" '$T/u/.claude-swap-backup' '$T/u/.claude' --now yesterday >/dev/null 2>&1; [[ \$? == 2 ]] || exit 1
    test ! -e '$T/u'"
check "refuses a root whose last component is not .claude-swap-backup (exit 1, nothing written)" \
    bash -c "'$HERE/make-cswap-state.sh' '$T/bad/cswap' '$T/bad/.claude' 2>/dev/null; [[ \$? == 1 ]] && test ! -e '$T/bad'"
mkdir -p "$T/tz"
check "refuses a claudeDir directly under \$TMPDIR (exit 1, no shared .claude.json)" \
    bash -c "TMPDIR='$T/tz' '$HERE/make-cswap-state.sh' '$T/tz/x/.claude-swap-backup' '$T/tz/claude' 2>/dev/null; [[ \$? == 1 ]] \
             && test ! -e '$T/tz/.claude.json' -a ! -e '$T/tz/x' -a ! -e '$T/tz/claude'"
check "refuses a claudeDir directly under /tmp (exit 1, nothing created)" \
    bash -c "'$HERE/make-cswap-state.sh' '$T/t2/.claude-swap-backup' '$SHARED_PROBE' 2>/dev/null; [[ \$? == 1 ]] \
             && test ! -e '$SHARED_PROBE' -a ! -e '$T/t2'"
FH="$T/fakehome"
mkdir -p "$FH" "$T/othertmp"
for target in "$FH/.claude-swap-backup|$FH/x/.claude" "$T/ok1/.claude-swap-backup|$FH/.claude" \
              "$FH/proj/.claude-swap-backup|$T/ok2/.claude" "$FH/Library/.claude-swap-backup|$T/ok3/.claude"; do
    r="${target%%|*}"; c="${target##*|}"
    check "refuses $(basename "$(dirname "$r")")/$(basename "$r") + $(basename "$(dirname "$c")")/$(basename "$c") with HOME=fakehome (exit 1)" \
        bash -c "HOME='$FH' TMPDIR='$T/othertmp' '$HERE/make-cswap-state.sh' '$r' '$c' 2>/dev/null; [[ \$? == 1 ]]"
done
check "nothing was written under the fake home or the ok* folders" bash -c "[[ -z \"\$(ls -A '$FH')\" ]] && test ! -e '$T/ok1' -a ! -e '$T/ok2' -a ! -e '$T/ok3'"
check "refuses a claudeDir whose ../.claude.json is ~/.claude.json (HOME under \$TMPDIR, exit 1)" \
    bash -c "HOME='$T/fh2' '$HERE/make-cswap-state.sh' '$T/fh2x/.claude-swap-backup' '$T/fh2/claudex' 2>/dev/null; [[ \$? == 1 ]] \
             && test ! -e '$T/fh2x' -a ! -e '$T/fh2/.claude.json' -a ! -e '$T/fh2/claudex'"

# ---------------------------------------------------------------------------------------------
# make-claude-settings.sh
SC="$T/settings/plain/.claude"
check "make-claude-settings.sh prints the file path" test "$("$HERE/make-claude-settings.sh" "$SC")" == "$SC/settings.json"
pychecks settings "$SC/settings.json" plain "$SC" "printf 'USER-SL-%s' ok"
check "make-claude-settings.sh refuses an existing settings.json (exit 1)" status_of "$HERE/make-claude-settings.sh" 1 "$SC"
check "--force replaces it" bash -c "'$HERE/make-claude-settings.sh' '$SC' --force --user-statusline 'echo second' >/dev/null \
    && grep -q '\"command\": \"echo second\"' '$SC/settings.json'"
LC="$T/settings/legacy/.claude"
"$HERE/make-claude-settings.sh" "$LC" --legacy >/dev/null
pychecks settings "$LC/settings.json" legacy "$LC" "printf 'USER-SL-%s' ok"
QC="$T/settings/quote/.claude"
QCMD="printf '%s|' \"it's 世界\" 'a b' && exit 0"
"$HERE/make-claude-settings.sh" "$QC" --legacy --user-statusline "$QCMD" >/dev/null
pychecks settings "$QC/settings.json" legacy "$QC" "$QCMD"
NC="$T/settings/nochain/.claude"
"$HERE/make-claude-settings.sh" "$NC" --legacy --user-statusline '' >/dev/null
pychecks settings "$NC/settings.json" legacy-nochain "$NC" ""
EC="$T/settings/none/.claude"
"$HERE/make-claude-settings.sh" "$EC" --user-statusline '' >/dev/null
pychecks settings "$EC/settings.json" none "$EC" ""
DC="$T/settings/desktop/.claude"
DROOT="$T/settings/desktop/data root's"
"$HERE/make-claude-settings.sh" "$DC" --legacy --desktop-global "$DROOT" >/dev/null
pychecks settings "$DC/settings.json" desktop "$DC" "printf 'USER-SL-%s' ok" "$DROOT"
PC="$T/settings/proj/.claude"
PCWD="$T/settings/proj/work 專案"
mkdir -p "$PCWD"
OUT="$("$HERE/make-claude-settings.sh" "$PC" --project "$PCWD" "printf 'PROJECT-SL'")"
check "--project prints both paths" test "$OUT" == "$PC/settings.json"$'\n'"$PCWD/.claude/settings.json"
pychecks project "$PCWD/.claude/settings.json" "printf 'PROJECT-SL'"
check "make-claude-settings.sh usage errors exit 2" bash -c "
    s='$HERE/make-claude-settings.sh'
    \"\$s\" >/dev/null 2>&1; [[ \$? == 2 ]] || exit 1
    \"\$s\" '$T/settings/u/.claude' --bogus >/dev/null 2>&1; [[ \$? == 2 ]] || exit 1
    \"\$s\" '$T/settings/u/.claude' --project '$T/x' >/dev/null 2>&1; [[ \$? == 2 ]] || exit 1
    test ! -e '$T/settings/u'"
check "make-claude-settings.sh refuses ~/.claude (HOME=fakehome, exit 1)" \
    bash -c "HOME='$FH' TMPDIR='$T/othertmp' '$HERE/make-claude-settings.sh' '$FH/.claude' 2>/dev/null; [[ \$? == 1 ]] && test ! -e '$FH/.claude'"
check "make-claude-settings.sh refuses a folder inside ~ outside \$TMPDIR (exit 1)" \
    bash -c "HOME='$FH' TMPDIR='$T/othertmp' '$HERE/make-claude-settings.sh' '$FH/proj/.claude' 2>/dev/null; [[ \$? == 1 ]] && test ! -e '$FH/proj'"
check "make-claude-settings.sh refuses a --desktop-global root inside ~/Library (exit 1)" \
    bash -c "HOME='$FH' '$HERE/make-claude-settings.sh' '$T/settings/lib/.claude' --desktop-global '$FH/Library/Application Support/CODD' 2>/dev/null; [[ \$? == 1 ]] \
             && test ! -e '$T/settings/lib'"

# ---------------------------------------------------------------------------------------------
# rate-limits.sh
pychecks rate-limits "$HERE" "$T"
check "rate-limits.sh refuses ~/.claude (HOME=fakehome, exit 1)" \
    bash -c "HOME='$FH' TMPDIR='$T/othertmp' '$HERE/rate-limits.sh' '$FH/.claude/rl.json' 1 2 3 4 2>/dev/null; [[ \$? == 1 ]] && test ! -e '$FH/.claude'"

# ---------------------------------------------------------------------------------------------
# fake-cswap.py
pychecks cswap "$HERE" "$T"
check "fake-cswap.py --version needs no configuration" bash -c "[[ \"\$('$HERE/fake-cswap.py' --version)\" == 'cswap 0.26.0' ]]"

# ---------------------------------------------------------------------------------------------
# fake-claude-m3.sh
pychecks fake-claude "$HERE/fake-claude-m3.sh" "$T"
pychecks fake-claude-hooks "$HERE/fake-claude-m3.sh" "$T"
pychecks fake-claude-statusline "$HERE" "$T"
pychecks fake-claude-login "$HERE" "$T"

# ---------------------------------------------------------------------------------------------
# syntax
for f in "$HERE"/*.sh; do
    check "bash -n $(basename "$f")" bash -n "$f"
done
pychecks compile "$HERE/fake-cswap.py" "$HERE/_m3fix.py" "$HERE/_selftest.py" "$HERE/fake-claude-m3.sh"
check "fake-claude-m3.sh still runs under bash (re-execs python)" \
    bash -c "cd '$T' && printf 'FAKE-EXIT\r' | TMPDIR='$T/' bash '$HERE/fake-claude-m3.sh' --fake-marker '$T/bash-run' 2>/dev/null | grep -qx 'FAKE-CLAUDE-EXITING'"

# Every check stopped what it started; cleanup's pkill is only the safety net.
sleep 0.5
check "no process of the self test is left running" bash -c "! pgrep -f '$T/' >/dev/null"
pgrep -fl "$T/" 2>/dev/null | sed 's/^/           left: /'
echo "M3FIXTURES pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

#!/bin/bash
# M4 interface zoom (user feedback 2026-10-18: 「可以針對當前介面進行縮放（文字大小）」): Settings ›
# 外觀 › UI 字級 and 顯示方式 › 放大 ⌘+ / 縮小 ⌘− / 實際大小 ⌘0, which step UI 字級 and 終端機字級
# together. Real CODD.app (DEBUG build) on a temp data root (scripts/m2-fixtures/make-root.sh); the
# steps go through the menu commands (DEBUG `-codd-zoom`), never through posted events. No claude
# is started, never ~/.claude, never the real data root.
#
#   scripts/m4-ui-zoom.sh     # build first: xcodegen generate && xcodebuild … -derivedDataPath build/dd build
#   CODD_APP=/path/CODD.app/Contents/MacOS/CODD KEEP=1 MATRIX=1 scripts/m4-ui-zoom.sh
#
# Runs (each a separate background launch with -codd-quit-after and -codd-dump-state):
#   Z1  -codd-set-pref appearance.uiFontSize=16 / terminalFontSize=18: applied at launch (`zoom`
#       16, scale 16/13, a session row 47 pt, body text 16 pt, every terminal 18), not written;
#   Z2  -codd-zoom in, in, out: both sizes 14 (written to preferences.json), `zoom in` logged;
#   Z3  a plain relaunch starts at the stored 14 (the launch peek) and applies it;
#   Z4  -codd-zoom reset: both back to 13 in the file, `zoom.actualSize`;
#   Z5  clamping: uiFontSize=99 → 20 and terminalFontSize=99 → 28; `-codd-zoom in` then changes nothing;
#   Z6  (MATRIX=1) -codd-shortcut-matrix on a zsh tab: ⌘= ⌘+ ⌘− ⌘0 from a focused terminal reach
#       the menu (declined by the terminal, also as 注音 reports them) and step both sizes once.
# Prints `E2E ok …` / `E2E FAIL …` and `E2E pass=<n> fail=<m>`; ends every process whose argv
# carries the temp folder; removes it unless KEEP=1.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

cd "$(dirname "$0")/.."
REPO="$(pwd -P)"
APP="${CODD_APP:-build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD}"
FIX="$REPO/scripts/m2-fixtures"
PY="${PYTHON3:-python3}"
if [[ ! -x "$APP" ]]; then
    echo "E2E missing $APP (build the app first)" >&2
    exit 2
fi
command -v "$PY" >/dev/null || { echo "E2E needs python3 (JSON checks)" >&2; exit 2; }
# Window-stack guard (docs/M5-PLAN.md D23): the run fails when a window of this build rises above
# another app's window, even when every check passed (scripts/lib/zorder-guard.sh).
source scripts/lib/zorder-guard.sh

T="$(mktemp -d "${TMPDIR:-/tmp}/codd-zoom.XXXXXX")" || { echo "E2E mktemp failed" >&2; exit 2; }
ROOT="$(cd "$T" && pwd -P)" || exit 2
case "$ROOT" in
    /*/codd-zoom.??????) ;;
    *) echo "E2E unexpected temp folder '$ROOT'" >&2; exit 2 ;;
esac
PASS=0
FAIL=0
APP_PID=""
APP_NAME=""

cleanup() {
    local rc=$?
    pkill -CONT -f "$ROOT/" 2>/dev/null
    pkill -TERM -f "$ROOT/" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$ROOT/" >/dev/null || break
        sleep 0.3
    done
    pkill -KILL -f "$ROOT/" 2>/dev/null
    # After every CODD of the run has quit: a window-stack violation fails the run (exit 1).
    if ! zorder_guard_end && [[ $rc == 0 ]]; then rc=1; fi
    if [[ "${KEEP:-0}" == 1 ]]; then echo "E2E kept $ROOT"; else rm -rf -- "$ROOT"; fi
    exit "$rc"
}
trap cleanup EXIT
zorder_guard_begin "$ROOT" "$APP"

check() {
    local what="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "E2E ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "E2E FAIL $what"
    fi
}
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }

# jexpr <json file> <python expression>: prints the value ("" on any error, a missing file too).
# `z` is the dump's `zoom`, `e` its `preferences.effective`, `a` a preferences file's `appearance`.
jexpr() {
    "$PY" -I - "$@" 2>/dev/null <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    z = d.get("zoom") or {}
    e = (d.get("preferences") or {}).get("effective") or {}
    a = d.get("appearance") or {}
    v = eval(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}
jtrue() { [[ "$(jexpr "$@")" == True ]]; }

# start_app <name> <seconds> [flags…]: one background launch on the test root (every flag its own
# argument), dump $ROOT/<name>.json, log $ROOT/<name>.log.
start_app() {
    local name="$1" seconds="$2"; shift 2
    perl -e 'alarm shift; exec @ARGV' 90 "$APP" -codd-data-root "$A" -codd-claude-dir "$CA" \
        -codd-claude-path /usr/bin/false -codd-shell-argv "/bin/cat" -codd-login-env NO -codd-notifications NO \
        -codd-quit-after "$seconds" -codd-dump-state "$ROOT/$name.json" "$@" \
        >"$ROOT/$name.log" 2>&1 &
    APP_PID=$!
    APP_NAME="$name"
}
wait_app() {
    wait "$APP_PID"
    local status=$?
    echo "E2E $APP_NAME exit=$status log=$ROOT/$APP_NAME.log"
    [[ $status == 0 ]]
}

echo "E2E root=$ROOT app=$APP"
A="$ROOT/a"; CA="$ROOT/ca"
mkdir -p "$CA/projects"
"$FIX/make-root.sh" "$A" >/dev/null || exit 2
PREFS="$A/preferences.json"

# Z1. A level set for this run only: applied at launch, never written.
start_app z1 5 -codd-set-pref "appearance.uiFontSize=16" -codd-set-pref "appearance.terminalFontSize=18"
check "Z1 launched and quit" wait_app
check "Z1 the launch peek applied 16" contains "$ROOT/z1.log" "zoom launch ui=16"
check "Z1 zoom.uiFontSize 16" jtrue "$ROOT/z1.json" "z['uiFontSize'] == 16"
check "Z1 scale 16/13" jtrue "$ROOT/z1.json" "abs(z['scale'] - 16/13) < 1e-6"
check "Z1 effective UI and terminal sizes" jtrue "$ROOT/z1.json" "e['uiFontSize'] == 16 and e['terminalFontSize'] == 18"
check "Z1 a session row is 47 pt, the header 64" jtrue "$ROOT/z1.json" "z['metrics']['sessionRowHeight'] == 47 and z['metrics']['headerHeight'] == 64"
check "Z1 body text 16 pt" jtrue "$ROOT/z1.json" "abs(z['fonts']['body13'] - 16) < 0.01"
check "Z1 every terminal at 18" jtrue "$ROOT/z1.json" "z['terminal']['shell'] == 18 and z['terminal'].get('engines', 18) == 18"
not_written() { [[ ! -f "$PREFS" ]] || jtrue "$PREFS" "a.get('uiFontSize', 13) != 16"; }
check "Z1 set-pref is not written" not_written

# Z2. Two steps up, one down: both sizes 14, written.
start_app z2 6 -codd-zoom in -codd-zoom in -codd-zoom out
check "Z2 launched and quit" wait_app
check "Z2 steps logged" contains "$ROOT/z2.log" "zoom in ui=15 terminal=15"
check "Z2 the step down logged" contains "$ROOT/z2.log" "zoom out ui=14 terminal=14"
check "Z2 applied 14" jtrue "$ROOT/z2.json" "z['uiFontSize'] == 14 and z['terminalFontSize'] == 14 and z['steps'] == 3"
check "Z2 stored 14 / 14" jtrue "$ROOT/z2.json" "z['stored'] == {'uiFontSize': 14, 'terminalFontSize': 14}"
check "Z2 preferences.json has 14 / 14" jtrue "$PREFS" "a['uiFontSize'] == 14 and a['terminalFontSize'] == 14"

# Z3. A plain relaunch starts at the stored level.
start_app z3 5
check "Z3 launched and quit" wait_app
check "Z3 the launch peek read 14" contains "$ROOT/z3.log" "zoom launch ui=14"
check "Z3 applied 14 and its row height" jtrue "$ROOT/z3.json" "z['uiFontSize'] == 14 and z['metrics']['sessionRowHeight'] == 41"
check "Z3 terminals at 14" jtrue "$ROOT/z3.json" "z['terminal']['shell'] == 14"

# Z4. 實際大小: both back to 13 in the file.
start_app z4 5 -codd-zoom reset
check "Z4 launched and quit" wait_app
check "Z4 reset logged" contains "$ROOT/z4.log" "zoom reset ui=13 terminal=13"
check "Z4 actual size" jtrue "$ROOT/z4.json" "z['actualSize'] and z['uiFontSize'] == 13 and z['scale'] == 1"
check "Z4 preferences.json has 13 / 13" jtrue "$PREFS" "a['uiFontSize'] == 13 and a['terminalFontSize'] == 13"

# Z5. Out-of-range values clamp; a step at the top changes nothing.
start_app z5 5 -codd-set-pref "appearance.uiFontSize=99" -codd-set-pref "appearance.terminalFontSize=99" -codd-zoom in
check "Z5 launched and quit" wait_app
check "Z5 clamped to 20 / 28" jtrue "$ROOT/z5.json" "z['uiFontSize'] == 20 and z['terminalFontSize'] == 28"
check "Z5 the step at the top did nothing" jtrue "$ROOT/z5.json" "z['steps'] == 0 and not z['canZoomIn'] and z['canZoomOut']"
check "Z5 nothing written" jtrue "$PREFS" "a['uiFontSize'] == 13"

# Z6. The keys themselves, from a focused terminal (opt-in: the matrix orders the test window in).
if [[ "${MATRIX:-0}" == 1 ]]; then
    W="$ROOT/w"; mkdir -p "$W"
    start_app z6 40 -codd-spawn-shell "$W" -codd-shell-argv "/bin/zsh -f" -codd-shortcut-matrix YES
    check "Z6 launched and quit" wait_app
    for chord in "⌘=" "⌘+" "⌘−" "⌘0"; do
        check "Z6 terminal $chord" contains "$ROOT/z6.log" "SHORTCUT focus=terminal $chord ok"
    done
    check "Z6 matrix ran" contains "$ROOT/z6.log" "SHORTCUTS ok="
else
    echo "E2E skip Z6 (MATRIX=1 runs the shortcut matrix)"
fi

check "no Anthropic API" lacks "$ROOT/z1.log" "api.anthropic.com"
echo "E2E pass=$PASS fail=$FAIL"
[[ $FAIL == 0 ]]

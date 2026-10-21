#!/bin/bash
# M1 step 4a smoke test: real codd-holder processes streamed into CODD.app's libghostty terminals.
#
# Uses a temporary data root only (never ~/Library/Application Support/CODD) and a temporary Claude
# directory (never ~/.claude), children are `/bin/zsh -f` (no rc files) and the login-shell
# capture is off, so nothing of the user's setup is read and no `claude` process is started.
# Every holder it started is killed at the end. (scripts/m1-e2e.sh covers claude sessions.)
#
#   scripts/m1-smoke.sh            # build first: xcodegen generate && xcodebuild … -derivedDataPath build/dd build
#   CODD_APP=/path/CODD.app/Contents/MacOS/CODD KEEP=1 scripts/m1-smoke.sh   # keep the data root for inspection
#
# Steps:
#   1. launch, spawn a shell, type a command through the holder stream, open the ⌘J panel (its own
#      shell holder) and type there, dump both terminals' text, quit;
#   2. the holders outlive the app (adopted by launchd, ppid 1) and run from <root>/bin;
#   3. relaunch: the session and the panel reattach to the same holders, the replay shows the
#      earlier output, new input round-trips;
#   4. relaunch: a shell tab (another holder) spawns lazily and takes input; tabs never appear as
#      sessions of their own;
#   5. clean up every holder of the data root.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

cd "$(dirname "$0")/.."
APP="${CODD_APP:-build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD}"
if [[ ! -x "$APP" ]]; then
    echo "SMOKE missing $APP (build the app first)" >&2
    exit 2
fi
# Window-stack guard (docs/M5-PLAN.md D23): the run fails when a window of this build rises above
# another app's window, even when every check passed (scripts/lib/zorder-guard.sh).
source scripts/lib/zorder-guard.sh

# Short and normalized: socket paths must stay under 104 bytes, and `pkill -f` matches it verbatim.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codd-smoke.XXXXXX" | tr -s /)"
WORK="$ROOT/work"
mkdir -p "$WORK" "$ROOT/claude/sessions"
# Own hook endpoint (docs/M2-PLAN.md D24), written like scripts/m1-e2e.sh does: a random free port in
# 43000-43999 and a fresh token, so a smoke run never takes the port the user's sessions post to (47821).
read -r SMOKE_PORT SMOKE_TOKEN < <(python3 -I -c 'import random,secrets,socket
for _ in range(500):
    p = random.randint(43000, 43999)
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
    except OSError:
        continue
    finally:
        s.close()
    print(p, secrets.token_hex(32))
    break')
if [[ -z "${SMOKE_PORT:-}" ]]; then
    echo "SMOKE no free port in 43000-43999 (or no python3)" >&2
    rm -rf "$ROOT"
    exit 2
fi
(umask 077 && printf '{"port":%s,"token":"%s","v":1}\n' "$SMOKE_PORT" "$SMOKE_TOKEN" >"$ROOT/config.json")
echo "SMOKE hook port=$SMOKE_PORT"
PASS=0
FAIL=0

cleanup() {
    local rc=$?
    pkill -TERM -f "$ROOT/" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$ROOT/" >/dev/null || break
        sleep 0.3
    done
    pkill -KILL -f "$ROOT/" 2>/dev/null
    # After every CODD of the run has quit: a window-stack violation fails the run (exit 1).
    if ! zorder_guard_end && [[ $rc == 0 ]]; then rc=1; fi
    if [[ "${KEEP:-0}" == 1 ]]; then echo "SMOKE kept $ROOT"; else rm -rf "$ROOT"; fi
    exit "$rc"
}
trap cleanup EXIT
zorder_guard_begin "$ROOT" "$APP"

check() {
    local what="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "SMOKE ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "SMOKE FAIL $what"
    fi
}

contains() { grep -qF -- "$2" "$1"; }
# Text of one section (=== MAIN === / === PANEL ===) of a terminal dump.
section() { awk -v want="=== $2 ===" '/^=== /{on=($0==want); next} on' "$1"; }
section_contains() { section "$1" "$2" | grep -qF -- "$3"; }

# One app run: real holders in the temp root, quits after $1 seconds; the rest are extra flags.
run_app() {
    local log="$1" seconds="$2"; shift 2
    perl -e 'alarm shift; exec @ARGV' 90 "$APP" -codd-real-holders -codd-data-root "$ROOT" -codd-claude-dir "$ROOT/claude" \
        -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO -codd-quit-after "$seconds" "$@" >"$log" 2>&1
    echo "SMOKE run exit=$? log=$log"
}

holder_pids() { pgrep -f "$ROOT/bin/codd-holder-" | sort; }
all_adopted() {
    local pid
    for pid in $(holder_pids); do
        [[ "$(ps -o ppid= -p "$pid" | tr -d ' ')" == 1 ]] || return 1
    done
    [[ -n "$(holder_pids)" ]]
}

echo "SMOKE root=$ROOT app=$APP"

# 1. First launch.
run_app "$ROOT/run1.log" 9 -codd-spawn-shell "$WORK" \
    -codd-send-input 'echo M1-$((6*7))-MARK; printf "ENV=%s/%s/%s\n" "$TERM" "$COLORTERM" "$TERM_PROGRAM"' \
    -codd-open-panel YES -codd-send-panel-input 'echo PANEL-$((2+3))-MARK' \
    -codd-dump-terminal "$ROOT/dump1.txt" -codd-snapshot "$ROOT/shot1.png"
check "holder binary copied out of the bundle" contains "$ROOT/run1.log" "holder binary $ROOT/bin/codd-holder-"
check "session spawned" contains "$ROOT/run1.log" "spawned session="
check "panel shell spawned" contains "$ROOT/run1.log" "spawned tab="
check "terminal dump written" test -s "$ROOT/dump1.txt"
check "typed command ran in the terminal" section_contains "$ROOT/dump1.txt" MAIN "M1-42-MARK"
check "child env TERM/COLORTERM/TERM_PROGRAM" section_contains "$ROOT/dump1.txt" MAIN "ENV=xterm-256color/truecolor/ghostty"
check "panel shell took input" section_contains "$ROOT/dump1.txt" PANEL "PANEL-5-MARK"

# 2. The holders survive the quit.
sleep 0.5
FIRST_PIDS="$(holder_pids | tr '\n' ' ')"
echo "SMOKE holders after quit: $FIRST_PIDS"
check "two holders alive after quit" test "$(holder_pids | wc -l | tr -d ' ')" -eq 2
check "holders adopted by launchd (ppid 1)" all_adopted

# 3. Relaunch: reattach + replay + new input.
run_app "$ROOT/run2.log" 9 -codd-send-input 'echo M2-$((10+5))-MARK' -codd-dump-terminal "$ROOT/dump2.txt"
check "relaunch discovered the session" contains "$ROOT/run2.log" "sessions=1 live=1"
check "relaunch discovered the panel's holder" contains "$ROOT/run2.log" "discovered tabs=1 live=1"
check "no new holder was spawned" bash -c "! grep -q 'spawned' '$ROOT/run2.log'"
check "replay shows the first run's output" section_contains "$ROOT/dump2.txt" MAIN "M1-42-MARK"
check "input through the stream after reattach" section_contains "$ROOT/dump2.txt" MAIN "M2-15-MARK"
check "panel restored with its replay" section_contains "$ROOT/dump2.txt" PANEL "PANEL-5-MARK"
check "same holders as before" test "$(holder_pids | tr '\n' ' ')" = "$FIRST_PIDS"

# 4. Relaunch: a shell tab spawns lazily; it is not a session of its own.
run_app "$ROOT/run3.log" 9 -codd-open-zsh-tab YES -codd-send-panel-input 'echo TAB-$((3*3))-MARK; pwd' \
    -codd-dump-terminal "$ROOT/dump3.txt" -codd-snapshot "$ROOT/shot3.png"
check "shell tab spawned" contains "$ROOT/run3.log" "spawned tab="
check "shell tab took input" section_contains "$ROOT/dump3.txt" PANEL "TAB-9-MARK"
check "shell tab runs in the session folder" section_contains "$ROOT/dump3.txt" PANEL "$(cd "$WORK" && pwd -P)"
check "tabs are not listed as sessions" contains "$ROOT/run3.log" "sessions=1 live=1"
check "three holders alive after quit" test "$(holder_pids | wc -l | tr -d ' ')" -eq 3
check "tab layout persisted" contains "$ROOT/panes.json" '"panelOpen" : true'

# 5. Cleanup happens in the trap; report what will be killed.
echo "SMOKE killing holders: $(holder_pids | tr '\n' ' ')"
echo "SMOKE pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

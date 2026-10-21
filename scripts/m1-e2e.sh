#!/bin/bash
# M1 end-to-end test (docs/M1-PLAN.md §4b): real CODD.app, real codd-holder, real hook endpoint,
# real libghostty terminal, FAKE claude (scripts/fake-claude.sh: no Anthropic call, no quota).
#
# Isolation: a temporary data root (never ~/Library/Application Support/CODD), a temporary Claude
# directory (registry, .claude.json; never ~/.claude), no login-shell capture, notifications off.
# Every holder it started is killed at the end. The hook endpoint gets its own config.json: a
# random free port in 43000-43999 and a fresh token, so it never meets a real CODD (47821-47899)
# or the hooks of sessions a real CODD started.
#
#   scripts/m1-e2e.sh             # build first: xcodegen generate && xcodebuild … -derivedDataPath build/dd build
#   CODD_APP=/path/CODD.app/Contents/MacOS/CODD KEEP=1 scripts/m1-e2e.sh   # keep the data root
#
# Runs:
#   1. new claude session: DA1 answered, SessionStart through the installed codd-hook copy, hooks
#      drive BUSY → WAITING → (answer bar key 1 reaches the PTY) → BUSY → IDLE/DONE; Dock badge 1
#      while waiting; a wrong token gets 401 and changes nothing; /health answers;
#   2. relaunch: the session is listed and reattached to the same holder, replay shows the output,
#      input round-trips, and it is IDLE (lastViewedAt persisted, no stale DONE);
#   3. the holder is killed while CODD is not running: relaunch shows STOPPED · 可接續;
#   4. RESUME: claude starts again with --resume <Claude session id> and reaches IDLE;
#   5. the hook port is taken by another program: degraded status, no crash, session still listed,
#      and the endpoint binds by itself once the port is free again;
#   6. claude exits while CODD runs: holder EXIT turns the session EXITED with its exit code.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

cd "$(dirname "$0")/.."
APP="${CODD_APP:-build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD}"
if [[ ! -x "$APP" ]]; then
    echo "E2E missing $APP (build the app first)" >&2
    exit 2
fi
if ! command -v python3 >/dev/null; then
    echo "E2E needs python3 (JSON parsing)" >&2
    exit 2
fi
# Window-stack guard (docs/M5-PLAN.md D23): the run fails when a window of this build rises above
# another app's window, even when every check passed (scripts/lib/zorder-guard.sh).
source scripts/lib/zorder-guard.sh

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codd-e2e.XXXXXX" | tr -s /)"
ROOT="${ROOT%/}"
WORK="$ROOT/work"
CLAUDE_DIR="$ROOT/claude"
FAKE="$ROOT/fake-claude"
mkdir -p "$WORK" "$CLAUDE_DIR/sessions"
cp scripts/fake-claude.sh "$FAKE"
chmod +x "$FAKE"
printf '{"projects":{"%s":{}}}\n' "$WORK" >"$ROOT/.claude.json"
read -r E2E_PORT E2E_TOKEN < <(python3 -I -c 'import random,secrets,socket
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
if [[ -z "${E2E_PORT:-}" ]]; then
    echo "E2E no free port in 43000-43999" >&2
    exit 2
fi
(umask 077 && printf '{"port":%s,"token":"%s","v":1}\n' "$E2E_PORT" "$E2E_TOKEN" >"$ROOT/config.json")
PASS=0
FAIL=0
BLOCKER_PID=""

cleanup() {
    local rc=$?
    [[ -n "$BLOCKER_PID" ]] && kill "$BLOCKER_PID" 2>/dev/null
    pkill -TERM -f "$ROOT/" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$ROOT/" >/dev/null || break
        sleep 0.3
    done
    pkill -KILL -f "$ROOT/" 2>/dev/null
    # After every CODD of the run has quit: a window-stack violation fails the run (exit 1).
    if ! zorder_guard_end && [[ $rc == 0 ]]; then rc=1; fi
    if [[ "${KEEP:-0}" == 1 ]]; then echo "E2E kept $ROOT"; else rm -rf "$ROOT"; fi
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

contains() { grep -qF -- "$2" "$1"; }
# json <file> <python expression over `d`>: prints the value ("" when missing).
json() { python3 -I -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=eval(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")' "$1" "$2"; }
session_field() { json "$1" "next((s.get('$2') for s in d['sessions']), None)"; }
state_in() { local s; s="$(session_field "$1" state)"; [[ " $2 " == *" $s "* ]]; }

# start_app <name> <seconds> [flags…]: runs in the background; logs to $ROOT/<name>.log.
start_app() {
    local name="$1" seconds="$2"; shift 2
    perl -e 'alarm shift; exec @ARGV' 60 "$APP" -codd-data-root "$ROOT" -codd-claude-dir "$CLAUDE_DIR" \
        -codd-claude-path "$FAKE" -codd-login-env NO -codd-notifications NO -codd-quit-after "$seconds" \
        -codd-dump-state "$ROOT/$name.json" "$@" >"$ROOT/$name.log" 2>&1 &
    APP_PID=$!
}
wait_app() {
    wait "$APP_PID"
    local status=$?
    echo "E2E app exit=$status log=$ROOT/$1.log"
    [[ $status == 0 ]]
}
# wait_for <seconds> <command…>: polls every 100 ms.
wait_for() {
    local deadline=$((SECONDS + $1)); shift
    while (( SECONDS <= deadline )); do
        "$@" && return 0
        sleep 0.1
    done
    return 1
}
holder_pids() { pgrep -f "$ROOT/bin/codd-holder-" | sort; }
all_adopted() {
    local pid
    for pid in $(holder_pids); do
        [[ "$(ps -o ppid= -p "$pid" | tr -d ' ')" == 1 ]] || return 1
    done
    [[ -n "$(holder_pids)" ]]
}

echo "E2E root=$ROOT app=$APP"

# ---------------------------------------------------------------------------------------------
# 1. New claude session driven by hooks.
start_app run1 18 -codd-new-claude "$WORK" -codd-auto-answer 1 -codd-dump-terminal "$ROOT/dump1.txt"
SEEN=""
BADGE_WHILE_WAITING=""
deadline=$((SECONDS + 15))
while (( SECONDS <= deadline )); do
    # State and badge from one read of the dump (it is rewritten while we poll).
    snapshot="$(json "$ROOT/run1.json" "'%s %s' % (next((s.get('state') for s in d['sessions']), ''), d.get('dockBadge') or '-')")"
    state="${snapshot%% *}"
    badge="${snapshot#* }"
    if [[ -n "$state" && "$SEEN" != *"$state"* ]]; then SEEN="$SEEN $state"; fi
    if [[ "$state" == waiting && "$BADGE_WHILE_WAITING" != 1 ]]; then BADGE_WHILE_WAITING="$badge"; fi
    if [[ "$SEEN" == *waiting* && ( "$state" == idle || "$state" == done ) ]]; then break; fi
    sleep 0.1
done
echo "E2E states seen by polling:$SEEN"
SID="$(session_field "$ROOT/run1.json" id)"
PORT="$(json "$ROOT/config.json" "d['port']")"
TOKEN="$(json "$ROOT/config.json" "d['token']")"
echo "E2E session=$SID port=$PORT"
check "the endpoint uses this run's port" test "$PORT:$TOKEN" = "$E2E_PORT:$E2E_TOKEN"
check "session is IDLE/DONE after the turn" state_in "$ROOT/run1.json" "idle done"
check "Dock badge showed 1 while WAITING" test "$BADGE_WHILE_WAITING" = 1
BEFORE="$(session_field "$ROOT/run1.json" state)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -X POST -H 'Content-Type: application/json' \
    -H 'X-CODD-Token: not-the-token' -H "X-CODD-Session: $SID" \
    --data-binary "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\"}" "http://127.0.0.1:$PORT/hooks")"
echo "E2E wrong token -> $CODE"
check "wrong token is rejected with 401" test "$CODE" = 401
HEALTH="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health")"
check "/health answers as CODD" test "$HEALTH" = '{"ok":true,"app":"codd"}'
sleep 1
check "wrong token changed nothing" test "$(session_field "$ROOT/run1.json" state)" = "$BEFORE"
wait_app run1
check "first-run transitions busy -> waiting -> busy" \
    bash -c "grep -q 'idle->busy\|starting->busy' '$ROOT/run1.log' && grep -q 'busy->waiting' '$ROOT/run1.log' && grep -q 'waiting->busy' '$ROOT/run1.log'"
check "turn ended IDLE or DONE" bash -c "grep -Eq 'busy->(idle|done)' '$ROOT/run1.log'"
check "answer key went to the PTY" contains "$ROOT/run1.log" "answer session=$SID key=1 sent=true"
check "codd-hook installed under bin/" bash -c "ls '$ROOT/bin' | grep -Eq '^codd-hook-[0-9a-f]{12}$'"
check "holder installed under bin/" bash -c "ls '$ROOT/bin' | grep -Eq '^codd-holder-[0-9a-f]{12}$'"
check "startup probe (DA1) answered" contains "$ROOT/dump1.txt" "FAKE-DA1-OK"
check "SessionStart ran the installed codd-hook" contains "$ROOT/dump1.txt" "FAKE-SESSIONSTART hook=$ROOT/bin/codd-hook-"
check "hooks posted 204" contains "$ROOT/dump1.txt" "FAKE permission=204"
check "fake claude received key 1 (0x31)" contains "$ROOT/dump1.txt" "FAKE-ANSWER key=31"
check "--settings names the installed codd-hook" contains "$ROOT/sessions/$SID/meta.json" "$ROOT/bin/codd-hook-"
check "endpoint counted the 401" test "$(json "$ROOT/run1.json" "d['hooks']['rejected'].get('401')")" = 1
check "endpoint accepted the session's hooks" test "$(json "$ROOT/run1.json" "d['hooks']['accepted'] >= 6")" = True
check "no attention left" test "$(json "$ROOT/run1.json" "d['attention']")" = 0
check "layout.json lists the session" contains "$ROOT/layout.json" "\"claudeSessionId\" : \"$SID\""
sleep 0.5
HOLDER="$(holder_pids | head -1)"
check "holder survived the quit" test -n "$HOLDER"
check "holder adopted by launchd (ppid 1)" all_adopted

# ---------------------------------------------------------------------------------------------
# 2. Relaunch: listed, reattached, replayed, IDLE.
start_app run2 7 -codd-send-input 'reattach-e2e' -codd-dump-terminal "$ROOT/dump2.txt"
wait_app run2
check "relaunch discovered the live session" contains "$ROOT/run2.log" "sessions=1 live=1"
check "reattached to the same holder" contains "$ROOT/run2.log" "attached session=$SID holderPid=$HOLDER "
check "no new holder spawned" bash -c "! grep -q 'spawned session=' '$ROOT/run2.log'"
check "replay shows the first run's output" contains "$ROOT/dump2.txt" "FAKE-CLAUDE-IDLE"
check "input round-trips after reattach" contains "$ROOT/dump2.txt" "fake: reattach-e2e"
check "relaunch shows IDLE, not a stale DONE" test "$(session_field "$ROOT/run2.json" state)" = idle
check "same holder still running" test "$(holder_pids | head -1)" = "$HOLDER"

# ---------------------------------------------------------------------------------------------
# 3. The holder dies while CODD is not running.
kill -KILL "$HOLDER"
wait_for 5 bash -c "! kill -0 $HOLDER 2>/dev/null"
start_app run3 5
wait_app run3
check "dead holder discovered as not live" contains "$ROOT/run3.log" "sessions=1 live=0"
check "claude session is STOPPED (可接續)" test "$(session_field "$ROOT/run3.json" state)" = stopped
check "its Claude session id is kept for RESUME" test "$(session_field "$ROOT/run3.json" claudeSessionId)" = "$SID"

# ---------------------------------------------------------------------------------------------
# 4. RESUME.
start_app run4 10 -codd-resume-stopped YES -codd-dump-terminal "$ROOT/dump4.txt"
wait_for 9 state_in "$ROOT/run4.json" "idle"
wait_app run4
check "RESUME spawned claude --resume <id>" contains "$ROOT/run4.log" "resume=$SID"
check "fake claude saw --resume" contains "$ROOT/dump4.txt" "FAKE-CLAUDE session=$SID resume=$SID"
check "resumed session reached IDLE" test "$(session_field "$ROOT/run4.json" state)" = idle
check "resumed claude ran SessionStart through codd-hook" contains "$ROOT/dump4.txt" "FAKE-SESSIONSTART hook=$ROOT/bin/codd-hook-"

# ---------------------------------------------------------------------------------------------
# 5. The hook port is taken: degraded, not crashed.
python3 -I -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)' "$PORT" &
BLOCKER_PID=$!
sleep 0.5
start_app run5 10
# The port frees while the app runs: the endpoint binds on a retry (review E2E-1).
wait_for 6 grep -q "error hooks port $PORT in use" "$ROOT/run5.log"
sleep 1
kill "$BLOCKER_PID" 2>/dev/null
wait "$BLOCKER_PID" 2>/dev/null
BLOCKER_PID=""
wait_app run5
check "port in use is reported, the app keeps running" contains "$ROOT/run5.log" "error hooks port $PORT in use"
check "session still listed while degraded" test "$(session_field "$ROOT/run5.json" id)" = "$SID"
check "the endpoint binds once the port is free again" contains "$ROOT/run5.log" "hooks listening port=$PORT (after a retry)"
check "and reports listening" test "$(json "$ROOT/run5.json" "d['hooks']['status']")" = listening

# ---------------------------------------------------------------------------------------------
# 6. claude exits while CODD is running.
start_app run6 7 -codd-send-input 'FAKE-EXIT'
wait_for 6 bash -c "grep -q 'exit session=$SID status=3' '$ROOT/run6.log'"
wait_app run6
check "holder EXIT reached the store" contains "$ROOT/run6.log" "exit session=$SID status=3"
check "session is EXITED with code 3" test "$(session_field "$ROOT/run6.json" state):$(session_field "$ROOT/run6.json" exitCode)" = exited:3

echo "E2E killing holders: $(holder_pids | tr '\n' ' ')"
echo "E2E pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

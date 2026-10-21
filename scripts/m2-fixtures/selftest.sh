#!/bin/bash
# Self test of the M2 fixtures (docs/M2-PLAN.md C4, §6). Everything happens in one fresh mktemp
# folder; every process it starts carries that folder in its argv and is killed at the end
# (`pkill -f <tmp>/` only); the folder is removed unless KEEP=1.
#
#   scripts/m2-fixtures/selftest.sh
#   scripts/m2-fixtures/selftest.sh --with-app build/m2fixtures/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
#
# --with-app also launches CODD (real mode, DEBUG build) on a make-root.sh root seeded by
# seed-layout.sh, with a temp Claude directory, a fake claude path and `/bin/zsh -f` shells, and
# checks the state dump: the seeded groups and non-archived sessions, and the hook endpoint on the
# root's own port. Build the app first, e.g.
#   xcodebuild -project CODD.xcodeproj -scheme CODD -configuration Debug -derivedDataPath build/m2fixtures build
# Prints "FIXTURES pass=N fail=M"; exit 1 when a check failed, 2 on bad arguments.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

usage() {
    cat >&2 <<'EOF'
usage: selftest.sh [--with-app <path to CODD.app/Contents/MacOS/CODD>]
  KEEP=1 keeps the temp folder. PYTHON3=<python> picks the checker's python (default python3).
EOF
    exit 2
}

HERE="$(cd "$(dirname "$0")" && pwd -P)"
APP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-app) [[ $# -ge 2 && -n "$2" ]] || usage; APP="$2"; shift 2 ;;
        *) usage ;;
    esac
done
if [[ -n "$APP" && ! -x "$APP" ]]; then
    echo "FIXTURES missing app $APP (build it first: xcodebuild ... -derivedDataPath build/m2fixtures build)" >&2
    exit 2
fi
PY="${PYTHON3:-python3}"
command -v "$PY" >/dev/null || { echo "FIXTURES needs python3" >&2; exit 2; }
# Window-stack guard (docs/M5-PLAN.md D23), only with --with-app: the run fails when a window of that
# build rises above another app's window, even when every check passed.
source "$HERE/../lib/zorder-guard.sh"

# Short (holder sockets stay under 104 bytes) and normalized: `pkill -f` matches it verbatim. Only a
# folder this run created is ever removed: anything else aborts before a process starts.
T="$(mktemp -d "${TMPDIR:-/tmp}/codd-m2fx.XXXXXX")" || { echo "FIXTURES mktemp failed" >&2; exit 2; }
[[ -n "$T" && -d "$T" ]] || { echo "FIXTURES mktemp gave no folder" >&2; exit 2; }
T="$(cd "$T" && pwd -P)" || exit 2
case "$T" in
    /*/codd-m2fx.??????) ;;
    *) echo "FIXTURES unexpected temp folder '$T'" >&2; exit 2 ;;
esac
PASS=0
FAIL=0

cleanup() {
    local rc=$?
    pkill -TERM -f "$T/" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$T/" >/dev/null || break
        sleep 0.3
    done
    pkill -KILL -f "$T/" 2>/dev/null
    # After the app runs (a guard that never began, without --with-app, passes).
    if ! zorder_guard_end && [[ $rc == 0 ]]; then rc=1; fi
    if [[ "${KEEP:-0}" == 1 ]]; then echo "FIXTURES kept $T"; else rm -rf -- "$T"; fi
    exit "$rc"
}
trap cleanup EXIT

check() {
    local what="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "FIXTURES ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "FIXTURES FAIL $what"
    fi
}

# Runs one _selftest.py command and counts its CHECK lines (a missing CHECKS-DONE is a failure).
pychecks() {
    local line done=0
    while IFS= read -r line; do
        case "$line" in
            "CHECK ok "*) PASS=$((PASS + 1)); echo "FIXTURES ok   ${line#CHECK ok }" ;;
            "CHECK FAIL "*) FAIL=$((FAIL + 1)); echo "FIXTURES FAIL ${line#CHECK FAIL }" ;;
            "CHECKS-DONE "*) done=1 ;;
            *) echo "         $line" ;;
        esac
    done < <("$PY" -I "$HERE/_selftest.py" "$@" 2>&1)
    if [[ $done != 1 ]]; then
        FAIL=$((FAIL + 1)); echo "FIXTURES FAIL $1 checker did not finish"
    fi
}

jget() { "$PY" -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }
status_of() { [[ "$("$1" "${@:3}" >/dev/null 2>&1; echo $?)" == "$2" ]]; }
gone() { ! kill -0 "$1" 2>/dev/null || [[ "$(ps -o stat= -p "$1" 2>/dev/null)" == Z* ]]; }
contains_port() { grep -q "hooks listening port=$2\$" "$1" && [[ "$2" -ge 43000 && "$2" -le 43999 ]]; }

echo "FIXTURES tmp=$T${APP:+ app=$APP}"

# ---------------------------------------------------------------------------------------------
# make-root.sh
ROOT="$T/root"
LINE="$("$HERE/make-root.sh" "$ROOT")"
check "make-root.sh succeeds" test -n "$LINE"
pychecks config "$ROOT" "$LINE"
BEFORE="$(cat "$ROOT/config.json")"
check "make-root.sh refuses an existing config.json (exit 1)" status_of "$HERE/make-root.sh" 1 "$ROOT"
check "config.json unchanged after the refusal" test "$(cat "$ROOT/config.json")" = "$BEFORE"
check "make-root.sh without arguments prints usage (exit 2)" status_of "$HERE/make-root.sh" 2
mkdir -p "$T/fakehome"
check "make-root.sh refuses ~/.claude (HOME=$T/fakehome)" \
    bash -c "HOME='$T/fakehome' '$HERE/make-root.sh' '$T/fakehome/.claude/x' 2>/dev/null; [[ \$? == 1 && ! -e '$T/fakehome/.claude' ]]"
check "make-root.sh refuses ~/Library (HOME=$T/fakehome)" \
    bash -c "HOME='$T/fakehome' '$HERE/make-root.sh' '$T/fakehome/Library/Application Support/CODD' 2>/dev/null; [[ \$? == 1 && ! -e '$T/fakehome/Library' ]]"
NESTED="$T/a/b/root2"
check "make-root.sh creates parents" bash -c "'$HERE/make-root.sh' '$NESTED' >/dev/null && test -f '$NESTED/config.json'"

# ---------------------------------------------------------------------------------------------
# fake-external-claude.sh start / set-status / stop
CD="$T/claude"
EXT_CWD="$T/work/ext proj"
mkdir -p "$EXT_CWD"
read -r EPID ESID < <("$HERE/fake-external-claude.sh" start "$CD" "$EXT_CWD" "$T/ext-1")
check "external start prints '<pid> <sessionId>'" test -n "${EPID:-}" -a -n "${ESID:-}"
pychecks external "$CD" "${EPID:-0}" "${ESID:-}" "$EXT_CWD" "$T/ext-1" busy "external test"
REG="$CD/sessions/${EPID:-0}.json"
T0="$(jget "$REG" statusUpdatedAt)"
P0="$(jget "$REG" procStart)"
"$HERE/fake-external-claude.sh" set-status "$CD" "${EPID:-0}" waiting 'permission prompt'
pychecks external-status "$CD" "${EPID:-0}" waiting 'permission prompt' "${T0:-0}"
T1="$(jget "$REG" statusUpdatedAt)"
"$HERE/fake-external-claude.sh" set-status "$CD" "${EPID:-0}" idle
pychecks external-status "$CD" "${EPID:-0}" idle - "${T1:-0}"
check "set-status keeps sessionId and procStart" test "$(jget "$REG" sessionId)|$(jget "$REG" procStart)" = "$ESID|$P0"
check "set-status of an unknown pid fails" status_of "$HERE/fake-external-claude.sh" 1 set-status "$CD" 1 idle
check "stop removes the file and the process" \
    bash -c "'$HERE/fake-external-claude.sh' stop '$CD' '${EPID:-0}' && ! test -e '$REG'"
check "stopped dummy is gone" gone "${EPID:-0}"
read -r E2PID E2SID < <("$HERE/fake-external-claude.sh" start "$CD" "$EXT_CWD" "$T/ext-2" idle "第二個 外部")
pychecks external "$CD" "${E2PID:-0}" "${E2SID:-}" "$EXT_CWD" "$T/ext-2" idle "第二個 外部"
check "SIGTERM: the dummy removes its own file (clean exit)" \
    bash -c "kill -TERM ${E2PID:-0}; for i in 1 2 3 4 5 6 7 8 9 10; do test -e '$CD/sessions/${E2PID:-0}.json' || exit 0; sleep 0.2; done; exit 1"
perl -e 'sleep 30' "$T/not-a-dummy" </dev/null >/dev/null 2>&1 &
OTHER=$!
check "stop of a pid that is not a dummy refuses to kill it" \
    bash -c "'$HERE/fake-external-claude.sh' stop '$CD' $OTHER 2>/dev/null; [[ \$? == 1 ]] && kill -0 $OTHER"
kill "$OTHER" 2>/dev/null
wait "$OTHER" 2>/dev/null
check "fake-external-claude.sh usage (exit 2)" status_of "$HERE/fake-external-claude.sh" 2 bogus

# host mode under a pty (like a CODD shell's argv): the dummy's parent is the host process.
pychecks host "$HERE/fake-external-claude.sh" "$CD" "$T/work/host-proj" "$T/host-1"

# ---------------------------------------------------------------------------------------------
# make-transcripts.sh: a CJK + space + non-BMP path, and a plain space path.
ASCII_PREFIX="$(printf '%s' "$T/work" | sed 's/[^A-Za-z0-9]/-/g')"
CJK_CWD="$T/work/整合 範例𠮷"
mkdir -p "$CJK_CWD"
MANIFEST="$("$HERE/make-transcripts.sh" "$CD" "$CJK_CWD")"
check "make-transcripts.sh prints the manifest path" test -f "$MANIFEST"
# "/整合 範例" are 6 UTF-16 units, U+20BB7 two more: 8 dashes.
pychecks transcripts "$MANIFEST" "$CJK_CWD" "$ASCII_PREFIX--------" "$CD"
check "make-transcripts.sh refuses a second run for the same folder" status_of "$HERE/make-transcripts.sh" 1 "$CD" "$CJK_CWD"
SPACE_CWD="$T/work/my proj"
mkdir -p "$SPACE_CWD"
MANIFEST2="$("$HERE/make-transcripts.sh" "$CD" "$SPACE_CWD")"
pychecks transcripts "$MANIFEST2" "$SPACE_CWD" "$ASCII_PREFIX-my-proj" "$CD"
check "make-transcripts.sh usage (exit 2)" status_of "$HERE/make-transcripts.sh" 2 "$CD"

# ---------------------------------------------------------------------------------------------
# seed-layout.sh on a make-root.sh root.
SROOT="$T/seedroot"
"$HERE/make-root.sh" "$SROOT" >/dev/null
SCONFIG="$(cat "$SROOT/config.json")"
LMANIFEST="$("$HERE/seed-layout.sh" "$SROOT" "$T/seedwork")"
check "seed-layout.sh prints the manifest path" test -f "$LMANIFEST"
pychecks layout "$SROOT" "$T/seedwork" "$LMANIFEST"
check "seed-layout.sh leaves config.json alone" test "$(cat "$SROOT/config.json")" = "$SCONFIG"
check "seed-layout.sh refuses an existing layout.json" status_of "$HERE/seed-layout.sh" 1 "$SROOT" "$T/seedwork"
check "seed-layout.sh creates a missing data root" bash -c "'$HERE/seed-layout.sh' '$T/newroot' '$T/newwork' >/dev/null && test -f '$T/newroot/layout.json'"

# ---------------------------------------------------------------------------------------------
# fake-claude-m2.sh under a pty: no hook URL, registry mode, typed / pasted input, FAKE-EXIT.
pychecks fake-claude "$HERE/fake-claude-m2.sh" "$T"
# A copy with a sidecar .env, a hook sink, the SessionStart command hook, --resume, FAKE-CLEAR, SIGTERM.
pychecks fake-claude-hooks "$HERE/fake-claude-m2.sh" "$T"

# ---------------------------------------------------------------------------------------------
# --with-app: CODD on a seeded make-root.sh root.
if [[ -n "$APP" ]]; then
    zorder_guard_begin "$T" "$APP"
    AROOT="$T/approot"
    "$HERE/make-root.sh" "$AROOT" >/dev/null
    AMANIFEST="$("$HERE/seed-layout.sh" "$AROOT" "$T/appwork")"
    mkdir -p "$T/appclaude/sessions" "$T/fc"
    cp "$HERE/fake-claude-m2.sh" "$T/fc/fake-claude-app"
    chmod +x "$T/fc/fake-claude-app"
    # perl alarm: a hung app is killed after 60 s.
    perl -e 'alarm shift; exec @ARGV' 60 "$APP" -codd-data-root "$AROOT" -codd-claude-dir "$T/appclaude" \
        -codd-claude-path "$T/fc/fake-claude-app" -codd-shell-argv "/bin/zsh -f" -codd-login-env NO \
        -codd-notifications NO -codd-dump-state "$T/app-dump.json" -codd-quit-after 4 >"$T/app.log" 2>&1
    APP_STATUS=$?
    echo "FIXTURES app exit=$APP_STATUS log=$T/app.log"
    check "app ran and quit by itself (exit 0)" test "$APP_STATUS" == 0
    check "app wrote the state dump" test -s "$T/app-dump.json"
    if [[ -s "$T/app-dump.json" ]]; then
        pychecks dump "$T/app-dump.json" "$AMANIFEST" "$AROOT/config.json" "$T/app.log"
    fi
    check "app left no session holder running (nothing was started)" bash -c "! pgrep -f '$AROOT/bin/codd-holder-' >/dev/null"

    # fake-claude-m2 as CODD's claude (a copy + sidecar .env: CODD passes no FAKE_* variables), its
    # registry file in the watched <claudeDir>/sessions, typed input through the holder stream.
    BROOT="$T/approot2"
    "$HERE/make-root.sh" "$BROOT" >/dev/null
    BPORT="$(jget "$BROOT/config.json" port)"
    mkdir -p "$T/appclaude2/sessions" "$T/appwork2/proj"
    cp "$HERE/fake-claude-m2.sh" "$T/fc/fake-claude"
    chmod +x "$T/fc/fake-claude"
    printf 'FAKE_REGISTRY_DIR=%s\nFAKE_LOG_DIR=%s\nFAKE_PRINT_ENV=CODD_SESSION_ID\n' \
        "$T/appclaude2/sessions" "$T/fclog-app" >"$T/fc/fake-claude.env"
    perl -e 'alarm shift; exec @ARGV' 60 "$APP" -codd-data-root "$BROOT" -codd-claude-dir "$T/appclaude2" \
        -codd-claude-path "$T/fc/fake-claude" -codd-shell-argv "/bin/zsh -f" -codd-login-env NO \
        -codd-notifications NO -codd-new-claude "$T/appwork2/proj" -codd-send-input 'hello 世界' \
        -codd-dump-state "$T/app2-dump.json" -codd-quit-after 8 >"$T/app2.log" 2>&1
    APP_STATUS=$?
    echo "FIXTURES app exit=$APP_STATUS log=$T/app2.log"
    FLOGS=("$T"/fclog-app/fake-*.log)
    FLOG="${FLOGS[0]}"
    [[ -f "$FLOG" ]] || FLOG=""
    check "app 2 ran and quit by itself (exit 0)" test "$APP_STATUS" == 0
    check "CODD started the fake claude (FAKE_LOG_DIR log)" test -n "$FLOG"
    FLOG="${FLOG:-/nonexistent}"
    check "fake claude under CODD: DA1 answered by the terminal" grep -qx 'FAKE-DA1-OK' "$FLOG"
    check "fake claude under CODD: SessionStart through the installed codd-hook" \
        grep -q "^FAKE-SESSIONSTART hook=$BROOT/bin/codd-hook-[0-9a-f]* status=0\$" "$FLOG"
    check "fake claude under CODD: typed CJK line and submit" bash -c "grep -qx 'FAKE-LINE hello 世界' '$FLOG' && grep -qx 'FAKE-SUBMIT' '$FLOG'"
    check "fake claude under CODD: UserPromptSubmit and Stop accepted (204)" \
        bash -c "grep -qx 'FAKE-HOOK UserPromptSubmit 204' '$FLOG' && grep -qx 'FAKE-HOOK Stop 204' '$FLOG'"
    check "CODD saw the turn (busy, then done or idle)" \
        bash -c "grep -q 'idle->busy' '$T/app2.log' && grep -Eq 'busy->(done|idle)' '$T/app2.log'"
    check "CODD's hook endpoint on the root's own port" contains_port "$T/app2.log" "$BPORT"
    FPID="$(basename "$FLOG" .log)"; FPID="${FPID#fake-}"
    check "registry file <claudeDir>/sessions/<fake pid>.json while it runs" test -f "$T/appclaude2/sessions/$FPID.json"
    pkill -TERM -f "$BROOT/bin/codd-holder-" 2>/dev/null
    check "holder hangup: the fake claude removes its registry file" \
        bash -c "for i in \$(seq 50); do test -e '$T/appclaude2/sessions/$FPID.json' || exit 0; sleep 0.1; done; exit 1"
    check "holder and fake claude ended" bash -c "for i in \$(seq 50); do pgrep -f '$BROOT/' >/dev/null || exit 0; sleep 0.1; done; exit 1"
fi

# Every check stopped what it started; cleanup's pkill is only the safety net.
sleep 0.5
check "no process of the self test is left running" bash -c "! pgrep -f '$T/' >/dev/null"
pgrep -fl "$T/" 2>/dev/null | sed 's/^/         left: /'
echo "FIXTURES pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

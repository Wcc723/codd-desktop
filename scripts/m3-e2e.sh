#!/bin/bash
# M3 end-to-end test (docs/M3-PLAN.md §5 I4, A1-A14): real CODD.app (DEBUG build), real codd-holder,
# real hook endpoint and /statusline route, real codd-statusline, FAKE claudes and a FAKE cswap only
# (scripts/m3-fixtures: no Anthropic call, no quota, no Keychain, never ~/.claude, never the real
# cswap or ~/.claude-swap-backup).
#
# Isolation: one mktemp folder in the per-user temp folder; inside it one group folder per scenario
# group with its own data root (scripts/m2-fixtures/make-root.sh: own hook port in 43000-43999, own
# token), its own Claude directory and `.claude.json` (`home/`), its own fake cswap state
# (make-cswap-state.sh), its own copies of the fake cswap and the fake claude with sidecars, and its
# own Claude settings (make-claude-settings.sh). No login-shell capture, notifications off, shells
# are `/bin/zsh -f`. Every launch passes -codd-data-root, -codd-claude-dir, -codd-cswap-path,
# -codd-cswap-root and -codd-claude-path inside the folder and stays in the background
# (CODD_BACKGROUND=1). Every process it starts carries the folder in its argv; the cleanup sends
# SIGCONT, SIGTERM, then SIGKILL to `pkill -f "<tmp>/"` only, and removes the folder unless KEEP=1.
# The one link that points outside (A13, `realclaude -> ~/.claude`, to prove the installer's guard)
# is only ever resolved, never read or written through; `rm -rf` removes the link, not its target.
#
#   scripts/m3-e2e.sh            # build first: xcodegen generate && xcodebuild … -derivedDataPath build/dd build
#   CODD_APP=/path/CODD.app/Contents/MacOS/CODD KEEP=1 scripts/m3-e2e.sh   # keep the temp folder
#   ONLY=A4,A7 scripts/m3-e2e.sh # only these sections (ids A1..A15, comma separated; unset = all, same
#                                # output and exit codes as before). Unselected sections print `E2E skip <id>`
#                                # and their groups and launches do not run; a check of an unselected section
#                                # inside a launch that does run is evaluated silently (not counted). A3 also
#                                # runs A1/A2's launch (it needs the quota.json that launch writes). An unknown
#                                # id exits 64 with the valid ids. A13 includes its over-every-run scan of
#                                # the runs that happened.
#
# Scenarios (each run is a separate app launch with -codd-quit-after and -codd-dump-state):
#   A1   accounts from the fake state: R7 order #2 #3 #1, active #3, plans MAX 20x;
#   A2   status line: --settings carries statusLine = '<dataRoot>/bin/codd-statusline-<hex12>'
#        (single-quoted: Claude runs it through /bin/sh -c) with the user's padding, the chain env
#        decodes to the user's command, the fake claude's status line prints USER-SL-ok and exits
#        0, #3 turns `statusline` 91 % / 15 %, quota.json 0600;
#   A3   pinned sessions (the ⌘N pin flag, and a launch profile whose environment sets
#        CLAUDE_CONFIG_DIR to the cswap profile): the claude sees CLAUDE_CONFIG_DIR, reports cswap-2,
#        #2 turns `statusline`, the session carries account 2 pinned, the profile's registry folder
#        is watched (an external there is listed), the profile path never shows in dump or log;
#   A4   direct switch + UNDO through the fake cswap (switch 2, then switch 3), a failure envelope
#        (redacted in the dump), and two lock timeouts then success on attempt 3;
#   A5   auto-switch ON with 1w at 1 %: switch to the R7-first eligible account #2; a low report
#        for #2 inside the cooldown and a relaunch (cooldown from quota.json) switch nothing;
#        all accounts low: none-eligible recorded once; a `cswap switch` that keeps failing is
#        tried twice, then waits, and is notified once;
#   A6   global installer on a user-shaped settings.json (CODD web leftovers, hook-tap, osascript):
#        plan, apply with backup, foreign handlers byte-identical, desktop wrapper chaining the
#        user's command, second plan no changes, uninstall, a file touched after the plan refused;
#   A7   quit dialog with a running shell: keep-running leaves the holder, stop-all ends it;
#   A8   preferences applied (stale 1800 s, menu bar counts, Dock off), no login item;
#   A9   global hotkey registered on the test combo ctrl+option+cmd+f12 (never ⌥Space);
#   A10  4 accounts: the menu bar lists 3 (the active one among them) and the expander count;
#   A11  add account (dialog C, all three steps): the ephemeral shell runs the fake /login,
#        `cswap add --slot 4 --alias studio`, `switch 3`, the ephemeral session and its folder gone;
#        the alias 工作室 is refused before cswap runs;
#   A12  numbers: codd-statusline 200 runs against the running app, app idle CPU and footprint with
#        3 fake claudes reporting every second;
#   A13  isolation: every `exec` log line inside the folder; -codd-hooks-apply into the real
#        ~/.claude refused before anything is read (a settings path through a link, and, with a
#        fake home (CFFIXED_USER_HOME), a -codd-claude-dir through a link and no override at
#        all); the D1 `cswap list` fallback only on request; no e-mail and no profile slug in any
#        data root file, dump or log;
#   A14  a stale cswap profile: the ⌘N option disabled and the pin refused with the banner text;
#   A15  a data root whose path has a space and a single quote (the standard root has a space):
#        the status line still runs and reports.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1
# A run started inside a CODD session (a claude's Bash tool, a CODD terminal) inherits that
# session's hook variables. They belong to the user's own CODD, never to this run: with
# CODD_STATUSLINE_CHAIN set, every codd-statusline of A12 ran the user's status line too (about
# 110 ms per run instead of 3), and the hook URL / token name the real CODD's endpoint.
unset CODD_STATUSLINE_CHAIN CODD_STATUSLINE_TIMEOUT_MS CODD_HOOK_URL CODD_HOOK_TOKEN CODD_SESSION_ID

# ONLY=<ids>: section selection (see the header). Validated before anything else happens.
ALL_IDS="A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 A11 A12 A13 A14 A15"
ONLY="${ONLY:-}"
if [[ -n "$ONLY" ]]; then
    IFS=',' read -r -a _only_ids <<<"$ONLY"
    for _id in "${_only_ids[@]}"; do
        case " $ALL_IDS " in
            *" $_id "*) ;;
            *) echo "E2E unknown section '$_id' in ONLY (valid: ${ALL_IDS// /,})" >&2; exit 64 ;;
        esac
    done
fi
# sel <id>: the section is selected (always, when ONLY is unset).
sel() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

# The fakes refuse paths outside the per-user temp folder; make sure TMPDIR names it.
if [[ -z "${TMPDIR:-}" ]]; then
    TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
    export TMPDIR
fi

cd "$(dirname "$0")/.."
REPO="$(pwd -P)"
APP="${CODD_APP:-build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD}"
FIX2="$REPO/scripts/m2-fixtures"
FIX3="$REPO/scripts/m3-fixtures"
PY="${PYTHON3:-/usr/bin/python3}"
[[ -x "$PY" ]] || PY="python3"
if [[ ! -x "$APP" ]]; then
    echo "E2E missing $APP (build the app first)" >&2
    exit 2
fi
command -v "$PY" >/dev/null || { echo "E2E needs python3 (JSON checks)" >&2; exit 2; }
# Window-stack guard (docs/M5-PLAN.md D23): the run fails when a window of this build rises above
# another app's window, even when every check passed (scripts/lib/zorder-guard.sh).
source scripts/lib/zorder-guard.sh

# Short (holder sockets must stay under 104 bytes) and resolved (`pkill -f` matches it verbatim).
T="$(mktemp -d "${TMPDIR%/}/codd-m3e.XXXXXX")" || { echo "E2E mktemp failed" >&2; exit 2; }
ROOT="$(cd "$T" && pwd -P)" || exit 2
case "$ROOT" in
    /*/codd-m3e.??????) ;;
    *) echo "E2E unexpected temp folder '$ROOT'" >&2; exit 2 ;;
esac
PASS=0
FAIL=0
APP_PID=""
APP_NAME=""
USER_SL="printf 'USER-SL-%s' ok"

cleanup() {
    local rc=$?
    pkill -CONT -f "$ROOT/" 2>/dev/null
    pkill -TERM -f "$ROOT/" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
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
    # A check of an unselected section (its label starts with the id) is run silently: its waits
    # still gate the checks after it, nothing is counted or printed.
    if ! sel "${what%% *}"; then "$@" >/dev/null 2>&1; return 0; fi
    if "$@"; then
        PASS=$((PASS + 1)); echo "E2E ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "E2E FAIL $what"
    fi
}
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
count_of() { grep -cF -- "$2" "$1" 2>/dev/null || true; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
fsub() { "$PY" -I -c 'import sys; print("%.2f" % (float(sys.argv[1]) - float(sys.argv[2])))' "$1" "$2"; }
fle() { "$PY" -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$1" "$2" 2>/dev/null; }
alive() { [[ -n "$1" && "$1" -gt 1 ]] 2>/dev/null && kill -0 "$1" 2>/dev/null; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null; }
epoch() { date +%s; }

# jexpr <json file> <python expression> [args…]: prints the value ("" on any error). The expression
# sees `d` (the file), `a` (the extra args) and the helpers below.
jexpr() {
    "$PY" -I - "$@" 2>/dev/null <<'PY'
import base64, json, os, re, sys
def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)
try:
    d = load(sys.argv[1])
    a = sys.argv[3:]
    def S(i): return next((s for s in d.get("sessions", []) if s.get("id") == i), None)
    def ext(): return [s for s in d.get("sessions", []) if s.get("external")]
    def X(pid): return next((s for s in ext() if s.get("externalPid") == int(pid)), None)
    def claudes(): return [s for s in d.get("sessions", []) if s.get("kind") == "claude" and not s.get("external")]
    def acc(): return d.get("accounts") or {}
    def order(): return acc().get("order") or []
    def A(i): return next((x for x in order() if x.get("id") == str(i)), None)
    def opt(i): return next((o for o in (d.get("newSession") or {}).get("accountOptions", []) if o.get("id") == str(i)), None)
    def posted(kind=None): return [p for p in (d.get("notifications") or {}).get("posted", []) if kind is None or p.get("kind") == kind]
    v = eval(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}
jtrue() { [[ "$(jexpr "$@")" == True ]]; }

# calls <cswap log> <python expression> [args…]: `L` is the list of argv lists the fake cswap logged.
calls() {
    "$PY" -I - "$@" 2>/dev/null <<'PY'
import json, sys
try:
    L = []
    with open(sys.argv[1], encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                L.append(json.loads(line)["argv"])
except FileNotFoundError:
    L = []
a = sys.argv[3:]
def n(*argv): return sum(1 for x in L if x == list(argv))
def sub(name): return [x for x in L if x and x[0] == name]
v = eval(sys.argv[2])
print("" if v is None else v)
PY
}
ctrue() { [[ "$(calls "$@")" == True ]]; }

# setup_group <name> [make-cswap-state args…]: a data root, a home with .claude / .claude.json /
# .claude-swap-backup, the fakes with sidecars, a work folder. Sets G.
setup_group() {
    local name="$1"; shift
    G="$ROOT/$name"
    mkdir -p "$G/bin" "$G/work" "$G/fakelog"
    "$FIX2/make-root.sh" "$G/d" >/dev/null || { echo "E2E make-root failed ($name)" >&2; exit 2; }
    "$FIX3/make-cswap-state.sh" "$G/home/.claude-swap-backup" "$G/home/.claude" "$@" >/dev/null \
        || { echo "E2E make-cswap-state failed ($name)" >&2; exit 2; }
    mkdir -p "$G/home/.claude/sessions"
    cp "$FIX3/fake-cswap.py" "$G/bin/cswap"
    cp "$FIX3/fake-claude-m3.sh" "$G/bin/fake-claude"
    chmod +x "$G/bin/cswap" "$G/bin/fake-claude"
    cswap_env "$name"
    cat >"$G/bin/fake-claude.env" <<EOF
FAKE_REGISTRY_DIR=auto
FAKE_DEFAULT_CLAUDE_DIR=$G/home/.claude
FAKE_LOG_DIR=$G/fakelog
FAKE_RATE_LIMITS_FILE=$G/rl.json
FAKE_PRINT_ENV=CLAUDE_CONFIG_DIR,ANTHROPIC_API_KEY,CODD_STATUSLINE_CHAIN
FAKE_CSWAP_ROOT=$G/home/.claude-swap-backup
EOF
}
# cswap_env <group> [extra KEY=VALUE…]: (re)writes the fake cswap's sidecar.
cswap_env() {
    local g="$ROOT/$1"; shift
    { printf 'FAKE_CSWAP_ROOT=%s\nFAKE_CSWAP_LOG=%s\n' "$g/home/.claude-swap-backup" "$g/cswap-calls.jsonl"
      for kv in "$@"; do printf '%s\n' "$kv"; done; } >"$g/bin/cswap.env"
}
# rl <group> <5h used> <5h reset|-> <7d used> <7d reset|->: the fake claudes' rate_limits.
rl() { local g="$ROOT/$1"; shift; "$FIX3/rate-limits.sh" "$g/rl.json" "$@" >/dev/null; }
profile_dir() { ls -d "$ROOT/$1/home/.claude-swap-backup/sessions/2-"* 2>/dev/null | head -1; }

# start_app <name> <group> <seconds> [flags…]: runs in the background; the dump is $ROOT/<name>.json,
# the log $ROOT/<name>.log. Later flags win (e.g. another -codd-cswap-root).
start_app() {
    local name="$1" g="$ROOT/$2" seconds="$3"; shift 3
    rm -f "$ROOT/$name.json"
    perl -e 'alarm shift; exec @ARGV' 120 "$APP" -codd-data-root "$g/d" -codd-claude-dir "$g/home/.claude" \
        -codd-cswap-path "$g/bin/cswap" -codd-cswap-root "$g/home/.claude-swap-backup" \
        -codd-claude-path "$g/bin/fake-claude" -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO \
        -codd-quit-after "$seconds" -codd-dump-state "$ROOT/$name.json" "$@" >"$ROOT/$name.log" 2>&1 &
    APP_PID=$!
    APP_NAME="$name"
    RUNS+=("$name")
}
RUNS=()
wait_app() {
    wait "$APP_PID"
    local status=$?
    echo "E2E $APP_NAME exit=$status log=$ROOT/$APP_NAME.log"
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
spawned_id() { grep -o "spawned session=[^ ]* kind=$2" "$1" 2>/dev/null | head -1 | sed 's/spawned session=//; s/ kind=.*//'; }
holder_of() { grep -o "spawned session=$2 kind=[a-z]* holderPid=[0-9]*" "$1" 2>/dev/null | head -1 | sed 's/.*holderPid=//'; }
# end_holders <group>: ends that group's holders (their children get SIGHUP) and waits.
end_holders() {
    pkill -TERM -f "$ROOT/$1/d/bin/codd-holder-" 2>/dev/null
    wait_for 10 bash -c "! pgrep -f '$ROOT/$1/d/bin/codd-holder-' >/dev/null"
}
fake_log() { printf '%s/fakelog/fake-%s.log' "$ROOT/$1" "$2"; }
fake_json() { printf '%s/fakelog/fake-%s.json' "$ROOT/$1" "$2"; }
iso_epoch() { "$PY" -I -c 'import sys, datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))' "$1"; }
# write_profiles <dataRoot> <json profiles to add after the built-ins> (before the root's first launch).
write_profiles() {
    "$PY" -I - "$1/profiles.json" "$2" <<'PY'
import json, os, sys
builtins = [
    {"id": "claude-default", "name": "claude-default", "kind": "claude", "environment": {}, "extraArguments": []},
    {"id": "claude-plan", "name": "claude-plan", "kind": "claude", "defaultPermissionMode": "plan", "environment": {}, "extraArguments": []},
    {"id": "claude-rc", "name": "claude-rc", "kind": "claude", "environment": {}, "extraArguments": ["--remote-control"]},
]
extra = json.loads(sys.argv[2])
shell = [{"id": "zsh", "name": "zsh", "kind": "shell", "environment": {}, "extraArguments": []}]
doc = {"version": 1, "defaultProfileId": "claude-default", "profiles": builtins + extra + shell}
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2, sort_keys=True)
PY
}

echo "E2E root=$ROOT app=$APP"
for _id in $ALL_IDS; do sel "$_id" || echo "E2E skip $_id"; done

# =============================================================================================
# Group a: accounts, status line, pinned sessions (A1, A2, A3).
if sel A1 || sel A2 || sel A3; then
setup_group a
A="$ROOT/a"
PROFILE_A="$(profile_dir a)"
PROFILE_SLUG="$(basename "$PROFILE_A")"
"$FIX3/make-claude-settings.sh" "$A/home/.claude" >/dev/null || exit 2
write_profiles "$A/d" "[{\"id\":\"pin2\",\"name\":\"pin2 e2e\",\"kind\":\"claude\",\"environment\":{\"CLAUDE_CONFIG_DIR\":\"$PROFILE_A\"},\"extraArguments\":[]}]" || exit 2
NOW="$(epoch)"
rl a 9 $((NOW + 9000)) 85 $((NOW + 260000))

# ---------------------------------------------------------------------------------------------
# A1 + A2. Accounts from the state, the status line of one unpinned claude.
start_app a1 a 16 -codd-new-claude "$A/work"
D="$ROOT/a1.json"
check "A2 #3 turns statusline 91 % / 15 % within 15 s" wait_for 15 jtrue "$D" \
    "A(3)['five']['source'] == 'statusline' and A(3)['five']['remaining'] == 91 and A(3)['weekly']['source'] == 'statusline' and A(3)['weekly']['remaining'] == 15"
check "A1 accounts ready, cswap 0.26.0, R7 order #2 #3 #1" jtrue "$D" \
    "acc()['availability'] == 'ready' and acc()['cswapVersion'] == '0.26.0' and [x['id'] for x in order()] == ['2', '3', '1']"
check "A1 active #3 (the .claude.json identity), aliases as cswap stores them" jtrue "$D" \
    "acc()['active'] == '3' and [x['active'] for x in order()] == [False, True, False] and [x['alias'] for x in order()] == ['藍鵲', '工作', '個人']"
check "A1 plans MAX 20x from the config backups" jtrue "$D" "[x['plan'] for x in order()] == ['MAX 20x'] * 3"
check "A1 #2 from the cswap cache (5h 98 %, 1w 46 %, source cswap cache)" jtrue "$D" \
    "A(2)['five']['remaining'] == 98 and A(2)['weekly']['remaining'] == 46 and A(2)['source'] == 'cswap cache' and A(2)['hasSessionProfile'] is True"
wait_app
check "A1 app quit by itself" test $? == 0
S_A1="$(spawned_id "$ROOT/a1.log" claude)"
F_A1="$(jexpr "$D" "S(a[0])['pid']" "$S_A1")"
echo "E2E a1 claude session=$S_A1 fake pid=$F_A1"
check "A2 --settings carries statusLine = '<dataRoot>/bin/codd-statusline-<hex12>' (quoted) with the user's padding" jtrue "$(fake_json a "${F_A1:-x}")" \
    "(lambda s: s['statusLine']['type'] == 'command' and re.fullmatch(\"'\" + re.escape(a[0]) + r\"/bin/codd-statusline-[0-9a-f]{12}'\", s['statusLine']['command']) is not None and s['statusLine'].get('padding') == 0)(json.loads(d['argv'][d['argv'].index('--settings') + 1]))" \
    "$A/d"
check "A2 the hooks are still all there next to it (14 events)" jtrue "$(fake_json a "${F_A1:-x}")" \
    "len(json.loads(d['argv'][d['argv'].index('--settings') + 1])['hooks']) == 14"
check "A2 the fake claude saw the statusLine command at startup" grep -qF "FAKE-STATUSLINE-CONFIG interval=1000 command='$A/d/bin/codd-statusline-" "$(fake_log a "${F_A1:-x}")"
check "A2 CODD_STATUSLINE_CHAIN decodes to the user's own command" bash -c \
    "grep '^FAKE-ENV CODD_STATUSLINE_CHAIN=' '$(fake_log a "${F_A1:-x}")' | head -1 | sed 's/^FAKE-ENV CODD_STATUSLINE_CHAIN=//' | base64 -D | grep -qxF \"$USER_SL\""
check "A2 the chained status line printed USER-SL-ok and exited 0" bash -c \
    "grep -qx 'FAKE-STATUSLINE-OUT USER-SL-ok' '$(fake_log a "${F_A1:-x}")' && grep -qx 'FAKE-STATUSLINE-EXIT 0' '$(fake_log a "${F_A1:-x}")' && ! grep -q '^FAKE-STATUSLINE-EXIT [^0]' '$(fake_log a "${F_A1:-x}")'"
check "A2 the claude is unpinned and follows #3" jtrue "$D" "S(a[0])['account'] == '3' and S(a[0])['accountPinned'] is False" "$S_A1"
check "A2 statusline counters: reports accepted, last key default -> #3, nothing dropped" jtrue "$D" \
    "d['statusline']['accepted'] >= 3 and d['statusline']['lastKey'] == 'default' and d['statusline']['lastAccount'] == '3' and d['statusline']['dropped'] == 0"
check "A2 quota.json written with mode 0600" test "$(mode_of "$A/d/quota.json")" == 600
check "A2 quota.json keeps #3 from statusline (9 / 85 used) and #2 from cswap" jtrue "$A/d/quota.json" \
    "d['v'] == 1 and d['accounts']['3']['fiveHour']['source'] == 'statusline' and d['accounts']['3']['fiveHour']['usedPercent'] == 9 and d['accounts']['3']['weekly']['usedPercent'] == 85 and d['accounts']['2']['weekly']['source'] == 'cswap'"
check "A2 log: statusline first report key=default account=3" contains "$ROOT/a1.log" "statusline first report key=default account=3"
end_holders a

if sel A3; then
# ---------------------------------------------------------------------------------------------
# A3a. A session pinned through the ⌘N account select's path; an external in the profile.
rl a 20 $((NOW + 9000)) 30 $((NOW + 300000))
read -r XPID _ < <("$FIX2/fake-external-claude.sh" start "$PROFILE_A" "$A/work" "$ROOT/m-profile-ext" idle "profile external")
start_app a2 a 16 -codd-new-claude "$A/work" -codd-new-claude-account 2
D="$ROOT/a2.json"
check "A3 pinned session: #2 turns statusline 80 % / 70 % (key cswap-2)" wait_for 15 jtrue "$D" \
    "A(2)['five']['source'] == 'statusline' and A(2)['five']['remaining'] == 80 and A(2)['weekly']['remaining'] == 70 and d['statusline']['lastKey'] == 'cswap-2'"
check "A3 the active account is still #3 and keeps its own numbers" jtrue "$D" \
    "acc()['active'] == '3' and A(3)['weekly']['remaining'] == 15"
check "A3 the external whose registry sits in the profile's sessions folder is listed" wait_for 8 jtrue "$D" "X(a[0]) is not None" "${XPID:-0}"
wait_app
check "A3 app quit by itself" test $? == 0
"$FIX2/fake-external-claude.sh" stop "$PROFILE_A" "$XPID" >/dev/null 2>&1
S_A2="$(spawned_id "$ROOT/a2.log" claude)"
F_A2="$(jexpr "$D" "S(a[0])['pid']" "$S_A2")"
echo "E2E a2 pinned session=$S_A2 fake pid=$F_A2"
check "A3 dump: the session carries account 2, pinned (the #2 chip)" jtrue "$D" "S(a[0])['account'] == '2' and S(a[0])['accountPinned'] is True and S(a[0])['external'] is False" "$S_A2"
check "A3 log: pinned session=… account=#2" contains "$ROOT/a2.log" "pinned session=$S_A2 account=#2"
check "A3 the pinned claude saw CLAUDE_CONFIG_DIR (masked) and no API key" bash -c \
    "grep -qx 'FAKE-ENV CLAUDE_CONFIG_DIR=set' '$(fake_log a "${F_A2:-x}")' && grep -qx 'FAKE-ENV ANTHROPIC_API_KEY=unset' '$(fake_log a "${F_A2:-x}")'"
check "A3 its registry file went into the profile's sessions folder (FAKE_REGISTRY_DIR=auto)" bash -c \
    "grep -qx 'FAKE-REGISTRY <CLAUDE_CONFIG_DIR>/sessions/${F_A2:-x}.json' '$(fake_log a "${F_A2:-x}")'"
check "A3 the profile path never appears in the dump or the log" bash -c \
    "! grep -qF -- '$PROFILE_SLUG' '$D' '$ROOT/a2.log' && ! grep -qF -- '.claude-swap-backup/sessions' '$D' '$ROOT/a2.log'"
end_holders a

# ---------------------------------------------------------------------------------------------
# A3b. A launch profile whose environment sets CLAUDE_CONFIG_DIR to the cswap profile.
rl a 30 $((NOW + 9000)) 40 $((NOW + 300000))
start_app a3 a 16 -codd-new-claude "$A/work" -codd-new-profile pin2
D="$ROOT/a3.json"
check "A3 launch-profile pin: #2 turns statusline 70 % / 60 % (key cswap-2)" wait_for 15 jtrue "$D" \
    "A(2)['five']['source'] == 'statusline' and A(2)['five']['remaining'] == 70 and A(2)['weekly']['remaining'] == 60 and d['statusline']['lastKey'] == 'cswap-2' and d['statusline']['lastAccount'] == '2'"
wait_app
check "A3 launch-profile run quit by itself" test $? == 0
S_A3="$(spawned_id "$ROOT/a3.log" claude)"
F_A3="$(jexpr "$D" "S(a[0])['pid']" "$S_A3")"
check "A3 launch-profile session records account 2 (pinned)" jtrue "$D" "S(a[0])['account'] == '2' and S(a[0])['accountPinned'] is True" "$S_A3"
check "A3 launch-profile claude saw CLAUDE_CONFIG_DIR" contains "$(fake_log a "${F_A3:-x}")" "FAKE-ENV CLAUDE_CONFIG_DIR=set"
check "A3 launch-profile: the profile path never appears in the dump or the log" bash -c \
    "! grep -qF -- '$PROFILE_SLUG' '$D' '$ROOT/a3.log'"
end_holders a

fi

fi

# =============================================================================================
# Group s: a data root with a space and a single quote (A15). The standard root
# `~/Library/Application Support/CODD` has a space; Claude runs the status line through
# `/bin/sh -c`, so an unquoted path exited 127 in every CODD session (M3 review).
if sel A15; then
setup_group s
S_="$ROOT/s"
SROOT="$S_/d m3'e"
"$FIX2/make-root.sh" "$SROOT" >/dev/null || { echo "E2E make-root failed (s)" >&2; exit 2; }
"$FIX3/make-claude-settings.sh" "$S_/home/.claude" >/dev/null || exit 2
NOW="$(epoch)"
rl s 9 $((NOW + 9000)) 85 $((NOW + 260000))
start_app s1 s 16 -codd-data-root "$SROOT" -codd-new-claude "$S_/work"
D="$ROOT/s1.json"
check "A15 space and quote root: #3 turns statusline 91 % / 15 %" wait_for 15 jtrue "$D" \
    "A(3)['five']['source'] == 'statusline' and A(3)['five']['remaining'] == 91 and A(3)['weekly']['remaining'] == 15"
wait_app
check "A15 run quit by itself" test $? == 0
S_S1="$(spawned_id "$ROOT/s1.log" claude)"
F_S1="$(jexpr "$D" "S(a[0])['pid']" "$S_S1")"
check "A15 statusLine.command is the root single-quoted ('\\'' for the quote)" jtrue "$(fake_json s "${F_S1:-x}")" \
    "(lambda c: c.startswith(\"'\") and c.endswith(\"'\") and (\"'\\\\''\".join(a[0].split(\"'\")) + '/bin/codd-statusline-') in c)(json.loads(d['argv'][d['argv'].index('--settings') + 1])['statusLine']['command'])" \
    "$SROOT"
check "A15 the status line ran through /bin/sh: USER-SL-ok, exit 0, never 127" bash -c \
    "grep -qx 'FAKE-STATUSLINE-OUT USER-SL-ok' '$(fake_log s "${F_S1:-x}")' && ! grep -q '^FAKE-STATUSLINE-EXIT [^0]' '$(fake_log s "${F_S1:-x}")'"
check "A15 reports accepted and attributed to #3, nothing dropped" jtrue "$D" \
    "d['statusline']['accepted'] >= 3 and d['statusline']['lastAccount'] == '3' and d['statusline']['dropped'] == 0"
pkill -TERM -f "$SROOT/bin/codd-holder-" 2>/dev/null
wait_for 10 bash -c "! pgrep -f '$SROOT/bin/codd-holder-' >/dev/null"

fi

# =============================================================================================
# Group b: direct switching (A4).
if sel A4; then
setup_group b
B="$ROOT/b"
"$FIX3/make-claude-settings.sh" "$B/home/.claude" >/dev/null || exit 2
cswap_env b FAKE_CSWAP_SWITCH_DELAY_MS=1500

# ---------------------------------------------------------------------------------------------
# A4a. Switch to #2 (each switch takes 1.5 s, so the dump shows #2 before UNDO goes back).
start_app b1 b 20 -codd-switch-account 2 -codd-undo-switch YES
D="$ROOT/b1.json"
check "A4 switch: the dump shows #2 active" wait_for 15 jtrue "$D" "acc()['active'] == '2' and str(acc()['lastSwitch']['to']) == '2' and acc()['lastSwitch']['reason'] == 'user'"
check "A4 UNDO: back on #3, lastSwitch is the undo from #2" wait_for 15 jtrue "$D" \
    "acc()['active'] == '3' and str(acc()['lastSwitch']['from']) == '2' and str(acc()['lastSwitch']['to']) == '3' and acc()['lastSwitch']['reason'] == 'undo' and acc()['switchState']['state'] == 'idle'"
wait_app
check "A4 switch run quit by itself" test $? == 0
check "A4 fake cswap: switch 2 --json, then switch 3 --json (UNDO), nothing else switched" ctrue "$B/cswap-calls.jsonl" \
    "sub('switch') == [['switch', '2', '--json'], ['switch', '3', '--json']]"
check "A4 log: the toast's UNDO was pressed and #3 is active again" bash -c \
    "grep -q 'debug switch-account to=#2 outcome=switched' '$ROOT/b1.log' && grep -q 'debug undo-switch pressed=true' '$ROOT/b1.log' && grep -q 'debug undo-switch active=#3' '$ROOT/b1.log'"
check "A4 cswap's state says #3 again" jtrue "$B/home/.claude-swap-backup/sequence.json" "d['activeAccountNumber'] == 3"

# ---------------------------------------------------------------------------------------------
# A4b. A failure envelope (the message names both e-mails).
cswap_env b FAKE_CSWAP_FAIL=error
start_app b2 b 10 -codd-switch-account 2
D="$ROOT/b2.json"
check "A4 failure: switchState failed with a redacted message" wait_for 10 jtrue "$D" \
    "acc()['switchState']['state'] == 'failed' and '•••@•••' in acc()['switchState']['message'] and 'example.com' not in json.dumps(d)"
wait_app
check "A4 failure run quit by itself" test $? == 0
check "A4 failure: still on #3, lastSwitch outcome failed" jtrue "$D" "acc()['active'] == '3' and acc()['lastSwitch']['outcome'].startswith('failed')"
check "A4 failure: the log names the failure without an e-mail" bash -c \
    "grep -q 'accounts switch to=#2 failed' '$ROOT/b2.log' && ! grep -qF 'example.com' '$ROOT/b2.log'"

# ---------------------------------------------------------------------------------------------
# A4c. Two credential-lock timeouts, then success on the third attempt.
rm -f "$B/home/.claude-swap-backup/.fake-cswap-lock-fails"
cswap_env b FAKE_CSWAP_LOCK_FAILS=2
BEFORE_SWITCHES="$(calls "$B/cswap-calls.jsonl" "len(sub('switch'))")"
start_app b3 b 12 -codd-switch-account 2
D="$ROOT/b3.json"
check "A4 lock: active #2 after the retries" wait_for 12 jtrue "$D" "acc()['active'] == '2' and str(acc()['lastSwitch']['to']) == '2' and acc()['lastSwitch']['reason'] == 'user' and acc()['switchState']['state'] == 'idle'"
wait_app
check "A4 lock run quit by itself" test $? == 0
check "A4 lock: exactly three switch 2 --json calls in this run" ctrue "$B/cswap-calls.jsonl" \
    "sub('switch')[int(a[0]):] == [['switch', '2', '--json']] * 3" "${BEFORE_SWITCHES:-0}"
check "A4 lock: log switched to=#2" contains "$ROOT/b3.log" "accounts switched to=#2 reason=user"

fi

# =============================================================================================
# Group c: auto-switch (A5).
if sel A5; then
setup_group c
C="$ROOT/c"
"$FIX3/make-claude-settings.sh" "$C/home/.claude" >/dev/null || exit 2
NOW="$(epoch)"
R3_WEEK=$((NOW + 260000))
rl c 9 $((NOW + 9000)) 99 "$R3_WEEK"

# ---------------------------------------------------------------------------------------------
# A5a. 1w at 1 % on the active #3 → one switch to #2; a low #2 inside the cooldown → nothing.
start_app c1 c 30 -codd-new-claude "$C/work" -codd-set-pref accounts.autoSwitch.enabled=true -codd-auto-switch-tick 1
D="$ROOT/c1.json"
check "A5 auto-switch to #2 (the R7-first eligible account)" wait_for 20 jtrue "$D" \
    "d['autoSwitch']['enabled'] and d['autoSwitch']['lastSwitch'] == 'switched #3 -> #2' and acc()['active'] == '2' and bool(d['autoSwitch']['lastAutoSwitchAt'])"
check "A5 the notification was recorded (suppressed: notifications off)" jtrue "$D" \
    "len(posted('account-auto-switch')) == 1 and posted('account-auto-switch')[0]['suppressed'] is True and '#2' in posted('account-auto-switch')[0]['title']"
check "A5 fake cswap: exactly one switch 2 --json" ctrue "$C/cswap-calls.jsonl" "sub('switch') == [['switch', '2', '--json']]"
R2_WEEK_ISO="$(jexpr "$D" "A(2)['weekly']['resetsAt']")"
R2_WEEK="$(iso_epoch "$R2_WEEK_ISO" 2>/dev/null)"
echo "E2E #2 weekly reset $R2_WEEK_ISO ($R2_WEEK)"
rl c 9 $((NOW + 9000)) 99 "${R2_WEEK:-0}"
check "A5 a low report for #2 inside the cooldown (1w 1 %)" wait_for 12 jtrue "$D" \
    "A(2)['weekly']['source'] == 'statusline' and A(2)['weekly']['remaining'] == 1"
sleep 3
check "A5 inside the cooldown: no second switch call" ctrue "$C/cswap-calls.jsonl" "len(sub('switch')) == 1"
check "A5 the runner says cooling-down" jtrue "$D" "d['autoSwitch']['lastDecision'] == 'cooling-down'"
LAST_AUTO="$(jexpr "$D" "d['autoSwitch']['lastAutoSwitchAt']")"
wait_app
check "A5 run quit by itself" test $? == 0
check "A5 quota.json keeps the cooldown (autoSwitch.lastAt) and #2's low week" jtrue "$C/d/quota.json" \
    "d['autoSwitch']['lastAt'] == a[0] and d['accounts']['2']['weekly']['usedPercent'] == 99" "$LAST_AUTO"
check "A5 log: auto-switch to=#2 from=#3 window=weekly remaining=1" contains "$ROOT/c1.log" "auto-switch to=#2 from=#3 window=weekly remaining=1"

# ---------------------------------------------------------------------------------------------
# A5b. A relaunch inside the cooldown: the low #2 still reports, nothing switches.
start_app c2 c 9 -codd-set-pref accounts.autoSwitch.enabled=true -codd-auto-switch-tick 1
D="$ROOT/c2.json"
check "A5 relaunch: #2 active and low, the cooldown read back from quota.json" wait_for 8 jtrue "$D" \
    "acc()['active'] == '2' and A(2)['weekly']['remaining'] == 1 and d['autoSwitch']['lastAutoSwitchAt'] == a[0] and d['autoSwitch']['lastDecision'] == 'cooling-down'" "$LAST_AUTO"
wait_app
check "A5 relaunch quit by itself" test $? == 0
check "A5 relaunch: still exactly one switch call in total" ctrue "$C/cswap-calls.jsonl" "len(sub('switch')) == 1"
end_holders c

# ---------------------------------------------------------------------------------------------
# A5c. Every account low: none eligible, recorded once.
setup_group e
E5="$ROOT/e"
"$FIX3/make-claude-settings.sh" "$E5/home/.claude" >/dev/null || exit 2
"$PY" -I - "$E5/home/.claude-swap-backup/cache/usage.json" <<'PY'
import json, os, sys
p = sys.argv[1]
doc = json.load(open(p, encoding="utf-8"))
for n in ("1", "2"):
    doc["accounts"][n]["lastGood"]["seven_day"]["pct"] = 99
tmp = p + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY
NOW="$(epoch)"
rl e 9 $((NOW + 9000)) 99 $((NOW + 260000))
start_app e1 e 14 -codd-new-claude "$E5/work" -codd-set-pref accounts.autoSwitch.enabled=true -codd-auto-switch-tick 1
D="$ROOT/e1.json"
check "A5 all low: none-eligible decided and notified" wait_for 12 jtrue "$D" \
    "d['autoSwitch']['lastDecision'] == 'none-eligible' and d['autoSwitch']['notified'] is True"
sleep 3
check "A5 all low: recorded once (suppressed), no switch" jtrue "$D" \
    "len(posted('account-none-eligible')) == 1 and posted('account-none-eligible')[0]['suppressed'] is True and acc()['active'] == '3'"
wait_app
check "A5 all-low run quit by itself" test $? == 0
check "A5 all low: the log says none eligible exactly once" test "$(count_of "$ROOT/e1.log" "auto-switch none eligible")" == 1
check "A5 all low: the fake cswap never switched" ctrue "$E5/cswap-calls.jsonl" "sub('switch') == []"
end_holders e

# ---------------------------------------------------------------------------------------------
# A5d. A `cswap switch` that keeps failing: one quick retry, then a wait (it writes and rolls
# back the global credentials every time); the user hears about it once (M3 review).
setup_group cf
CF="$ROOT/cf"
"$FIX3/make-claude-settings.sh" "$CF/home/.claude" >/dev/null || exit 2
cswap_env cf FAKE_CSWAP_FAIL=error
NOW="$(epoch)"
rl cf 9 $((NOW + 9000)) 99 $((NOW + 260000))
start_app cf1 cf 16 -codd-new-claude "$CF/work" -codd-set-pref accounts.autoSwitch.enabled=true -codd-auto-switch-tick 1
D="$ROOT/cf1.json"
check "A5 failing switch: two attempts, then the runner waits (retry-wait)" wait_for 14 jtrue "$D" \
    "d['autoSwitch']['failures'] == 2 and d['autoSwitch']['lastDecision'] == 'retry-wait' and bool(d['autoSwitch']['retryNotBefore'])"
sleep 3
check "A5 failing switch: exactly two switch calls, still on #3" bash -c \
    "[[ \"\$('$PY' -I -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if l.strip() and json.loads(l)[\"argv\"][0] == \"switch\"))' '$CF/cswap-calls.jsonl')\" == 2 ]]"
check "A5 failing switch: one failure notification (suppressed: notifications off)" jtrue "$D" \
    "len(posted('account-auto-switch-failed')) == 1 and posted('account-auto-switch-failed')[0]['suppressed'] is True and '#2' in posted('account-auto-switch-failed')[0]['title'] and acc()['active'] == '3'"
wait_app
check "A5 failing-switch run quit by itself" test $? == 0
check "A5 failing switch: the log names the growing wait" contains "$ROOT/cf1.log" "auto-switch to=#2 failed failures=2; retrying in 300 s"
end_holders cf

fi

# =============================================================================================
# Group f: the global installer on a user-shaped settings.json (A6).
if sel A6; then
setup_group f
F="$ROOT/f"
SETTINGS="$("$FIX3/make-claude-settings.sh" "$F/home/.claude" --legacy)" || exit 2
cp "$SETTINGS" "$ROOT/f-original.json"
LEGACY_EVENTS="$("$PY" -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
ev = sorted(e for e, groups in d["hooks"].items() if "status-writer.js" in json.dumps(groups))
print(",".join(ev))' "$SETTINGS")"
echo "E2E legacy events: $LEGACY_EVENTS"
# compare_foreign <before> <after>: every hook-tap / osascript handler group byte-identical (as JSON
# and as text lines), every other top-level key identical and in the same order.
compare_foreign() {
    "$PY" -I - "$1" "$2" <<'PY'
import json, sys
def load(p):
    with open(p, encoding="utf-8") as f:
        text = f.read()
    return text, json.loads(text)
bt, b = load(sys.argv[1]); at, a = load(sys.argv[2])
def foreign(doc):
    out = []
    for event, groups in doc.get("hooks", {}).items():
        for g in groups:
            s = json.dumps(g, ensure_ascii=False, sort_keys=False)
            if "hook-tap" in s or "osascript" in s:
                out.append((event, s))
    return out
fb, fa = foreign(b), foreign(a)
ok = fb == fa and len(fb) == 14
lines = lambda t: [l.strip().rstrip(",") for l in t.splitlines() if "hook-tap" in l or "osascript" in l]
ok = ok and lines(bt) == lines(at) and len(lines(bt)) >= 14
others = lambda d: [(k, v) for k, v in d.items() if k not in ("hooks", "statusLine")]
ok = ok and others(b) == others(a) and [k for k in b if k != "statusLine"] == [k for k in a if k != "statusLine"]
sys.exit(0 if ok else 1)
PY
}

# ---------------------------------------------------------------------------------------------
# A6a. Plan only: the legacy events, foreign tools kept, nothing written.
start_app f1 f 6 -codd-hooks-plan update
wait_app
check "A6 plan run quit by itself" test $? == 0
D="$ROOT/f1.json"
check "A6 plan: removes exactly the 10 CODD web events, adds the desktop status line" jtrue "$D" \
    "(lambda p: p['action'] == 'update' and p['changes'] and sorted(p['removedEvents']) == a[0].split(',') and len(p['removedEvents']) == 10 and p['statusLineAfter'] == 'desktop')(d['installer']['plan'])" \
    "$LEGACY_EVENTS"
check "A6 plan: hook-tap and osascript kept" jtrue "$D" "set(d['installer']['plan']['foreignKept']) >= {'hook-tap', 'osascript'}"
check "A6 plan: inspection saw the web leftovers and both foreign tools" jtrue "$D" \
    "(lambda i: len(i['legacyEvents']) == 10 and {f['code'] for f in i['foreign']} >= {'hook-tap', 'osascript'})(d['installer']['inspection'])"
check "A6 plan: settings.json untouched, no backup" bash -c \
    "cmp -s '$SETTINGS' '$ROOT/f-original.json' && ! ls '$F/home/.claude/' | grep -q codd-bak"

# ---------------------------------------------------------------------------------------------
# A6b. Apply: backup next to the file, foreign handlers byte-identical, desktop wrapper chaining.
start_app f2 f 8 -codd-hooks-plan update -codd-hooks-apply YES
wait_app
check "A6 apply run quit by itself" test $? == 0
BACKUP1="$(ls "$F/home/.claude/" | grep '^settings\.json\.codd-bak-' | head -1)"
echo "E2E backup: $BACKUP1"
check "A6 apply: log names the backup" contains "$ROOT/f2.log" "debug hooks-apply backup=$BACKUP1"
check "A6 apply: the backup holds the original bytes, mode kept" bash -c \
    "[[ -n '$BACKUP1' ]] && cmp -s '$F/home/.claude/$BACKUP1' '$ROOT/f-original.json' && [[ \$(stat -f %Lp '$F/home/.claude/$BACKUP1') == \$(stat -f %Lp '$SETTINGS') ]]"
check "A6 apply: every hook-tap / osascript handler and every other key byte-identical" compare_foreign "$ROOT/f-original.json" "$SETTINGS"
check "A6 apply: no status-writer.js and no codd-statusline.js left" bash -c \
    "! grep -q 'status-writer.js' '$SETTINGS' && ! grep -q 'codd-statusline.js' '$SETTINGS'"
check "A6 apply: statusLine is the desktop guard wrapper chaining the user's command" jtrue "$SETTINGS" \
    "(lambda m: m is not None and m.group(1) == a[0] and base64.b64decode(m.group(2)).decode() == a[1] and m.group(3) == a[1])(re.fullmatch(r\"if \\[ -x '(.+)/bin/codd-statusline' \\]; then '\\1/bin/codd-statusline' --data-root '\\1' --chain-b64 (\\S+); else /bin/sh -c '(.*)'; fi\", d['statusLine']['command'].replace(\"'\\\\''\", \"'\")))" \
    "$F/d" "$USER_SL"
wrapper_renders() {
    local cmd; cmd="$(jexpr "$SETTINGS" "d['statusLine']['command']")"
    [[ -n "$cmd" && "$(echo '{}' | /bin/sh -c "$cmd")" == USER-SL-ok ]]
}
check "A6 apply: the wrapper renders the user's status line (app not running)" wrapper_renders
check "A6 apply: the backups index records the reason" jtrue "$F/d/claude-settings-backups.json" \
    "d['v'] == 1 and d['backups'][-1]['name'] == a[0] and d['backups'][-1]['reason'] == '更新 hooks 與 statusline'" "$BACKUP1"
cp "$SETTINGS" "$ROOT/f-applied.json"

# ---------------------------------------------------------------------------------------------
# A6c. A second plan has no changes.
start_app f3 f 6 -codd-hooks-plan update
wait_app
check "A6 second plan run quit by itself" test $? == 0
check "A6 second plan: no changes" jtrue "$ROOT/f3.json" "d['installer']['plan']['changes'] is False and d['installer']['inspection']['upToDate'] is True"

# ---------------------------------------------------------------------------------------------
# A6d. A file touched after the plan is refused (nothing written, no backup).
BACKUPS_BEFORE="$(ls "$F/home/.claude/" | grep -c '^settings\.json\.codd-bak-')"
start_app f4 f 12 -codd-hooks-plan uninstall -codd-hooks-apply YES -codd-hooks-apply-delay 2500
wait_for 10 grep -q "debug hooks-apply waiting ms=2500" "$ROOT/f4.log"
"$PY" -I -c 'import os, sys, time; t = time.time() + 5; os.utime(sys.argv[1], (t, t))' "$SETTINGS"
wait_app
check "A6 touched run quit by itself" test $? == 0
check "A6 touched after the plan: refused (changedSinceRead)" contains "$ROOT/f4.log" "debug hooks-apply failed (changedSinceRead)"
check "A6 touched after the plan: content unchanged, no new backup" bash -c \
    "cmp -s '$SETTINGS' '$ROOT/f-applied.json' && [[ \$(ls '$F/home/.claude/' | grep -c '^settings\.json\.codd-bak-') == $BACKUPS_BEFORE ]]"

# ---------------------------------------------------------------------------------------------
# A6e. Uninstall gives the user's own command back.
sleep 1.1   # a new backup name (seconds resolution) is not required, but keeps the listing simple
start_app f5 f 8 -codd-hooks-plan uninstall -codd-hooks-apply YES
wait_app
check "A6 uninstall run quit by itself" test $? == 0
check "A6 uninstall: statusLine is the user's command again" jtrue "$SETTINGS" "d['statusLine']['command'] == a[0] and d['statusLine']['type'] == 'command'" "$USER_SL"
check "A6 uninstall: a second backup holds the applied file" bash -c \
    "[[ \$(ls '$F/home/.claude/' | grep -c '^settings\.json\.codd-bak-') == 2 ]] && for b in \$(ls '$F/home/.claude/' | grep '^settings\.json\.codd-bak-'); do cmp -s '$F/home/.claude/'\$b '$ROOT/f-applied.json' && exit 0; done; exit 1"
check "A6 uninstall: foreign handlers still byte-identical" compare_foreign "$ROOT/f-original.json" "$SETTINGS"

fi

# =============================================================================================
# Group g: quit dialog (A7).
if sel A7; then
setup_group g
Gq="$ROOT/g"
"$FIX3/make-claude-settings.sh" "$Gq/home/.claude" >/dev/null || exit 2
T0="$(now)"
start_app g1 g 40 -codd-spawn-shell "$Gq/work" -codd-quit-request 4 -codd-quit-choice keep-running
wait_app
G1_STATUS=$?
T1="$(now)"
echo "E2E g1 ran $(fsub "$T1" "$T0")s"
check "A7 keep-running: the app quit by itself" test "$G1_STATUS" == 0
check "A7 keep-running: long before its quit-after (40 s)" fle "$(fsub "$T1" "$T0")" 20
S_G="$(spawned_id "$ROOT/g1.log" shell)"
H_G="$(holder_of "$ROOT/g1.log" "$S_G")"
echo "E2E quit shell session=$S_G holder=$H_G"
check "A7 dialog D was shown for 1 running session and answered keep-running" jtrue "$ROOT/g1.json" \
    "d['quitDialog']['choice'] == 'keep-running' and d['quitDialog']['running'] == 1"
check "A7 log: quit trigger=user decision=ask, then quit choice=keep-running" bash -c \
    "grep -q 'quit trigger=user decision=ask running=1' '$ROOT/g1.log' && grep -q 'quit choice=keep-running keepNextTime=false' '$ROOT/g1.log'"
check "A7 keep-running: the holder survived" alive "${H_G:-0}"
start_app g2 g 40 -codd-quit-request 4 -codd-quit-choice stop-all
wait_app
check "A7 stop-all run quit by itself" test $? == 0
check "A7 stop-all: every session stopped before the quit" contains "$ROOT/g2.log" "quit stop-all sessions=1 tabs=0 left=0"
check "A7 stop-all: the holder is gone" wait_for 10 bash -c "! kill -0 ${H_G:-0} 2>/dev/null"

fi

# =============================================================================================
# Group h: preferences applied, the test hotkey, menu bar counts (A8, A9).
if sel A8 || sel A9; then
setup_group h
H="$ROOT/h"
"$FIX3/make-claude-settings.sh" "$H/home/.claude" >/dev/null || exit 2
read -r WPID _ < <("$FIX2/fake-external-claude.sh" start "$H/home/.claude" "$H/work" "$ROOT/m-wait" waiting "waiting external" "permission prompt")
start_app h1 h 10 -codd-set-pref sessions.staleAfterSeconds=1800 -codd-set-pref notifications.menuBarIcon=iconAndCounts \
    -codd-set-pref general.showInDock=false -codd-global-hotkey YES -codd-hotkey ctrl+option+cmd+f12
D="$ROOT/h1.json"
check "A8 a waiting external counts as attention" wait_for 12 jtrue "$D" "X(a[0]) is not None and d['attention'] == 1" "${WPID:-0}"
check "A8 menu bar counts mode: title ◆1" wait_for 5 jtrue "$D" "d['menuBar']['title'] == '◆1' and d['preferences']['effective']['menuBarTitle'] == '◆1'"
wait_app
check "A8 run quit by itself" test $? == 0
"$FIX2/fake-external-claude.sh" stop "$H/home/.claude" "$WPID" >/dev/null 2>&1
check "A8 the three assignments applied (set-pref)" jtrue "$D" \
    "all(x['applied'] for x in d['preferences']['setPrefs']) and len(d['preferences']['setPrefs']) == 3 and d['preferences']['values']['sessions.staleAfterSeconds'] == '1800' and d['preferences']['values']['notifications.menuBarIcon'] == 'iconAndCounts' and d['preferences']['values']['general.showInDock'] == 'false'"
check "A8 stale 1800 s reached the store" jtrue "$D" "d['preferences']['effective']['staleAfterSeconds'] == 1800"
check "A8 Dock off wanted (.accessory), background run stays accessory" jtrue "$D" "d['dock']['wanted'] == 'accessory' and d['dock']['policy'] == 'accessory'"
check "A8 no login item on a test root" jtrue "$D" "d['loginItem']['registered'] is False and d['loginItem']['real'] is False"
check "A8 set-pref values are never written (no preferences.json)" test ! -e "$H/d/preferences.json"
check "A9 hotkey registered on the test combo" jtrue "$D" \
    "d['hotkey']['registered'] is True and d['hotkey']['combo'] == 'ctrl+option+cmd+f12' and d['preferences']['effective']['hotkey'] == 'ctrl+option+cmd+f12'"
check "A9 log: hotkey registered combo=ctrl+option+cmd+f12" contains "$ROOT/h1.log" "hotkey registered combo=ctrl+option+cmd+f12"

fi

# =============================================================================================
# Group i: four accounts in the menu bar (A10).
if sel A10; then
setup_group i --accounts 4
I="$ROOT/i"
"$FIX3/make-claude-settings.sh" "$I/home/.claude" >/dev/null || exit 2
start_app i1 i 6
wait_app
check "A10 run quit by itself" test $? == 0
D="$ROOT/i1.json"
check "A10 four accounts in R7 order, #4 MAX 5x" jtrue "$D" \
    "[x['id'] for x in order()] == ['2', '3', '1', '4'] and A(4)['plan'] == 'MAX 5x'"
check "A10 menu bar: 3 rows (the active #3 among them) + ▸ 全部帳號 4" jtrue "$D" \
    "d['menuBar']['accounts'] == ['2', '3', '1'] and d['menuBar']['total'] == 4 and d['menuBar']['expanded'] is False"

fi

# =============================================================================================
# Group j: add account, dialog C (A11).
if sel A11; then
setup_group j
J="$ROOT/j"
"$FIX3/make-claude-settings.sh" "$J/home/.claude" >/dev/null || exit 2
printf 'FAKE_LOGIN_AS=4\n' >>"$J/bin/fake-claude.env"
start_app j1 j 40 -codd-add-account studio
D="$ROOT/j1.json"
check "A11 add-account ends added within 30 s" wait_for 30 grep -q "debug add-account alias-ok=true slot=#4 ending=added" "$ROOT/j1.log"
check "A11 dump: #4 studio is managed, #3 active again" wait_for 6 jtrue "$D" \
    "A(4) is not None and A(4)['alias'] == 'studio' and acc()['active'] == '3' and not any(s['ephemeral'] for s in d['sessions'])"
wait_app
check "A11 run quit by itself" test $? == 0
E_J="$(grep -o 'ephemeral shell session=[^ ]*' "$ROOT/j1.log" | head -1 | sed 's/.*session=//')"
echo "E2E ephemeral session=$E_J"
check "A11 the ephemeral shell typed the login and saw it change" bash -c \
    "grep -q 'ephemeral shell typed session=$E_J sent=true' '$ROOT/j1.log' && grep -q 'debug add-account login changed=true' '$ROOT/j1.log'"
check "A11 fake cswap: add --slot 4 --alias studio, then switch 3 --json" ctrue "$J/cswap-calls.jsonl" \
    "(lambda i: i >= 0 and L[i + 1:] == [['switch', '3', '--json']])(next((k for k, x in enumerate(L) if x == ['add', '--slot', '4', '--alias', 'studio']), -1))"
check "A11 the ephemeral session ended and its folder is gone" bash -c \
    "[[ -n '$E_J' ]] && grep -q 'ephemeral shell discarded session=$E_J' '$ROOT/j1.log' && [[ ! -e '$J/d/sessions/$E_J' ]] && ! pgrep -f '$J/d/sessions/$E_J' >/dev/null"
check "A11 cswap's state: #4 studio, #3 active again" jtrue "$J/home/.claude-swap-backup/sequence.json" \
    "d['accounts']['4']['alias'] == 'studio' and d['activeAccountNumber'] == 3"
ADDS="$(calls "$J/cswap-calls.jsonl" "len(sub('add'))")"
start_app j2 j 40 -codd-add-account 工作室
wait_for 30 grep -q "debug add-account alias-ok=false" "$ROOT/j2.log"
wait_app
check "A11 工作室 run quit by itself" test $? == 0
check "A11 工作室 refused by cswap's rule before cswap runs, then cancelled" bash -c \
    "grep -q \"add-account refused: the alias does not pass cswap's rule\" '$ROOT/j2.log' && grep -q 'debug add-account alias-ok=false slot=#.* ending=cancelled' '$ROOT/j2.log'"
check "A11 工作室: no add call in the fake cswap log" ctrue "$J/cswap-calls.jsonl" "len(sub('add')) == int(a[0])" "${ADDS:-x}"
check "A11 工作室: the ephemeral session is gone too" jtrue "$ROOT/j2.json" "not any(s['ephemeral'] for s in d['sessions'])"

fi

# =============================================================================================
# Group k: numbers (A12): three fake claudes reporting every second.
if sel A12; then
setup_group k
K="$ROOT/k"
"$FIX3/make-claude-settings.sh" "$K/home/.claude" >/dev/null || exit 2
NOW="$(epoch)"
rl k 9 $((NOW + 9000)) 85 $((NOW + 260000))
for n in 1 2 3; do
    start_app "k$n" k 4 -codd-new-claude "$K/work"
    wait_app >/dev/null
done
check "A12 three claude holders running" bash -c "[[ \$(pgrep -f '$K/d/bin/codd-holder-' | wc -l) -eq 3 ]]"
start_app k4 k 32
K_APP=$APP_PID
D="$ROOT/k4.json"
check "A12 three CODD claudes attached and reporting" wait_for 15 jtrue "$D" "len(claudes()) == 3 and d['statusline']['accepted'] >= 6"
sleep 8
CPU0="$(ps -o cputime= -p "$K_APP" | tr -d ' ')"
T0="$(now)"
sleep 10
CPU1="$(ps -o cputime= -p "$K_APP" | tr -d ' ')"
T1="$(now)"
FOOT="$(footprint "$K_APP" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}')"
CPU_PCT="$("$PY" -I -c 'import sys
def s(t):
    parts = [float(x) for x in t.split(":")]
    v = 0.0
    for p in parts: v = v * 60 + p
    return v
print("%.2f" % ((s(sys.argv[2]) - s(sys.argv[1])) / (float(sys.argv[4]) - float(sys.argv[3])) * 100))' "$CPU0" "$CPU1" "$T0" "$T1")"
echo "E2E number app idle CPU with 3 reporters: $CPU0 -> $CPU1 over $(fsub "$T1" "$T0") s = $CPU_PCT %"
echo "E2E number app footprint with 3 fake claudes: ${FOOT:-n/a}"
check "A12 idle CPU with 3 reporters below 5 % (sanity bound; the report has the number)" fle "${CPU_PCT:-99}" 5
# codd-statusline: 200 runs from zsh against the running app's endpoint, no chain (global mode).
printf '{"session_id":"e2e","rate_limits":{"five_hour":{"used_percentage":9,"resets_at":%s},"seven_day":{"used_percentage":85,"resets_at":%s}}}\n' \
    $((NOW + 9000)) $((NOW + 260000)) >"$ROOT/sl-input.json"
ACC0="$(jexpr "$D" "d['statusline']['server']['accepted']")"
SL_MS="$(/bin/zsh -f -c '
zmodload zsh/datetime
bin=$1; root=$2; input=$3
t0=$EPOCHREALTIME
for i in {1..200}; do "$bin" --data-root "$root" <"$input" >/dev/null; done
t1=$EPOCHREALTIME
printf "%.2f\n" $(( (t1 - t0) * 1000.0 / 200 ))' zsh "$K/d/bin/codd-statusline" "$K/d" "$ROOT/sl-input.json")"
echo "E2E number codd-statusline (this build, global mode, endpoint up, no chain): $SL_MS ms per run"
check "A12 the app received the 200 reports" wait_for 10 jtrue "$D" "d['statusline']['server']['accepted'] - int(a[0]) >= 200" "${ACC0:-0}"
check "A12 codd-statusline below 25 ms per run in this build (release target < 10 ms, see the report)" fle "${SL_MS:-99}" 25
wait_app
check "A12 measurement run quit by itself" test $? == 0
# The same three reporters with Home shown, the 1 Hz timers running as if visible, and no state
# dump (its writes are the e2e's cost, not the app's). Before the M3 review fix Home rebuilt every
# card on every report: about 2 % here; the bound catches that, not the 0.5 % budget (see the report).
rm -f "$ROOT/k5.json"
perl -e 'alarm shift; exec @ARGV' 120 "$APP" -codd-data-root "$K/d" -codd-claude-dir "$K/home/.claude" \
    -codd-cswap-path "$K/bin/cswap" -codd-cswap-root "$K/home/.claude-swap-backup" -codd-claude-path "$K/bin/fake-claude" \
    -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO -codd-quit-after 30 \
    -codd-show home -CODDForceVisibleTimers YES >"$ROOT/k5.log" 2>&1 &
APP_PID=$!
APP_NAME=k5
RUNS+=(k5)
sleep 14
CPU0="$(ps -o cputime= -p "$APP_PID" | tr -d ' ')"
T0="$(now)"
H0="$(count_of "$ROOT/k5.log" "HOME render")"
sleep 10
CPU1="$(ps -o cputime= -p "$APP_PID" | tr -d ' ')"
T1="$(now)"
H1="$(count_of "$ROOT/k5.log" "HOME render")"
HOME_PCT="$("$PY" -I -c 'import sys
def s(t):
    v = 0.0
    for p in t.split(":"): v = v * 60 + float(p)
    return v
print("%.2f" % ((s(sys.argv[2]) - s(sys.argv[1])) / (float(sys.argv[4]) - float(sys.argv[3])) * 100))' "$CPU0" "$CPU1" "$T0" "$T1")"
echo "E2E number app idle CPU, Home shown, timers visible, no dump, 3 reporters: $HOME_PCT % (HOME renders in 10 s: $((H1 - H0)))"
check "A12 Home with 3 reporters: no rebuild per report (at most 2 renders in 10 s)" test "$((H1 - H0))" -le 2
check "A12 Home with 3 reporters below 1.8 % (no dump, timers visible)" fle "${HOME_PCT:-99}" 1.8
wait_app
check "A12 Home measurement run quit by itself" test $? == 0
end_holders k

fi

# =============================================================================================
# Group l: isolation guards and the D1 fallback (A13), a stale profile (A14).
if sel A13 || sel A14; then
setup_group l
L_="$ROOT/l"
"$FIX3/make-claude-settings.sh" "$L_/home/.claude" >/dev/null || exit 2

if sel A13; then
# ---------------------------------------------------------------------------------------------
# A13a. -codd-hooks-apply with a settings path that resolves into the real ~/.claude: refused
# before the plan reads anything. The path does not exist there, and the action (remove-legacy)
# would not create a missing file, so even a broken guard could not write.
if [[ -d "$HOME/.claude" ]]; then
    ln -s "$HOME/.claude" "$L_/realclaude"
    GUARD_MISSING="codd-m3e-guard-$$-$RANDOM"
    start_app l1 l 5 -codd-claude-settings "$L_/realclaude/$GUARD_MISSING/settings.json" -codd-hooks-plan remove-legacy -codd-hooks-apply YES
    wait_app
    check "A13 guard run quit by itself" test $? == 0
    check "A13 -codd-hooks-apply into the real ~/.claude refused" contains "$ROOT/l1.log" "installer apply refused (the target resolves into the real ~/.claude)"
    check "A13 refused before the plan (nothing read): no hooks-plan line, no plan in the dump" bash -c \
        "! grep -q 'debug hooks-plan' '$ROOT/l1.log' && [[ \"\$('$PY' -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"installer\"][\"plan\"])' '$ROOT/l1.json')\" == None ]]"
    check "A13 nothing was created in the real ~/.claude" test ! -e "$HOME/.claude/$GUARD_MISSING"
    rm -f "$L_/realclaude"
else
    echo "E2E skip A13 guard check (no ~/.claude on this Mac)"
fi

# ---------------------------------------------------------------------------------------------
# A13d. The same guard for a -codd-claude-dir that resolves into ~/.claude, and for a run that
# names no Claude files at all. Both need the "real" ~/.claude to be readable, so the app gets a
# fake home (CFFIXED_USER_HOME, honoured by NSHomeDirectory): nothing of the user's is read.
FAKEHOME="$L_/fakehome"
mkdir -p "$FAKEHOME/.claude/sessions"
printf '{\n  "model": "fake-home"\n}\n' >"$FAKEHOME/.claude/settings.json"
FAKE_BYTES="$(shasum -a 256 "$FAKEHOME/.claude/settings.json" | cut -d' ' -f1)"
ln -s "$FAKEHOME/.claude" "$L_/fakeclaude-link"
CFFIXED_USER_HOME="$FAKEHOME" start_app l6 l 5 -codd-claude-dir "$L_/fakeclaude-link" -codd-hooks-plan remove-legacy -codd-hooks-apply YES
wait_app
check "A13 -codd-claude-dir run quit by itself" test $? == 0
check "A13 -codd-claude-dir through a link into ~/.claude: refused before the plan" bash -c \
    "grep -qF 'installer apply refused (the target resolves into the real ~/.claude)' '$ROOT/l6.log' && ! grep -q 'debug hooks-plan' '$ROOT/l6.log'"
rm -f "$ROOT/l7.json"
CFFIXED_USER_HOME="$FAKEHOME" perl -e 'alarm shift; exec @ARGV' 60 "$APP" -codd-data-root "$L_/d" \
    -codd-cswap-path "$L_/bin/cswap" -codd-cswap-root "$L_/home/.claude-swap-backup" -codd-claude-path "$L_/bin/fake-claude" \
    -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO -codd-quit-after 5 -codd-dump-state "$ROOT/l7.json" \
    -codd-hooks-plan remove-legacy -codd-hooks-apply YES >"$ROOT/l7.log" 2>&1 &
APP_PID=$!
APP_NAME=l7
RUNS+=(l7)
wait_app
check "A13 no-override run quit by itself" test $? == 0
check "A13 no -codd-claude-dir / -codd-claude-settings: refused" contains "$ROOT/l7.log" \
    "installer apply refused (no -codd-claude-dir or -codd-claude-settings)"
check "A13 the fake home's settings.json is untouched and has no backup" bash -c \
    "[[ \"\$(shasum -a 256 '$FAKEHOME/.claude/settings.json' | cut -d' ' -f1)\" == '$FAKE_BYTES' ]] && ! ls '$FAKEHOME/.claude/' | grep -q codd-bak"
rm -f "$L_/fakeclaude-link"

# ---------------------------------------------------------------------------------------------
# A13b. D1: cswap's state in a shape CODD does not support (cswap itself still works): no `list`
# at launch, exactly one after an explicit refresh.
mkdir -p "$L_/broken/.claude-swap-backup"
printf '{"activeAccountNumber": 3, "sequence": [1, 2, 3], "accounts": [1, 2, 3]}' >"$L_/broken/.claude-swap-backup/sequence.json"
start_app l2 l 7 -codd-cswap-root "$L_/broken/.claude-swap-backup"
wait_app
check "A13 unsupported state run quit by itself" test $? == 0
check "A13 unsupported state: accounts unavailable with the D1 copy" jtrue "$ROOT/l2.json" \
    "acc()['availability'] in ('unsupported', 'unreadable') and '讀不到 cswap 狀態' in (acc()['note'] or '') and '立即更新' in (acc()['note'] or '')"
check "A13 unsupported state: no cswap list at launch (only --version)" ctrue "$L_/cswap-calls.jsonl" "sub('list') == [] and L[-1] == ['--version']"
start_app l3 l 9 -codd-cswap-root "$L_/broken/.claude-swap-backup" -codd-refresh-accounts YES
D="$ROOT/l3.json"
check "A13 explicit refresh: the cswap list fallback shows the accounts" wait_for 8 jtrue "$D" \
    "acc()['fallback'] is True and sorted(x['id'] for x in order()) == ['1', '2', '3'] and acc()['active'] == '3'"
wait_app
check "A13 refresh run quit by itself" test $? == 0
check "A13 exactly one cswap list --json in total" ctrue "$L_/cswap-calls.jsonl" "len(sub('list')) == 1 and sub('list') == [['list', '--json']]"
check "A13 log: cswap list fallback" contains "$ROOT/l3.log" "cswap list fallback"

fi

if sel A14; then
# ---------------------------------------------------------------------------------------------
# A14. A pinned session on #2 while its profile is fine, stopped; then cswap marks the profile
# stale: the ⌘N option is disabled, a new pin is refused and RESUME shows the problem banner.
NOW="$(epoch)"
rl l 9 $((NOW + 9000)) 85 $((NOW + 260000))
start_app l4 l 10 -codd-new-claude "$L_/work" -codd-new-claude-account 2
D="$ROOT/l4.json"
wait_for 10 grep -q "spawned session=.* kind=claude" "$ROOT/l4.log"
S_L4="$(spawned_id "$ROOT/l4.log" claude)"
check "A14 a pinned #2 session first (profile usable, option enabled)" wait_for 8 jtrue "$D" \
    "S(a[0]) is not None and S(a[0])['accountPinned'] is True and opt(2)['enabled'] is True and bool(S(a[0]).get('claudeSessionId'))" "$S_L4"
wait_app
check "A14 pinned run quit by itself" test $? == 0
end_holders l
"$FIX3/make-cswap-state.sh" "$L_/home/.claude-swap-backup" "$L_/home/.claude" --stale 2 >/dev/null || exit 2
check "A14 cswap's stale marker written next to the profile" bash -c "ls -a '$L_/home/.claude-swap-backup/sessions/' | grep -q '^\\.2-.*\\.cswap-stale-credentials$'"
start_app l5 l 8 -codd-new-claude "$L_/work" -codd-new-claude-account 2 -codd-resume-stopped YES
D="$ROOT/l5.json"
check "A14 RESUME of the pinned session refused with the problem banner" wait_for 8 jtrue "$D" \
    "d['problem'] is not None and d['problem']['message'] == '#2 的登入資料需要更新：先在終端機執行一次 cswap run 2' and d['problem'].get('sessionId') == a[0]" "$S_L4"
wait_app
check "A14 stale run quit by itself" test $? == 0
check "A14 #2 profile stale in the dump (never its path)" jtrue "$D" "A(2)['hasSessionProfile'] is True and A(2)['profileStale'] is True"
check "A14 ⌘N option for #2 disabled (follow still enabled)" jtrue "$D" "opt(2) is not None and opt(2)['enabled'] is False and opt('follow')['enabled'] is True"
check "A14 a new pin to #2 refused with the same text, nothing started" bash -c \
    "grep -qF 'debug new-claude refused: #2 的登入資料需要更新：先在終端機執行一次 cswap run 2' '$ROOT/l5.log' && ! grep -q 'spawned session=.* kind=claude' '$ROOT/l5.log'"
check "A14 the stopped session stays stopped (RESUME refused, logged)" contains "$ROOT/l5.log" "resume session=$S_L4 refused"
check "A14 the pinned session is still STOPPED and pinned to #2" jtrue "$D" "S(a[0])['state'] == 'stopped' and S(a[0])['account'] == '2' and S(a[0])['accountPinned'] is True" "$S_L4"

fi

fi

# =============================================================================================
# A13c. Over every run: exec lines inside the folder, no e-mail, no profile slug.
if sel A13; then
ALL_LOGS=(); ALL_DUMPS=()
for r in "${RUNS[@]}"; do ALL_LOGS+=("$ROOT/$r.log"); [[ -e "$ROOT/$r.json" ]] && ALL_DUMPS+=("$ROOT/$r.json"); done
EXECS="$(cat "${ALL_LOGS[@]}" | grep -o 'exec [a-z-]* path=[^ ]* sub=[^ ]*' | sort | uniq -c | sort -rn)"
echo "E2E exec lines:"; echo "$EXECS" | sed 's/^/E2E   /'
check "A13 every exec line (D38) names a path inside the temp folder" bash -c \
    "[[ -n \"\$(cat ${ALL_LOGS[*]} | grep -o 'exec [a-z-]* path=[^ ]*')\" ]] && ! cat ${ALL_LOGS[*]} | grep -o 'exec [a-z-]* path=[^ ]*' | sed 's/.* path=//' | grep -v '^$ROOT/' | grep -q ."
check "A13 the only exec tools are cswap (claude --version runs only with Settings open)" bash -c \
    "! cat ${ALL_LOGS[*]} | grep -o 'exec [a-z-]* path=' | grep -v '^exec cswap path=' | grep -q ."
DATA_FILES="$(find "$ROOT"/*/d -type f 2>/dev/null)"
check "A13 no @example.com in any data root file (quota.json, preferences.json, layout, sessions…)" bash -c \
    "[[ -n '$(echo "$DATA_FILES" | head -1)' ]] && ! find '$ROOT' -path '*/d/*' -type f -print0 | xargs -0 grep -lF '@example.com' | grep -q ."
check "A13 no @example.com in any dump or app log" bash -c "! grep -lF '@example.com' ${ALL_DUMPS[*]} ${ALL_LOGS[*]} | grep -q ."
check "A13 no example.com (covers the plan's example-com and cswap's real slug) in any dump or app log" bash -c \
    "! grep -lF -e 'example.com' -e 'example-com' ${ALL_DUMPS[*]} ${ALL_LOGS[*]} | grep -q ."
check "A13 the quota caches hold no e-mail" bash -c "! grep -lF 'example' '$ROOT'/*/d/quota.json | grep -q ."

fi

echo "E2E leftover processes before cleanup: $(pgrep -f "$ROOT/" | wc -l | tr -d ' ')"
echo "E2E pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

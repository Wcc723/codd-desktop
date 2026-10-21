#!/bin/bash
# M2 end-to-end test (docs/M2-PLAN.md §6, step I7): real CODD.app (DEBUG build), real codd-holder,
# real hook endpoint, real libghostty terminals, FAKE claudes only (scripts/m2-fixtures: no
# Anthropic call, no quota, never ~/.claude).
#
# Isolation: every data root is made by scripts/m2-fixtures/make-root.sh (its own hook port in
# 43000-43999 and a fresh token) inside one mktemp folder, every Claude directory is a temp folder
# too, no login-shell capture (-codd-login-env NO), notifications off, shells are `/bin/zsh -f` or
# `/bin/cat` (no rc files), 刪除對話紀錄 moves into <root>/trash (never ~/.Trash). Every process it
# starts carries the temp folder in its argv; the cleanup sends SIGCONT, SIGTERM, then SIGKILL to
# `pkill -f "<tmp>/"` only, and removes the folder unless KEEP=1.
#
#   scripts/m2-e2e.sh            # build first: xcodegen generate && xcodebuild … -derivedDataPath build/dd build
#   CODD_APP=/path/CODD.app/Contents/MacOS/CODD KEEP=1 scripts/m2-e2e.sh   # keep the temp folder
#   ONLY=R4,R5 scripts/m2-e2e.sh # only these sections (ids R1..R13, comma separated; unset = all, same
#                                # output and exit codes as before). Unselected sections print `E2E skip <id>`;
#                                # the launches an unselected section would have left behind for a selected
#                                # one still run, silently (R5/R6/R11 need R4a's session, R11 needs R2b's
#                                # claude, R12 needs R4b, R3/R8/R9/R10 need C1's shell, R10 needs R7's tabs).
#                                # An unknown id exits 64 with the valid ids. R2 covers R2b/R2c, R11 covers
#                                # the STATE view and the sidebar filter, R4 covers R4a/R4b/R4c.
#
# Runs (each a separate app launch with -codd-quit-after and -codd-dump-state):
#   R1   seeded layout (seed-layout.sh): groups in order with colors, projects in their groups, the
#        pinned session in `pinned` and the PINNED section, the archived one absent but kept in
#        layout.json, the collapsed project stays collapsed;
#   R2   externals (fake-external-claude.sh start) in a known folder (busy) and an unknown one: both
#        external with their pid, the unknown one in a transient project in 未分類; waiting
#        'permission prompt' counts as attention (NEEDS YOU); stopped → gone, transient project
#        gone; layout.json never names either;
#   R2b  a CODD claude whose launch profile sets FAKE_REGISTRY_DIR keeps a registry file and is
#        never external; R2c a claude inside a CODD shell (`fake-external-claude.sh host` as the
#        shell's argv) is external with hostSession = that shell session;
#   R3   single instance: a second app on the same root exits 0 within 5 s (`another-instance`),
#        the first logs `show-window requested`, keeps its session attached, no file changes;
#   R4   launch profile flags and environment reach the fake claude; resume of a fixture
#        transcript runs `--resume <id>`; the ⌘N resume picker lists the fixtures in order with the
#        expiry warning, without sdk / other-cwd ones, the running one disabled;
#   R5   composer: 'hello 世界' → FAKE-LINE + FAKE-SUBMIT; '第一行\n第二行' → FAKE-PASTE 第一行⏎第二行 +
#        FAKE-SUBMIT; composer.json history holds both; lastPrompt learned (one-line form, D20);
#   R6   ⌘K query: the session in Sessions, its project in Projects, `在 <project> 新增 session`;
#   R7   two panel tabs + maximize persisted (panes.json keeps the M1 `panel` key) and reattached to
#        the same tab holders after a relaunch;
#   R8   a shell whose holder was SIGKILLed replays its last screen read-only after relaunch;
#   R9   a SIGSTOPped holder becomes UNREACHABLE, SIGCONT clears it and the session is not stopped;
#   R10  closing the main window keeps CODD running until its quit; holders survive the quit;
#   R11  STATE view with `-codd-stale-after 1`: the Idle head says `n stale`, idle rows are stale;
#        the sidebar filter keeps one project's rows, NEEDS YOU and PINNED included;
#   R12  刪除對話紀錄 of a stopped claude session moves exactly its transcript and sibling folder
#        into the injected trash folder and the session leaves CODD;
#   R13  a fresh root without config.json (plain mkdir) listens on a port in 43000-43999.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

# ONLY=<ids>: section selection (see the header). Validated before anything else happens.
ALL_IDS="R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13"
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
# CHK=0 turns `check` into a silent run (its waits still happen, nothing is counted or printed): used
# by launches that only prepare state for another selected section. chk_for <id> sets it.
CHK=1
chk_for() { if sel "$1"; then CHK=1; else CHK=0; fi; }

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

# Short (holder sockets must stay under 104 bytes) and resolved (`pkill -f` matches it verbatim,
# and a real claude records getcwd() with symlinks resolved).
T="$(mktemp -d "${TMPDIR:-/tmp}/codd-m2e.XXXXXX")" || { echo "E2E mktemp failed" >&2; exit 2; }
ROOT="$(cd "$T" && pwd -P)" || exit 2
case "$ROOT" in
    /*/codd-m2e.??????) ;;
    *) echo "E2E unexpected temp folder '$ROOT'" >&2; exit 2 ;;
esac
FAKE="$ROOT/fake-claude"
FAKELOG="$ROOT/fakelog"
FEXT="$ROOT/fext.sh"
cp "$FIX/fake-claude-m2.sh" "$FAKE"
cp "$FIX/fake-external-claude.sh" "$FEXT"
chmod +x "$FAKE" "$FEXT"
# CODD passes sessions only an allow-list of its environment: the fake reads its settings from a
# sidecar next to its copy. Launch profiles add their own environment on top (R2b, R4).
printf 'FAKE_LOG_DIR=%s\n' "$FAKELOG" >"$FAKE.env"
PASS=0
FAIL=0
APP_PID=""
APP_NAME=""

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
    if [[ "$CHK" != 1 ]]; then "$@" >/dev/null 2>&1; return 0; fi
    if "$@"; then
        PASS=$((PASS + 1)); echo "E2E ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "E2E FAIL $what"
    fi
}
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
# Viewport dumps wrap long lines: search them with the line breaks removed.
joined_contains() { tr -d '\n' <"$1" 2>/dev/null | grep -qF -- "$2"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
# fsub <a> <b>: a - b with two decimals; fle <a> <b>: a <= b (floats).
fsub() { "$PY" -I -c 'import sys; print("%.2f" % (float(sys.argv[1]) - float(sys.argv[2])))' "$1" "$2"; }
fle() { "$PY" -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$1" "$2" 2>/dev/null; }
mtime() { stat -f '%Fm' "$1" 2>/dev/null; }
alive() { [[ -n "$1" && "$1" -gt 1 ]] 2>/dev/null && kill -0 "$1" 2>/dev/null; }

# jexpr <json file> <python expression> [args…]: prints the value ("" on any error). The expression
# sees `d` (the file), `a` (the extra args) and the helpers below.
jexpr() {
    "$PY" -I - "$@" 2>/dev/null <<'PY'
import json, os, re, sys
def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)
try:
    d = load(sys.argv[1])
    a = sys.argv[3:]
    def S(i): return next((s for s in d.get("sessions", []) if s.get("id") == i), None)
    def ext(): return [s for s in d.get("sessions", []) if s.get("external")]
    def X(pid): return next((s for s in ext() if s.get("externalPid") == int(pid)), None)
    def P(i): return next((p for p in d.get("projects", []) if p.get("id") == i), None)
    def rows(): return (d.get("sidebar") or {}).get("rows", [])
    def srows(section): return [r for r in rows() if r.get("kind") == "session" and r.get("section") == section]
    def rp(x): return os.path.realpath(x) if x else x
    v = eval(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}
jtrue() { [[ "$(jexpr "$@")" == True ]]; }

# start_app <name> <dataRoot> <claudeDir> <seconds> [flags…]: runs in the background; the dump is
# $ROOT/<name>.json, the log $ROOT/<name>.log. Later flags win (e.g. another -codd-shell-argv).
start_app() {
    local name="$1" root="$2" cdir="$3" seconds="$4"; shift 4
    perl -e 'alarm shift; exec @ARGV' 90 "$APP" -codd-data-root "$root" -codd-claude-dir "$cdir" \
        -codd-claude-path "$FAKE" -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO \
        -codd-quit-after "$seconds" -codd-dump-state "$ROOT/$name.json" "$@" >"$ROOT/$name.log" 2>&1 &
    APP_PID=$!
    APP_NAME="$name"
}
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
holders_of() { pgrep -f "$1/bin/codd-holder-" | sort -n | tr '\n' ' '; }
fake_log() { printf '%s/fake-%s.log' "$FAKELOG" "$1"; }
# lines_follow <file> <line> <next line>: <line> occurs and the line after it is <next line>.
lines_follow() {
    "$PY" -I -c 'import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
sys.exit(0 if any(l == sys.argv[2] and i + 1 < len(lines) and lines[i + 1] == sys.argv[3] for i, l in enumerate(lines)) else 1)' "$@" 2>/dev/null
}
write_profiles() {  # <dataRoot> <json profiles to add after the built-ins>
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
mkdir -p "$FAKELOG"

# =============================================================================================
# Root A: seeded layout, externals, sidebar filter.
A="$ROOT/a"; CA="$ROOT/ca"
mkdir -p "$CA/sessions" "$ROOT/elsewhere"
"$FIX/make-root.sh" "$A" >/dev/null || exit 2
LM="$("$FIX/seed-layout.sh" "$A" "$ROOT/wa")" || exit 2
SITE="$(jexpr "$LM" "next(p['path'] for p in d['projects'] if p['name']=='northstar-site')")"
CJK="$(jexpr "$LM" "next(p['path'] for p in d['projects'] if p['name']=='整合範例')")"
DESK="$(jexpr "$LM" "next(p['path'] for p in d['projects'] if p['name']=='codd-desktop')")"
PINNED="$(jexpr "$LM" "d['pinned']")"
ARCHIVED="$(jexpr "$LM" "d['archived']")"
COLLAPSED="$(jexpr "$LM" "d['collapsedProject']")"
CJK_SESSION="$(jexpr "$LM" "next(p['sessions'][0] for p in d['projects'] if p['id']==d['collapsedProject'])")"
ELSE="$ROOT/elsewhere"
write_profiles "$A" "[{\"id\":\"reg\",\"name\":\"registry e2e\",\"kind\":\"claude\",\"environment\":{\"FAKE_REGISTRY_DIR\":\"$CA/sessions\"},\"extraArguments\":[]}]"

# ---------------------------------------------------------------------------------------------
# R1. Seeded layout reproduced.
if sel R1; then
start_app r1 "$A" "$CA" 5
wait_app
check "R1 app quit by itself" test $? == 0
D="$ROOT/r1.json"
check "R1 groups in order with their colors" jtrue "$D" \
    "[(g['name'], g['color']) for g in d['groupsInfo']] == [('藍鵲 · 網站','blue'), ('個人 · Github','green'), ('未分類', None)]"
check "R1 projects sit in their groups" jtrue "$D" \
    "all(P(p['id']) is not None and P(p['id'])['group'] == p['groupId'] for p in load(a[0])['projects'])" "$LM"
check "R1 non-archived sessions listed (claude STOPPED, shell EXITED)" jtrue "$D" \
    "sorted(s['id'] for s in d['sessions']) == sorted(load(a[0])['visibleSessions']) and all(s['state'] == ('stopped' if s['kind'] == 'claude' else 'exited') for s in d['sessions'])" "$LM"
check "R1 pinned session in pinned and in the PINNED section" jtrue "$D" \
    "d['pinned'] == [a[0]] and S(a[0])['pinned'] and [r['id'] for r in srows('pinned')] == [a[0]]" "$PINNED"
check "R1 archived session in archived, not in sessions" jtrue "$D" "d['archived'] == [a[0]] and S(a[0]) is None" "$ARCHIVED"
check "R1 collapsed project stays collapsed (its session row hidden)" jtrue "$D" \
    "P(a[0])['collapsed'] and a[1] not in [r['id'] for r in srows('tree')] and a[0] in [r['id'] for r in rows() if r['kind'] == 'project']" \
    "$COLLAPSED" "$CJK_SESSION"
# layout.json ids are UUIDs: CoddCore writes them upper case, the dump and the fixtures lower case.
check "R1 layout.json keeps the archived session after quit" jtrue "$A/layout.json" \
    "any(s['id'].lower() == a[0] and s.get('archivedAt') for s in d['sessions'])" "$ARCHIVED"
check "R1 layout.json keeps the project collapsed" jtrue "$A/layout.json" \
    "next(p for p in d['projects'] if p['id'].lower() == a[0])['collapsed'] is True" "$COLLAPSED"
check "R1 hooks on the root's own port" jtrue "$D" \
    "d['hooks']['status'] == 'listening' and d['hooks']['port'] == load(a[0])['port']" "$A/config.json"
fi

# ---------------------------------------------------------------------------------------------
# R2. External sessions: known folder (busy), unknown folder (transient project), live states.
if sel R2; then
read -r KPID _ < <("$FEXT" start "$CA" "$SITE" "$ROOT/m-known" busy "known external")
read -r UPID _ < <("$FEXT" start "$CA" "$ELSE" "$ROOT/m-unknown" idle "unknown external")
echo "E2E externals known=$KPID unknown=$UPID"
start_app r2 "$A" "$CA" 20
D="$ROOT/r2.json"
check "R2 both externals listed" wait_for 12 jtrue "$D" "X(a[0]) is not None and X(a[1]) is not None" "$KPID" "$UPID"
check "R2 known-folder external under northstar-site, busy, with its pid" jtrue "$D" \
    "X(a[0])['external'] and X(a[0])['project'] == 'northstar-site' and X(a[0])['state'] == 'busy' and X(a[0])['id'].startswith('ext-%s-' % a[0])" "$KPID"
check "R2 unknown-folder external in a transient project in 未分類" jtrue "$D" \
    "any(p['transient'] and p['group'] is None and rp(p['cwd']) == rp(a[1]) and X(a[0])['id'] in p['sessions'] for p in d['projects'])" \
    "$UPID" "$ELSE"
check "R2 layout.json never names the transient project or an ext- id (while shown)" jtrue "$A/layout.json" \
    "not any(s['id'].startswith('ext-') for s in d['sessions']) and not any(rp(p['path']) == rp(a[0]) for p in d['projects'])" "$ELSE"
"$FEXT" set-status "$CA" "$KPID" waiting 'permission prompt'
check "R2 external turns WAITING (permission) and counts as attention" wait_for 8 jtrue "$D" \
    "X(a[0])['state'] == 'waiting' and X(a[0]).get('reason') == 'permission' and d['attention'] == 1" "$KPID"
check "R2 waiting external is in NEEDS YOU" jtrue "$D" "X(a[0])['id'] in [r['id'] for r in srows('needsYou')]" "$KPID"
"$FEXT" stop "$CA" "$KPID"
"$FEXT" stop "$CA" "$UPID"
check "R2 stopped externals are gone, and the transient project with them" wait_for 8 jtrue "$D" \
    "not ext() and not any(p['transient'] for p in d['projects']) and d['attention'] == 0"
wait_app
check "R2 app quit by itself" test $? == 0
check "R2 layout.json never names the transient project or an ext- id (after quit)" jtrue "$A/layout.json" \
    "not any(s['id'].startswith('ext-') for s in d['sessions']) and not any(rp(p['path']) == rp(a[0]) for p in d['projects'])" "$ELSE"
fi

# ---------------------------------------------------------------------------------------------
# R2b + R2c. CODD's own claude with a registry file; a claude inside a CODD shell.
# (R11's filter run expects the claude this launch leaves in northstar-site.)
if sel R2 || sel R11; then
chk_for R2
start_app r2b "$A" "$CA" 12 -codd-spawn-shell "$DESK" -codd-shell-argv "$FEXT host $CA $DESK $ROOT/m-host" \
    -codd-new-claude "$SITE" -codd-new-profile reg
D="$ROOT/r2b.json"
HOSTFILE="$CA/host-m-host.txt"
wait_for 12 test -s "$HOSTFILE"
HPID="$(awk '{print $1; exit}' "$HOSTFILE" 2>/dev/null)"
SHELL_ID=""; CODD_CLAUDE=""
wait_for 12 bash -c "grep -q 'spawned session=.* kind=shell' '$ROOT/r2b.log' && grep -q 'spawned session=.* kind=claude' '$ROOT/r2b.log'"
SHELL_ID="$(spawned_id "$ROOT/r2b.log" shell)"
CODD_CLAUDE="$(spawned_id "$ROOT/r2b.log" claude)"
echo "E2E host dummy=$HPID shell=$SHELL_ID claude=$CODD_CLAUDE"
check "R2c claude inside a CODD shell is external with hostSession = that shell" wait_for 12 jtrue "$D" \
    "X(a[0]) is not None and X(a[0])['hostSession'] == a[1] and S(a[1])['kind'] == 'shell'" "${HPID:-0}" "$SHELL_ID"
wait_for 12 jtrue "$D" "S(a[0]) is not None and S(a[0]).get('pid') is not None and S(a[0])['state'] in ('idle', 'done')" "$CODD_CLAUDE"
FPID="$(jexpr "$D" "S(a[0])['pid']" "$CODD_CLAUDE")"
check "R2b CODD's fake claude keeps a registry file (profile env)" test -s "$CA/sessions/${FPID:-x}.json"
check "R2b the fake claude saw the profile's FAKE_REGISTRY_DIR" contains "$(fake_log "${FPID:-x}")" "FAKE-REGISTRY $CA/sessions/${FPID:-x}.json"
sleep 1.5   # a few registry snapshots later
check "R2b CODD's claude is never external" jtrue "$D" \
    "S(a[0])['external'] is False and X(a[1]) is None and len(ext()) == 1" "$CODD_CLAUDE" "${FPID:-0}"
check "R2b the log never added it as external (not even before WELCOME)" lacks "$ROOT/r2b.log" "external added id=ext-${FPID:-x}-"
wait_app
check "R2b app quit by itself" test $? == 0
# End this run's holders (host dummy and fake claude remove their registry files on hangup).
pkill -TERM -f "$A/bin/codd-holder-" 2>/dev/null
check "R2bc holders ended, registry files removed" wait_for 10 bash -c \
    "! pgrep -f '$A/bin/codd-holder-' >/dev/null && ! ls '$CA/sessions/'*.json >/dev/null 2>&1"
CHK=1
fi

# ---------------------------------------------------------------------------------------------
# R11b. Sidebar filter: one project's rows, NEEDS YOU and PINNED included.
if sel R11; then
read -r W1 _ < <("$FEXT" start "$CA" "$SITE" "$ROOT/m-w1" waiting "site wait" "permission prompt")
read -r W2 _ < <("$FEXT" start "$CA" "$CJK" "$ROOT/m-w2" waiting "cjk wait" "permission prompt")
start_app r11b "$A" "$CA" 8 -codd-sidebar-filter northstar-site
D="$ROOT/r11b.json"
wait_for 12 jtrue "$D" "X(a[0]) is not None and X(a[1]) is not None and X(a[0])['id'] in [r['id'] for r in srows('needsYou')]" "$W1" "$W2"
check "R11 filter: both waits count as attention, NEEDS YOU shows only the matching one" jtrue "$D" \
    "d['attention'] == 2 and [r['id'] for r in srows('needsYou')] == [X(a[0])['id']]" "$W1" "$W2"
check "R11 filter: PINNED keeps the matching pinned session" jtrue "$D" "[r['id'] for r in srows('pinned')] == [a[0]]" "$PINNED"
check "R11 filter: only northstar-site rows in TREE mode" jtrue "$D" \
    "d['sidebar']['mode'] == 'tree' and d['sidebar']['filter'] == 'northstar-site' and [r['title'] for r in rows() if r['kind'] == 'project'] == ['northstar-site'] and [r['title'] for r in rows() if r['kind'] == 'group'] == ['藍鵲 · 網站'] and all(S(r['id'])['project'] == 'northstar-site' for r in rows() if r['kind'] == 'session') and len(srows('tree')) >= 2"
wait_app
check "R11b app quit by itself" test $? == 0
"$FEXT" stop "$CA" "$W1"
"$FEXT" stop "$CA" "$W2"
fi

# =============================================================================================
# Root B: profiles, resume, resume picker, composer, quick switch, stale, 刪除對話紀錄.
B="$ROOT/b"; CB="$ROOT/cb"; WB="$ROOT/wb/claude-lab"
mkdir -p "$CB/sessions" "$WB"
"$FIX/make-root.sh" "$B" >/dev/null || exit 2
TM="$("$FIX/make-transcripts.sh" "$CB" "$WB")" || exit 2
AID="$(jexpr "$TM" "d['expected'][0]['id']")"
H4B=""
write_profiles "$B" '[{"id":"e2e","name":"e2e profile","kind":"claude","environment":{"FOO":"bar-42","FAKE_PRINT_ENV":"FOO"},"extraArguments":["--e2e-flag"]}]'

# ---------------------------------------------------------------------------------------------
# R4a. A custom profile's flags and environment reach claude.
# (R5, R6 and R11 use the session this launch leaves.)
if sel R4 || sel R5 || sel R6 || sel R11; then
chk_for R4
start_app r4a "$B" "$CB" 7 -codd-new-claude "$WB" -codd-new-profile e2e -codd-dump-terminal "$ROOT/r4a-term.txt"
wait_app
check "R4a app quit by itself" test $? == 0
S4A="$(spawned_id "$ROOT/r4a.log" claude)"
F4A="$(jexpr "$ROOT/r4a.json" "S(a[0])['pid']" "$S4A")"
echo "E2E profile session=$S4A fake pid=$F4A"
check "R4a terminal shows FAKE-ARGV with --e2e-flag" bash -c \
    "grep -q 'FAKE-ARGV' '$ROOT/r4a-term.txt' && tr -d '\n' <'$ROOT/r4a-term.txt' | grep -qF -- '--e2e-flag'"
check "R4a terminal shows FAKE-ENV FOO=bar-42" joined_contains "$ROOT/r4a-term.txt" "FAKE-ENV FOO=bar-42"
check "R4a exact argv line has --e2e-flag (FAKE_LOG_DIR)" grep -Eq -- '^FAKE-ARGV .*--e2e-flag( |$)' "$(fake_log "${F4A:-x}")"
check "R4a layout row records the profile that ran" jtrue "$B/layout.json" \
    "next(s for s in d['sessions'] if s['id'].lower() == a[0]).get('launchProfileId') == 'e2e'" "$S4A"
CHK=1
fi

# ---------------------------------------------------------------------------------------------
# R4b. Resume of a fixture transcript. (R4c and R12 use the session this launch leaves.)
S4B="" H4B=""
if sel R4 || sel R12; then
chk_for R4
start_app r4b "$B" "$CB" 7 -codd-new-claude "$WB" -codd-resume-transcript "$AID" -codd-dump-terminal "$ROOT/r4b-term.txt"
wait_app
check "R4b app quit by itself" test $? == 0
S4B="$(spawned_id "$ROOT/r4b.log" claude)"
F4B="$(jexpr "$ROOT/r4b.json" "S(a[0])['pid']" "$S4B")"
echo "E2E resumed session=$S4B transcript=$AID fake pid=$F4B"
check "R4b FAKE-ARGV has --resume <transcript id>" joined_contains "$ROOT/r4b-term.txt" "--resume $AID"
check "R4b exact argv: --resume <id> (FAKE_LOG_DIR)" grep -Eq -- "^FAKE-ARGV .*--resume $AID( |\$)" "$(fake_log "${F4B:-x}")"
check "R4b the session's claudeSessionId is the transcript id" jtrue "$ROOT/r4b.json" "S(a[0])['claudeSessionId'] == a[1]" "$S4B" "$AID"
CHK=1
fi

# ---------------------------------------------------------------------------------------------
# R4c. The ⌘N resume picker over the fixtures (the running resume makes its transcript 執行中).
if sel R4; then
start_app r4c "$B" "$CB" 7 -codd-show new-session -codd-new-session-path "$WB" -codd-new-session-start resume
D="$ROOT/r4c.json"
wait_for 12 jtrue "$D" "len(d.get('resumePicker') or []) > 0"
wait_app
check "R4c app quit by itself" test $? == 0
check "R4c picker lists the fixture transcripts, newest first, with their titles and branches" jtrue "$D" \
    "[(r['id'], r['title'], r['branch']) for r in d['resumePicker']] == [(e['id'], e['title'], e['branch']) for e in load(a[0])['expected']]" "$TM"
check "R4c the 26-day transcript expires in 4 days, no other warning" jtrue "$D" \
    "{r['id']: r['expiresInDays'] for r in d['resumePicker']} == {e['id']: e['expiresInDays'] for e in load(a[0])['expected']} and [r['expiresInDays'] for r in d['resumePicker'] if r['ageDays'] == 26] == [4]" "$TM"
check "R4c sdk and other-cwd transcripts absent" jtrue "$D" \
    "not any(r['id'] in load(a[0])['hidden'] for r in d['resumePicker'])" "$TM"
check "R4c the running session's transcript is disabled (執行中)" jtrue "$D" \
    "[r['id'] for r in d['resumePicker'] if r['disabled']] == [a[0]]" "$AID"
check "R4c command preview starts with claude --resume" jtrue "$D" "d['newSession']['command'].startswith('claude --resume ')"
fi

# ---------------------------------------------------------------------------------------------
# R5. Composer: one line, then multi-line CJK (bracketed paste), history persisted.
if sel R5; then
start_app r5a "$B" "$CB" 9 -codd-select-session "$S4A" -codd-composer-open YES -codd-composer-send 'hello 世界'
D="$ROOT/r5a.json"
check "R5a lastPrompt learned from UserPromptSubmit" wait_for 14 jtrue "$D" "S(a[0])['lastPrompt'] == 'hello 世界'" "$S4A"
wait_app
check "R5a app quit by itself" test $? == 0
check "R5a composer sent the line (log)" bash -c "grep -q 'debug composer-send session=$S4A chars=8 sent=true' '$ROOT/r5a.log' && grep -q 'COMPOSER sent session=$S4A bytes=[0-9]* paste=false submit=true' '$ROOT/r5a.log'"
check "R5a fake claude: FAKE-LINE hello 世界 then FAKE-SUBMIT" lines_follow "$(fake_log "${F4A:-x}")" 'FAKE-LINE hello 世界' 'FAKE-SUBMIT'
start_app r5b "$B" "$CB" 9 -codd-select-session "$S4A" -codd-composer-open YES -codd-composer-send '第一行\n第二行'
D="$ROOT/r5b.json"
check "R5b lastPrompt is the last text (one line, D20)" wait_for 14 jtrue "$D" "S(a[0])['lastPrompt'] == '第一行 第二行'" "$S4A"
wait_app
check "R5b app quit by itself" test $? == 0
check "R5b composer sent a paste (log)" contains "$ROOT/r5b.log" "paste=true submit=true"
check "R5b fake claude: FAKE-PASTE 第一行⏎第二行 then FAKE-SUBMIT" lines_follow "$(fake_log "${F4A:-x}")" 'FAKE-PASTE 第一行⏎第二行' 'FAKE-SUBMIT'
check "R5 composer.json history holds both sends, draft empty" jtrue "$B/sessions/$S4A/composer.json" \
    "d['history']['entries'][-2:] == ['hello 世界', '第一行\n第二行'] and d.get('draft', '') == ''"
check "R5 dump: composer open with 2 history entries" jtrue "$D" \
    "S(a[0])['composer']['open'] and S(a[0])['composer']['historyCount'] == 2" "$S4A"
fi

# ---------------------------------------------------------------------------------------------
# R6. ⌘K quick switch with part of the session title ("fake claude m2", project claude-lab).
if sel R6; then
start_app r6 "$B" "$CB" 6 -codd-palette-query claude
D="$ROOT/r6.json"
wait_for 10 jtrue "$D" "(d.get('palette') or {}).get('shown') and len(d['palette']['rows']) > 0"
wait_app
check "R6 app quit by itself" test $? == 0
TITLE4A="$(jexpr "$D" "S(a[0])['title']" "$S4A")"
echo "E2E palette query=claude title='$TITLE4A'"
check "R6 the query is part of the session title" bash -c "[[ '$TITLE4A' == *claude* ]]"
check "R6 palette: the session in Sessions" jtrue "$D" \
    "d['palette']['query'] == 'claude' and any(r['section'] == 'sessions' and r['title'] == a[0] for r in d['palette']['rows'])" "$TITLE4A"
check "R6 palette: its project in Projects" jtrue "$D" \
    "any(r['section'] == 'projects' and r['title'].endswith('claude-lab') for r in d['palette']['rows'])"
check "R6 palette: 在 claude-lab 新增 session in Actions" jtrue "$D" \
    "any(r['section'] == 'actions' and r['title'] == '在 claude-lab 新增 session' for r in d['palette']['rows'])"
fi

# ---------------------------------------------------------------------------------------------
# R11a. STATE view and stale idle sessions.
if sel R11; then
start_app r11a "$B" "$CB" 6 -codd-sidebar-mode state -codd-stale-after 1
D="$ROOT/r11a.json"
check "R11 STATE view: the idle fake claude row is stale" wait_for 10 jtrue "$D" \
    "d['sidebar']['mode'] == 'state' and any(r['id'] == a[0] and r['stale'] for r in srows('idle')) and S(a[0])['stale']" "$S4A"
check "R11 STATE view: Idle head counts its rows and says n stale" jtrue "$D" \
    "next(r for r in rows() if r['kind'] == 'section' and r['id'] == 'idle')['count'] == len(srows('idle')) and next(r for r in rows() if r['kind'] == 'section' and r['id'] == 'idle').get('hint') == '%d stale' % len([r for r in srows('idle') if r['stale']])"
wait_app
check "R11a app quit by itself" test $? == 0
if [[ -n "$S4B" ]]; then H4B="$(jexpr "$D" "S(a[0])['holderPid']" "$S4B")"; fi
fi

# ---------------------------------------------------------------------------------------------
# R12. 刪除對話紀錄 of a stopped claude session (its claudeSessionId is fixture a).
if sel R12; then
[[ -n "$H4B" ]] || H4B="$(jexpr "$ROOT/r4b.json" "S(a[0])['holderPid']" "$S4B")"
[[ -n "$H4B" ]] && kill -TERM "$H4B" 2>/dev/null
check "R12 the resumed session's holder ended (session stopped)" wait_for 10 bash -c "! kill -0 ${H4B:-0} 2>/dev/null"
start_app r12 "$B" "$CB" 6 -codd-trash-dir "$B/trash" -codd-delete-history "$S4B"
wait_app
check "R12 app quit by itself" test $? == 0
D="$ROOT/r12.json"
SIB="$(jexpr "$TM" "d['siblingFolder']['path']")"
check "R12 log: two files moved" contains "$ROOT/r12.log" "delete-history session=$S4B files=2"
check "R12 transcript and sibling folder are in the trash folder" bash -c \
    "test -f '$B/trash/$AID.jsonl' && test -f '$B/trash/$AID/subagents/agent-1.jsonl'"
check "R12 they left the projects folder" bash -c "! test -e '$(jexpr "$TM" "d['expected'][0]['path']")' && ! test -e '$SIB'"
check "R12 the other fixture transcripts are untouched" jtrue "$TM" \
    "all(os.path.isfile(e['path']) and os.path.getsize(e['path']) == e['sizeBytes'] for e in d['expected'][1:]) and len(os.listdir(os.path.dirname(d['expected'][0]['path']))) == 5"
check "R12 the trash folder holds nothing else" bash -c "[[ \"\$(ls '$B/trash' | sort | tr '\n' ' ')\" == '$AID $AID.jsonl ' ]]"
check "R12 the session left CODD (dump)" jtrue "$D" "S(a[0]) is None" "$S4B"
check "R12 the session left layout.json" jtrue "$B/layout.json" "not any(s['id'].lower() == a[0] for s in d['sessions'])" "$S4B"
fi

# =============================================================================================
# Root C: single instance, UNREACHABLE, dead-session replay, panel tabs, lifecycle.
C="$ROOT/c"; CC="$ROOT/cc"
mkdir -p "$CC/sessions" "$ROOT/wc/term" "$ROOT/wc/panel"
"$FIX/make-root.sh" "$C" >/dev/null || exit 2
S8=""; H8=""
if sel R3 || sel R8 || sel R9 || sel R10; then
chk_for C1
start_app c1 "$C" "$CC" 5 -codd-spawn-shell "$ROOT/wc/term" -codd-shell-argv /bin/cat -codd-send-input REPLAY-MARKER-42 \
    -codd-dump-terminal "$ROOT/c1-term.txt"
wait_app
check "C1 app quit by itself" test $? == 0
S8="$(spawned_id "$ROOT/c1.log" shell)"
H8="$(grep -o "spawned session=$S8 kind=shell holderPid=[0-9]*" "$ROOT/c1.log" | head -1 | sed 's/.*holderPid=//')"
echo "E2E shell session=$S8 holder=$H8"
check "C1 the shell printed the marker" contains "$ROOT/c1-term.txt" "REPLAY-MARKER-42"
check "C1 its holder survived the quit" alive "${H8:-0}"
CHK=1
fi

# ---------------------------------------------------------------------------------------------
# R3. Single instance.
if sel R3; then
start_app r3a "$C" "$CC" 14 -codd-select-session "$S8"
A_PID=$APP_PID
wait_for 12 grep -q "attached session=$S8" "$ROOT/r3a.log"
sleep 1.5
M_LAYOUT="$(mtime "$C/layout.json")"; M_CONFIG="$(mtime "$C/config.json")"; M_PANES="$(mtime "$C/panes.json")"
T0="$(now)"
perl -e 'alarm shift; exec @ARGV' 30 "$APP" -codd-data-root "$C" -codd-claude-dir "$CC" -codd-claude-path "$FAKE" \
    -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO -codd-quit-after 8 \
    -codd-dump-state "$ROOT/r3b.json" >"$ROOT/r3b.log" 2>&1 &
B_PID=$!
wait_for 5 bash -c "! kill -0 $B_PID 2>/dev/null"
T1="$(now)"
if alive "$B_PID"; then kill -TERM "$B_PID" 2>/dev/null; fi
wait "$B_PID"
B_STATUS=$?
echo "E2E second instance exit=$B_STATUS after $(fsub "$T1" "$T0")s"
quick_exit() { [[ $B_STATUS == 0 ]] && fle "$(fsub "$T1" "$T0")" 5.2; }
check "R3 second instance exits 0 within 5 s" quick_exit
check "R3 second instance logs another-instance with the first's pid" contains "$ROOT/r3b.log" "another-instance pid=$A_PID root="
check "R3 second instance wrote no state dump" test ! -e "$ROOT/r3b.json"
check "R3 first instance logs show-window requested" wait_for 3 grep -q "show-window requested" "$ROOT/r3a.log"
check "R3 first instance keeps running" alive "$A_PID"
check "R3 layout.json, config.json and panes.json unchanged by the second" \
    test "$(mtime "$C/layout.json")|$(mtime "$C/config.json")|$(mtime "$C/panes.json")" == "$M_LAYOUT|$M_CONFIG|$M_PANES"
APP_PID=$A_PID; APP_NAME=r3a
wait_app
check "R3 first instance quit by itself" test $? == 0
check "R3 first instance kept its session attached (no close, no takeover)" bash -c \
    "! grep -q 'closed session=$S8' '$ROOT/r3a.log' && ! grep -qi 'taken over' '$ROOT/r3a.log'"
check "R3 first instance still shows it live and reachable" jtrue "$ROOT/r3a.json" \
    "S(a[0])['state'] == 'shell' and not S(a[0])['unreachable']" "$S8"
fi

# ---------------------------------------------------------------------------------------------
# R9. UNREACHABLE: SIGSTOP the holder, then SIGCONT.
if sel R9; then
start_app r9 "$C" "$CC" 34 -codd-select-session "$S8" -codd-keepalive 1000,2000 -codd-unreachable-after 2
D="$ROOT/r9.json"
wait_for 12 grep -q "attached session=$S8" "$ROOT/r9.log"
sleep 1
kill -STOP "$H8"
TS="$(now)"
check "R9 stopped holder → unreachable within 15 s" wait_for 15 jtrue "$D" "S(a[0])['unreachable'] is True" "$S8"
TU="$(now)"
kill -CONT "$H8"
check "R9 SIGCONT → reachable again within 20 s" wait_for 20 jtrue "$D" "S(a[0])['unreachable'] is False" "$S8"
TR="$(now)"
echo "E2E unreachable after $(fsub "$TU" "$TS")s, cleared $(fsub "$TR" "$TU")s after SIGCONT"
check "R9 the session is not stopped (still a live shell)" jtrue "$D" "S(a[0])['state'] == 'shell'" "$S8"
wait_app
check "R9 app quit by itself" test $? == 0
check "R9 no takeover, holder still running" bash -c "! grep -qi 'taken over' '$ROOT/r9.log' && kill -0 $H8"
fi

# ---------------------------------------------------------------------------------------------
# R8. Dead-session replay.
if sel R8; then
kill -KILL "$H8" 2>/dev/null
wait_for 5 bash -c "! kill -0 $H8 2>/dev/null"
start_app r8 "$C" "$CC" 6 -codd-select-session "$S8" -codd-dump-terminal "$ROOT/r8-term.txt"
wait_app
check "R8 app quit by itself" test $? == 0
D="$ROOT/r8.json"
check "R8 replayed viewport shows the last output" contains "$ROOT/r8-term.txt" "REPLAY-MARKER-42"
check "R8 replay footer holder 已結束" contains "$ROOT/r8-term.txt" "holder 已結束"
check "R8 session EXITED and marked replayed" jtrue "$D" "S(a[0])['state'] == 'exited' and S(a[0])['replayed'] is True" "$S8"
check "R8 log: ring replayed" contains "$ROOT/r8.log" "replay session=$S8 bytes="
fi

# ---------------------------------------------------------------------------------------------
# R7. Panel tabs + maximize, persisted and reattached. (R10 counts on the tab holders left running.)
if sel R7 || sel R10; then
chk_for R7
start_app r7 "$C" "$CC" 9 -codd-spawn-shell "$ROOT/wc/panel" -codd-open-panel YES -codd-panel-tabs 2 -codd-maximize-panel YES
D="$ROOT/r7.json"
check "R7 pane: two panel tabs with holders, maximized" wait_for 12 jtrue "$D" \
    "d.get('pane') and len(d['pane']['panelTabs']) == 2 and all(t.get('holderPid') for t in d['pane']['panelTabs']) and d['pane']['panelMaximized'] is True and d['pane']['panelOpen'] is True"
wait_app
check "R7 app quit by itself" test $? == 0
S7="$(jexpr "$D" "d['pane']['session']")"
TABPIDS="$(jexpr "$D" "' '.join(str(p) for p in sorted(t['holderPid'] for t in d['pane']['panelTabs']))")"
echo "E2E panel session=$S7 tab holders=$TABPIDS"
check "R7 panes.json: 2 panelTabs, panelMaximized, and the M1 panel key" jtrue "$C/panes.json" \
    "len(d['sessions'][a[0]]['panelTabs']) == 2 and d['sessions'][a[0]]['panelMaximized'] is True and d['sessions'][a[0]]['panel']['id'] in [t['id'] for t in d['sessions'][a[0]]['panelTabs']] and d['version'] == 1" "$S7"
check "R7 both tab holders run after the quit" bash -c "for p in $TABPIDS; do kill -0 \$p || exit 1; done; [[ -n '$TABPIDS' ]]"
CHK=1
fi
if sel R7; then
start_app r7b "$C" "$CC" 6 -codd-select-session "$S7"
D="$ROOT/r7b.json"
check "R7 relaunch: both panel tabs reattached to the same holders" wait_for 12 jtrue "$D" \
    "d.get('pane') and d['pane']['session'] == a[0] and ' '.join(str(p) for p in sorted(t.get('holderPid', 0) for t in d['pane']['panelTabs'])) == a[1]" "$S7" "$TABPIDS"
wait_app
check "R7b app quit by itself" test $? == 0
check "R7 relaunch spawned no tab holder" lacks "$ROOT/r7b.log" "spawned tab="
check "R7 relaunch kept maximize" jtrue "$D" "d['pane']['panelMaximized'] is True"
fi

# ---------------------------------------------------------------------------------------------
# R10. Lifecycle: the window closes, CODD keeps running; holders survive the quit.
if sel R10; then
BEFORE="$(holders_of "$C")"
T0="$(now)"
start_app r10 "$C" "$CC" 8 -codd-close-main-window YES
D="$ROOT/r10.json"
check "R10 windowVisible false after closing the main window" wait_for 10 jtrue "$D" "d['windowVisible'] is False"
check "R10 the app keeps running with the window closed" bash -c "kill -0 $APP_PID && grep -q 'debug closed the main window' '$ROOT/r10.log'"
wait_app
R10_STATUS=$?
T1="$(now)"
echo "E2E r10 ran $(fsub "$T1" "$T0")s"
check "R10 app quit by itself" test "$R10_STATUS" == 0
check "R10 it kept running until its quit-after (8 s)" fle 7.5 "$(fsub "$T1" "$T0")"
check "R10 every holder survived the quit" bash -c "[[ -n '$BEFORE' && '$(holders_of "$C")' == '$BEFORE' ]]"
fi

# =============================================================================================
# R13. A fresh root without config.json gets a test-range port.
if sel R13; then
mkdir -p "$ROOT/d" "$ROOT/cd/sessions"
start_app r13 "$ROOT/d" "$ROOT/cd" 4
wait_app
check "R13 app quit by itself" test $? == 0
check "R13 fresh root listens on a port in 43000-43999 (config.json created with it)" jtrue "$ROOT/r13.json" \
    "d['hooks']['status'] == 'listening' and 43000 <= d['hooks']['port'] <= 43999 and load(a[0])['port'] == d['hooks']['port']" "$ROOT/d/config.json"
check "R13 log: hooks port-range=test" contains "$ROOT/r13.log" "hooks port-range=test"
fi

echo "E2E killing holders: $(pgrep -f "$ROOT/.*/bin/codd-holder-" | tr '\n' ' ')"
echo "E2E pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

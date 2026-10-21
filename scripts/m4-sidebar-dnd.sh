#!/bin/bash
# M4 sidebar drag and drop (user feedback on the M3 build): mouse drag reorder of sessions,
# projects and groups, and folders dropped from Finder becoming projects. Real CODD.app (DEBUG
# build) on a temp data root seeded by scripts/m2-fixtures (make-root.sh + seed-layout.sh); the
# drags are driven in-process by the DEBUG hooks (synthetic dragging infos through the outline's
# own drop path: no posted events, no real dragging session, no general pasteboard). No claude is
# started (sessions stay STOPPED), never ~/.claude, never the real data root.
#
#   scripts/m4-sidebar-dnd.sh     # build first: xcodegen generate && xcodebuild … -derivedDataPath build/dd build
#   CODD_APP=/path/CODD.app/Contents/MacOS/CODD KEEP=1 scripts/m4-sidebar-dnd.sh
#
# Runs (each a separate background launch with -codd-quit-after and -codd-dump-state):
#   D1  -codd-sidebar-drag-test YES: every DRAGTEST line ok (sessions down / up / never into another
#       project, projects within a group / into another group / into and out of 未分類, groups down /
#       up, layout.json read back, folders: plain file refused, between projects, duplicate revealed
#       and selected, outside the groups → 未分類), `DRAGTESTS … fail=0`;
#   D2  relaunch: the tree order (groups → projects → sessions) equals D1's `DRAGTEST order` line;
#   D3  -codd-drop-folders f1 f2 file -codd-drop-folders-group <blue> -codd-drop-folders-index 0:
#       f1 and f2 are the group's first two projects, the file is ignored;
#   D4  the same f1 dropped again outside the groups: not added, revealed and selected;
#   D5  a plain file alone: no drop target (op 0, not accepted).
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

T="$(mktemp -d "${TMPDIR:-/tmp}/codd-dnd.XXXXXX")" || { echo "E2E mktemp failed" >&2; exit 2; }
ROOT="$(cd "$T" && pwd -P)" || exit 2
case "$ROOT" in
    /*/codd-dnd.??????) ;;
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

# jexpr <json file> <python expression> [args…]: prints the value ("" on any error). `order()` is
# the tree order in the `DRAGTEST order` form.
jexpr() {
    "$PY" -I - "$@" 2>/dev/null <<'PY'
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    a = sys.argv[3:]
    def order():
        out = []
        for g in d.get("groupsInfo", []):
            gid = None if g.get("ungrouped") else g["id"]
            ps = [p for p in d.get("projects", []) if p.get("group") == gid]
            out.append(g["id"] + "[" + ",".join(p["id"] + "(" + ",".join(p.get("sessions", [])) + ")" for p in ps) + "]")
        return " ".join(out)
    # CODD stores standardized paths (`/private/var/…` reads `/var/…`): compare resolved.
    def rp(x): return os.path.realpath(x) if x else x
    def P(cwd): return next((p for p in d.get("projects", []) if rp(p.get("cwd")) == rp(cwd)), None)
    def side(): return d.get("sidebar") or {}
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
        -codd-trash-dir "$ROOT/trash" -codd-quit-after "$seconds" -codd-dump-state "$ROOT/$name.json" "$@" \
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
mkdir -p "$CA/projects" "$ROOT/trash"
"$FIX/make-root.sh" "$A" >/dev/null || exit 2
LM="$("$FIX/seed-layout.sh" "$A" "$ROOT/wa")" || exit 2
BLUE="$(jexpr "$LM" "next(g['id'] for g in d['groups'] if g['name']=='藍鵲 · 網站')")"

# D1. The drag self-test.
start_app d1 25 -codd-sidebar-drag-test YES
wait_app
check "D1 drag self-test ran" contains "$ROOT/d1.log" "DRAGTESTS ok="
check "D1 every drag passed" contains "$ROOT/d1.log" " fail=0"
check "D1 no failed DRAGTEST line" lacks "$ROOT/d1.log" " FAIL "
for name in sessions.down sessions.up projects.withinGroup projects.intoGroup projects.intoUngrouped groups.down groups.up \
            persisted folders.plainFile folders.betweenProjects folders.duplicate folders.outsideGroups; do
    check "D1 $name" contains "$ROOT/d1.log" "DRAGTEST $name ok"
done
ORDER="$(grep -o 'DRAGTEST order .*' "$ROOT/d1.log" | tail -1 | sed 's/^DRAGTEST order //')"
check "D1 order line logged" test -n "$ORDER"

# D2. Relaunch: the order survived (layout.json read back by a new process).
start_app d2 6
wait_app
check "D2 tree order after relaunch equals D1's" test "$(jexpr "$ROOT/d2.json" "order()" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$ORDER" | tr 'A-Z' 'a-z')"

# D3. Folders (and a file) from Finder before the blue group's first project.
mkdir -p "$ROOT/drop/f1" "$ROOT/drop/f2"
printf 'x\n' >"$ROOT/drop/file.txt"
start_app d3 8 -codd-drop-folders "$ROOT/drop/f1" -codd-drop-folders "$ROOT/drop/f2" -codd-drop-folders "$ROOT/drop/file.txt" \
    -codd-drop-folders-group "$BLUE" -codd-drop-folders-index 0
wait_app
check "D3 drop accepted with two added" contains "$ROOT/d3.log" "debug drop-folders op=1 accepted=true added=2 existing=0"
check "D3 f1, f2 lead the group in drop order" jtrue "$ROOT/d3.json" \
    "[rp(p['cwd']) for p in d['projects'] if (p.get('group') or '').lower()==a[0].lower()][:2] == [rp(a[1]), rp(a[2])]" \
    "$BLUE" "$ROOT/drop/f1" "$ROOT/drop/f2"
check "D3 the file is not a project" jtrue "$ROOT/d3.json" "P(a[0]) is None" "$ROOT/drop/file.txt"
COUNT="$(jexpr "$ROOT/d3.json" "len(d['projects'])")"

# D4. The same folder again, outside the groups: revealed and selected, not added.
start_app d4 8 -codd-drop-folders "$ROOT/drop/f1"
wait_app
check "D4 nothing added" contains "$ROOT/d4.log" "added=0 existing=1"
check "D4 project count unchanged" test "$(jexpr "$ROOT/d4.json" "len(d['projects'])")" = "$COUNT"
check "D4 that project is selected" jtrue "$ROOT/d4.json" "side().get('selectedProjects') == [P(a[0])['id']]" "$ROOT/drop/f1"

# D5. A plain file alone has no drop target.
start_app d5 6 -codd-drop-folders "$ROOT/drop/file.txt"
wait_app
check "D5 plain file refused" contains "$ROOT/d5.log" "debug drop-folders op=0 accepted=false"

check "no process of this run left" bash -c "sleep 1; ! pgrep -f '$ROOT/' >/dev/null"
echo "E2E pass=$PASS fail=$FAIL"
[[ $FAIL == 0 ]]

#!/bin/bash
# M5 end-to-end test (docs/M5-PLAN.md §6): the real CODD.app (DEBUG build), real codd-holder, the real
# hook server, the onboarding window, the data preflight, the bundle identity, stop while STARTING,
# the accessibility audit (mock mode), the copy audit and the release dry run. The fakes only: the M4
# fake claude (scripts/m4-fixtures/fake-claude-m4.sh, answers --version), the M3 fake cswap
# (scripts/m3-fixtures/fake-cswap.py + make-cswap-state.sh), the M3 settings fixture with CODD web's
# legacy hooks (make-claude-settings.sh --legacy) and the M5 import fixture
# (scripts/m5-fixtures/make-import-fixture.sh: made-up projects, a made-up .claude.json, transcripts).
# No Anthropic call, no real claude, no real cswap, never ~/.claude, ~/.claude.json, the real data root
# or the real defaults domains (nothing here runs `defaults`).
#
# Isolation: one mktemp folder (codd-m5e.XXXXXX) in the per-user temp folder; inside it one group
# folder per scenario group (two letters: holder sockets must stay under 104 bytes) with its own data
# root (scripts/m2-fixtures/make-root.sh: own hook port in 43000-43999, own token), its own Claude
# directory (`home/.claude`, so `home/.claude.json` is the "user's" .claude.json), its own trash folder
# (-codd-trash-dir), its own copies of the fakes with `.env` sidecars and its own work folder. Every
# launch passes each CODD flag as its own argument, -codd-data-root and -codd-claude-dir inside the
# folder (A1 is mock mode: -codd-mock), -codd-quit-after, -codd-dump-state, -codd-login-env NO,
# -codd-notifications NO, and stays in the background (CODD_BACKGROUND=1). The window-stack watcher
# (scripts/lib/zorder-guard.sh) runs over the whole run: a CODD window above another app's window fails
# the run. Every process it starts carries the folder in its argv; the cleanup sends SIGCONT, SIGTERM,
# then SIGKILL to `pkill -f "<tmp>/"` only (also the `/var/…` spelling) and removes the folder unless
# KEEP=1.
#
#   scripts/m5-e2e.sh            # build first: xcodegen generate && xcodebuild … -derivedDataPath build/dd build
#   CODD_APP=/path/CODD.app/Contents/MacOS/CODD KEEP=1 scripts/m5-e2e.sh   # keep the temp folder
#   ONLY=O1,D2 scripts/m5-e2e.sh # only these sections (ids below, comma separated; unset = all). Unselected
#                                # sections print `E2E skip <id>`; their groups and launches do not run. I1
#                                # (isolation) scans only the runs that happened. An unknown id exits 64 with
#                                # the valid ids.
#
# Sections (each run is a separate app launch with -codd-quit-after and -codd-dump-state):
#   O1  a new root with -codd-onboarding auto, the import fixture, the fake claude, the fake cswap (3
#       accounts) and CODD web's legacy hooks: the wizard shows and the main window does not; the boot
#       rows; the import rows (last-use order, 2 hidden, the missing folder absent, prefixes, pre-checked
#       rows); `suggest` → the two parent groups; ⌘Q mid-way writes nothing; a full flow: `next` imports
#       exactly the checked projects into the suggested groups and colors, hooks-preview plans only,
#       reveal-notes is skipped (background), accounts are aliases, `notify` → suppressed, `finish` →
#       onboarding.json v1 and the main window; .claude.json, the transcripts and settings.json unchanged;
#       a relaunch shows no wizard.
#   O2  an existing (seeded) root: no wizard with -codd-onboarding auto; -codd-show onboarding lists only
#       projects not in CODD yet (`already`); skipping every step imports nothing.
#   O3  no cswap and a claude path that does not exist: `[FAIL] claude`, `[ .. ] cswap`, the step 5 note,
#       the flow still finishes.
#   D1  newer files (layout.json, preferences.json, panes.json, a composer.json, config.json at v99,
#       written with v1 content): every byte unchanged after runs that change things (a composer send, a
#       panel tab, a zoom step, a new session); one `newer` issue per file and one banner each; the
#       sidebar shows the v99 layout's groups and sessions, the pane the v99 panes.json's tabs.
#   D2  corrupt files (layout.json, preferences.json, profiles.json, cleanup.json, files/recent.json, a
#       composer.json) moved to `<name>.corrupt-<ms>` with the planted bytes and bannered; quota.json and a
#       hooks record removed without a banner; config.json repaired in place with its port kept; a
#       layout.json LayoutStore itself moves aside gets its banner through the post-load sweep; a
#       preferences.json with "version":"1" is not moved.
#   D3  cache/VERSION 0 with a planted file → wiped, VERSION 1, the notes index rebuilt; the next launch
#       keeps the cache; a cache without VERSION keeps its file and gains VERSION.
#   K1  the built bundle: app.codd.CODD, CFBundleShortVersionString = VERSION, the helpers signed
#       app.codd.codd-*, the binaries name the legacy id only as the legacy constant.
#   S1  -codd-new-claude + -codd-stop-after-create YES: stop deferred, then applied after the spawn, the
#       session ends as for any stop (EXITED with RESUME, or STOPPED), no holder left.
#   A1  mock mode -codd-a11y-audit over every screen (onboarding 1-6 included): 0 unlabeled; the
#       outsideKeyLoop count printed.
#   C1  scripts/tools/copy-audit.py exits 0; scripts/release.sh --dry-run names app.codd.CODD and VERSION.
#   I1  isolation over every run: exec paths inside the temp folder, no `defaults migrat…` line (other
#       roots never migrate), D25 (autosavesLayout false), no e-mail of the fixtures in any dump or log,
#       no anthropic.com, no new ~/.claude*.codd-bak-* (names only); the window-stack summary at the end.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

# ONLY=<ids>: section selection (see the header). Validated before anything else happens.
ALL_IDS="O1 O2 O3 D1 D2 D3 K1 S1 A1 C1 I1"
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

# The fakes and fixtures refuse paths outside the per-user temp folder; make sure TMPDIR names it.
if [[ -z "${TMPDIR:-}" ]]; then
    TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
    export TMPDIR
fi

cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"
APP="${CODD_APP:-build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD}"
FIX2="$REPO/scripts/m2-fixtures"
FIX3="$REPO/scripts/m3-fixtures"
FIX4="$REPO/scripts/m4-fixtures"
FIX5="$REPO/scripts/m5-fixtures"
PY=/usr/bin/python3
[[ -x "$PY" ]] || PY="python3"
if [[ ! -x "$APP" ]]; then
    echo "E2E missing $APP (build the app first)" >&2
    exit 2
fi
command -v "$PY" >/dev/null || { echo "E2E needs python3 (JSON checks)" >&2; exit 2; }
VERSION_TEXT="$(tr -d '[:space:]' <"$REPO/VERSION" 2>/dev/null)"
[[ -n "$VERSION_TEXT" ]] || { echo "E2E missing $REPO/VERSION" >&2; exit 2; }
# Window-stack guard (docs/M5-PLAN.md D23): the run fails when a window of this build rises above
# another app's window, even when every check passed.
source scripts/lib/zorder-guard.sh

# Short (holder sockets must stay under 104 bytes) and resolved (`pkill -f` matches it verbatim).
T="$(mktemp -d "${TMPDIR%/}/codd-m5e.XXXXXX")" || { echo "E2E mktemp failed" >&2; exit 2; }
ROOT="$(cd "$T" && pwd -P)" || exit 2
case "$ROOT" in
    /*/codd-m5e.??????) ;;
    *) echo "E2E unexpected temp folder '$ROOT'" >&2; exit 2 ;;
esac
# CODD standardizes some paths (`/private/var/…` → `/var/…`): processes and log lines may use it.
ROOTV="${ROOT#/private}"
PASS=0
FAIL=0
APP_PID=""
APP_NAME=""
RUNS=()

kill_ours() {
    local sig="$1"
    pkill "-$sig" -f "$ROOT/" 2>/dev/null
    [[ "$ROOTV" != "$ROOT" ]] && pkill "-$sig" -f "$ROOTV/" 2>/dev/null
    return 0
}
ours_left() { pgrep -f "$ROOT/" >/dev/null 2>&1 || { [[ "$ROOTV" != "$ROOT" ]] && pgrep -f "$ROOTV/" >/dev/null 2>&1; }; }
cleanup() {
    local rc=$?
    kill_ours CONT
    kill_ours TERM
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        ours_left || break
        sleep 0.3
    done
    kill_ours KILL
    # After every CODD of the run has quit: a window-stack violation fails the run (exit 1).
    if ! zorder_guard_end && [[ $rc == 0 ]]; then rc=1; fi
    if [[ "${KEEP:-0}" == 1 ]]; then echo "E2E kept $ROOT"; else rm -rf -- "$ROOT"; fi
    exit "$rc"
}
trap cleanup EXIT
zorder_guard_begin "$ROOT" "$APP"

# check "<id> <label>" <command…>: counted only when its section is selected.
check() {
    local what="$1"; shift
    local id="${what%% *}"
    case " $ALL_IDS " in *" $id "*) sel "$id" || { "$@" >/dev/null 2>&1; return 0; } ;; esac
    if "$@"; then
        PASS=$((PASS + 1)); echo "E2E ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "E2E FAIL $what"
    fi
}
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
contains_i() { grep -qiF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
matches() { grep -qE -- "$2" "$1" 2>/dev/null; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -c1-64; }
# stamps <path…>: "relative size mtime_ns sha256" per regular file under each path (files or folders,
# symlinks never followed), sorted; the before / after fingerprint of fixtures CODD must only read.
stamps() {
    "$PY" -I - "$@" 2>/dev/null <<'PY'
import hashlib, os, stat, sys
out = []
def add(p):
    st = os.lstat(p)
    if not stat.S_ISREG(st.st_mode):
        return
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    out.append("%s %d %d %s" % (p, st.st_size, st.st_mtime_ns, h.hexdigest()))
for top in sys.argv[1:]:
    if os.path.isdir(top) and not os.path.islink(top):
        for d, dirs, files in os.walk(top):
            dirs.sort()
            for name in sorted(files):
                add(os.path.join(d, name))
    elif os.path.lexists(top):
        add(top)
    else:
        out.append("%s absent" % top)
print("\n".join(sorted(out)))
PY
}
# pyok <python code> [args…]: exit status of a small Python check (sys.argv[1:] are the args).
pyok() { local code="$1"; shift; "$PY" -I -c "$code" "$@" 2>/dev/null; }

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
    def low(x): return str(x).lower()
    def rp(x): return os.path.realpath(x) if x else x
    def S(i): return next((s for s in d.get("sessions", []) if low(s.get("id")) == low(i)), None)
    def O(): return d.get("onboarding") or {}
    def boot(name): return next((b for b in O().get("boot", []) if b.get("name") == name), None)
    def boots(): return O().get("boot", [])
    def IMP(): return O().get("import") or {}
    def rows(): return IMP().get("rows", [])
    def row(path): return next((r for r in rows() if rp(r.get("path")) == rp(path)), None)
    def opt(key): return next((o for o in IMP().get("options", []) if o.get("key") == key), None)
    def optn(name): return next((o for o in IMP().get("options", []) if o.get("name") == name), None)
    def step(i): return next((s for s in O().get("steps", []) if s.get("id") == i), None)
    def DF(): return d.get("dataFiles") or {}
    def PF(): return (DF().get("preflight") or {}).get("files", [])
    def pf(f): return next((x for x in PF() if x.get("file") == f), None)
    def issues(kind=None): return [i for i in DF().get("issues", []) if kind is None or i.get("kind") == kind]
    def issue(f, kind=None): return next((i for i in issues(kind) if i.get("file") == f), None)
    def B(): return d.get("bundle") or {}
    def N(): return d.get("notes") or {}
    def P(cwd): return next((p for p in d.get("projects", []) if rp(p.get("cwd")) == rp(cwd)), None)
    v = eval(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}
jtrue() { [[ "$(jexpr "$@")" == True ]]; }

# setup_group <name>: a data root, a home with .claude, the fake claude with its sidecar, a work folder.
# Sets G.
setup_group() {
    local name="$1"
    G="$ROOT/$name"
    mkdir -p "$G/bin" "$G/work" "$G/fakelog" "$G/trash" "$G/home/.claude/sessions"
    "$FIX2/make-root.sh" "$G/d" >"$G/root.txt" || { echo "E2E make-root failed ($name)" >&2; exit 2; }
    chmod 600 "$G/root.txt"
    cp "$FIX4/fake-claude-m4.sh" "$G/bin/fake-claude"
    chmod 755 "$G/bin/fake-claude"
    printf 'FAKE_REGISTRY_DIR=auto\nFAKE_DEFAULT_CLAUDE_DIR=%s\nFAKE_LOG_DIR=%s\nFAKE_STATUSLINE_INTERVAL_MS=0\n' \
        "$G/home/.claude" "$G/fakelog" >"$G/bin/fake-claude.env"
    echo "E2E group $name root=$G"
}
port_of() { jexpr "$ROOT/$1/d/config.json" "d['port']"; }
# cswap_setup <group>: the M3 fake cswap and its state (#1 #2 #3, #3 active) in its own home (`cs/`),
# so its .claude.json never meets the import fixture's (`home/.claude.json`).
cswap_setup() {
    local g="$ROOT/$1"
    mkdir -p "$g/cs/.claude"
    "$FIX3/make-cswap-state.sh" "$g/cs/.claude-swap-backup" "$g/cs/.claude" >/dev/null \
        || { echo "E2E make-cswap-state failed ($1)" >&2; exit 2; }
    cp "$FIX3/fake-cswap.py" "$g/bin/cswap"
    chmod 755 "$g/bin/cswap"
    printf 'FAKE_CSWAP_ROOT=%s\nFAKE_CSWAP_LOG=%s\n' "$g/cs/.claude-swap-backup" "$g/cswap-calls.jsonl" >"$g/bin/cswap.env"
}
# import_setup <group>: the M5 import fixture (projects under work/imp, home/.claude.json, transcripts)
# and CODD web's legacy hooks in home/.claude/settings.json. EXPECT lines in <group>/import.txt.
import_setup() {
    local g="$ROOT/$1"
    bash "$FIX5/make-import-fixture.sh" "$g/home/.claude" "$g/work/imp" >"$g/import.txt" \
        || { echo "E2E make-import-fixture failed ($1)" >&2; exit 2; }
    "$FIX3/make-claude-settings.sh" "$g/home/.claude" --legacy >/dev/null \
        || { echo "E2E make-claude-settings failed ($1)" >&2; exit 2; }
}
# expect_path <group> <rank>: the project path of that EXPECT line.
expect_path() { awk -v r="$2" '$1 == "EXPECT" && $2 == r {print $3}' "$ROOT/$1/import.txt"; }
absent_path() { awk '$1 == "ABSENT" {print $2}' "$ROOT/$1/import.txt"; }
# The paths the fixture expects, in rank order (one per line).
expect_list() { awk '$1 == "EXPECT" {print $3}' "$ROOT/$1/import.txt"; }

# start_app <name> <group> <seconds> [flags…]: runs in the background; the dump is $ROOT/<name>.json, the
# log $ROOT/<name>.log. Later flags win.
start_app() {
    local name="$1" g="$ROOT/$2" seconds="$3"; shift 3
    rm -f "$ROOT/$name.json"
    perl -e 'alarm shift; exec @ARGV' 150 "$APP" -codd-data-root "$g/d" -codd-claude-dir "$g/home/.claude" \
        -codd-claude-path "$g/bin/fake-claude" -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO \
        -codd-trash-dir "$g/trash" -codd-quit-after "$seconds" -codd-dump-state "$ROOT/$name.json" "$@" >"$ROOT/$name.log" 2>&1 &
    APP_PID=$!
    APP_NAME="$name"
    RUNS+=("$name")
}
wait_app() {
    wait "$APP_PID"
    local status=$?
    echo "E2E $APP_NAME exit=$status log=$ROOT/$APP_NAME.log"
    [[ $status == 0 ]]
}
# run_app <section> <name> <group> <seconds> [flags…]: start_app, wait, and check that it quit by itself.
run_app() {
    local section="$1"; shift
    start_app "$@"
    check "$section $1 quit by itself" wait_app
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
# end_holders <group>: ends that group's holders (their children get SIGHUP) and waits.
end_holders() {
    pkill -TERM -f "$ROOT/$1/d/bin/codd-holder-" 2>/dev/null
    [[ "$ROOTV" != "$ROOT" ]] && pkill -TERM -f "$ROOTV/$1/d/bin/codd-holder-" 2>/dev/null
    wait_for 10 holders_gone "$1"
}
holders_gone() {
    ! pgrep -f "$ROOT/$1/d/bin/codd-holder-" >/dev/null 2>&1 && ! pgrep -f "$ROOTV/$1/d/bin/codd-holder-" >/dev/null 2>&1
}
# aside_of <file>: the `<file>.corrupt-<ms>` next to it (the first one), or nothing.
aside_of() { ls -1 "$1".corrupt-[0-9]* 2>/dev/null | head -1; }
# planted_aside <file> <planted copy>: exactly one aside of <file>, with the planted bytes.
planted_aside() {
    local n
    n="$(ls -1 "$1".corrupt-[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$n" == 1 ]] && cmp -s "$(aside_of "$1")" "$2"
}

# Before / after facts for I1 (names only; never a listing of ~/.claude or its contents).
home_backups() {
    { find "$HOME" -maxdepth 1 -name '.claude.json.codd-bak-*' 2>/dev/null
      [[ -d "$HOME/.claude" ]] && find "$HOME/.claude" -maxdepth 1 -name 'settings.json.codd-bak-*' 2>/dev/null; } | sort
}
HOME_BACKUPS_BEFORE="$(home_backups)"
STARTED=$SECONDS

echo "E2E root=$ROOT app=$APP version=$VERSION_TEXT"
for _id in $ALL_IDS; do sel "$_id" || echo "E2E skip $_id"; done

# =============================================================================================
# O1: the first launch on a new root (D5–D13).
if sel O1; then
# o1a: the wizard at step 2 after `next,suggest`, then quit (⌘Q mid-way writes nothing, D7).
setup_group oa
OA="$G"
import_setup oa
cswap_setup oa
OA_FIX_BEFORE="$(stamps "$OA/home/.claude.json" "$OA/home/.claude/projects" "$OA/home/.claude/settings.json")"
run_app O1 o1a oa 16 -codd-cswap-path "$OA/bin/cswap" -codd-cswap-root "$OA/cs/.claude-swap-backup" \
    -codd-onboarding auto -codd-onboarding-actions "next,suggest"
D="$ROOT/o1a.json"
PORT_OA="$(port_of oa)"
check "O1 gate: show=true reason=new-root (log)" contains "$ROOT/o1a.log" "onboarding gate show=true reason=new-root"
check "O1 the wizard shows, the main window does not" jtrue "$D" "O()['shown'] is True and d.get('windowVisible') is False and O()['source'] == 'live'"
check "O1 the probe ran once the wizard showed (log)" matches "$ROOT/o1a.log" "onboarding probe ms=[0-9]+ claude=found cswap=ready hooks=legacy writable=true mcp=true candidates=8 already=0"
check "O1 boot claude: [ OK ] with the fake's version and path" jtrue "$D" \
    "boot('claude')['tag'] == 'ok' and '2.1.302' in boot('claude')['value'] and rp(boot('claude')['detail']) == rp(a[0])" "$OA/bin/fake-claude"
check "O1 boot cswap: [ OK ] 0.26.0 · 3 個帳號" jtrue "$D" "boot('cswap')['tag'] == 'ok' and boot('cswap')['value'] == '0.26.0 · 3 個帳號'"
check "O1 boot hooks: [ .. ] 需要更新（n 個事件） with CODD web's legacy events" jtrue "$D" \
    "boot('hooks')['tag'] == 'pending' and boot('hooks')['value'].startswith('需要更新（') and '個事件）' in boot('hooks')['value'] and '舊版 CODD web：' in boot('hooks')['detail']"
check "O1 boot data root: writable, MCP 127.0.0.1:<port> 可用" jtrue "$D" \
    "(lambda b: b is not None and b['tag'] == 'ok' and b['value'] == '可寫入' and b['detail'] == 'MCP 127.0.0.1:%s 可用' % a[0])(next((x for x in boots() if rp(x['name']) == rp(a[1])), None))" \
    "$PORT_OA" "$OA/d"
check "O1 boot import source: 6 個專案, read only" jtrue "$D" \
    "(lambda b: b is not None and b['tag'] == 'ok' and b['value'] == '6 個專案' and b['detail'] == '只讀取，不會改動')(next((x for x in boots() if rp(x['name']) == rp(a[0])), None))" \
    "$OA/home/.claude.json"
check "O1 boot header 4 OK · 1 待處理, the waiting line of step 2" jtrue "$D" \
    "O()['bootHeader'] == '4 OK · 1 待處理' and boots()[-1]['tag'] == 'waiting' and boots()[-1]['name'] == 'projects'"
check "O1 on step 2 after next; step 1 done" jtrue "$D" "O()['step'] == 2 and step('detect')['state'] == 'done' and step('import')['state'] == 'current'"
check "O1 import source is the fixture's .claude.json, 6 shown + 2 hidden, none already in CODD" jtrue "$D" \
    "rp(IMP()['source']) == rp(a[0]) and IMP()['total'] == 6 and IMP()['hidden'] == 2 and IMP()['already'] == 0 and IMP()['problem'] is None" \
    "$OA/home/.claude.json"
check "O1 import rows in the fixture's last-use order (hidden ones included)" jtrue "$D" \
    "[rp(r['path']) for r in rows()] == [rp(p) for p in a[0].split()]" "$(expect_list oa | tr '\n' ' ')"
check "O1 transcripts and hidden kinds as the fixture says" pyok '
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rows = {os.path.realpath(r["path"]): r for r in d["onboarding"]["import"]["rows"]}
ok = True
for line in open(sys.argv[2]):
    f = line.split()
    if f[:1] != ["EXPECT"]:
        continue
    r = rows.get(os.path.realpath(f[2]))
    t = int(f[3].split("=")[1]); h = f[4].split("=")[1]
    ok = ok and r is not None and r["transcripts"] == t and r["hidden"] == h
sys.exit(0 if ok else 1)' "$D" "$OA/import.txt"
check "O1 the missing folder is not a candidate" jtrue "$D" "row(a[0]) is None" "$(absent_path oa)"
check "O1 name prefixes: labs/ on mcp and x only (D10)" jtrue "$D" \
    "[r['name'] for r in rows() if r['prefix']] and all(str(r['prefix']).rstrip('/') == 'labs' for r in rows() if r['prefix']) and sorted(r['name'] for r in rows() if r['prefix']) == ['mcp', 'x']"
check "O1 pre-checked: the 5 projects used within 14 days that are not hidden (D8)" jtrue "$D" \
    "IMP()['checked'] == 5 and sorted(rp(r['path']) for r in rows() if r['checked']) == sorted(rp(p) for p in a)" \
    "$(expect_path oa 2)" "$(expect_path oa 3)" "$(expect_path oa 5)" "$(expect_path oa 6)" "$(expect_path oa 7)"
check "O1 suggest: two new groups, clients and labs (D9)" jtrue "$D" \
    "optn('clients') is not None and optn('labs') is not None and optn('clients')['kind'] == 'new' and optn('labs')['kind'] == 'new'"
check "O1 suggest: alpha-web, alpha-api → clients; mcp, x → labs; solo-tool 未分類" jtrue "$D" \
    "row(a[0])['group'] == row(a[1])['group'] == optn('clients')['key'] and row(a[2])['group'] == row(a[3])['group'] == optn('labs')['key'] and row(a[4])['group'] == row(a[4])['suggestion'] and opt(row(a[4])['group'])['kind'] == 'ungrouped'" \
    "$(expect_path oa 2)" "$(expect_path oa 5)" "$(expect_path oa 3)" "$(expect_path oa 7)" "$(expect_path oa 6)"
check "O1 the unchecked legacy-site keeps clients as its suggestion" jtrue "$D" "row(a[0])['checked'] is False and row(a[0])['suggestion'] == optn('clients')['key']" "$(expect_path oa 8)"
check "O1 log: action next / suggest ok" bash -c "grep -q 'onboarding action=next step=2 ok=true' '$ROOT/o1a.log' && grep -q 'onboarding action=suggest step=2 ok=true' '$ROOT/o1a.log'"
check "O1 ⌘Q mid-way: no onboarding.json, nothing imported (D7)" bash -c "[[ ! -e '$OA/d/onboarding.json' ]] && ! grep -q 'onboarding import projects=' '$ROOT/o1a.log'"
check "O1 accounts are aliases only (3 rows, no @)" jtrue "$D" "len(O()['accounts']['rows']) == 3 and all('@' not in str(r['alias']) for r in O()['accounts']['rows'])"
check "O1 the fixture's .claude.json, transcripts and settings.json unchanged (o1a)" test \
    "$(stamps "$OA/home/.claude.json" "$OA/home/.claude/projects" "$OA/home/.claude/settings.json")" == "$OA_FIX_BEFORE"
end_holders oa

# o1b: the whole flow on a second new root with the same fixtures.
setup_group ob
OB="$G"
import_setup ob
cswap_setup ob
OB_FIX_BEFORE="$(stamps "$OB/home/.claude.json" "$OB/home/.claude/projects" "$OB/home/.claude/settings.json")"
run_app O1 o1b ob 20 -codd-cswap-path "$OB/bin/cswap" -codd-cswap-root "$OB/cs/.claude-swap-backup" -codd-onboarding auto \
    -codd-onboarding-actions "next,suggest,next,hooks-preview,next,reveal-notes,next,next,notify,finish"
D="$ROOT/o1b.json"
check "O1 every action ran ok (log)" bash -c "[[ \$(grep -c 'onboarding action=[a-z-]* step=[0-9] ok=true' '$ROOT/o1b.log') == 10 ]] && ! grep -q 'onboarding action=.* ok=false' '$ROOT/o1b.log'"
check "O1 next on step 2 imported 5 projects in 2 groups (log)" contains "$ROOT/o1b.log" "onboarding import projects=5 groups=2"
check "O1 layout.json: exactly the 5 checked projects in clients / labs / 未分類 with the suggested colors" pyok '
import json, os, sys
lay = json.load(open(sys.argv[1], encoding="utf-8"))
step2 = json.load(open(sys.argv[2], encoding="utf-8"))["onboarding"]["import"]["options"]
colors = {o["name"]: o["color"] for o in step2}
groups = {g["id"]: g for g in lay["groups"]}
got = {os.path.realpath(p["path"]): (groups[p["groupId"]]["name"] if p.get("groupId") else None) for p in lay["projects"]}
want = {os.path.realpath(sys.argv[3]): "clients", os.path.realpath(sys.argv[4]): "clients", os.path.realpath(sys.argv[5]): "labs",
        os.path.realpath(sys.argv[6]): "labs", os.path.realpath(sys.argv[7]): None}
named = {g["name"]: g for g in lay["groups"]}
ok = got == want and sorted(named) == ["clients", "labs"]
ok = ok and all(str(named[n].get("color")).lower() == str(colors.get(n)).lower() for n in ("clients", "labs"))
ok = ok and len({named[n].get("color") for n in ("clients", "labs")}) == 2
sys.exit(0 if ok else 1)' "$OB/d/layout.json" "$ROOT/o1a.json" \
    "$(expect_path ob 2)" "$(expect_path ob 5)" "$(expect_path ob 3)" "$(expect_path ob 7)" "$(expect_path ob 6)"
check "O1 hooks-preview: a plan with changes, nothing written (log)" bash -c \
    "grep -q 'onboarding hooks-preview changes=true' '$ROOT/o1b.log' && ! ls '$OB/home/.claude'/settings.json.codd-bak-* >/dev/null 2>&1"
check "O1 notebook path = <root>/notes, MCP running" jtrue "$D" "rp(O()['notebook']['path']) == rp(a[0]) and O()['notebook']['mcpRunning'] is True" "$OB/d/notes"
check "O1 reveal-notes skipped in a background run (log)" contains "$ROOT/o1b.log" "notes reveal-folder skipped (background run)"
o1_notified() { contains "$ROOT/o1b.log" "onboarding notifications=suppressed" && [[ "$(jexpr "$ROOT/o1b.json" "O()['notifications']")" == suppressed ]]; }
check "O1 notify → suppressed (-codd-notifications NO)" o1_notified
check "O1 finish → onboarding.json v1 (steps, 5 projects, 2 groups, suppressed, this version)" pyok '
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
ok = s.get("v") == 1 and s.get("appVersion") == sys.argv[2] and s.get("imported") == {"projects": 5, "groups": 2}
ok = ok and s.get("notifications") == "suppressed" and isinstance(s.get("completedAt"), str)
ok = ok and sorted(s.get("steps", {})) == sorted(["detect", "import", "hooks", "notebook", "accounts", "done"])
ok = ok and all(v == "done" for v in s["steps"].values())
sys.exit(0 if ok else 1)' "$OB/d/onboarding.json" "$VERSION_TEXT"
check "O1 onboarding.json is 0600" test "$(stat -f '%Lp' "$OB/d/onboarding.json" 2>/dev/null)" == 600
check "O1 after finish: the main window shows, the wizard is gone (log saved)" bash -c \
    "grep -q 'onboarding saved file=onboarding.json finishing=done imported=5 notifications=suppressed' '$ROOT/o1b.log'"
check "O1 after finish: dump says main window visible, wizard closed, completedAt set" jtrue "$D" \
    "d.get('windowVisible') is True and O()['shown'] is False and O()['completedAt'] and rp(O()['file']) == rp(a[0])" "$OB/d/onboarding.json"
check "O1 the sidebar has the imported projects (dump)" jtrue "$D" "all(P(p) is not None for p in a)" \
    "$(expect_path ob 2)" "$(expect_path ob 3)" "$(expect_path ob 5)" "$(expect_path ob 6)" "$(expect_path ob 7)"
check "O1 accounts step: 3 alias rows, no @" jtrue "$D" "len(O()['accounts']['rows']) == 3 and all('@' not in str(r['alias']) for r in O()['accounts']['rows'])"
check "O1 the fixture's .claude.json, transcripts and settings.json unchanged (o1b)" test \
    "$(stamps "$OB/home/.claude.json" "$OB/home/.claude/projects" "$OB/home/.claude/settings.json")" == "$OB_FIX_BEFORE"
# o1c: a relaunch on the finished root: no wizard.
OB_ONB="$(stamps "$OB/d/onboarding.json")"
run_app O1 o1c ob 8 -codd-cswap-path "$OB/bin/cswap" -codd-cswap-root "$OB/cs/.claude-swap-backup" -codd-onboarding auto
check "O1 relaunch: gate show=false reason=existing-root, no probe" bash -c \
    "grep -q 'onboarding gate show=false reason=existing-root' '$ROOT/o1c.log' && ! grep -q 'onboarding probe' '$ROOT/o1c.log'"
o1_relaunched() { [[ "$(stamps "$OB/d/onboarding.json")" == "$OB_ONB" ]] && jtrue "$ROOT/o1c.json" "d.get('windowVisible') is True and O()['shown'] is False"; }
check "O1 relaunch: onboarding.json untouched, main window shown" o1_relaunched
end_holders ob
fi

# =============================================================================================
# O2: an existing root (seeded layout plus one of the fixture's projects).
if sel O2; then
setup_group o2
O2G="$G"
import_setup o2
"$FIX2/seed-layout.sh" "$O2G/d" "$O2G/work/seed" >"$O2G/seed.txt" || { echo "E2E seed-layout failed (o2)" >&2; exit 2; }
# alpha-web is in CODD already (ungrouped), so the wizard must leave it out.
"$PY" -I - "$O2G/d/layout.json" "$(expect_path o2 2)" <<'PY' || { echo "E2E layout edit failed (o2)" >&2; exit 2; }
import json, sys, uuid
path, project = sys.argv[1], sys.argv[2]
lay = json.load(open(path, encoding="utf-8"))
lay["projects"].append({"id": str(uuid.uuid4()), "name": "alpha-web", "path": project, "order": 1, "pinned": False, "collapsed": False})
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(lay, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n")
PY
run_app O2 o2a o2 8 -codd-onboarding auto
check "O2 existing root: gate show=false reason=existing-root, no wizard, no probe" bash -c \
    "grep -q 'onboarding gate show=false reason=existing-root' '$ROOT/o2a.log' && ! grep -q 'onboarding probe' '$ROOT/o2a.log' && ! grep -q 'onboarding open' '$ROOT/o2a.log'"
check "O2 existing root: main window shown, onboarding not shown (dump)" jtrue "$ROOT/o2a.json" "d.get('windowVisible') is True and O()['shown'] is False"
# The sidebar's projects and groups before the skipped wizard (ids, paths, groups, colors).
layout_facts() {
    "$PY" -I - "$1" 2>/dev/null <<'PY'
import json, sys
lay = json.load(open(sys.argv[1], encoding="utf-8"))
print(sorted((str(g["id"]).lower(), g["name"], g.get("color")) for g in lay["groups"]))
print(sorted((str(p["id"]).lower(), p["path"], str(p.get("groupId")).lower()) for p in lay["projects"]))
PY
}
O2_FACTS="$(layout_facts "$O2G/d/layout.json")"
run_app O2 o2b o2 14 -codd-show onboarding -codd-onboarding-actions "skip,skip,skip,skip,skip,skip"
D="$ROOT/o2b.json"
check "O2 -codd-show onboarding opens it (reason show-flag)" bash -c "grep -q 'onboarding gate show=true reason=show-flag' '$ROOT/o2b.log'"
check "O2 the already imported project is left out (already = 1)" jtrue "$D" "IMP()['already'] == 1 and row(a[0]) is None and row(a[1]) is not None" \
    "$(expect_path o2 2)" "$(expect_path o2 5)"
o2_nothing_imported() { ! matches "$ROOT/o2b.log" "onboarding import projects=[1-9]" && [[ "$(layout_facts "$O2G/d/layout.json")" == "$O2_FACTS" ]]; }
check "O2 skipping every step imports nothing (log, layout.json's projects and groups)" o2_nothing_imported
check "O2 the six skips ended the wizard (onboarding.json, every step skipped)" pyok '
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if s.get("imported") == {"projects": 0, "groups": 0} and all(v == "skipped" for v in s["steps"].values()) else 1)' "$O2G/d/onboarding.json"
end_holders o2
fi

# =============================================================================================
# O3: no cswap, a claude path that does not exist.
if sel O3; then
setup_group o3
O3G="$G"
run_app O3 o3 o3 14 -codd-claude-path "$O3G/bin/no-such-claude" -codd-onboarding auto \
    -codd-onboarding-actions "next,next,next,next,next,finish"
D="$ROOT/o3.json"
o3_claude_missing() { jtrue "$ROOT/o3.json" "boot('claude')['tag'] == 'fail' and boot('claude')['value'] == '找不到'" && contains "$ROOT/o3.log" "onboarding claude missing path="; }
check "O3 [FAIL] claude 找不到 (log: claude missing)" o3_claude_missing
check "O3 [ .. ] cswap 沒有安裝" jtrue "$D" "boot('cswap')['tag'] == 'pending' and boot('cswap')['value'] == '沒有安裝'"
check "O3 the step 5 note says CODD works without cswap" jtrue "$D" "O()['accounts']['note'] is not None and 'cswap' in O()['accounts']['note'] and O()['accounts']['rows'] == []"
check "O3 the flow still finishes (onboarding.json, main window)" bash -c \
    "[[ -s '$O3G/d/onboarding.json' ]] && grep -q 'onboarding saved file=onboarding.json finishing=done' '$ROOT/o3.log'"
check "O3 no claude was run (no exec claude line)" lacks "$ROOT/o3.log" "exec claude path="
end_holders o3
fi

# =============================================================================================
# D1: files a newer CODD wrote (v99) are read as far as possible and never written.
if sel D1; then
setup_group dn
DN="$G"
"$FIX2/seed-layout.sh" "$DN/d" "$DN/work/seed" >"$DN/seed.txt" || { echo "E2E seed-layout failed (dn)" >&2; exit 2; }
DN_MANIFEST="$DN/d/manifest-layout.json"
# dn1 writes v1 files: a shell with two panel tabs, a composer send, a zoom step.
run_app D1 dn1 dn 16 -codd-spawn-shell "$DN/work" -codd-open-panel YES -codd-panel-tabs 2 \
    -codd-composer-open YES -codd-composer-send 'echo d1-one' -codd-zoom in
SID="$(spawned_id "$ROOT/dn1.log" shell)"
echo "E2E dn shell session=$SID"
COMPOSER="$(ls -1 "$DN/d/sessions"/*/composer.json 2>/dev/null | head -1)"
PANEL_TABS="$(jexpr "$ROOT/dn1.json" "' '.join(t['id'] for t in (d.get('pane') or {}).get('panelTabs', []))")"
check "D1 setup: dn1 wrote layout, panes, preferences and a composer.json; two panel tabs" bash -c \
    "[[ -n '$SID' && -s '$DN/d/layout.json' && -s '$DN/d/panes.json' && -s '$DN/d/preferences.json' && -n '$COMPOSER' ]] && [[ \$(echo '$PANEL_TABS' | wc -w | tr -d ' ') == 2 ]]"
# Every versioned file becomes v99 with its v1 content.
"$PY" -I - "$DN/d" "$COMPOSER" <<'PY' || { echo "E2E version bump failed (dn)" >&2; exit 2; }
import json, os, sys
root, composer = sys.argv[1], sys.argv[2]
for path, key in ((os.path.join(root, "layout.json"), "version"), (os.path.join(root, "panes.json"), "version"),
                  (os.path.join(root, "preferences.json"), "version"), (composer, "v"), (os.path.join(root, "config.json"), "v")):
    if not path or not os.path.exists(path):
        continue
    obj = json.load(open(path, encoding="utf-8"))
    obj[key] = 99
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
PY
DN_FILES=("$DN/d/layout.json" "$DN/d/panes.json" "$DN/d/preferences.json" "$COMPOSER" "$DN/d/config.json")
DN_BEFORE="$(stamps "${DN_FILES[@]}")"
# dn2 changes things through existing flags: the same shell shown, a third panel tab, a composer send, a zoom step.
run_app D1 dn2 dn 16 -codd-select-session "$SID" -codd-open-panel YES -codd-panel-tabs 3 \
    -codd-composer-open YES -codd-composer-send 'echo d1-two' -codd-zoom in
D="$ROOT/dn2.json"
check "D1 dn2: every v99 file byte for byte unchanged" test "$(stamps "${DN_FILES[@]}")" == "$DN_BEFORE"
check "D1 one newer issue per file, v99 (layout, panes, preferences, composer, config)" jtrue "$D" \
    "all((issue(f, 'newer') or {}).get('version') == 99 for f in ('layout.json', 'panes.json', 'preferences.json', 'config.json')) and any(i['file'].endswith('/composer.json') and i.get('version') == 99 for i in issues('newer')) and len(issues('newer')) == 5"
check "D1 one banner per issue (shown + queued), the newer wording" jtrue "$D" \
    "DF()['bannersShown'] >= 1 and DF()['bannersShown'] + DF()['bannersQueued'] >= 5 and all('是較新版本的 CODD 寫的（v99）' in i['message'] for i in issues('newer'))"
check "D1 the sidebar shows the v99 layout's groups and sessions (read only)" jtrue "$D" \
    "(lambda m: all(n in [g['name'] for g in d.get('groupsInfo', [])] for n in ('藍鵲 · 網站', '個人 · Github')) and all(S(i) is not None for i in m['visibleSessions']) and S(a[1]) is not None)(load(a[0]))" \
    "$DN_MANIFEST" "$SID"
check "D1 the pane shows the v99 panes.json's panel tabs" jtrue "$D" \
    "low((d.get('pane') or {}).get('session')) == low(a[0]) and set(a[1].split()) <= set(t['id'] for t in d['pane'].get('panelTabs', [])) and len(a[1].split()) == 2" \
    "$SID" "$PANEL_TABS"
check "D1 preferences.json read only (origin newerReadOnly(99))" jtrue "$D" "str((d.get('preferences') or {}).get('origin')).startswith('newerReadOnly(99')"
check "D1 logs: layout, panes, composer and config.json kept read-only" bash -c \
    "grep -q 'layout.json is version 99 (newer CODD)' '$ROOT/dn2.log' && grep -q 'panes.json is v99 (newer CODD)' '$ROOT/dn2.log' && grep -qi 'composer state session=$SID v=99 newer: not saved' '$ROOT/dn2.log' && grep -q 'hooks config.json is v99 (newer CODD): used read-only' '$ROOT/dn2.log'"
check "D1 log: the preflight reported 5 newer files" matches "$ROOT/dn2.log" "data preflight .*newer=5"
# dn3 creates a session: still nothing written.
run_app D1 dn3 dn 10 -codd-spawn-shell "$DN/work"
dn3_unchanged() { contains "$ROOT/dn3.log" "spawned session=" && [[ "$(stamps "${DN_FILES[@]}")" == "$DN_BEFORE" ]]; }
check "D1 dn3: a new session in memory, every v99 file still unchanged" dn3_unchanged
end_holders dn
fi

# =============================================================================================
# D2: corrupt files.
if sel D2; then
setup_group dc
DC="$G"
mkdir -p "$DC/planted" "$DC/d/files" "$DC/d/hooks"
CSID="$(uuidgen | tr 'A-Z' 'a-z')"
HSID="$(uuidgen | tr 'A-Z' 'a-z')"
mkdir -p "$DC/d/sessions/$CSID"
plant() { printf '%s' "$2" >"$DC/d/$1"; printf '%s' "$2" >"$DC/planted/${1//\//_}"; }
plant layout.json '{"version":1,"groups":[ broken'
plant preferences.json 'garbage, not json'
plant profiles.json '[1,2'
plant cleanup.json 'not json at all'
plant files/recent.json '{{'
plant "sessions/$CSID/composer.json" 'nope'
printf 'garbage' >"$DC/d/quota.json"
printf 'garbage' >"$DC/d/hooks/$HSID.json"
PORT_DC="$(port_of dc)"
printf '{"port":%s,"token":"not-a-token","v":1}\n' "$PORT_DC" >"$DC/d/config.json"
chmod 600 "$DC/d/config.json"
run_app D2 dc1 dc 14
D="$ROOT/dc1.json"
for f in layout.json preferences.json profiles.json cleanup.json files/recent.json "sessions/$CSID/composer.json"; do
    check "D2 $f moved to <name>.corrupt-<ms> with the planted bytes" planted_aside "$DC/d/$f" "$DC/planted/${f//\//_}"
    check "D2 $f: a corrupt issue naming the file and its aside" jtrue "$D" \
        "(lambda i: i is not None and i['aside'].startswith(a[0] + '.corrupt-') and i['message'].startswith(a[0] + ' 無法讀取，已移到 '))(issue(a[0], 'corrupt'))" "$f"
done
check "D2 defaults used: an empty sidebar, preferences loaded" jtrue "$D" "d.get('loaded') is True and d.get('projects') == [] and (d.get('preferences') or {}).get('loaded') is True"
check "D2 one banner per corrupt file (shown + queued)" jtrue "$D" "DF()['bannersShown'] >= 1 and DF()['bannersShown'] + DF()['bannersQueued'] >= 6"
check "D2 quota.json and the hooks record removed, no banner for them" jtrue "$D" \
    "pf('quota.json')['status'] == 'removed' and pf('hooks/' + a[0] + '.json')['status'] == 'removed' and issue('quota.json') is None and issue('hooks/' + a[0] + '.json') is None" "$HSID"
dc_derived_gone() { [[ -z "$(aside_of "$DC/d/quota.json")" && -z "$(aside_of "$DC/d/hooks/$HSID.json")" && ! -e "$DC/d/hooks/$HSID.json" ]]; }
check "D2 no aside for quota.json or the hooks record" dc_derived_gone
dc_config_kept() {
    [[ "$(port_of dc)" == "$PORT_DC" ]] && [[ -z "$(aside_of "$DC/d/config.json")" ]] \
        && ls "$DC/d"/config.json.invalid-* >/dev/null 2>&1 && jtrue "$ROOT/dc1.json" "issue('config.json') is None"
}
check "D2 config.json repaired in place: port kept, never moved aside (the store's .invalid- copy), no issue" dc_config_kept
check "D2 log: the preflight moved 6 files and removed 2" matches "$ROOT/dc1.log" "data preflight .*corrupt=6 removed=2"
end_holders dc

# ds: a layout.json the preflight reads but LayoutStore rejects (a member holding 1e999, a number no
# Swift type holds: the preflight's top-level scan skips it, JSONValue.parse fails on it; an unpaired
# surrogate escape is no good here, JSONValue.parse repairs it), and a preferences.json with a string
# version (its store repairs it: never moved).
setup_group ds
DS="$G"
mkdir -p "$DS/planted"
printf '%s' '{"version":1,"groups":[],"projects":[],"sessions":[],"note":1e999}' >"$DS/d/layout.json"
cp "$DS/d/layout.json" "$DS/planted/layout.json"
printf '%s' '{"version":"1"}' >"$DS/d/preferences.json"
run_app D2 ds1 ds 14
D="$ROOT/ds1.json"
check "D2 the preflight reads the shape-corrupt layout.json as current (never stricter)" jtrue "$D" "pf('layout.json')['status'] == 'current'"
check "D2 LayoutStore moved it aside itself, with the planted bytes" planted_aside "$DS/d/layout.json" "$DS/planted/layout.json"
ds_swept() {
    matches "$ROOT/ds1.log" "data corrupt file=layout\\.json moved=layout\\.json\\.corrupt-[0-9]+ by=store" \
        && jtrue "$ROOT/ds1.json" "issue('layout.json', 'corrupt') is not None and DF()['bannersShown'] >= 1"
}
check "D2 the post-load sweep bannered it (issue + log by=store)" ds_swept
ds_prefs_kept() {
    [[ -s "$DS/d/preferences.json" && -z "$(aside_of "$DS/d/preferences.json")" ]] \
        && jtrue "$ROOT/ds1.json" "pf('preferences.json')['status'] == 'current' and issue('preferences.json') is None"
}
check "D2 preferences.json with \"version\":\"1\" is not moved (its store repairs it)" ds_prefs_kept
end_holders ds
fi

# =============================================================================================
# D3: cache/VERSION.
if sel D3; then
setup_group dk
DK="$G"
mkdir -p "$DK/d/cache"
printf '0\n' >"$DK/d/cache/VERSION"
printf 'planted\n' >"$DK/d/cache/planted.txt"
run_app D3 dk1 dk 12
cache_version() { tr -d '[:space:]' <"$1/d/cache/VERSION" 2>/dev/null; }
dk_wiped() {
    jtrue "$ROOT/dk1.json" "DF()['preflight']['cacheWiped'] is True" && contains "$ROOT/dk1.log" "file=cache/VERSION wiped found=0" \
        && [[ "$(cache_version "$DK")" == 1 ]]
}
check "D3 VERSION 0: the cache wiped, VERSION 1 written (dump, log)" dk_wiped
check "D3 the planted cache file is gone" test ! -e "$DK/d/cache/planted.txt"
dk_index() { [[ -s "$DK/d/cache/notes-index.sqlite" ]] && jtrue "$ROOT/dk1.json" "N()['index']['rebuilt'] is True"; }
check "D3 the notes index was rebuilt into cache/" dk_index
printf 'planted again\n' >"$DK/d/cache/planted2.txt"
run_app D3 dk2 dk 10
dk_kept() {
    jtrue "$ROOT/dk2.json" "DF()['preflight']['cacheWiped'] is False" && [[ -e "$DK/d/cache/planted2.txt" ]] \
        && lacks "$ROOT/dk2.log" "file=cache/VERSION wiped"
}
check "D3 the next launch keeps the cache (no wipe, the new file kept)" dk_kept
end_holders dk

setup_group dv
DV="$G"
mkdir -p "$DV/d/cache"
printf 'post-M4 cache\n' >"$DV/d/cache/planted.txt"
run_app D3 dv1 dv 10
dv_written() {
    [[ -e "$DV/d/cache/planted.txt" && "$(cache_version "$DV")" == 1 ]] \
        && jtrue "$ROOT/dv1.json" "DF()['preflight']['cacheWiped'] is False" && matches "$ROOT/dv1.log" "file=cache/VERSION written"
}
check "D3 a cache without VERSION keeps its file and gains VERSION 1 (no wipe)" dv_written
end_holders dv
fi

# =============================================================================================
# K1: the built bundle.
if sel K1; then
BUNDLE="${APP%/Contents/MacOS/*}"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$BUNDLE/Contents/Info.plist" 2>/dev/null; }
check "K1 CFBundleIdentifier app.codd.CODD" test "$(plist CFBundleIdentifier)" == "app.codd.CODD"
check "K1 CFBundleShortVersionString = VERSION ($VERSION_TEXT), CFBundleVersion a number" bash -c \
    "[[ \"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '$BUNDLE/Contents/Info.plist')\" == '$VERSION_TEXT' ]] && [[ \"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '$BUNDLE/Contents/Info.plist')\" =~ ^[0-9]+\$ ]]"
for helper in codd-holder codd-hook codd-statusline; do
    check "K1 $helper signed app.codd.$helper" test "$(codesign -d --verbose=1 "$BUNDLE/Contents/MacOS/$helper" 2>&1 | sed -n 's/^Identifier=//p')" == "app.codd.$helper"
done
# The legacy id, assembled so the copy audit's F rule never sees it spelled out (CoddIdentity has it).
LEGACY_WORD="fancy""codd"
LEGACY_ID="app.$LEGACY_WORD.CODD"
legacy_strings() {
    local f bad=0 lines
    for f in "$BUNDLE"/Contents/MacOS/*; do
        [[ -f "$f" ]] || continue
        lines="$(strings -a "$f" 2>/dev/null | grep -F "$LEGACY_WORD" | sort -u)"
        [[ -n "$lines" ]] && echo "$lines" | sed "s|^|E2E   $(basename "$f"): |"
        if [[ -n "$lines" ]] && printf '%s\n' "$lines" | grep -vqxF -e "$LEGACY_ID" -e "$LEGACY_ID.showMainWindow"; then bad=1; fi
    done
    [[ $bad == 0 ]]
}
check "K1 the binaries name the legacy id only as the legacy constant" legacy_strings
fi

# =============================================================================================
# S1: stop while STARTING (D20).
if sel S1; then
setup_group st
ST="$G"
run_app S1 st1 st 12 -codd-new-claude "$ST/work" -codd-stop-after-create YES
STID="$(grep -o 'stop deferred session=[^ ]*' "$ROOT/st1.log" | head -1 | sed 's/stop deferred session=//')"
check "S1 log: stop deferred, then stop applied-after-spawn for the same session" bash -c \
    "[[ -n '$STID' ]] && a=\$(grep -n 'stop deferred session=$STID' '$ROOT/st1.log' | head -1 | cut -d: -f1) && b=\$(grep -n 'stop applied-after-spawn session=$STID holderPid=[0-9]' '$ROOT/st1.log' | head -1 | cut -d: -f1) && [[ -n \"\$a\" && -n \"\$b\" ]] && (( a < b ))"
# As for any stop of a running claude: the holder's SIGHUP ends the child, the EXIT frame drives EXITED
# (with RESUME); STOPPED when the holder vanished without one. Either way it is no longer live.
check "S1 the session ends as for any stop (EXITED, or STOPPED), not live" jtrue "$ROOT/st1.json" \
    "S(a[0]) is not None and S(a[0])['state'] in ('exited', 'stopped')" "$STID"
check "S1 no holder left within 5 s" wait_for 5 holders_gone st
end_holders st
fi

# =============================================================================================
# A1: the accessibility audit in mock mode (D21).
if sel A1; then
mkdir -p "$ROOT/a1"
RUNS+=("a1")
perl -e 'alarm shift; exec @ARGV' 300 "$APP" -codd-mock -codd-a11y-audit "$ROOT/a1/a11y.json" -codd-full-keyboard-access YES \
    -codd-login-env NO -codd-notifications NO -codd-quit-after 240 >"$ROOT/a1.log" 2>&1
A1_STATUS=$?
echo "E2E a1 exit=$A1_STATUS log=$ROOT/a1.log"
grep -E '^A11Y screens=' "$ROOT/a1.log" | sed 's/^/E2E   /'
check "A1 the audit exited 0 (nothing unlabeled)" test "$A1_STATUS" == 0
check "A1 a11y.json: 0 unlabeled over every screen, onboarding 1-6 included" pyok '
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
names = [r["screen"] for r in s["screens"]]
ok = s["unlabeled"] == 0 and all(len(r["unlabeled"]) == 0 for r in s["screens"]) and len(names) >= 30
ok = ok and all(any(n == "onboarding-%d" % i or n.startswith("onboarding-%d " % i) for n in names) for i in range(1, 7))
sys.exit(0 if ok else 1)' "$ROOT/a1/a11y.json"
OUTSIDE="$(jexpr "$ROOT/a1/a11y.json" "d['outsideKeyLoop']")"
echo "E2E number A1 outsideKeyLoop=${OUTSIDE:-?} (report only)"
check "A1 the summary line names the same totals" bash -c "grep -qE '^A11Y screens=[0-9]+ unlabeled=0 outsideKeyLoop=${OUTSIDE:-x}\$' '$ROOT/a1.log'"
fi

# =============================================================================================
# C1: the copy audit and the release dry run (no CODD launch).
if sel C1; then
"$PY" -I scripts/tools/copy-audit.py >"$ROOT/copy-audit.txt" 2>&1
COPY_STATUS=$?
tail -1 "$ROOT/copy-audit.txt" | sed 's/^/E2E   /'
check "C1 copy-audit.py exits 0" test "$COPY_STATUS" == 0
check "C1 copy-audit: failing=0" matches "$ROOT/copy-audit.txt" "^COPY findings=[0-9]+ failing=0 "
scripts/release.sh --dry-run >"$ROOT/release-dry.txt" 2>&1
REL_STATUS=$?
grep '^RELEASE dry-run' "$ROOT/release-dry.txt" | sed 's/^/E2E   /'
check "C1 release.sh --dry-run exits 0" test "$REL_STATUS" == 0
check "C1 release.sh --dry-run: bundle=app.codd.CODD version=$VERSION_TEXT" matches "$ROOT/release-dry.txt" \
    "^RELEASE dry-run .* version=${VERSION_TEXT//./\\.} build=[0-9]+ .*bundle=app\\.codd\\.CODD "
check "C1 release.sh --dry-run built nothing (no build/release created by it)" bash -c "grep -q '(nothing was built)' '$ROOT/release-dry.txt'"
fi

# =============================================================================================
if sel I1 && (( ${#RUNS[@]} == 0 )); then echo "E2E skip I1 (no run to scan: select it with other sections or run everything)"; fi
if sel I1 && (( ${#RUNS[@]} > 0 )); then
ALL_LOGS=(); ALL_DUMPS=()
for r in "${RUNS[@]}"; do ALL_LOGS+=("$ROOT/$r.log"); [[ -e "$ROOT/$r.json" ]] && ALL_DUMPS+=("$ROOT/$r.json"); done
[[ ${#ALL_DUMPS[@]} -gt 0 ]] || ALL_DUMPS=(/dev/null)
EXECS="$(cat "${ALL_LOGS[@]}" 2>/dev/null | grep -oE 'exec [a-z-]+ path=[^ ]* sub=[^ ]*' | sed "s|$ROOT|<tmp>|; s|$ROOTV|<tmp>|" | sort | uniq -c | sort -rn)"
echo "E2E exec lines:"; echo "$EXECS" | sed 's/^/E2E   /'
exec_inside() {
    local paths
    paths="$(cat "${ALL_LOGS[@]}" 2>/dev/null | grep -oE 'exec [a-z-]+ path=[^ ]*' | sed 's/.* path=//')"
    if [[ -z "$paths" ]]; then [[ -n "$ONLY" ]]; return; fi   # (a targeted run may start no tool at all)
    ! printf '%s\n' "$paths" | grep -vE "^($ROOT|$ROOTV)/" | grep -q .
}
check "I1 every exec line (the fake claude, the fake cswap) names a path inside the temp folder" exec_inside
check "I1 no defaults migration line in any log (non-standard roots never migrate, D2)" bash -c \
    "! grep -l 'defaults migrat' ${ALL_LOGS[*]} 2>/dev/null | grep -q ."
d25_all() {
    local f
    for f in "${ALL_DUMPS[@]}"; do
        [[ "$f" == /dev/null ]] && continue
        jtrue "$f" "B()['autosavesLayout'] is False and B()['legacyDefaults'] == 'notApplicable' and B()['id'] == 'app.codd.CODD' and B()['version'] == a[0]" "$VERSION_TEXT" || return 1
    done
}
check "I1 every dump: bundle app.codd.CODD at VERSION, no frame / split / status item autosave (D25), no defaults copy" d25_all
check "I1 no fixture e-mail (example.com) in any dump or app log" bash -c \
    "! grep -lF -e 'example.com' -e 'example-com' ${ALL_DUMPS[*]} ${ALL_LOGS[*]} 2>/dev/null | grep -q ."
check "I1 no anthropic.com in any dump or app log" bash -c "! grep -liF 'anthropic.com' ${ALL_DUMPS[*]} ${ALL_LOGS[*]} 2>/dev/null | grep -q ."
check "I1 no new \$HOME/.claude.json.codd-bak-* or ~/.claude/settings.json.codd-bak-* (names only)" test "$(home_backups)" == "$HOME_BACKUPS_BEFORE"
fi

echo "E2E time $((SECONDS - STARTED)) s"
echo "E2E leftover processes before cleanup: $( (pgrep -f "$ROOT/"; pgrep -f "$ROOTV/") 2>/dev/null | sort -u | wc -l | tr -d ' ')"
nothing_left() { ! ours_left; }
check "every app of the run quit and every holder ended (no process carries the temp folder)" wait_for 5 nothing_left
echo "E2E pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

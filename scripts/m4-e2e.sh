#!/bin/bash
# M4 end-to-end test (docs/M4-PLAN.md §10 I4b, B1-B13, plus the 2026-10-18 user feedback U1 / U2):
# the real CODD.app (DEBUG build), real codd-holder, the real hook server with its M4 routes
# (`/mcp`, `/hooks/prompt`, `/n/<id>.md`), real git (read only, on a fixture repo), the C11 fakes
# only (scripts/m4-fixtures: fake claude m4 with MCP / prompt hooks / tool edits / print mode,
# mcp-client.py; scripts/m3-fixtures: fake cswap). No Anthropic call, no real claude, no real
# cswap, never ~/.claude, ~/.claude.json, ~/.codex or the real data root.
#
# Isolation: one mktemp folder in the per-user temp folder; inside it one group folder per scenario
# group (one or two letters: holder sockets must stay under 104 bytes) with its own data root
# (scripts/m2-fixtures/make-root.sh: own hook port in 43000-43999, own token), its own Claude
# directory (`home/.claude`, so `<claudeDir>/../.claude.json` is `home/.claude.json`), its own trash
# folder (-codd-trash-dir on every launch), its own copies of the fakes with `.env` sidecars, and
# its own work folder. No login-shell capture, notifications off, shells are `/bin/zsh -f`. Every
# launch passes each CODD flag as its own argument and stays in the background
# (CODD_BACKGROUND=1). Every process it starts carries the folder in its argv; the cleanup sends
# SIGCONT, SIGTERM, then SIGKILL to `pkill -f "<tmp>/"` only (also the `/var/…` spelling CODD's
# standardized paths use), and removes the folder unless KEEP=1. The one link that points outside
# (B8, `realclaudejson -> ~/.claude.json`, to prove the registration guard) is only ever resolved by
# CODD's guard, never read or written through; `rm -rf` removes the link, not its target.
#
#   scripts/m4-e2e.sh            # build first: xcodegen generate && xcodebuild … -derivedDataPath build/dd build
#   CODD_APP=/path/CODD.app/Contents/MacOS/CODD KEEP=1 scripts/m4-e2e.sh   # keep the temp folder
#   ONLY=B1,B3 scripts/m4-e2e.sh # only these sections (ids B1..B13, U1, U2, comma separated; unset = all,
#                                # same output and exit codes as before). Unselected sections print
#                                # `E2E skip <id>`; their groups and launches do not run. Shared groups run
#                                # what a selected section needs (B3/B4/B5 share the m1 launch, B10 re-runs
#                                # B9's t0/t1 launches because the digest counts depend on them); a check of
#                                # an unselected section inside a launch that does run is evaluated silently
#                                # (not counted). B12 (isolation) scans only the runs that happened, so it is
#                                # meant for the full run. An unknown id exits 64 with the valid ids.
#
# Groups (each run is a separate app launch with -codd-quit-after and -codd-dump-state):
#   B1   notes storage: the make-notes fixture's counts and searches (打卡 / 打卡頁 / #rwd),
#        cache/notes-index.sqlite created (an M4 index next to notes/ removed), deleted → rebuilt
#        (missing), garbage bytes → rebuilt (corrupt),
#        an external create / edit / delete while running reflected within 3 s, no .md outside notes/;
#   B2   editor: -codd-notes-new + -codd-notes-type → the D3 file name; a 4000 × 3000 paste → the
#        asset at 2576 and its Markdown line; -codd-notes-annotate → the block + its burned-in copy
#        in cache/annotated/ (never beside the asset);
#   B3   MCP: one fake claude m4 session runs the session MCP script (discover -32601, initialize
#        2025-11-25, 4 tools, search 打卡, read with the annotation list and one image, append on the
#        APPEND note with history + activity, refused on a READ note, OFF and trashed reads isError),
#        the OFF note in no MCP answer; mcp.clients = 1; external token 200, wrong token 401, foreign
#        Origin 403; note URL 200, wrong t 404, OFF note 404; notes_write listed with AI 可寫入;
#   B4   prompt expansion: systemMessage + additionalContext for a ref, the OFF refusal without its
#        title, 204 without a ref, the last prompt still recorded;
#   B5   per-session config: --mcp-config right before --settings, mcp.json 0600 with the derived
#        token, /hooks/prompt + allow rules, a foreign `codd` → `codd-desktop`, autoAttachMCP off →
#        neither file nor route;
#   B6   send to session: submit (paste + submit in the fake's stdin log), ref (composer draft),
#        refused while WAITING, a PROMPT gets `sent`;
#   B7   file editor on the fixture repo: git facts, encodings, dirty → banner with the session,
#        clean → reload, AI touch, SHOW AI CHANGES one hunk @@ -40,2 +40,4 @@, revert + save = HEAD,
#        CRLF / BOM / Big5 saved byte for byte, .git/index untouched, nothing written without ⌘S;
#   B8   registration on a make-claude-json.sh file: masked diff, apply with backup and only
#        mcpServers changed, a change outside mcpServers during the apply delay kept (rebase), no lock
#        left, remove → original bytes, rotation, a link to $HOME/.claude.json refused before reading;
#   B9   retention: the first run on a fresh root archives nothing and records firstRunAt; then
#        notes archived / kept / purged into the trash folder with a tombstone, a stopped session
#        archived and an old ring trashed;
#   B10  cleanup counts, `保留 30 天`, the Monday digest recorded once, none with < 5 candidates;
#   B11  condense with the fake claude -p: D32's exact argv, no CODD tokens in its environment, the
#        notes' text on stdin (the long note's old sections only, no OFF note), summary + archived
#        sources, the long note unchanged, the run folder gone; a pinned cswap account sets
#        CLAUDE_CONFIG_DIR (printed `set` only);
#   U1   sidebar drag and drop (user feedback): the DEBUG drag self-test through the outline's own
#        drop path, the order after a relaunch, folders dropped as projects;
#   U2   interface zoom (user feedback): ⌘+ twice persisted, applied after a relaunch;
#   B13  numbers: 1,000-note index build, search p95 (1 / 2 / 3 characters), note open, notes_read
#        with / without images, prompt expansion, 1 MB / 10 MB file open, idle CPU with the Notebook
#        and the Files mode shown (3 silent fake claudes), footprint;
#   B12  isolation over every run: exec paths, anthropic.com, tokens in dumps / logs, trash and
#        pasteboard targets, $HOME backups, the ~/.codex/config.toml fingerprint, a source grep for
#        .codex writes, no stray .md files.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

# ONLY=<ids>: section selection (see the header). Validated before anything else happens.
ALL_IDS="B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12 B13 U1 U2"
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
# SECT: the section ids the launch being run belongs to; labels that do not start with an id
# ("n1 quit by itself") are attributed to them. Empty = always counted.
SECT=""
check_selected() {
    local id="${1%% *}" s
    case " $ALL_IDS " in *" $id "*) sel "$id"; return ;; esac
    for s in $SECT; do sel "$s" && return 0; done
    [[ -z "$SECT" ]]
}

# Digest periods (Monday 09:00) and note dates are local: pin the zone the fixtures use.
export TZ=Asia/Taipei
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
FIX4="$REPO/scripts/m4-fixtures"
PY=/usr/bin/python3
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
T="$(mktemp -d "${TMPDIR%/}/codd-m4e.XXXXXX")" || { echo "E2E mktemp failed" >&2; exit 2; }
ROOT="$(cd "$T" && pwd -P)" || exit 2
case "$ROOT" in
    /*/codd-m4e.??????) ;;
    *) echo "E2E unexpected temp folder '$ROOT'" >&2; exit 2 ;;
esac
# CODD standardizes some paths (`/private/var/…` → `/var/…`): processes and log lines may use it.
ROOTV="${ROOT#/private}"
PASS=0
FAIL=0
APP_PID=""
APP_NAME=""
RUNS=()
SECRETS="$ROOT/secrets.txt"
: >"$SECRETS"
chmod 600 "$SECRETS"
# Every .md a fixture put into a work folder (B12: the runs add none).
MDBASE="$ROOT/work-md-baseline.txt"
: >"$MDBASE"

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

check() {
    local what="$1"; shift
    # A check of an unselected section is run silently: its waits still gate the checks after it,
    # nothing is counted or printed.
    if ! check_selected "$what"; then "$@" >/dev/null 2>&1; return 0; fi
    if "$@"; then
        PASS=$((PASS + 1)); echo "E2E ok   $what"
    else
        FAIL=$((FAIL + 1)); echo "E2E FAIL $what"
    fi
}
number() { echo "E2E number $*"; }
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
matches() { grep -qE -- "$2" "$1" 2>/dev/null; }
count_of() { grep -cF -- "$2" "$1" 2>/dev/null || true; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
fsub() { "$PY" -I -c 'import sys; print("%.2f" % (float(sys.argv[1]) - float(sys.argv[2])))' "$1" "$2"; }
fle() { "$PY" -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$1" "$2" 2>/dev/null; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -c1-64; }
# stamp <file>: size, mtime (ns) and inode.
stamp() { "$PY" -I -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_size, s.st_mtime_ns, s.st_ino)' "$1" 2>/dev/null; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
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
    def claudes(): return [s for s in d.get("sessions", []) if s.get("kind") == "claude" and not s.get("external")]
    def N(): return d.get("notes") or {}
    def M(): return d.get("mcp") or {}
    def F(): return d.get("files") or {}
    def TAB(title): return next((t for t in F().get("tabs", []) if t.get("title") == title), None)
    def RET(): return d.get("retention") or {}
    def CL(): return d.get("cleanup") or {}
    def REG(): return (d.get("registration") or {}).get("claudeCode") or {}
    def Z(): return d.get("zoom") or {}
    def posted(kind=None): return [p for p in (d.get("notifications") or {}).get("posted", []) if kind is None or p.get("kind") == kind]
    def side(): return d.get("sidebar") or {}
    def P(cwd): return next((p for p in d.get("projects", []) if rp(p.get("cwd")) == rp(cwd)), None)
    def order():
        out = []
        for g in d.get("groupsInfo", []):
            gid = None if g.get("ungrouped") else g["id"]
            ps = [p for p in d.get("projects", []) if p.get("group") == gid]
            out.append(g["id"] + "[" + ",".join(p["id"] + "(" + ",".join(p.get("sessions", [])) + ")" for p in ps) + "]")
        return " ".join(out)
    v = eval(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}
jtrue() { [[ "$(jexpr "$@")" == True ]]; }

# jl <jsonl file> <python expression> [args…]: the same over a JSON-lines file (mcp-client.py, the
# fake's prompt / stdin logs). `L` = the parsed lines, `R(label)` = the first line with that label,
# `text(r)` = its tool result text, `err(r)` = isError, `imgs(r)` = image blocks, `tools(r)` = tool names.
jl() {
    "$PY" -I - "$@" 2>/dev/null <<'PY'
import json, sys
try:
    L = []
    try:
        with open(sys.argv[1], encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    L.append(json.loads(line))
    except FileNotFoundError:
        pass  # nothing logged (e.g. no input reached the fake's stdin)
    a = sys.argv[3:]
    def R(label): return next((r for r in L if r.get("label") == label), None)
    def result(r): return ((r or {}).get("body") or {}).get("result") or {}
    def content(r): c = result(r).get("content"); return c if isinstance(c, list) else []
    def text(r): return "".join(c.get("text") or "" for c in content(r) if c.get("type") == "text")
    def err(r): return bool(result(r).get("isError"))
    def imgs(r): return [c for c in content(r) if c.get("type") == "image"]
    def tools(r): return sorted(t.get("name") for t in result(r).get("tools") or [])
    def dumps(x): return json.dumps(x, ensure_ascii=False)
    v = eval(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}
jltrue() { [[ "$(jl "$@")" == True ]]; }

# setup_group <name>: a data root, a home with .claude, the fakes with sidecars, a work folder. Sets G.
setup_group() {
    local name="$1"
    G="$ROOT/$name"
    mkdir -p "$G/bin" "$G/work" "$G/fakelog" "$G/trash" "$G/out" "$G/home/.claude/sessions" "$G/home/.claude/projects"
    "$FIX2/make-root.sh" "$G/d" >"$G/root.txt" || { echo "E2E make-root failed ($name)" >&2; exit 2; }
    chmod 600 "$G/root.txt"
    cp "$FIX4/fake-claude-m4.sh" "$G/bin/fake-claude"
    cp "$FIX4/mcp-client.py" "$G/bin/mcp-client.py"
    chmod 755 "$G/bin/fake-claude" "$G/bin/mcp-client.py"
    fake_env "$name"
    echo "E2E group $name root=$G"
}
port_of() { jexpr "$ROOT/$1/d/config.json" "d['port']"; }
# fake_env <group> [KEY=VALUE…]: (re)writes the fake claude's sidecar; silent status line.
fake_env() {
    local g="$ROOT/$1"; shift
    { printf 'FAKE_REGISTRY_DIR=auto\nFAKE_DEFAULT_CLAUDE_DIR=%s\nFAKE_LOG_DIR=%s\nFAKE_STATUSLINE_INTERVAL_MS=0\n' \
          "$g/home/.claude" "$g/fakelog"
      for kv in "$@"; do printf '%s\n' "$kv"; done; } >"$g/bin/fake-claude.env"
}
# cswap_setup <group>: the M3 fake cswap and its state (#1 #2 #3, #3 active, #2 with a profile).
cswap_setup() {
    local g="$ROOT/$1"
    "$FIX3/make-cswap-state.sh" "$g/home/.claude-swap-backup" "$g/home/.claude" >/dev/null \
        || { echo "E2E make-cswap-state failed ($1)" >&2; exit 2; }
    cp "$FIX3/fake-cswap.py" "$g/bin/cswap"
    chmod 755 "$g/bin/cswap"
    printf 'FAKE_CSWAP_ROOT=%s\nFAKE_CSWAP_LOG=%s\n' "$g/home/.claude-swap-backup" "$g/cswap-calls.jsonl" >"$g/bin/cswap.env"
}

# start_app <name> <group> <seconds> [flags…]: runs in the background; the dump is $ROOT/<name>.json
# (none with NODUMP=1), the log $ROOT/<name>.log. Later flags win.
start_app() {
    local name="$1" g="$ROOT/$2" seconds="$3"; shift 3
    # (bash 3.2 with `set -u` refuses an empty "${a[@]}": the dump flag is a pair, or a repeat of the quit flag.)
    local dump=(-codd-dump-state "$ROOT/$name.json")
    [[ "${NODUMP:-0}" == 1 ]] && dump=(-codd-quit-after "$seconds")
    rm -f "$ROOT/$name.json"
    now_ms >"$ROOT/$name.start"
    perl -e 'alarm shift; exec @ARGV' 150 "$APP" -codd-data-root "$g/d" -codd-claude-dir "$g/home/.claude" \
        -codd-claude-path "$g/bin/fake-claude" -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO \
        -codd-trash-dir "$g/trash" -codd-quit-after "$seconds" "${dump[@]}" "$@" >"$ROOT/$name.log" 2>&1 &
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
# run_app <name> <group> <seconds> [flags…]: start_app, wait, and check that it quit by itself.
run_app() {
    start_app "$@"
    check "$1 quit by itself" wait_app
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
holder_count() { pgrep -f "$ROOT/$1/d/bin/codd-holder-" 2>/dev/null | wc -l | tr -d ' '; }
# fake_pid <run> <group> [interactive|print]: the pid of the first fake claude of that mode that
# started after the run began (its FAKE_LOG_DIR json's startedAt).
fake_pid() {
    "$PY" -I - "$ROOT/$2/fakelog" "$(cat "$ROOT/$1.start" 2>/dev/null || echo 0)" "${3:-interactive}" 2>/dev/null <<'PY'
import glob, json, os, sys
best = None
for p in glob.glob(os.path.join(sys.argv[1], "fake-*.json")):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        continue
    if d.get("mode") != sys.argv[3] or int(d.get("startedAt") or 0) < int(sys.argv[2]):
        continue
    if best is None or d["startedAt"] < best["startedAt"]:
        best = d
print(best["pid"] if best else "")
PY
}
# fake_files <run> <group> [mode]: FL / FJ = that run's fake claude log / json.
fake_files() {
    local pid
    pid="$(fake_pid "$@")"
    FL="$ROOT/$2/fakelog/fake-${pid:-none}.log"
    FJ="$ROOT/$2/fakelog/fake-${pid:-none}.json"
}
# fake_wait <seconds> <run> <group> <line prefix>: waits for that run's fake to print the line.
fake_has() { local pid; pid="$(fake_pid "$1" "$2")"; [[ -n "$pid" ]] && grep -q -- "^$3" "$ROOT/$2/fakelog/fake-$pid.log" 2>/dev/null; }
fake_wait() { local s="$1"; shift; wait_for "$s" fake_has "$@"; }
# session_cfg <group> <session id>: that session's mcp.json (the X-CODD-Session header matches).
session_cfg() {
    "$PY" -I - "$ROOT/$1/d/sessions" "$2" 2>/dev/null <<'PY'
import glob, json, os, sys
for p in glob.glob(os.path.join(sys.argv[1], "*", "mcp.json")):
    try:
        with open(p, encoding="utf-8") as f:
            servers = json.load(f)["mcpServers"]
    except Exception:
        continue
    for entry in servers.values():
        if str((entry.get("headers") or {}).get("X-CODD-Session", "")).lower() == sys.argv[2].lower():
            print(p)
            sys.exit(0)
PY
}
# note_file <notesDir> <id>: the active note file whose frontmatter says `id: <id>`.
note_file() { grep -l -- "^id: $2\$" "$1"/*.md "$1"/*/*.md 2>/dev/null | grep -v '/\.codd/' | head -1; }
# secret <value>: remembered for the B12 token checks (the file never goes into a check's input).
secret() { [[ -n "$1" ]] && printf '%s\n' "$1" >>"$SECRETS"; }
client() { "$PY" -I "$ROOT/$1/bin/mcp-client.py" "${@:2}"; }
# png_size <file>: "<w>x<h>" from sips.
png_size() { sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }

# Before / after facts for B12 (names and stat only; never a listing of ~/.claude or its contents).
home_backups() {
    { find "$HOME" -maxdepth 1 -name '.claude.json.codd-bak-*' 2>/dev/null
      [[ -d "$HOME/.claude" ]] && find "$HOME/.claude" -maxdepth 1 -name 'settings.json.codd-bak-*' 2>/dev/null; } | sort
}
codex_stamp() { [[ -e "$HOME/.codex/config.toml" ]] && stat -f '%z %m' "$HOME/.codex/config.toml" 2>/dev/null || echo "absent"; }
HOME_BACKUPS_BEFORE="$(home_backups)"
CODEX_BEFORE="$(codex_stamp)"
NOW=2026-10-17T10:00:00+08:00
STARTED=$SECONDS

echo "E2E root=$ROOT app=$APP"
for _id in $ALL_IDS; do sel "$_id" || echo "E2E skip $_id"; done

# =============================================================================================
# Group n: notes storage (B1), editor, paste, annotate (B2).
if sel B1 || sel B2; then
setup_group n
NG="$ROOT/n"
NOTES="$NG/d/notes"
bash "$FIX4/make-notes.sh" "$NOTES" --project "$NG/work" --manifest "$NG/notes.json" >"$NG/ids.txt" \
    || { echo "E2E make-notes failed (n)" >&2; exit 2; }
N1="$NOTES/2026-10-15-打卡頁-rwd-跑版紀錄.md"
CJK="$NOTES/2026-10-16-注音輸入法筆記.md"

# ---------------------------------------------------------------------------------------------
if sel B1; then
SECT="B1"
# B1a. First run: the index is built (missing), the fixture's counts, search 打卡. An M4 build's
# index next to notes/ (derived data in the old place) is planted first: the launch removes it.
printf 'M4 index\n' >"$NG/d/notes-index.sqlite"
printf 'M4 wal\n' >"$NG/d/notes-index.sqlite-wal"
run_app n1 n 9 -codd-show notebook -codd-notes-search 打卡
D="$ROOT/n1.json"
check "B1 notes available, index rebuilt (reason missing), 20 indexed" jtrue "$D" \
    "N()['available'] and N()['index']['rebuilt'] is True and N()['index']['reason'] == 'missing' and N()['index']['count'] == 20"
check "B1 counts: INBOX 18, PINNED 1, PROMPTS 2, ARCHIVE 1, TRASH 1" jtrue "$D" \
    "(lambda c: (c['inbox'], c['pinned'], c['prompts'], c['archive'], c['trash']) == (18, 1, 2, 1, 1))(N()['counts'])"
check "B1 search 打卡 → rwd-punch-k7x2, cjk-search-note" jtrue "$D" \
    "N()['search']['query'] == '打卡' and sorted(N()['search']['ids']) == ['cjk-search-note', 'rwd-punch-k7x2']"
check "B1 cache/notes-index.sqlite created (not inside notes/)" bash -c "[[ -s '$NG/d/cache/notes-index.sqlite' && ! -e '$NOTES/notes-index.sqlite' ]]"
check "B1 the data root has no notes-index.sqlite (the M4 one removed, -wal too)" bash -c "! ls '$NG/d'/notes-index.sqlite* >/dev/null 2>&1"
check "B1 log: notes legacy-index removed (index and -wal)" contains "$ROOT/n1.log" "notes legacy-index removed files=notes-index.sqlite,notes-index.sqlite-wal"
check "B1 cache/ mode 0700" test "$(mode_of "$NG/d/cache")" == 700
number "B1 index build (20 fixture notes): $(jexpr "$D" "N()['index']['buildMs']") ms; search 打卡 $(jexpr "$D" "N()['search']['ms']") ms"

# B1b. Second run: up to date (no rebuild), search 打卡頁.
run_app n2 n 7 -codd-show notebook -codd-notes-search 打卡頁
D="$ROOT/n2.json"
check "B1 reopen: index up to date (not rebuilt)" jtrue "$D" "N()['index']['rebuilt'] is False and N()['index']['count'] == 20"
check "B1 search 打卡頁 → rwd-punch-k7x2 only" jtrue "$D" "sorted(N()['search']['ids']) == ['rwd-punch-k7x2']"
number "B1 reopen (index up to date): $(jexpr "$D" "N()['index']['buildMs']") ms"

# B1c. The index deleted → rebuilt (missing); search #rwd.
rm -f "$NG/d/cache/notes-index.sqlite" "$NG/d/cache/notes-index.sqlite-wal" "$NG/d/cache/notes-index.sqlite-shm"
run_app n3 n 7 -codd-show notebook -codd-notes-search "#rwd"
D="$ROOT/n3.json"
check "B1 deleted index: rebuilt, reason missing, 20 indexed" jtrue "$D" \
    "N()['index']['rebuilt'] is True and N()['index']['reason'] == 'missing' and N()['index']['count'] == 20"
check "B1 search #rwd → rwd-punch-k7x2 only" jtrue "$D" "sorted(N()['search']['ids']) == ['rwd-punch-k7x2']"

# B1d. Garbage bytes in the index → rebuilt (corrupt), counts unchanged.
rm -f "$NG/d/cache/notes-index.sqlite-wal" "$NG/d/cache/notes-index.sqlite-shm"
"$PY" -I -c 'import os,sys; open(sys.argv[1], "wb").write(os.urandom(8192))' "$NG/d/cache/notes-index.sqlite"
run_app n4 n 7 -codd-show notebook
D="$ROOT/n4.json"
check "B1 corrupted index: rebuilt, reason corrupt" jtrue "$D" "N()['index']['rebuilt'] is True and N()['index']['reason'] == 'corrupt'"
check "B1 corrupted index: counts as before (INBOX 18, TRASH 1)" jtrue "$D" "N()['counts']['inbox'] == 18 and N()['counts']['trash'] == 1"

# B1e. Another program creates, edits and deletes notes while CODD runs (D7): reflected within 3 s.
start_app n5 n 26 -codd-show notebook -codd-notes-select cjk-search-note
D="$ROOT/n5.json"
check "B1 live: the notebook is open with cjk-search-note shown, clean" wait_for 15 jtrue "$D" \
    "N()['available'] and (N()['selected'] or {}).get('id') == 'cjk-search-note' and not N()['selected']['dirty']"
sleep 1
EXT="$NOTES/2026-10-18-外部新增的筆記.md"
T0="$(now)"
printf -- '---\nid: external-e2e-x1y2\ntitle: 外部新增的筆記\nkind: note\nai: read\nscope: global\npinned: false\nstatus: active\ncreated: 2026-10-18T09:00:00+08:00\nupdated: 2026-10-18T09:00:00+08:00\n---\n# 外部新增的筆記\n\n別的程式寫進來的內容。\n' >"$EXT"
check "B1 live: an external create shows in INBOX within 3 s (19)" wait_for 3 jtrue "$D" "N()['counts']['inbox'] == 19"
number "B1 external create → INBOX: $(fsub "$(now)" "$T0") s (incl. the dump's write delay)"
T0="$(now)"
printf '\n外部程式加的一行\n' >>"$CJK"
CJK_SHA="$(sha "$CJK")"
check "B1 live: an external edit of the shown clean note reloads it within 3 s (hash, clean)" wait_for 3 jtrue "$D" \
    "N()['selected']['hash'] == a[0] and not N()['selected']['dirty'] and N()['externalReloads'] >= 1" "$CJK_SHA"
number "B1 external edit → reloaded: $(fsub "$(now)" "$T0") s"
T0="$(now)"
rm -f "$EXT"
check "B1 live: an external delete leaves INBOX within 3 s (18)" wait_for 3 jtrue "$D" "N()['counts']['inbox'] == 18"
number "B1 external delete → INBOX: $(fsub "$(now)" "$T0") s"
check "B1 live: the external changes were counted (externalEvents)" jtrue "$D" "N()['externalEvents'] >= 2"
check "n5 quit by itself" wait_app
check "B1 live: the reload never rewrote the edited file" test "$(sha "$CJK")" == "$CJK_SHA"
check "B1 log: notes external reload id=cjk-search-note" contains "$ROOT/n5.log" "notes external reload id=cjk-search-note"

# ---------------------------------------------------------------------------------------------
fi

if sel B2; then
SECT="B2"
# B2a. A new note through the editor: nothing on disk until typed, then the D3 file name.
ls "$NOTES"/*.md | sort >"$NG/md-before.txt"
run_app n6 n 9 -codd-notes-new "E2E 新筆記" -codd-notes-type "第一行內容\n第二行"
ls "$NOTES"/*.md | sort >"$NG/md-after.txt"
NEW_MD="$(comm -13 "$NG/md-before.txt" "$NG/md-after.txt")"
echo "E2E new note file: $(basename "${NEW_MD:-none}")"
check "B2 exactly one new note file" test "$(printf '%s\n' "$NEW_MD" | grep -c .)" == 1
check "B2 its name is the D3 form YYYY-MM-DD-e2e-新筆記.md" bash -c "basename '$NEW_MD' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-e2e-新筆記\.md$'"
check "B2 the typed text is in it, with an id in the frontmatter" bash -c "grep -q '第二行' '$NEW_MD' && grep -qE '^id: e2e-[a-z0-9]{4}$' '$NEW_MD'"
check "B2 dump: quickNote kind note with its id" jtrue "$ROOT/n6.json" "N()['quickNote']['kind'] == 'note' and N()['quickNote']['id'] is not None"
check "B2 new note file mode 0600" test "$(mode_of "$NEW_MD")" == 600

# B2b. A 4000 × 3000 screenshot pasted into n1: the asset at 2576 × 1932 and its Markdown line.
"$PY" -I "$FIX4/make-png.py" "$NG/work/big.png" 4000 3000 >/dev/null || exit 2
run_app n7 n 10 -codd-notes-select rwd-punch-k7x2 -codd-notes-paste-image "$NG/work/big.png"
D="$ROOT/n7.json"
ASSET="$(jexpr "$D" "N()['lastPaste']['asset']")"
echo "E2E pasted asset=$ASSET bytes=$(jexpr "$D" "N()['lastPaste']['bytes']")"
check "B2 paste: resized, under assets/rwd-punch-k7x2/<hash6>.png" bash -c \
    "[[ '$(jexpr "$D" "N()['lastPaste']['resized']")' == True ]] && [[ '$ASSET' =~ ^assets/rwd-punch-k7x2/[0-9a-f]{6,}\.png$ ]]"
check "B2 paste: the asset is 2576 × 1932" test "$(png_size "$NOTES/${ASSET:-none}")" == "2576x1932"
check "B2 paste: n1 has the ![截圖 yyyy-MM-dd HH:mm](asset) line" pyok '
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
sys.exit(0 if re.search(r"!\[截圖 \d{4}-\d{2}-\d{2} \d{2}:\d{2}\]\(" + re.escape(sys.argv[2]) + r"\)", t) else 1)' "$N1" "$ASSET"
check "B2 paste: asset file mode 0600" test "$(mode_of "$NOTES/${ASSET:-none}")" == 600

# B2c. The ImageAnnotate 完成 path: the codd-annotations block and the burned-in copy.
cat >"$NG/work/ann.json" <<'JSON'
{"v":1,"image":"assets/rwd-punch-k7x2/9f3a1c.png","size":[750,1334],"items":[{"n":1,"type":"rect","x":20,"y":1150,"w":710,"h":120,"note":"e2e：按鈕被底部導覽列蓋住"},{"n":2,"type":"point","x":375,"y":330,"note":"e2e：時鐘太大"},{"n":3,"type":"text","x":40,"y":80,"note":"e2e 文字","color":"cyan"}],"send":{"original":false,"annotated":true,"list":true}}
JSON
rm -rf "$NG/d/cache/annotated"
run_app n8 n 9 -codd-notes-annotate "rwd-punch-k7x2:9f3a1c.png:$NG/work/ann.json"
check "B2 annotate: the block in n1 (one block, the new items)" bash -c \
    "grep -q 'e2e：按鈕被底部導覽列蓋住' '$N1' && grep -q '\"color\":\"cyan\"' '$N1' && [[ \$(grep -c '^\`\`\`codd-annotations' '$N1') == 1 ]]"
ANNOTATED="$(ls "$NG/d/cache/annotated/" 2>/dev/null | grep -E '^[0-9a-f]{12}-9f3a1c\.annotated\.png$' | head -1)"
check "B2 annotate: the copy regenerated in cache/annotated/ (750 × 1334)" test "$(png_size "$NG/d/cache/annotated/${ANNOTATED:-none}")" == "750x1334"
check "B2 annotate: the dump names that copy" jtrue "$ROOT/n8.json" "N()['annotate']['lastDone']['annotatedPNG'] == a[0]" "${ANNOTATED:-none}"
check "B2 annotate: no burned-in copy anywhere in notes/" bash -c "! find '$NOTES' -name '*.annotated.*' | grep -q ."
check "B2 annotate: dump lastDone 3 items" jtrue "$ROOT/n8.json" "N()['annotate']['lastDone']['items'] == 3"
fi
SECT="B1 B2"
check "B1 no .md outside <dataRoot>/notes (data root, home, work)" bash -c \
    "! find '$NG' -name '*.md' -not -path '$NOTES/*' | grep -q ."
end_holders n
fi

# =============================================================================================
# Group m: MCP (B3), prompt expansion (B4), per-session config (B5).
if sel B3 || sel B4 || sel B5; then
SECT="B3 B4 B5"
setup_group m
MG="$ROOT/m"
MPORT="$(port_of m)"
bash "$FIX4/make-notes.sh" "$MG/d/notes" --project "$MG/work" >/dev/null || { echo "E2E make-notes failed (m)" >&2; exit 2; }
{ cat "$FIX4/mcp-script-session.jsonl"
  printf '%s\n' '{"label": "read-trashed", "tool": "notes_read", "arguments": {"ref": "trashed-idea-t3x1"}}'; } >"$MG/mcp-script.jsonl"
printf '看一下 codd://note/rwd-punch-k7x2 的問題\n這個不能看 codd://note/ai-off-note\n沒有引用的一般問題\n' >"$MG/prompts.txt"
fake_env m "FAKE_MCP_SCRIPT=$MG/mcp-script.jsonl" "FAKE_MCP_LOG=$MG/out/mcp1.jsonl" "FAKE_PROMPTS=$MG/prompts.txt" \
    "FAKE_PROMPT_DELAY_MS=500" "FAKE_PROMPT_LOG=$MG/out/prompts1.jsonl" "FAKE_STDIN_LOG=$MG/out/stdin1.jsonl"

# ---------------------------------------------------------------------------------------------
# m1. One CODD claude session: its MCP script, its prompts; then external callers and note URLs.
start_app m1 m 34 -codd-new-claude "$MG/work"
D="$ROOT/m1.json"
check "B3 the fake session finished its MCP script and prompts" fake_wait 30 m1 m "FAKE-PROMPTS-DONE"
fake_files m1 m
S_M1="$(spawned_id "$ROOT/m1.log" claude)"
echo "E2E m1 claude session=$S_M1 fake=$FL"
check "B3 dump: exactly one MCP client, the session" wait_for 10 jtrue "$D" \
    "len(M()['clients']) == 1 and M()['clients'][0]['kind'] == 'session' and M()['running'] is True"
SESSCFG="$(session_cfg m "$S_M1")"
X="$MG/out"
client m --url "http://127.0.0.1:$MPORT/mcp" --token-from-config "$MG/d/config.json" --init call tools/list >"$X/ext-ok.jsonl" 2>&1
client m --url "http://127.0.0.1:$MPORT/mcp" --token-from-config "$MG/d/config.json" --bearer --init call tools/call \
    '{"name":"notes_search","arguments":{"query":"OFF-NOTE-SECRET-42"}}' >"$X/ext-off.jsonl" 2>&1
client m --url "http://127.0.0.1:$MPORT/mcp" --header X-CODD-Token:wrong call tools/list >"$X/ext-401.jsonl" 2>&1
client m --config "${SESSCFG:-/nonexistent}" --origin http://evil.example call tools/list >"$X/ext-403.jsonl" 2>&1
client m --note-token-from-config "$MG/d/config.json" rwd-punch-k7x2 get "http://127.0.0.1:$MPORT/n/rwd-punch-k7x2.md" >"$X/url-ok.jsonl" 2>&1
client m get "http://127.0.0.1:$MPORT/n/rwd-punch-k7x2.md?t=000000000000000000000000" >"$X/url-bad.jsonl" 2>&1
client m --note-token-from-config "$MG/d/config.json" ai-off-note get "http://127.0.0.1:$MPORT/n/ai-off-note.md" >"$X/url-off.jsonl" 2>&1
client m --note-token-from-config "$MG/d/config.json" trashed-idea-t3x1 get "http://127.0.0.1:$MPORT/n/trashed-idea-t3x1.md" >"$X/url-trashed.jsonl" 2>&1
check "m1 quit by itself" wait_app
ML="$X/mcp1.jsonl"
check "B3 server/discover → JSON-RPC -32601 (legacy handshake)" jltrue "$ML" "R('discover')['body']['error']['code'] == -32601"
check "B3 initialize → protocolVersion 2025-11-25, server codd" jltrue "$ML" \
    "result(R('initialize'))['protocolVersion'] == '2025-11-25' and result(R('initialize'))['serverInfo']['name'] == 'codd'"
check "B3 notifications/initialized → 202" jltrue "$ML" "R('initialized')['status'] == 202"
check "B3 tools/list: the five tools, notes_write absent (AI 可寫入 OFF)" jltrue "$ML" \
    "tools(R('tools')) == sorted(['notes_search', 'notes_list', 'notes_read', 'notes_append', 'notes_create'])"
check "B3 notes_search 打卡 hits rwd-punch-k7x2 and cjk-search-note" jltrue "$ML" \
    "not err(R('search')) and 'rwd-punch-k7x2' in dumps(R('search')['body']) and 'cjk-search-note' in dumps(R('search')['body'])"
check "B3 notes_read rwd-punch-k7x2: the §3.7 text with the annotation list" jltrue "$ML" \
    "not err(R('read')) and '# 打卡頁 RWD 跑版紀錄' in text(R('read')) and 'annotations（原圖像素，左上為原點）:' in text(R('read')) and '1 rect' in text(R('read'))"
check "B3 notes_read rwd-punch-k7x2: one image block" jltrue "$ML" "len(imgs(R('read'))) == 1"
check "B3 notes_append on the APPEND note: ok" jltrue "$ML" "not err(R('append'))"
APPEND_NOTE="$MG/d/notes/2026-10-16-ai-附加測試.md"
check "B3 the append landed in the file with its codd:ai-append marker" bash -c \
    "grep -qF 'AI 附加的一行（fixture）' '$APPEND_NOTE' && grep -qF '<!-- codd:ai-append session=' '$APPEND_NOTE'"
check "B3 a history snapshot was taken before the append" bash -c "ls '$MG/d/notes/.codd/history/ai-append-note/' 2>/dev/null | grep -q '\.md$'"
check "B3 the append is recorded as AI activity" pyok '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
sys.exit(0 if any(r.get("note") == "ai-append-note" and r.get("action") == "append" for r in rows) else 1)' "$MG/d/notes/.codd/activity.jsonl"
check "B3 notes_append on a READ note: isError" jltrue "$ML" "err(R('append-read-note'))"
check "B3 the READ note was not changed" lacks "$MG/d/notes/2026-10-16-全域-常用指令.md" "不應該成功"
check "B3 notes_read of the OFF note: isError" jltrue "$ML" "err(R('read-off'))"
check "B3 notes_read of a trashed note: isError" jltrue "$ML" "err(R('read-trashed'))"
check "B3 resources/list: no OFF note" jltrue "$ML" "R('resources')['status'] == 200 and 'ai-off-note' not in dumps(R('resources')['body'])"
check "B3 the OFF secret and title are in no MCP answer of the session" bash -c \
    "! grep -qF 'OFF-NOTE-SECRET-42' '$ML' && ! grep -qF '不給 AI 的私人紀錄' '$ML'"
check "B3 external token (X-CODD-Token from config.json) → tools/list 200" jltrue "$X/ext-ok.jsonl" \
    "L[-1]['method'] == 'tools/list' and L[-1]['status'] == 200 and 'notes_read' in tools(L[-1])"
# The answer echoes the query (`找不到符合「OFF-NOTE-SECRET-42」的筆記。`): the secret may appear only there.
check "B3 external Bearer search for the OFF secret finds nothing" jltrue "$X/ext-off.jsonl" \
    "L[-1]['status'] == 200 and not err(L[-1]) and 'ai-off-note' not in dumps(L[-1]['body']) and text(L[-1]).startswith('找不到符合「OFF-NOTE-SECRET-42」') and 'OFF-NOTE-SECRET-42' not in text(L[-1]).replace('「OFF-NOTE-SECRET-42」', '', 1) and '不給 AI 的私人紀錄' not in dumps(L[-1]['body'])"
check "B3 a wrong token → 401" jltrue "$X/ext-401.jsonl" "L[-1]['status'] == 401"
check "B3 a foreign Origin → 403" jltrue "$X/ext-403.jsonl" "L[-1]['status'] == 403"
check "B3 note URL with its token → 200 text/markdown with the note" jltrue "$X/url-ok.jsonl" \
    "L[-1]['status'] == 200 and 'text/markdown' in L[-1]['contentType'] and '打卡頁 RWD 跑版紀錄' in dumps(L[-1]['body'])"
check "B3 note URL with a wrong t → 404" jltrue "$X/url-bad.jsonl" "L[-1]['status'] == 404"
check "B3 the OFF note's URL (right token) → 404" jltrue "$X/url-off.jsonl" "L[-1]['status'] == 404"
check "B3 a trashed note's URL → 410" jltrue "$X/url-trashed.jsonl" "L[-1]['status'] == 410"
check "B3 the OFF note never left CODD (external answers, URLs; the search's own query echo aside)" bash -c \
    "! cat '$X'/ext-*.jsonl '$X'/url-*.jsonl | sed 's/找不到符合「OFF-NOTE-SECRET-42」//g' | grep -qF -e 'OFF-NOTE-SECRET-42' -e '不給 AI 的私人紀錄' -e 'MCP、引用展開與網址都不提供'"
check "B3 activity: read, expand and url recorded" pyok '
import json, sys
acts = {(r.get("note"), r.get("action")) for r in (json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip())}
sys.exit(0 if {("rwd-punch-k7x2", "read"), ("rwd-punch-k7x2", "expand"), ("rwd-punch-k7x2", "url")} <= acts else 1)' "$MG/d/notes/.codd/activity.jsonl"
check "B3 log: mcp initialized for the session, tools logged" bash -c \
    "grep -q 'mcp initialized caller=' '$ROOT/m1.log' && grep -q 'mcp tool=notes_read outcome=' '$ROOT/m1.log'"

# B4. Prompt expansion (D19), from the fake's prompt log.
PL="$X/prompts1.jsonl"
check "B4 three prompts posted to /hooks/prompt" jltrue "$PL" "len(L) == 3 and all(r['source'] == 'file' for r in L)"
check "B4 a codd:// ref → 200 JSON, the note in additionalContext" jltrue "$PL" \
    "L[0]['status'] == 200 and L[0]['valid'] and '打卡頁 RWD 跑版紀錄' in L[0]['body']['hookSpecificOutput']['additionalContext'] and '<codd-note ref=\"codd://note/rwd-punch-k7x2\"' in L[0]['body']['hookSpecificOutput']['additionalContext'] and L[0]['body']['hookSpecificOutput']['hookEventName'] == 'UserPromptSubmit'"
check "B4 its systemMessage: codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 1 張圖片）" jltrue "$PL" \
    "L[0]['body']['systemMessage'] == 'codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 1 張圖片）'"
check "B4 the fake printed the systemMessage line" contains "$FL" "FAKE-SYSTEM-MESSAGE codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 1 張圖片）"
check "B4 an OFF ref → the refusal line, without the OFF note's title or text" jltrue "$PL" \
    "L[1]['status'] == 200 and L[1]['body']['systemMessage'] == 'codd：codd://note/ai-off-note 無法展開（AI 存取為 OFF）' and '不給 AI 的私人紀錄' not in dumps(L[1]) and 'OFF-NOTE-SECRET-42' not in dumps(L[1])"
check "B4 no ref → 204" jltrue "$PL" "L[2]['status'] == 204"
check "B4 the session's last prompt is still recorded" jtrue "$D" "S(a[0])['lastPrompt'] == '沒有引用的一般問題'" "$S_M1"
check "B4 dump promptExpansion: 2 expansions, none late" jtrue "$D" \
    "d['promptExpansion']['count'] == 2 and d['promptExpansion']['late'] == 0"
number "B4 prompt expansion round trip (the fake's POST → answer): $(jl "$PL" "L[0]['ms']") ms; server $(jexpr "$D" "d['promptExpansion']['lastMs']") ms (last)"
grep -o 'prompt-expand session=[^ ]* refs=[0-9]* expanded=[0-9]* refused=[0-9]* chars=[0-9]* ms=[0-9.]*' "$ROOT/m1.log" | sed 's/session=[^ ]* //; s/^/E2E number B4 /'

# B5. The per-session config (D18).
check "B5 argv: --mcp-config <sessionDir>/mcp.json immediately before --settings" jtrue "$FJ" \
    "(lambda i: d['argv'][i + 1].endswith('/mcp.json') and '/sessions/' in d['argv'][i + 1] and d['argv'][i + 2] == '--settings')(d['argv'].index('--mcp-config'))"
check "B5 exactly one --mcp-config, the file the fake read" jtrue "$FJ" "d['argv'].count('--mcp-config') == 1 and len(d['mcpConfigs']) == 1"
check "B5 the session's mcp.json exists, mode 0600" bash -c "[[ -n '$SESSCFG' && \$(stat -f '%Lp' '$SESSCFG') == 600 ]]"
HOOKTOKEN_M="$(jexpr "$MG/d/config.json" "d['token']")"
check "B5 mcp.json: server codd, http to /mcp, token = HMAC(hookToken, codd-mcp-v1:<uuid>)" pyok '
import hmac, hashlib, json, sys
c = json.load(open(sys.argv[1]))["mcpServers"]
e = c["codd"]; h = e["headers"]
want = hmac.new(sys.argv[2].encode(), ("codd-mcp-v1:" + h["X-CODD-Session"].lower()).encode(), hashlib.sha256).hexdigest()
sys.exit(0 if list(c) == ["codd"] and e["type"] == "http" and e["url"] == "http://127.0.0.1:%s/mcp" % sys.argv[3] and h["X-CODD-Token"] == want and h["X-CODD-Session"].lower() == sys.argv[4].lower() else 1)' \
    "${SESSCFG:-/nonexistent}" "$HOOKTOKEN_M" "$MPORT" "$S_M1"
check "B5 --settings: UserPromptSubmit → /hooks/prompt (timeout 3), other events → /hooks, the allow rules" jtrue "$FJ" \
    "(lambda s: s['hooks']['UserPromptSubmit'][0]['hooks'][0]['url'] == 'http://127.0.0.1:%s/hooks/prompt' % a[0] and s['hooks']['UserPromptSubmit'][0]['hooks'][0]['timeout'] == 3 and s['hooks']['Stop'][0]['hooks'][0]['url'] == 'http://127.0.0.1:%s/hooks' % a[0] and s['permissions']['allow'] == ['mcp__codd__notes_search', 'mcp__codd__notes_read', 'mcp__codd__notes_list'])(json.loads(d['argv'][d['argv'].index('--settings') + 1]))" \
    "$MPORT"
check "B5 the fake saw the prompt url and the allow rules" contains "$FL" \
    "FAKE-SETTINGS prompt-url=http://127.0.0.1:$MPORT/hooks/prompt allow=mcp__codd__notes_search,mcp__codd__notes_read,mcp__codd__notes_list"
check "B5 dump: the session's config (server codd, its file)" jtrue "$D" \
    "any(low(c['session']) == low(a[0]) and c['serverName'] == 'codd' and str(c['file']).endswith('/mcp.json') for c in M()['sessionConfigs'])" "$S_M1"
check "B5 dump: Claude Code not registered (no .claude.json in this home)" jtrue "$D" "M()['claudeCode'] == 'notRegistered'"
end_holders m

# ---------------------------------------------------------------------------------------------
if sel B3 || sel B5; then
SECT="B3 B5"
# m2. AI 可寫入 ON + a foreign `codd` in <claudeDir>/../.claude.json: notes_write listed, `codd-desktop`.
bash "$FIX4/make-claude-json.sh" "$MG/home/.claude.json" --codd-foreign >/dev/null || { echo "E2E make-claude-json failed" >&2; exit 2; }
cp -p "$MG/home/.claude.json" "$MG/claude.json.orig"
fake_env m "FAKE_MCP_SCRIPT=$FIX4/mcp-script-session.jsonl" "FAKE_MCP_LOG=$MG/out/mcp2.jsonl"
start_app m2 m 24 -codd-set-pref notebook.aiCanWrite=true -codd-new-claude "$MG/work"
check "B3 m2: the fake session finished its MCP script" fake_wait 30 m2 m "FAKE-MCP-DONE"
check "m2 quit by itself" wait_app
fake_files m2 m
S_M2="$(spawned_id "$ROOT/m2.log" claude)"
SESSCFG2="$(session_cfg m "$S_M2")"
check "B3 with AI 可寫入 ON tools/list adds notes_write" jltrue "$MG/out/mcp2.jsonl" \
    "tools(R('tools')) == sorted(['notes_search', 'notes_list', 'notes_read', 'notes_append', 'notes_create', 'notes_write'])"
check "B5 a foreign codd in .claude.json → the session's server is codd-desktop" pyok '
import json, sys
c = json.load(open(sys.argv[1]))["mcpServers"]
sys.exit(0 if list(c) == ["codd-desktop"] and c["codd-desktop"]["type"] == "http" else 1)' "${SESSCFG2:-/nonexistent}"
check "B5 codd-desktop: the allow rules use the resolved name" contains "$FL" \
    "allow=mcp__codd-desktop__notes_search,mcp__codd-desktop__notes_read,mcp__codd-desktop__notes_list"
check "B5 dump: sessionConfigs serverName codd-desktop" jtrue "$ROOT/m2.json" \
    "any(low(c['session']) == low(a[0]) and c['serverName'] == 'codd-desktop' for c in M()['sessionConfigs'])" "$S_M2"
check "B5 the session's .claude.json was only read (bytes unchanged, no backup)" bash -c \
    "cmp -s '$MG/home/.claude.json' '$MG/claude.json.orig' && ! ls '$MG/home' | grep -q 'codd-bak'"
end_holders m

# ---------------------------------------------------------------------------------------------
fi

if sel B5; then
SECT="B5"
# m3. 自動掛載 MCP OFF: no --mcp-config, UserPromptSubmit stays on /hooks.
printf '自動掛載關閉時的一般問題\n' >"$MG/prompts3.txt"
fake_env m "FAKE_PROMPTS=$MG/prompts3.txt" "FAKE_PROMPT_LOG=$MG/out/prompts3.jsonl"
start_app m3 m 20 -codd-set-pref notebook.autoAttachMCP=false -codd-new-claude "$MG/work"
check "B5 m3: the fake posted its prompt" fake_wait 25 m3 m "FAKE-PROMPTS-DONE"
check "m3 quit by itself" wait_app
fake_files m3 m
S_M3="$(spawned_id "$ROOT/m3.log" claude)"
check "B5 autoAttachMCP off: no --mcp-config in argv" jtrue "$FJ" "'--mcp-config' not in d['argv'] and d['mcpConfigs'] == []"
check "B5 autoAttachMCP off: UserPromptSubmit on /hooks, no allow rules" contains "$FL" "FAKE-SETTINGS prompt-url=http://127.0.0.1:$MPORT/hooks allow=-"
check "B5 autoAttachMCP off: the prompt went to /hooks (204)" matches "$FL" "^FAKE-PROMPT-HOOK 204"
check "B5 autoAttachMCP off: no mcp.json for that session" bash -c \
    "[[ -n '$S_M3' && -z '$(session_cfg m "$S_M3")' && ! -e '$MG/d/sessions/$(lower "$S_M3")/mcp.json' ]]"
check "B5 autoAttachMCP off: the dump has no session config for it" jtrue "$ROOT/m3.json" \
    "not any(low(c['session']) == low(a[0]) and c['file'] for c in M()['sessionConfigs'])" "$S_M3"
end_holders m
fi
fi

# =============================================================================================
# Group s: send to session (B6).
if sel B6; then
SECT="B6"
setup_group s
SG="$ROOT/s"
bash "$FIX4/make-notes.sh" "$SG/d/notes" --project "$SG/work" >/dev/null || { echo "E2E make-notes failed (s)" >&2; exit 2; }

# s1. 送出 (submit): paste + submit of the note's AI text to claude's own PTY.
fake_env s "FAKE_STDIN_LOG=$SG/out/stdin1.jsonl"
run_app s1 s 22 -codd-new-claude "$SG/work" -codd-notes-send rwd-punch-k7x2:submit
check "B6 submit: debug notes-send outcome=sent" contains "$ROOT/s1.log" "debug notes-send id=rwd-punch-k7x2 action=submit outcome=sent"
check "B6 submit: the fake's stdin has one paste with the note's AI text, then a submit" jltrue "$SG/out/stdin1.jsonl" \
    "len([r for r in L if r.get('kind') == 'paste' and '# 打卡頁 RWD 跑版紀錄' in r.get('text', '') and 'codd://note/rwd-punch-k7x2' in r.get('text', '')]) == 1 and any(r.get('kind') == 'submit' for r in L)"
check "B6 submit: dump notes.lastSend sent (paste)" jtrue "$ROOT/s1.json" \
    "N()['lastSend']['last']['outcome'] == 'sent' and N()['lastSend']['last']['paste'] is True and N()['lastSend']['last']['note'] == 'rwd-punch-k7x2'"
end_holders s

# s2. 插入引用 (ref): the shown session's composer draft gets codd://note/<id>.
fake_env s "FAKE_STDIN_LOG=$SG/out/stdin2.jsonl"
run_app s2 s 16 -codd-new-claude "$SG/work" -codd-notes-send rwd-punch-k7x2:ref
S_S2="$(spawned_id "$ROOT/s2.log" claude)"
check "B6 ref: debug notes-send outcome=inserted" contains "$ROOT/s2.log" "debug notes-send id=rwd-punch-k7x2 action=ref outcome=inserted"
check "B6 ref: the session's composer draft holds the reference, the composer open" jtrue "$ROOT/s2.json" \
    "'rwd-punch-k7x2' in (S(a[0]).get('composer') or {}).get('refs', []) and (S(a[0]).get('composer') or {}).get('open') is True" "$S_S2"
check "B6 ref: nothing was pasted into the PTY" jltrue "$SG/out/stdin2.jsonl" "not any(r.get('kind') == 'paste' for r in L)"
end_holders s

# s3. A WAITING session (a PermissionRequest is pending): 送出 is refused.
printf 'Hook PermissionRequest {"tool_name": "Bash", "tool_input": {"command": "npm test"}}\n' >"$SG/waiting.txt"
fake_env s "FAKE_STDIN_LOG=$SG/out/stdin3.jsonl" "FAKE_TOOL_EDITS=$SG/waiting.txt" "FAKE_TOOL_EDIT_DELAY_MS=0"
run_app s3 s 18 -codd-new-claude "$SG/work" -codd-notes-send rwd-punch-k7x2:submit
S_S3="$(spawned_id "$ROOT/s3.log" claude)"
check "B6 waiting: the session is WAITING" jtrue "$ROOT/s3.json" "S(a[0])['state'] == 'waiting'" "$S_S3"
check "B6 waiting: 送出 refused with the composer's text" contains "$ROOT/s3.log" \
    "debug notes-send id=rwd-punch-k7x2 action=submit outcome=refused(Claude 在等你確認 · 先用下方按鍵回答)"
check "B6 waiting: nothing was pasted" jltrue "$SG/out/stdin3.jsonl" "not any(r.get('kind') == 'paste' for r in L)"
end_holders s

# s4. A PROMPT sent: `sent` / `sentTo` in its frontmatter.
fake_env s "FAKE_STDIN_LOG=$SG/out/stdin4.jsonl"
run_app s4 s 22 -codd-new-claude "$SG/work" -codd-notes-send keynote-p6d1:submit
S_S4="$(spawned_id "$ROOT/s4.log" claude)"
PROMPT_MD="$(note_file "$SG/d/notes" keynote-p6d1)"
check "B6 prompt: sent" contains "$ROOT/s4.log" "debug notes-send id=keynote-p6d1 action=submit outcome=sent"
check "B6 prompt: the PROMPT records sent and sentTo the session" bash -c \
    "grep -qE '^sent: [0-9]{4}-' '$PROMPT_MD' && grep -qi '^sentTo: $(lower "$S_S4")\$' '$PROMPT_MD'"
check "B6 prompt: its title went into the paste" jltrue "$SG/out/stdin4.jsonl" \
    "any(r.get('kind') == 'paste' and '# keynote 第 3 章大綱' in r.get('text', '') for r in L)"
end_holders s
fi

# =============================================================================================
# Group f: the file editor on the C11 fixture repo (B7).
if sel B7; then
SECT="B7"
setup_group f
FG="$ROOT/f"
bash "$FIX4/make-git-project.sh" "$FG/work/frontend" >/dev/null || { echo "E2E make-git-project failed" >&2; exit 2; }
REPOF="$FG/work/frontend"
PUNCH="$REPOF/src/pages/punch.vue"
GT="$FG/gitenv"; mkdir -p "$GT"; : >"$GT/config"
env -i PATH=/usr/bin:/bin HOME="$GT" GIT_CONFIG_GLOBAL="$GT/config" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$REPOF" --no-optional-locks -c core.fsmonitor=false cat-file blob HEAD:src/pages/punch.vue >"$FG/head-punch.vue"
INDEX_BEFORE="$(stamp "$REPOF/.git/index")"
# Every file's hash before (nothing but the files this group saves may change).
"$PY" -I - "$REPOF" >"$FG/tree-before.txt" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
for base, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x != ".git"]
    for name in sorted(files):
        p = os.path.join(base, name)
        print(hashlib.sha256(open(p, "rb").read()).hexdigest(), os.path.relpath(p, root))
PY
find "$REPOF" -name '*.md' >>"$MDBASE"

# f1. punch.vue dirty (x typed) when the fake's Edit lands: the banner names the session; nothing saved.
printf 'sleep 6000\nEdit %s   z-index: 10;→  z-index: 20;\n' "$PUNCH" >"$FG/edits1.txt"
fake_env f "FAKE_TOOL_EDITS=$FG/edits1.txt" "FAKE_EDIT_ROOT=$FG/work"
start_app f1 f 24 -codd-new-claude "$REPOF" -codd-open-file "$PUNCH" -codd-file-type x
D="$ROOT/f1.json"
check "B7 dirty: the fake's edit was applied" fake_wait 25 f1 f "FAKE-TOOL-EDITS-DONE 1"
S_F1="$(spawned_id "$ROOT/f1.log" claude)"
check "B7 dirty: the banner names the session (磁碟上的檔案已被 AI 變更（…）, unsaved)" wait_for 10 jtrue "$D" \
    "F()['banner'] is not None and low(F()['banner']['session']) == low(a[0]) and F()['banner']['title'].startswith('磁碟上的檔案已被 AI 變更（') and F()['banner']['unsaved'] is True" "$S_F1"
check "f1 quit by itself" wait_app
check "B7 open-file punch.vue logged (not binary, not read-only)" contains "$ROOT/f1.log" "debug open-file name=punch.vue ok=true binary=false readOnly=false"
check "B7 the typed x made the tab dirty" contains "$ROOT/f1.log" "debug file-type chars=1 dirty=true"
check "B7 dirty: the disk has the AI edit and not the typed x (nothing written without ⌘S)" pyok '
import sys
t = open(sys.argv[1], encoding="utf-8").read()
sys.exit(0 if "  z-index: 20;" in t and not t.startswith("x") else 1)' "$PUNCH"
check "B7 punch.vue: UTF-8, LF, Vue, dirty, banner" jtrue "$D" \
    "TAB('punch.vue')['encoding'] == 'utf8' and TAB('punch.vue')['eol'] == 'lf' and TAB('punch.vue')['language'] == 'vue' and TAB('punch.vue')['dirty'] and TAB('punch.vue')['banner']"
check "B7 git: branch feat/punch-rwd ↑2, three M files" jtrue "$D" \
    "F()['branch'] == 'feat/punch-rwd' and F()['ahead'] == 2 and sorted(F()['modified']) == ['src/components/PunchButton.vue', 'src/pages/punch.vue', 'tailwind.config.js']"
check "B7 git: ignored files known (node_modules, .env.local)" jtrue "$D" \
    "any(x.startswith('node_modules') for x in F()['ignored']) and '.env.local' in F()['ignored']"
check "B7 AI chip: punch.vue touched by the session (Edit)" jtrue "$D" \
    "any(t['path'] == 'src/pages/punch.vue' and low(t['session']) == low(a[0]) and t['tool'] == 'Edit' for t in F()['aiTouched'])" "$S_F1"
check "B7 ai-touches.json records the path" contains "$FG/d/files/ai-touches.json" "$PUNCH"
end_holders f

# f2. punch.vue clean when the next Edit lands: reloaded in place, no banner.
printf 'sleep 6000\nEdit %s   z-index: 20;→  z-index: 30;\n' "$PUNCH" >"$FG/edits2.txt"
fake_env f "FAKE_TOOL_EDITS=$FG/edits2.txt" "FAKE_EDIT_ROOT=$FG/work"
start_app f2 f 22 -codd-new-claude "$REPOF" -codd-open-file "$PUNCH"
D="$ROOT/f2.json"
check "B7 clean: the fake's edit was applied" fake_wait 25 f2 f "FAKE-TOOL-EDITS-DONE 1"
PUNCH_SHA="$(sha "$PUNCH")"
check "B7 clean: the tab reloaded the disk text (hash), clean, no banner" wait_for 10 jtrue "$D" \
    "TAB('punch.vue')['hash'] == a[0][:12] and not TAB('punch.vue')['dirty'] and F()['banner'] is None" "$PUNCH_SHA"
check "f2 quit by itself" wait_app
check "B7 clean: z-index 30 on disk" contains "$PUNCH" "  z-index: 30;"
end_holders f

# f3. SHOW AI CHANGES against HEAD: one hunk @@ -40,2 +40,4 @@; revert it and save: the disk = HEAD.
run_app f3 f 12 -codd-open-file "$PUNCH" -codd-file-show-ai-changes YES -codd-file-hunk 0:revert -codd-file-save YES -codd-file-find sticky
check "B7 SHOW AI CHANGES: one hunk @@ -40,2 +40,4 @@" contains "$ROOT/f3.log" "debug file-show-ai-changes on=true hunks=1 ranges=@@ -40,2 +40,4 @@"
check "B7 還原此段: no hunk left, the buffer dirty" contains "$ROOT/f3.log" "debug file-hunk 0:revert hunks=0 dirty=true"
check "B7 ⌘S: saved" contains "$ROOT/f3.log" "debug file-save ok=true"
check "B7 find sticky counted" matches "$ROOT/f3.log" "debug file-find current=[0-9]+ total=[1-9]"
check "B7 the saved punch.vue equals git HEAD's text byte for byte" cmp -s "$PUNCH" "$FG/head-punch.vue"

# f4–f6. CRLF / BOM / Big5: an x typed at the start and saved; every other byte kept.
for spec in "src/legacy-crlf.js:crlf" "src/bom.css:bom" "docs/big5.csv:big5"; do
    rel="${spec%%:*}"; kind="${spec##*:}"
    cp -p "$REPOF/$rel" "$FG/orig-$kind"
    run_app "f-$kind" f 10 -codd-open-file "$REPOF/$rel" -codd-file-type x -codd-file-save YES
    check "B7 $kind: saved" contains "$ROOT/f-$kind.log" "debug file-save ok=true"
    check "B7 $kind: the file is the original with only the typed x added" pyok '
import sys
o = open(sys.argv[1], "rb").read(); n = open(sys.argv[2], "rb").read(); k = sys.argv[3]
want = (o[:3] + b"x" + o[3:]) if k == "bom" else (b"x" + o)
sys.exit(0 if n == want and (k != "bom" or o.startswith(b"\xef\xbb\xbf")) else 1)' "$FG/orig-$kind" "$REPOF/$rel" "$kind"
done
# f7. A mixed-EOL file opened and saved unchanged: nothing is written at all (size, mtime, inode).
MIXED_BEFORE="$(stamp "$REPOF/src/mixed-eol.js")"
run_app f-mixed f 9 -codd-open-file "$REPOF/src/mixed-eol.js" -codd-file-save YES
check "B7 mixed EOL shown as crlf* (the majority, marked mixed)" jtrue "$ROOT/f-mixed.json" "TAB('mixed-eol.js')['eol'] == 'crlf*'"
check "B7 ⌘S on an unchanged file writes nothing (size, mtime, inode)" test "$(stamp "$REPOF/src/mixed-eol.js")" == "$MIXED_BEFORE"
check "B7 CRLF file shown as crlf" jtrue "$ROOT/f-crlf.json" "TAB('legacy-crlf.js')['eol'] == 'crlf' and TAB('legacy-crlf.js')['encoding'] == 'utf8'"
check "B7 BOM file shown as utf8BOM" jtrue "$ROOT/f-bom.json" "TAB('bom.css')['encoding'] == 'utf8BOM'"
check "B7 Big5 file shown as big5, editable" jtrue "$ROOT/f-big5.json" "TAB('big5.csv')['encoding'] == 'big5' and not TAB('big5.csv')['readOnly']"
check "B7 .git/index never written by CODD's git (size, mtime, inode)" test "$(stamp "$REPOF/.git/index")" == "$INDEX_BEFORE"
check "B7 nothing else in the repo changed (only punch.vue by the fake + ⌘S, the three saved files)" pyok '
import hashlib, os, sys
root = sys.argv[1]
before = dict(reversed(l.rstrip("\n").split(" ", 1)) for l in open(sys.argv[2], encoding="utf-8") if l.strip())
changed = set()
for rel, digest in before.items():
    p = os.path.join(root, rel)
    if not os.path.exists(p) or hashlib.sha256(open(p, "rb").read()).hexdigest() != digest:
        changed.add(rel)
now = set()
for base, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x != ".git"]
    now.update(os.path.relpath(os.path.join(base, n), root) for n in files)
sys.exit(0 if changed == {"src/pages/punch.vue", "src/legacy-crlf.js", "src/bom.css", "docs/big5.csv"} and now == set(before) else 1)' "$REPOF" "$FG/tree-before.txt"
check "B7 git ran only inside the fixture repo" bash -c \
    "grep -hoE 'exec git path=[^ ]*' '$ROOT'/f1.log '$ROOT'/f2.log '$ROOT'/f3.log '$ROOT'/f-*.log | grep -q . && ! grep -hoE 'exec git path=[^ ]*' '$ROOT'/f1.log '$ROOT'/f2.log '$ROOT'/f3.log '$ROOT'/f-*.log | sed 's/^exec git path=//' | grep -vE '^($REPOF|${REPOF#/private})(/|\$)' | grep -q ."
no_fsmonitor() {
    local pid
    for pid in $(pgrep -f 'fsmonitor--daemon' 2>/dev/null); do
        lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep -qF -e "$ROOT/" -e "$ROOTV/" && return 1
    done
    return 0
}
check "B7 no git fsmonitor daemon in the fixture repo" no_fsmonitor
fi

# =============================================================================================
# Group r: registration into Claude Code's user scope on a temp file (B8).
if sel B8; then
SECT="B8"
setup_group r
RG="$ROOT/r"
CJ="$RG/claude.json"
bash "$FIX4/make-claude-json.sh" "$CJ" >/dev/null || { echo "E2E make-claude-json failed (r)" >&2; exit 2; }
cp -p "$CJ" "$RG/claude.orig.json"
REG=(-codd-claude-json "$CJ")

# r1. Plan only: the masked diff in the dump, nothing written.
run_app r1 r 10 "${REG[@]}" -codd-mcp-register-plan claude-code
MCPTOKEN_R="$(jexpr "$RG/d/config.json" "d['mcpToken']")"
secret "$MCPTOKEN_R"
check "B8 plan: codd added to mcpServers (summary, line counts)" jtrue "$ROOT/r1.json" \
    "REG()['plan']['action'] == 'claude-code' and REG()['plan']['added'] > 0 and REG()['plan']['removed'] == 0 and REG()['plan']['summary'] == '只會在 mcpServers 加入 codd，其他設定不變'"
check "B8 plan: the diff shows the codd entry with the token masked (••••)" jtrue "$ROOT/r1.json" \
    "any('\"codd\"' in l for l in REG()['plan']['diff']) and any('\"X-CODD-Token\": \"••••\"' in l for l in REG()['plan']['diff']) and not any(a[0] in l for l in REG()['plan']['diff'])" "$MCPTOKEN_R"
check "B8 plan: the other servers are elided, not shown" jtrue "$ROOT/r1.json" \
    "any('保留既有' in l for l in REG()['plan']['diff']) and not any('stitch-like' in l for l in REG()['plan']['diff'])"
check "B8 plan: the file is untouched, no backup" bash -c "cmp -s '$CJ' '$RG/claude.orig.json' && ! ls '$RG' | grep -q 'codd-bak'"

# r2. Apply with a delay; meanwhile "Claude" rewrites a member outside mcpServers: the edit is rebased.
start_app r2 r 20 "${REG[@]}" -codd-mcp-register-plan claude-code -codd-mcp-register-apply YES -codd-mcp-register-apply-delay 6000
check "B8 apply waits between plan and write" wait_for 20 contains "$ROOT/r2.log" "mcp register-apply waiting ms=6000"
"$PY" -I - "$CJ" "$RG/claude.modified.json" <<'PY'
import os, re, sys
p, keep = sys.argv[1], sys.argv[2]
b = open(p, "rb").read()
n = re.subn(rb'"numStartups": (\d+)', lambda m: b'"numStartups": ' + str(int(m.group(1)) + 1).encode(), b, count=1)
assert n[1] == 1
tmp = p + ".e2e-tmp"
with open(tmp, "wb") as f:
    f.write(n[0])
os.chmod(tmp, 0o600)
os.replace(tmp, p)          # like Claude: a new file renamed into place
open(keep, "wb").write(n[0])
PY
check "r2 quit by itself" wait_app
check "B8 apply: wrote, with a backup" matches "$ROOT/r2.log" "debug mcp-register-apply wrote=true backup=claude\.json\.codd-bak-[0-9]{8}-[0-9]{6}"
BAK="$(ls "$RG"/claude.json.codd-bak-* 2>/dev/null | head -1)"
check "B8 the backup sits next to the file and holds the bytes it replaced (the fresh ones)" bash -c "[[ -n '$BAK' ]] && cmp -s '$BAK' '$RG/claude.modified.json'"
check "B8 the change outside mcpServers made during the delay is kept (rebased, not refused)" contains "$CJ" \
    "$(grep -o '"numStartups": [0-9]*' "$RG/claude.modified.json")"
# span <file>: bytes outside the top-level "mcpServers" member (string-aware brace matching).
outside_equal() {
    "$PY" -I - "$1" "$2" <<'PY'
import json, sys
def span(b):
    key = b'\n  "mcpServers": '
    i = b.index(key) + len(key)
    depth, j, s = 0, i, False
    while True:
        c = b[j:j + 1]
        if s:
            if c == b"\\": j += 1
            elif c == b'"': s = False
        elif c == b'"': s = True
        elif c in b"{[": depth += 1
        elif c in b"}]":
            depth -= 1
            if depth == 0: return i, j + 1
        j += 1
a = open(sys.argv[1], "rb").read(); b = open(sys.argv[2], "rb").read()
(ai, aj), (bi, bj) = span(a), span(b)
ja, jb = json.loads(a), json.loads(b)
ma, mb = ja.pop("mcpServers"), jb.pop("mcpServers")
codd = mb.pop("codd", None)
ok = a[:ai] == b[:bi] and a[aj:] == b[bj:] and ja == jb and list(ja) == list(jb) and ma == mb and list(ma) == list(mb)
ok = ok and codd is not None and codd["type"] == "http" and codd["url"].startswith("http://127.0.0.1:") and set(codd["headers"]) == {"X-CODD-Token"}
sys.exit(0 if ok else 1)
PY
}
check "B8 only mcpServers changed: every other member equal (JSON and key order), every byte outside the member equal" \
    outside_equal "$RG/claude.modified.json" "$CJ"
check "B8 no lock dir left" test ! -e "$CJ.lock"
check "B8 dump: registered, applied with the backup" jtrue "$ROOT/r2.json" \
    "REG()['state'] == 'registered' and REG()['applied']['wrote'] is True and str(REG()['applied']['backup']).startswith('claude.json.codd-bak-')"
check "B8 the file keeps mode 0600" test "$(mode_of "$CJ")" == 600

# r3. 移除: the bytes before the registration come back.
run_app r3 r 10 "${REG[@]}" -codd-mcp-register-plan remove -codd-mcp-register-apply YES
check "B8 remove: wrote" matches "$ROOT/r3.log" "debug mcp-register-apply wrote=true backup=claude\.json\.codd-bak-"
check "B8 remove → identical to the bytes before the registration" cmp -s "$CJ" "$RG/claude.modified.json"
check "B8 remove: no lock dir left" test ! -e "$CJ.lock"

# r4. Register again, then 輪替 the external token: the entry needs re-registering.
run_app r4 r 14 "${REG[@]}" -codd-mcp-register-plan claude-code -codd-mcp-register-apply YES -codd-mcp-rotate YES
MCPTOKEN_R2="$(jexpr "$RG/d/config.json" "d['mcpToken']")"
secret "$MCPTOKEN_R2"
check "B8 rotation wrote a new mcpToken (config.json 0600)" bash -c \
    "[[ -n '$MCPTOKEN_R2' && '$MCPTOKEN_R2' != '$MCPTOKEN_R' && \$(stat -f %Lp '$RG/d/config.json') == 600 ]]"
check "B8 rotation: registration needs re-registering, tokenRotatedAt set" jtrue "$ROOT/r4.json" \
    "REG()['state'] == 'needsReregister' and d['registration']['tokenRotatedAt'] is not None"
check "B8 rotation: the registered entry still has the old token" contains "$CJ" "$MCPTOKEN_R"

# r5. A -codd-claude-json that is a link to $HOME/.claude.json: refused before anything is read.
# Plan only (never -codd-mcp-register-apply): should the guard ever regress, this launch still has
# no write path into the real home.
ln -s "$HOME/.claude.json" "$RG/realclaudejson"
run_app r5 r 8 -codd-claude-json "$RG/realclaudejson" -codd-mcp-register-plan claude-code
check "B8 the link to ~/.claude.json: target disabled with the guard's reason" jtrue "$ROOT/r5.json" \
    "REG()['target'] == 'disabled' and str(REG().get('reason', '')).startswith('-codd-claude-json 被拒絕')"
check "B8 refused before the plan: plan failed (unavailable), no plan line, nothing written" bash -c \
    "grep -q 'debug mcp-register-plan failed (unavailable)' '$ROOT/r5.log' && ! grep -q 'mcp register-plan action=' '$ROOT/r5.log' && ! grep -q 'mcp-register-apply wrote=' '$ROOT/r5.log'"
rm -f "$RG/realclaudejson"
end_holders r
fi

# =============================================================================================
# Group t: retention (B9), cleanup and digest (B10).
if sel B9 || sel B10; then
SECT="B9 B10"
setup_group t
TG="$ROOT/t"
LM_T="$("$FIX2/seed-layout.sh" "$TG/d" "$TG/work")" || exit 2
read -r SID AID ZID < <("$PY" -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
by = {s["title"]: s["id"] for s in m["sessions"]}
print(by["refresh token 流程改寫"], by["舊的部署腳本"], by["zsh"])' "$LM_T")
SIDL="$(lower "$SID")"; AIDL="$(lower "$AID")"; ZIDL="$(lower "$ZID")"
echo "E2E seeded: stopped=$SID archived=$AID shell=$ZID"
iso_ago() { "$PY" -I -c '
import datetime, sys
now = datetime.datetime.fromisoformat(sys.argv[1])
print((now - datetime.timedelta(days=float(sys.argv[2]))).isoformat())' "$NOW" "$1"; }
"$PY" -I "$FIX4/age-layout.py" "$TG/d/layout.json" --stopped "$SID" "$(iso_ago 8)" >/dev/null || exit 2

# t0. The first retention run on this root (D30 grace): nothing archived even though a session
# stopped 8 days ago; firstRunAt recorded. A live CODD claude session starts here and keeps running.
mkdir -p "$TG/work/live"
run_app t0 t 12 -codd-now "$NOW" -codd-new-claude "$TG/work/live"
LIVE="$(spawned_id "$ROOT/t0.log" claude)"
LIVEL="$(lower "$LIVE")"
echo "E2E live session=$LIVE"
check "B9 first run: firstRunAt recorded (the notes clock, 2026-10-17 02:0x Z)" jtrue "$ROOT/t0.json" "str(RET()['firstRunAt']).startswith('2026-10-17T02:0')"
check "B9 first run: no session archived, no ring trashed (the grace)" jtrue "$ROOT/t0.json" "RET()['sessionsArchived'] == [] and RET()['ringsTrashed'] == []"
check "B9 first run: cleanup.json has retention.firstRunAt" jtrue "$TG/d/cleanup.json" "str(d['retention']['firstRunAt']).startswith('2026-10-17T02:0')"
check "B9 first run: the 8-day stopped session is not archived" jtrue "$TG/d/layout.json" \
    "not next(s for s in d['sessions'] if low(s['id']) == low(a[0])).get('archivedAt')" "$SID"
check "B9 the live session's holder keeps running" test "$(holder_count t)" -ge 1

# The aged notes (--old NOW; v2-review linked to the live session) and the aged layout.
bash "$FIX4/make-notes.sh" "$TG/d/notes" --old "$NOW" --session "$LIVEL" --manifest "$TG/notes.json" >/dev/null \
    || { echo "E2E make-notes failed (t)" >&2; exit 2; }
rm -f "$TG/d/cache/notes-index.sqlite" "$TG/d/cache/notes-index.sqlite-wal" "$TG/d/cache/notes-index.sqlite-shm"
"$PY" -I "$FIX4/age-layout.py" "$TG/d/layout.json" --stopped "$ZID" "$(iso_ago 4)" --archived "$AID" "$(iso_ago 31)" \
    --ring "$TG/d" "$AID" 1 --first-run "$TG/d" "$(iso_ago 30.05)" >"$TG/age.txt" || exit 2
cat "$TG/age.txt" | sed 's/^/E2E aged /'

# t1. Retention at NOW: notes and sessions.
start_app t1 t 22 -codd-now "$NOW" -codd-retention-run YES -codd-show cleanup
D="$ROOT/t1.json"
check "B9 the debug retention run finished" wait_for 20 grep -q 'debug retention-run runs=' "$ROOT/t1.log"
TPORT="$(port_of t)"
client t --note-token-from-config "$TG/d/config.json" trashed-idea-t3x1 get "http://127.0.0.1:$TPORT/n/trashed-idea-t3x1.md" >"$TG/out/url-purged.jsonl" 2>&1
check "t1 quit by itself" wait_app
check "B9 the 30 d note, the SCRATCH and the sent PROMPT archived" jtrue "$D" \
    "{'old-review-r30d', 'quick-scratch-s5c2', 'prompt-401-b3m9'} <= set(RET()['archived'])"
check "B9 the pinned note and the note linked to the live session kept" jtrue "$D" \
    "'mcp-demo-r8q1' not in RET()['archived'] and 'v2-review-h4n6' not in RET()['archived']"
check "B9 the 21 d note is stale, not archived" jtrue "$D" "'gear3d-n7q0' in RET()['staleIDs'] and 'gear3d-n7q0' not in RET()['archived']"
check "B9 on disk: status archived, archivedBy auto (old-review-r30d)" bash -c \
    "f=\$(grep -l '^id: old-review-r30d\$' '$TG/d/notes/'*.md); grep -q '^status: archived' \"\$f\" && grep -q '^archivedBy: auto' \"\$f\""
check "B9 the 31 d trashed note purged" jtrue "$D" "RET()['purged'] == ['trashed-idea-t3x1']"
check "B9 purge: the note file and its image in the -codd-trash-dir folder" bash -c \
    "ls '$TG/trash' | grep -q '已丟掉的舊想法' && find '$TG/trash' -name '1a2b3c.png' | grep -q . && ! find '$TG/d/notes/.codd/trash' -name '*已丟掉的舊想法*' | grep -q ."
check "B9 purge: a tombstone, and the note URL answers 410 purged" bash -c \
    "grep -q 'trashed-idea-t3x1' '$TG/d/notes/.codd/tombstones.json' && grep -q 'note-url id=trashed-idea-t3x1 status=410 purged' '$ROOT/t1.log'"
check "B9 the purged note's URL → 410" jltrue "$TG/out/url-purged.jsonl" "L[-1]['status'] == 410"
check "B9 sessions: the 8-day stopped session archived, the old ring trashed" jtrue "$D" \
    "a[0] in [low(x) for x in RET()['sessionsArchived']] and [low(x) for x in RET()['ringsTrashed']] == [a[1]] and RET()['trashTarget'] == 'folder'" "$SIDL" "$AIDL"
check "B9 sessions: the live session and the 4-day stopped shell are not archived" jtrue "$D" \
    "a[0] not in [low(x) for x in RET()['sessionsArchived']] and a[1] not in [low(x) for x in RET()['sessionsArchived']]" "$LIVEL" "$ZIDL"
check "B9 the ring and its holder.log moved into the trash folder" bash -c \
    "find '$TG/trash' -name 'ring*' | grep -q . && find '$TG/trash' -name 'holder.log*' | grep -q . && [[ ! -e '$TG/d/sessions/$AIDL/ring' ]]"
check "B9 layout.json: the stopped session has archivedAt" jtrue "$TG/d/layout.json" \
    "bool(next(s for s in d['sessions'] if low(s['id']) == low(a[0])).get('archivedAt'))" "$SID"
check "B9 cleanup.json keeps the aged firstRunAt and records lastRunAt" jtrue "$TG/d/cleanup.json" \
    "str(d['retention']['firstRunAt']).startswith('2026-09-1') and d['retention'].get('lastRunAt') is not None"
check "B9 log: the automatic moves are logged" bash -c \
    "grep -qE 'retention notes stale=[0-9]+ archived=[1-9]' '$ROOT/t1.log' && grep -qE 'retention sessions archived=[1-9][0-9]* rings=1' '$ROOT/t1.log'"
check "B9 every trash move went to the folder (trash target=folder)" bash -c \
    "grep -q 'trash target=folder' '$ROOT/t1.log' && ! grep -q 'trash target=system' '$ROOT/t0.log' '$ROOT/t1.log'"
check "B10 cleanup page: counts per tab in the dump" jtrue "$D" \
    "CL()['shown'] and CL()['counts']['notes'] >= 1 and CL()['counts']['files'] >= 1 and CL()['counts']['total'] == CL()['counts']['notes'] + CL()['counts']['sessions'] + CL()['counts']['files']"
echo "E2E cleanup counts at NOW: $(jexpr "$D" "CL()['counts']")"
end_holders t

if sel B10; then
SECT="B10"
# t2. The digest: Monday 09:05 local with ≥ 5 candidates, notifications off (recorded, suppressed).
for img in aa11bb cc22dd; do
    "$PY" -I "$FIX4/make-png.py" "$TG/d/notes/assets/gear3d-n7q0/$img.png" 64 64 --seed 7 >/dev/null
    touch -t 202610010900 "$TG/d/notes/assets/gear3d-n7q0/$img.png"
done
run_app t2 t 12 -codd-now 2026-10-19T09:05:00+08:00
D="$ROOT/t2.json"
echo "E2E cleanup counts at the digest: $(jexpr "$D" "CL()['counts']")"
check "B10 digest: at least 5 candidates at Monday 09:05" jtrue "$D" "CL()['counts']['total'] >= 5"
check "B10 digest: one cleanup-digest recorded, suppressed (notifications off), 清理建議 · n 項" jtrue "$D" \
    "len(posted('cleanup-digest')) == 1 and posted('cleanup-digest')[0]['suppressed'] is True and posted('cleanup-digest')[0]['title'].startswith('清理建議 · ')"
check "B10 digest: lastShownAt = the notes clock (2026-10-19 01:05 Z)" jtrue "$D" "str(CL()['digest']['lastShownAt']).startswith('2026-10-19T01:05')"
check "B10 digest: logged once" test "$(count_of "$ROOT/t2.log" "notification cleanup-digest suppressed")" == 1
run_app t2b t 10 -codd-now 2026-10-19T10:05:00+08:00
check "B10 digest: not again in the same period" jtrue "$ROOT/t2b.json" "len(posted('cleanup-digest')) == 0"

# t3. 保留 30 天 on a NOTES row: keepUntil in state.json.
run_app t3 t 12 -codd-now 2026-10-19T10:10:00+08:00 -codd-cleanup-action notes:gear3d-n7q0:keep
check "B10 keep: the row action ran" contains "$ROOT/t3.log" "debug cleanup-action tab=notes ids=1 action="
check "B10 keep: state.json keepUntil for gear3d-n7q0 (about 30 days on)" jtrue "$TG/d/notes/.codd/state.json" \
    "str(d['notes']['gear3d-n7q0']['keepUntil']).startswith('2026-11-1')"
check "B10 keep: one candidate fewer" pyok '
import re, sys
m = re.search(r"debug cleanup-action tab=notes ids=1 action=.* before=(\d+) after=(\d+)", open(sys.argv[1], encoding="utf-8").read())
sys.exit(0 if m and int(m.group(2)) == int(m.group(1)) - 1 else 1)' "$ROOT/t3.log"
end_holders t
fi
fi

# ---------------------------------------------------------------------------------------------
# B10b. No digest with fewer than 5 candidates (a fresh notebook, no layout).
if sel B10; then
SECT="B10"
setup_group d
bash "$FIX4/make-notes.sh" "$ROOT/d/d/notes" >/dev/null || exit 2
run_app d1 d 12 -codd-now 2026-10-19T09:05:00+08:00
echo "E2E cleanup counts (fresh notebook): $(jexpr "$ROOT/d1.json" "CL()['counts']")"
check "B10 fewer than 5 candidates: no digest recorded" jtrue "$ROOT/d1.json" \
    "CL()['counts']['total'] < 5 and len(posted('cleanup-digest')) == 0 and CL()['digest']['lastShownAt'] is None"

# =============================================================================================
# Group c: 交給 Claude 濃縮 with the fake claude -p (B11).
fi

if sel B11; then
SECT="B11"
setup_group c
CG="$ROOT/c"
cswap_setup c
PROFILE_C="$(ls -d "$CG/home/.claude-swap-backup/sessions/2-"* 2>/dev/null | head -1)"
PROFILE_SLUG="$(basename "${PROFILE_C:-none}")"
bash "$FIX4/make-notes.sh" "$CG/d/notes" --now "$NOW" >/dev/null || { echo "E2E make-notes failed (c)" >&2; exit 2; }
CN="$CG/d/notes"
DAILY="$(note_file "$CN" daily-log-d9w1)"
DAILY_SHA="$(sha "$DAILY")"
MD_BEFORE="$(find "$CN" -name '*.md' -not -path '*/.codd/*' | wc -l | tr -d ' ')"
fake_env c "FAKE_P_INPUT=$CG/p-input.txt" "FAKE_P_DATE=10/17"
CSW=(-codd-cswap-path "$CG/bin/cswap" -codd-cswap-root "$CG/home/.claude-swap-backup")
run_app c1 c 24 "${CSW[@]}" -codd-now "$NOW" -codd-condense rwd-punch-k7x2,cjk-search-note,ai-off-note,daily-log-d9w1 \
    -codd-condense-account follow -codd-condense-apply YES
fake_files c1 c print
check "B11 exec claude path=<the fake> sub=-p" bash -c \
    "grep -qE 'exec claude path=($CG|${CG#/private})/bin/fake-claude sub=-p' '$ROOT/c1.log'"
check "B11 preview: 3 sources, the OFF note left out, the run folder removed" matches "$ROOT/c1.log" \
    "debug condense sources=3 excluded=1 state=preview previewChars=[1-9][0-9]* folderRemoved=true"
check "B11 argv exactly D32's (-p, --model, --output-format text, --tools \"\", --permission-prompts none, --strict-mcp-config, --mcp-config <run>/mcp.json, --allowedTools mcp__codd__notes_read, --no-session-persistence)" jtrue "$FJ" \
    "d['mode'] == 'print' and d['argv'][:11] == ['-p', '--model', 'sonnet-5.5', '--output-format', 'text', '--tools', '', '--permission-prompts', 'none', '--strict-mcp-config', '--mcp-config'] and re.fullmatch(r'.*/run/condense-[^/]+/mcp\.json', d['argv'][11]) is not None and d['argv'][12:] == ['--allowedTools', 'mcp__codd__notes_read', '--no-session-persistence']"
check "B11 the child ran in the run folder" jtrue "$FJ" "re.search(r'/run/condense-[^/]+$', d['cwd']) is not None"
check "B11 FAKE-P-ENV CODD_HOOK_TOKEN=unset CODD_SESSION_ID=unset (no CODD URL either)" bash -c \
    "grep -q 'FAKE-P-ENV CODD_HOOK_TOKEN=unset CODD_SESSION_ID=unset' '$FL' && [[ \"\$('$PY' -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"env\"][\"CODD_HOOK_URL\"])' '$FJ')\" == unset ]]"
check "B11 follow: no CLAUDE_CONFIG_DIR" contains "$FL" "FAKE-P-ENV CLAUDE_CONFIG_DIR=unset"
check "B11 stdin: the notes' text, the long note's old sections only, no OFF note" pyok '
import datetime, sys
t = open(sys.argv[1], encoding="utf-8").read()
now = datetime.datetime.fromisoformat(sys.argv[2])
old = (now - datetime.timedelta(days=31)).strftime("## %Y-%m-%d")
new = (now - datetime.timedelta(days=1)).strftime("## %Y-%m-%d")
ok = "打卡頁 RWD 跑版紀錄" in t and "注音輸入法筆記" in t and "（舊段落 9 段）" in t and old in t and new not in t
ok = ok and "OFF-NOTE-SECRET-42" not in t and "不給 AI 的私人紀錄" not in t
sys.exit(0 if ok else 1)' "$CG/p-input.txt" "$NOW"
check "B11 apply: summary created, 2 archived, the long note kept" matches "$ROOT/c1.log" \
    "debug condense-apply summary=cleanup-1017-[a-z0-9]+ archived=2 kept=1"
SUMMARY_ID="$(grep -o 'debug condense-apply summary=[^ ]*' "$ROOT/c1.log" | head -1 | sed 's/.*summary=//')"
SUMMARY_MD="$(note_file "$CN" "${SUMMARY_ID:-none}")"
check "B11 the summary note: 摘要 · 10/17 清理（3 則）, condensedFrom the three sources" bash -c \
    "[[ -n '$SUMMARY_MD' ]] && grep -q '^# 摘要 · 10/17 清理（3 則）' '$SUMMARY_MD' && grep -q '^condensedFrom:' '$SUMMARY_MD' && grep -q 'rwd-punch-k7x2' '$SUMMARY_MD' && grep -q 'daily-log-d9w1' '$SUMMARY_MD'"
check "B11 whole-note sources archived by condense with condensedInto the summary" bash -c \
    "for id in rwd-punch-k7x2 cjk-search-note; do f=\$(grep -l \"^id: \$id\\\$\" '$CN'/*.md); grep -q '^status: archived' \"\$f\" && grep -q '^archivedBy: condense' \"\$f\" && grep -q '^condensedInto: $SUMMARY_ID' \"\$f\" || exit 1; done"
check "B11 the long note is unchanged (byte for byte)" test "$(sha "$DAILY")" == "$DAILY_SHA"
check "B11 nothing deleted: one more note file" test "$(find "$CN" -name '*.md' -not -path '*/.codd/*' | wc -l | tr -d ' ')" == "$((MD_BEFORE + 1))"
check "B11 the OFF note is untouched and active" bash -c "f=\$(grep -l '^id: ai-off-note\$' '$CN'/*.md); grep -q '^status: active' \"\$f\""
check "B11 no run folder left" bash -c "! ls '$CG/d/run' 2>/dev/null | grep -q '^condense-'"
check "B11 dump: condense applied (summary, archived, kept)" jtrue "$ROOT/c1.json" \
    "CL()['condense']['applied']['summary'] == a[0] and sorted(CL()['condense']['applied']['archived']) == ['cjk-search-note', 'rwd-punch-k7x2'] and CL()['condense']['applied']['kept'] == ['daily-log-d9w1']" "$SUMMARY_ID"
check "B11 the condense child was never an EXT session" jtrue "$ROOT/c1.json" "not any(s.get('external') for s in d['sessions'])"

# c2. A pinned cswap account: CLAUDE_CONFIG_DIR set (never printed), no profile path anywhere.
run_app c2 c 22 "${CSW[@]}" -codd-now "$NOW" -codd-condense global-note -codd-condense-account 2
fake_files c2 c print
check "B11 pinned #2: the run started" matches "$ROOT/c2.log" "debug condense sources=1 excluded=0 state=preview"
check "B11 pinned #2: FAKE-P-ENV CLAUDE_CONFIG_DIR=set" contains "$FL" "FAKE-P-ENV CLAUDE_CONFIG_DIR=set"
check "B11 pinned #2: the fake's JSON says set, not the path" jtrue "$FJ" "d['env']['CLAUDE_CONFIG_DIR'] == 'set' and a[0] not in json.dumps(d)" "$PROFILE_SLUG"
check "B11 the cswap profile path in no dump, app log or fake log" bash -c \
    "[[ '$PROFILE_SLUG' != none ]] && ! grep -qF -- '$PROFILE_SLUG' '$ROOT/c1.json' '$ROOT/c2.json' '$ROOT/c1.log' '$ROOT/c2.log' '$CG'/fakelog/*"
end_holders c
fi

# =============================================================================================
# Group u: sidebar drag and drop (user feedback 2026-10-18; the DEBUG hooks drive the outline's own
# drop path with synthetic dragging infos: no posted events, no real dragging session).
if sel U1; then
SECT="U1"
setup_group u
UG="$ROOT/u"
LM_U="$("$FIX2/seed-layout.sh" "$UG/d" "$UG/wa")" || exit 2
BLUE="$(jexpr "$LM_U" "next(g['id'] for g in d['groups'] if g['name'] == '藍鵲 · 網站')")"
run_app u1 u 25 -codd-sidebar-drag-test YES
check "U1 drag self-test ran, every drag passed" bash -c "grep -q 'DRAGTESTS ok=' '$ROOT/u1.log' && grep -q 'DRAGTESTS ok=[0-9]* fail=0' '$ROOT/u1.log' && ! grep -q 'DRAGTEST .* FAIL' '$ROOT/u1.log'"
for name in sessions.down sessions.up projects.withinGroup projects.intoGroup projects.intoUngrouped groups.down groups.up \
            persisted folders.plainFile folders.betweenProjects folders.duplicate folders.outsideGroups; do
    check "U1 $name" contains "$ROOT/u1.log" "DRAGTEST $name ok"
done
ORDER_U="$(grep -o 'DRAGTEST order .*' "$ROOT/u1.log" | tail -1 | sed 's/^DRAGTEST order //')"
run_app u2 u 7
check "U1 the order survives a relaunch (layout.json read by a new process)" test \
    "$(jexpr "$ROOT/u2.json" "order()" | tr 'A-Z' 'a-z')" == "$(printf '%s' "$ORDER_U" | tr 'A-Z' 'a-z')"
mkdir -p "$UG/drop/f1" "$UG/drop/f2"
printf 'x\n' >"$UG/drop/file.txt"
run_app u3 u 8 -codd-drop-folders "$UG/drop/f1" -codd-drop-folders "$UG/drop/f2" -codd-drop-folders "$UG/drop/file.txt" \
    -codd-drop-folders-group "$BLUE" -codd-drop-folders-index 0
check "U1 two folders and a file dropped on a group: two added" contains "$ROOT/u3.log" "debug drop-folders op=1 accepted=true added=2 existing=0"
check "U1 the folders lead the group in drop order, the file is not a project" jtrue "$ROOT/u3.json" \
    "[rp(p['cwd']) for p in d['projects'] if low(p.get('group') or '') == low(a[0])][:2] == [rp(a[1]), rp(a[2])] and P(a[3]) is None" \
    "$BLUE" "$UG/drop/f1" "$UG/drop/f2" "$UG/drop/file.txt"
run_app u4 u 7
check "U1 the dropped projects persist after a relaunch" jtrue "$ROOT/u4.json" "P(a[0]) is not None and P(a[1]) is not None" "$UG/drop/f1" "$UG/drop/f2"
end_holders u
fi

# =============================================================================================
# Group z: interface zoom (user feedback 2026-10-18): ⌘+ twice, persisted, applied after a relaunch.
if sel U2; then
SECT="U2"
setup_group z
ZG="$ROOT/z"
run_app z1 z 6 -codd-zoom in -codd-zoom in
check "U2 two zoom steps logged (14, 15)" bash -c "grep -q 'zoom in ui=14 terminal=14' '$ROOT/z1.log' && grep -q 'zoom in ui=15 terminal=15' '$ROOT/z1.log'"
check "U2 preferences.json stores UI 字級 15 and 終端機字級 15" jtrue "$ZG/d/preferences.json" \
    "d['appearance']['uiFontSize'] == 15 and d['appearance']['terminalFontSize'] == 15"
ROW15="$(jexpr "$ROOT/z1.json" "Z()['metrics']['sessionRowHeight']")"
run_app z2 z 6
check "U2 the relaunch starts at the stored size (launch peek)" contains "$ROOT/z2.log" "zoom launch ui=15"
check "U2 the relaunch applies it: scale 15/13, the zoomed metrics" jtrue "$ROOT/z2.json" \
    "Z()['uiFontSize'] == 15 and abs(Z()['scale'] - 15 / 13) < 1e-6 and Z()['metrics']['sessionRowHeight'] == int(a[0]) and Z()['metrics']['sessionRowHeight'] > 38" "${ROW15:-0}"
run_app z3 z 6 -codd-zoom reset
check "U2 實際大小 back to 13 in the file" jtrue "$ZG/d/preferences.json" "d['appearance']['uiFontSize'] == 13 and d['appearance']['terminalFontSize'] == 13"
end_holders z
fi

# =============================================================================================
# Group q: numbers (B13).
if sel B13; then
SECT="B13"
setup_group q
QG="$ROOT/q"
QPORT="$(port_of q)"
bash "$FIX4/make-notes.sh" "$QG/d/notes" --count 1000 --project "$QG/work" >/dev/null || { echo "E2E make-notes failed (q)" >&2; exit 2; }
"$PY" -I - "$QG/out/perf.jsonl" <<'PY'
import json, sys
with open(sys.argv[1] + ".script", "w", encoding="utf-8") as f:
    for q in ("打", "打卡", "打卡頁"):
        for i in range(20):
            f.write(json.dumps({"label": "s%s-%d" % (len(q), i), "tool": "notes_search", "arguments": {"query": q}}, ensure_ascii=False) + "\n")
    for i in range(10):
        f.write(json.dumps({"label": "ri-%d" % i, "tool": "notes_read", "arguments": {"ref": "rwd-punch-k7x2"}}) + "\n")
    for i in range(10):
        f.write(json.dumps({"label": "rt-%d" % i, "tool": "notes_read", "arguments": {"ref": "rwd-punch-k7x2", "include_images": False}}) + "\n")
PY
start_app q1 q 40 -codd-show notebook
check "B13 the 1,000-note notebook is open" wait_for 30 jtrue "$ROOT/q1.json" "N()['available'] and N()['index']['count'] >= 1000"
client q --url "http://127.0.0.1:$QPORT/mcp" --token-from-config "$QG/d/config.json" --init script "$QG/out/perf.jsonl.script" >"$QG/out/perf.jsonl" 2>&1
check "q1 quit by itself" wait_app
check "B13 the measurement calls all answered" jltrue "$QG/out/perf.jsonl" \
    "len([r for r in L if str(r.get('label', '')).startswith(('s', 'r')) and r.get('status') == 200]) == 80"
number "B13 index build, $(jexpr "$ROOT/q1.json" "N()['index']['count']") notes (~4 KB each, rebuilt from missing): $(jexpr "$ROOT/q1.json" "N()['index']['buildMs']") ms"
"$PY" -I - "$ROOT/q1.log" <<'PY'
import re, sys
search, read = [], []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.search(r"mcp tool=(notes_search|notes_read) outcome=\S+ ms=([0-9.]+) caller=external", line)
    if m:
        (search if m.group(1) == "notes_search" else read).append(float(m.group(2)))
def p95(v):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(0.95 * (len(v) - 1))))] if v else float("nan")
def med(v):
    v = sorted(v)
    return v[len(v) // 2] if v else float("nan")
for i, q in enumerate(("打 (1 char, LIKE)", "打卡 (2 chars, LIKE)", "打卡頁 (3 chars, FTS5 trigram)")):
    part = search[i * 20:(i + 1) * 20]
    print("E2E number B13 notes_search %s over 1,020 notes: p95 %.2f ms, median %.2f ms (server time, %d calls)" % (q, p95(part), med(part), len(part)))
print("E2E number B13 notes_read rwd-punch-k7x2 with its image: median %.2f ms, p95 %.2f ms" % (med(read[:10]), p95(read[:10])))
print("E2E number B13 notes_read rwd-punch-k7x2 without images: median %.2f ms, p95 %.2f ms" % (med(read[10:20]), p95(read[10:20])))
PY

# Note open, 1 MB / 10 MB file open.
run_app q2 q 9 -codd-show note:rwd-punch-k7x2
number "B13 note open (n1, live preview, its figure): $(jexpr "$ROOT/q2.json" "N()['openMs']") ms"
mkdir -p "$QG/work/files"
"$PY" -I -c '
import sys
lines = ["export const row%06d = { id: %d, label: \"打卡紀錄 %d\", value: %d };\n" % (i, i, i, i * 7) for i in range(14000)]
open(sys.argv[1], "w", encoding="utf-8").write("".join(lines))
with open(sys.argv[2], "w", encoding="ascii") as f:
    line = "0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\n"
    for _ in range((10 * 1024 * 1024) // len(line)):
        f.write(line)' "$QG/work/files/big.js" "$QG/work/files/big10.txt"
run_app q3 q 10 -codd-open-file "$QG/work/files/big.js"
number "B13 1 MB JavaScript file open (read, decode, code view): $(jexpr "$ROOT/q3.json" "F()['lastOpen']['ms']") ms for $(jexpr "$ROOT/q3.json" "F()['lastOpen']['bytes']") bytes"
run_app q4 q 10 -codd-open-file "$QG/work/files/big10.txt"
check "B13 the 10 MB file opened read-only in plain mode" jtrue "$ROOT/q4.json" "TAB('big10.txt')['readOnly'] and TAB('big10.txt')['plain']"
number "B13 10 MB text file open (read-only plain mode): $(jexpr "$ROOT/q4.json" "F()['lastOpen']['ms']") ms for $(jexpr "$ROOT/q4.json" "F()['lastOpen']['bytes']") bytes"

# Idle CPU and footprint with three silent fake claudes, the Notebook and then the Files mode shown
# (no state dump: its writes would be the e2e's cost, not the app's).
bash "$FIX4/make-git-project.sh" "$QG/work/repo" >/dev/null || exit 2
find "$QG/work/repo" -name '*.md' >>"$MDBASE"
for n in 1 2 3; do run_app "q5-$n" q 6 -codd-new-claude "$QG/work"; done
check "B13 three silent fake claude holders running" test "$(holder_count q)" -ge 3
measure_idle() {
    local label="$1"; shift
    NODUMP=1 start_app "$@"
    local pid=$APP_PID cpu0 cpu1 t0 t1 foot pct
    sleep 14
    cpu0="$(ps -o cputime= -p "$pid" | tr -d ' ')"; t0="$(now)"
    sleep 10
    cpu1="$(ps -o cputime= -p "$pid" | tr -d ' ')"; t1="$(now)"
    foot="$(footprint "$pid" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}')"
    pct="$("$PY" -I -c 'import sys
def s(t):
    v = 0.0
    for p in t.split(":"): v = v * 60 + float(p)
    return v
print("%.2f" % ((s(sys.argv[2]) - s(sys.argv[1])) / (float(sys.argv[4]) - float(sys.argv[3])) * 100))' "$cpu0" "$cpu1" "$t0" "$t1" 2>/dev/null)"
    number "B13 idle CPU, $label, 3 silent fake claudes: $cpu0 -> $cpu1 over $(fsub "$t1" "$t0") s = ${pct:-?} %; footprint ${foot:-n/a}"
    check "$1 quit by itself" wait_app
    [[ -n "$pct" ]] && fle "$pct" 5
}
check "B13 idle CPU with the Notebook shown below 5 % (sanity bound; the report has the number)" \
    measure_idle "Notebook shown" q6 q 30 -codd-show notebook
check "B13 idle CPU with the Files mode shown below 5 % (sanity bound)" \
    measure_idle "Files mode shown (punch.vue)" q7 q 30 -codd-open-file "$QG/work/repo/src/pages/punch.vue"
end_holders q
fi

# =============================================================================================
SECT=""
if sel B12 && (( ${#RUNS[@]} == 0 )); then echo "E2E skip B12 (no run to scan: select it with other sections or run everything)"; fi
if sel B12 && (( ${#RUNS[@]} > 0 )); then
# B12. Isolation over every run.
ALL_LOGS=(); ALL_DUMPS=()
for r in "${RUNS[@]}"; do ALL_LOGS+=("$ROOT/$r.log"); [[ -e "$ROOT/$r.json" ]] && ALL_DUMPS+=("$ROOT/$r.json"); done
FAKE_LOGS=()
while IFS= read -r f; do FAKE_LOGS+=("$f"); done < <(find "$ROOT" -path '*/fakelog/*' -type f 2>/dev/null; find "$ROOT" -path '*/out/*' -type f 2>/dev/null)
[[ ${#FAKE_LOGS[@]} -gt 0 ]] || FAKE_LOGS=(/dev/null)
[[ ${#ALL_DUMPS[@]} -gt 0 ]] || ALL_DUMPS=(/dev/null)
EXECS="$(cat "${ALL_LOGS[@]}" | grep -oE 'exec [a-z-]+ path=[^ ]* sub=[^ ]*' | sed "s|$ROOT|<tmp>|; s|$ROOTV|<tmp>|" | sort | uniq -c | sort -rn)"
echo "E2E exec lines:"; echo "$EXECS" | sed 's/^/E2E   /'
exec_inside() {
    local paths
    paths="$(cat "${ALL_LOGS[@]}" | grep -oE 'exec [a-z-]+ path=[^ ]*' | sed 's/.* path=//')"
    if [[ -z "$paths" ]]; then [[ -n "$ONLY" ]]; return; fi   # (a targeted run may start no tool at all)
    ! printf '%s\n' "$paths" | grep -vE "^($ROOT|$ROOTV)/" | grep -q .
}
check "B12 every exec line (git, the fake claude, the fake cswap) names a path inside the temp folder" exec_inside
check "B12 exec tools are only git, claude (-p, the fake) and cswap (the fake)" bash -c \
    "! cat ${ALL_LOGS[*]} | grep -oE 'exec [a-z-]+ path=' | grep -vE '^exec (git|claude|cswap) path=' | grep -q ."
check "B12 no anthropic.com in any app log, dump, fake log or client output" bash -c \
    "! grep -liF 'anthropic.com' ${ALL_LOGS[*]} ${ALL_DUMPS[*]} ${FAKE_LOGS[*]} 2>/dev/null | grep -q ."
# Every hook token, mcpToken (also rotated ones), session token (from each mcp.json and derived for
# every session folder) and note URL token (for the fixture ids) of the run.
"$PY" -I - "$ROOT" "$SECRETS" <<'PY'
import glob, hashlib, hmac, json, os, sys
root, path = sys.argv[1], sys.argv[2]
secrets = set(l.strip() for l in open(path) if l.strip())
ids = ["rwd-punch-k7x2", "ai-off-note", "trashed-idea-t3x1", "global-note", "cjk-search-note", "ai-append-note"]
for cfg in glob.glob(os.path.join(root, "*", "d", "config.json")):
    c = json.load(open(cfg))
    hook = c.get("token") or ""
    toks = [t for t in (c.get("mcpToken"), *secrets) if t and len(t) == 64]
    if hook:
        secrets.add(hook)
        for s in glob.glob(os.path.join(os.path.dirname(cfg), "sessions", "*")):
            sid = os.path.basename(s).lower()
            secrets.add(hmac.new(hook.encode(), ("codd-mcp-v1:" + sid).encode(), hashlib.sha256).hexdigest())
    for t in toks:
        secrets.add(t)
        for i in ids:
            secrets.add(hmac.new(t.encode(), ("codd-note-url-v1:" + i).encode(), hashlib.sha256).hexdigest()[:24])
for m in glob.glob(os.path.join(root, "*", "d", "sessions", "*", "mcp.json")):
    for e in json.load(open(m)).get("mcpServers", {}).values():
        t = (e.get("headers") or {}).get("X-CODD-Token")
        if t: secrets.add(t)
with open(path, "w") as f:
    f.write("\n".join(sorted(secrets)) + "\n")
PY
echo "E2E secrets collected: $(grep -c . "$SECRETS")"
no_secret_in() {
    [[ -s "$SECRETS" ]] || return 1
    ! grep -lF -f "$SECRETS" "$@" 2>/dev/null | grep -q .
}
check "B12 no hook token, mcpToken, session token or note URL token in any dump" no_secret_in "${ALL_DUMPS[@]}"
check "B12 none in any app log" no_secret_in "${ALL_LOGS[@]}"
check "B12 none in any fake log or client output" no_secret_in "${FAKE_LOGS[@]}"
check "B12 no SECRET-LEAK marker in any client output" bash -c "! grep -lF 'SECRET-LEAK' ${FAKE_LOGS[*]} 2>/dev/null | grep -q ."
check "B12 no trash target=system line in any app log (D38)" bash -c "! grep -lF 'trash target=system' ${ALL_LOGS[*]} | grep -q ."
check "B12 no pasteboard target=general line in any app log (D39)" bash -c "! grep -lF 'pasteboard target=general' ${ALL_LOGS[*]} | grep -q ."
check "B12 no new \$HOME/.claude.json.codd-bak-* or ~/.claude/settings.json.codd-bak-* (names only)" test "$(home_backups)" == "$HOME_BACKUPS_BEFORE"
check "B12 ~/.codex/config.toml: same size and mtime (or still absent)" test "$(codex_stamp)" == "$CODEX_BEFORE"
codex_writes() {
    # Every source line that names a .codex path; none of them may be a write.
    local lines
    lines="$(grep -rnE '(^|[^A-Za-z])\.codex(/|")' "$REPO/App" "$REPO"/Packages/*/Sources 2>/dev/null | grep -v '/Tests/')"
    echo "$lines" | sed 's/^/E2E   .codex: /' | cut -c1-200
    ! printf '%s\n' "$lines" | grep -qE 'write\(|createFile|createDirectory|FileHandle\(forWriting|replaceItem|moveItem|copyItem|\.atomic|fopen|open\('
}
check "B12 source grep: no CODD code path writes under .codex" codex_writes
find "$ROOT"/*/work "$ROOT/u/wa" "$ROOT/u/drop" -name '*.md' 2>/dev/null | sort >"$ROOT/work-md-after.txt"
check "B12 no .md written into the work and project folders (only the fixture repos' own files)" cmp -s \
    <(sort -u "$MDBASE") "$ROOT/work-md-after.txt"
check "B12 every .md outside the fixtures is under a data root's notes/ or a trash folder" bash -c \
    "! find '$ROOT' -name '*.md' -not -path '*/d/notes/*' -not -path '*/trash/*' -not -path '*/work/frontend/*' -not -path '*/work/repo/*' | grep -q ."

fi

echo "E2E time $((SECONDS - STARTED)) s"
echo "E2E leftover processes before cleanup: $( (pgrep -f "$ROOT/"; pgrep -f "$ROOTV/") 2>/dev/null | sort -u | wc -l | tr -d ' ')"
nothing_left() { ! ours_left; }
check "every app of the run quit and every holder ended (no process carries the temp folder)" wait_for 5 nothing_left
echo "E2E pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

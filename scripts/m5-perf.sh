#!/bin/bash
# M5 performance budgets: launch, idle CPU, session switch, memory, GPU (docs/M5-PLAN.md §2.8, D16, D17;
# docs/ARCHITECTURE.md "Performance budgets"). Measures a CODD build in the background on fresh temp
# roots (scripts/m2-fixtures/make-root.sh: own hook port) with a temp Claude directory, silent fake
# claudes and `zsh -f` shells: never the user's data root or ~/.claude, never a real claude, never focus.
#
#   scripts/m5-perf.sh
#   CODD_APP=<…/CODD.app/Contents/MacOS/CODD>   default build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD
#   ONLY=launch,idle,switch,memory,gpu          sections to run (default: all)
#   PERF_JSON=<file>                            also write the results as JSON
#   KEEP=1                                      keep the temp folder (logs, roots)
#
# Output: first `PERF env load1=<x> cpus=<n> build=<Debug|Release>` (a loaded Mac makes every number
# worse: only a quiet, sequential run decides budgets, D16), then one line per metric
#   PERF <name> value=<v><unit> budget=<op><b><unit> PASS|FAIL|SKIP (<note>)
# and `PERF summary pass=<n> fail=<n> skip=<n>`. Exit 1 on any FAIL or when a CODD window rose above
# another app's window (scripts/lib/zorder-guard.sh over the whole run), 2 on a setup error, 64 on a
# bad ONLY. Progress goes to stderr.
#
# Scenarios (every launch: -codd-data-root and -codd-claude-dir as their own arguments, -codd-login-env
# NO, -codd-notifications NO, -codd-claude-path <fake claude>, -codd-shell-argv "/bin/zsh -f",
# CODD_BACKGROUND=1; every holder and fake it started is ended by `pkill -f <its temp folder>/`):
#   launch  real mode on a root seeded with 15 STOPPED claude sessions (seed-layout.sh, extended), the
#           `perf launch-to-sidebar ms=<n> rows=<n>` log line, 3 runs, median.
#   idle    15 sessions = 12 shells (-codd-spawn-shell, -codd-spawn-count 12) + 3 silent fake claudes (3
#           seeded STOPPED claude sessions, -codd-resume-stopped YES); CPU over 10 s, once with
#           -CODDForceVisibleTimers YES (visible: from 125 s after launch, once every row is past the
#           2 minutes in which its durations count seconds, i.e. redraw every second; that is a
#           running clock, not idle) and once with -codd-close-main-window YES (hidden: from 12 s,
#           nothing draws); the holders summed over both runs. CPU = proc_pid_rusage user + system
#           (nanoseconds; `ps -o cputime` only resolves 10 ms, too coarse for 0.05 %).
#   switch  -CODDMetrics YES -codd-real-holders YES (else -CODDMetrics runs mock mode) -CODDMetricsDelay
#           6 -CODDMetricsPasses 3 -CODDMetricsVerbose YES with 15 shells: hot = -CODDMetricsSessions 4,
#           cold = all 15 in order (every switch past the 6 hot surfaces).
#   memory  phys_footprint 20 s after launch: the app on an empty root (base), and the app plus each
#           holder in the 15-session run (proc_pid_rusage, the number `footprint` prints).
#   gpu     mock mode with waiting lamps pulsing (-codd-mock -CODDForceVisibleTimers YES): footprint at
#           5 s and 35 s; one shown shell printing a 10 Hz spinner versus a quiet one with
#           -codd-force-render YES, the difference added to the 15-session total.
#
# Hooks this script needs from integration step I1 (docs/M5-PLAN.md §4): the `perf launch-to-sidebar`
# log line, -codd-force-render YES and -CODDMetricsSessions <n>. Until a build has them the affected
# lines are SKIP with the reason (and a fallback number, labeled so); found by looking for their
# strings in the build, and checked again in the run's output.
set -uo pipefail
# Launched CODDs stay in the background: no focus, no Dock icon (App/AppActivation.swift).
export CODD_BACKGROUND=1

# Budgets: mirror docs/ARCHITECTURE.md "Performance budgets" (plus D16's cold switch); a budget is
# changed in both places together, with the measured number and the reason. Columns: name, comparison,
# value, unit, what is measured. Changed (I4, 2026-10-19): gpu_animating_total 300 → 550 MB. The
# perf component measured the extra of a visible animating terminal as the Metal driver's per-process
# pool (27–28 regions of 8 MB, about 225 MB, the same with a 60-line Metal program that has no window
# and no libghostty; independent of window size and frame rate; it leaves about 1 s after the last
# frame), so the quiet 300 MB plus that pool once per process is the budget while anything animates.
# A `<name>.debug` row replaces `<name>` when the measured build is Debug. Added (fix round 1,
# 2026-10-19): launch_to_sidebar.debug < 450 ms. The Debug build measured 443–453 ms (log after the
# hook endpoint) and 410 ms (log when the rows are installed, as now) at load1 2.1 on an M4 Max: its
# unoptimized Swift builds and shows the main window in 175 ms (didFinishLaunching 105 ms → window
# shown 281 ms); the product target (a Release build) stays < 400 ms.
BUDGETS='
launch_to_sidebar     <   400   ms  launch to interactive sidebar, 15 stopped sessions, median of 3 runs
launch_to_sidebar.debug < 450   ms  the same, measured on a Debug build (unoptimized Swift)
idle_cpu_visible      <   0.5   %   app CPU, window visible (timers forced), 15 sessions
idle_cpu_hidden       <   0.1   %   app CPU, main window closed, 15 sessions
idle_cpu_holders      <   0.05  %   the 15 holders together (holders ~ 0), worse of the two runs
switch_hot_p50        <   16    ms  session switch among 4 sessions (hot after the first pass), p50
switch_hot_max        <   16    ms  the same, max
switch_cold_max       <   50    ms  session switch through 15 sessions in order (every switch cold), max
memory_holder_max     <=  2.5   MB  phys_footprint of each holder (the largest of 15)
memory_app_base       <   80    MB  app phys_footprint, real mode, no sessions
memory_total_15       <   300   MB  app + 15 holders, 15 quiet sessions
gpu_lamps_growth      <   5     MB  mock mode, waiting lamps pulse: footprint growth over 30 s
gpu_animating_total   <   550   MB  memory_total_15 plus what one visible animating terminal adds (Metal pool ~225 MB)
'

ALL_SECTIONS="launch idle switch memory gpu"
ONLY="${ONLY:-}"
if [[ -n "$ONLY" ]]; then
    for _id in ${ONLY//,/ }; do
        case " $ALL_SECTIONS " in
            *" $_id "*) ;;
            *) echo "PERF unknown section '$_id' in ONLY (valid: ${ALL_SECTIONS// /,})" >&2; exit 64 ;;
        esac
    done
fi
sel() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"
APP="${CODD_APP:-build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD}"
FIX="$REPO/scripts/m2-fixtures"
PY="${PYTHON3:-python3}"

# The first line, before anything can fail: the load and the build this run measured.
MACOS_DIR="$(cd "$(dirname "$APP")" 2>/dev/null && pwd -P)"
BUILD=Release
if [[ -e "$MACOS_DIR/CODD.debug.dylib" || "$APP" == */Debug/* ]]; then BUILD=Debug; fi
LOAD1="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
CPUS="$(sysctl -n hw.ncpu 2>/dev/null)"
echo "PERF env load1=${LOAD1:-?} cpus=${CPUS:-?} build=$BUILD"

if [[ ! -x "$APP" ]]; then
    echo "PERF missing $APP (build the app first)" >&2
    exit 2
fi
command -v "$PY" >/dev/null || { echo "PERF needs python3" >&2; exit 2; }
APP="$MACOS_DIR/$(basename "$APP")"

# Short (holder sockets must stay under 104 bytes) and resolved (`pkill -f` matches it verbatim).
TMP0="$(mktemp -d "${TMPDIR:-/tmp}/codd-perf.XXXXXX")" || { echo "PERF mktemp failed" >&2; exit 2; }
T="$(cd "$TMP0" && pwd -P)" || exit 2
case "$T" in
    /*/codd-perf.??????) ;;
    *) echo "PERF unexpected temp folder '$T'" >&2; exit 2 ;;
esac
CLAUDE_DIR="$T/claude"
WORK="$T/work"
FAKE="$T/bin/fake-claude"
SPINNER="$T/bin/spinner"
RESULTS="$T/results.tsv"
mkdir -p "$CLAUDE_DIR/sessions" "$CLAUDE_DIR/projects" "$WORK" "$T/bin" || exit 2
: >"$RESULTS"
cp "$FIX/fake-claude-m2.sh" "$FAKE" && chmod +x "$FAKE" || exit 2
# The animating terminal of the gpu section: a 10 Hz spinner on one line (no spaces in its argv:
# -codd-shell-argv splits on spaces).
cat >"$SPINNER" <<'EOF'
#!/bin/sh
while :; do
    for c in '|' '/' '-' '\'; do
        printf '\r%s working' "$c"
        sleep 0.1
    done
done
EOF
chmod +x "$SPINNER" || exit 2

# proc_pid_rusage of each pid: "now <monotonic ns>" first, then "<pid> <cpu ns> <phys_footprint bytes>"
# for every pid still alive. CPU is user + system, converted from mach ticks.
cat >"$T/bin/rusage.py" <<'EOF'
import ctypes, sys, time
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class RusageV0(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired", "resident",
        "phys_footprint", "start_abstime", "exit_abstime")]
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
timebase = Timebase()
libsystem.mach_timebase_info(ctypes.byref(timebase))
print("now", time.monotonic_ns())
for arg in sys.argv[1:]:
    info = RusageV0()
    if arg.isdigit() and libproc.proc_pid_rusage(int(arg), 0, ctypes.byref(info)) == 0:
        ticks = info.user + info.system
        print(arg, ticks * timebase.numer // timebase.denom, info.phys_footprint)
EOF

ZRC=0
FINISHED=0
# Ends every process this run started (all of them run from, or name, the temp folder), then the
# window-stack guard (after the last CODD quit).
stop_all() {
    pkill -CONT -f "$T/" 2>/dev/null
    pkill -TERM -f "$T/" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        pgrep -f "$T/" >/dev/null || break
        sleep 0.3
    done
    pkill -KILL -f "$T/" 2>/dev/null
    if declare -F zorder_guard_end >/dev/null; then
        zorder_guard_end || ZRC=1
    fi
}
remove_temp() {
    if [[ "${KEEP:-0}" == 1 ]]; then echo "PERF kept $T" >&2; else rm -rf -- "$T"; fi
}
on_exit() {
    local rc=$?
    [[ $FINISHED == 1 ]] && return
    stop_all
    remove_temp
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

note() { echo "perf: $*" >&2; }

# The window-stack guard over the whole run (test-tools, docs/M5-PLAN.md §2.11).
if [[ -f "$REPO/scripts/lib/zorder-guard.sh" ]]; then
    # shellcheck source=lib/zorder-guard.sh
    source "$REPO/scripts/lib/zorder-guard.sh"
    zorder_guard_begin "$T" "$APP" >&2 || { echo "PERF zorder guard did not start" >&2; exit 2; }
else
    echo "PERF scripts/lib/zorder-guard.sh missing: the window stack is not checked" >&2
fi

# ---- I1 hooks: present in this build? ----------------------------------------------------------
has_string() {
    local file
    for file in "$MACOS_DIR/CODD" "$MACOS_DIR/CODD.debug.dylib"; do
        [[ -f "$file" ]] && grep -aqF -- "$1" "$file" && return 0
    done
    return 1
}
HAS_LAUNCH_LINE=0; has_string "perf launch-to-sidebar" && HAS_LAUNCH_LINE=1
HAS_FORCE_RENDER=0; has_string "-codd-force-render" && HAS_FORCE_RENDER=1
HAS_METRICS_SESSIONS=0; has_string "CODDMetricsSessions" && HAS_METRICS_SESSIONS=1
note "I1 hooks in this build: launch-line=$HAS_LAUNCH_LINE force-render=$HAS_FORCE_RENDER metrics-sessions=$HAS_METRICS_SESSIONS"

# ---- Results -------------------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0

# budget_field <name> <column 2|3|4>: the `<name>.debug` row on a Debug build when there is one.
budget_field() {
    local value=""
    [[ "$BUILD" == Debug ]] && value="$(awk -v n="$1.debug" -v c="$2" '$1 == n { print $c; exit }' <<<"$BUDGETS")"
    [[ -n "$value" ]] || value="$(awk -v n="$1" -v c="$2" '$1 == n { print $c; exit }' <<<"$BUDGETS")"
    printf '%s\n' "$value"
}

# record <name> <value|n/a> <result> <note>
record() {
    local name="$1" value="$2" result="$3" text="$4" op unit budget shown
    op="$(budget_field "$name" 2)"; budget="$(budget_field "$name" 3)"; unit="$(budget_field "$name" 4)"
    shown="$value"; [[ "$value" == n/a ]] || shown="$value$unit"
    echo "PERF $name value=$shown budget=$op$budget$unit $result ($text)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$value" "$unit" "$op" "$budget" "$result" "$text" >>"$RESULTS"
    case "$result" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        *) SKIP=$((SKIP + 1)) ;;
    esac
}

# emit <name> <value> <note>: PASS / FAIL against the table; an empty value is a SKIP.
emit() {
    local name="$1" value="$2" text="$3" op budget ok
    if [[ -z "$value" || "$value" == n/a ]]; then
        record "$name" n/a SKIP "$text"
        return
    fi
    op="$(budget_field "$name" 2)"; budget="$(budget_field "$name" 3)"
    ok="$(awk -v v="$value" -v b="$budget" -v op="$op" 'BEGIN {
        if (op == "<") r = (v < b); else if (op == "<=") r = (v <= b); else r = 0; print r }')"
    if [[ "$ok" == 1 ]]; then record "$name" "$value" PASS "$text"; else record "$name" "$value" FAIL "$text"; fi
}

# skip <name> <value|n/a> <note>
skip() { record "$1" "${2:-n/a}" SKIP "$3"; }

# ---- Helpers -------------------------------------------------------------------------------------
# A fresh data root with its own hook port.
make_root() { "$FIX/make-root.sh" "$1" >/dev/null; }

# seed_root <root> <n>: seed-layout.sh's groups and projects with exactly n STOPPED claude sessions
# (no holder runs for them) and nothing else (its shell and archived sessions are dropped, so a
# resume-stopped run starts exactly n claudes).
seed_root() {
    local root="$1" count="$2"
    "$FIX/seed-layout.sh" "$root" "$root-work" >/dev/null || return 1
    "$PY" -I - "$root/layout.json" "$count" <<'PY'
import json, os, sys, time, uuid
path, total = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as f:
    layout = json.load(f)

def iso(t):
    ms = int(round(t * 1000))
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms // 1000)) + ".%03dZ" % (ms % 1000)

projects = layout["projects"]
sessions = [s for s in layout["sessions"] if s["kind"] == "claude" and "archivedAt" not in s][:total]
orders = {}
for s in sessions:
    orders[s["projectId"]] = max(orders.get(s["projectId"], -1), s["order"])
now = time.time()
index = 0
while len(sessions) < total:
    project = projects[index % len(projects)]
    order = orders.get(project["id"], -1) + 1
    orders[project["id"]] = order
    sessions.append({"id": str(uuid.uuid4()), "projectId": project["id"], "kind": "claude", "order": order,
                     "pinned": False, "color": "none", "createdAt": iso(now - 3600 * (index + 1)),
                     "title": "perf session %d" % (index + 1), "claudeSessionId": str(uuid.uuid4()),
                     "launchProfileId": "claude-default", "lastState": {"kind": "idle"},
                     "lastStateAt": iso(now - 600 * (index + 1))})
    index += 1
layout["sessions"] = sessions
data = (json.dumps(layout, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n").encode("utf-8")
tmp = path + ".tmp-%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "wb") as f:
    f.write(data)
os.replace(tmp, path)
PY
}

# launch <log> <timeout s> <root> [flags…]: one CODD in the background (sets PID) with the flags every
# run needs; later flags win (another -codd-shell-argv).
PID=""
launch() {
    local log="$1" timeout="$2" root="$3"; shift 3
    perl -e 'alarm shift; exec @ARGV' "$timeout" "$APP" -codd-data-root "$root" -codd-claude-dir "$CLAUDE_DIR" \
        -codd-claude-path "$FAKE" -codd-shell-argv "/bin/zsh -f" -codd-login-env NO -codd-notifications NO \
        "$@" >"$log" 2>&1 &
    PID=$!
}

# finish_app <pid> <root>: waits for the app (it quits by itself), then ends what it left behind: the
# root's holders (they outlive the app) and the run's children started from $T/bin (fake claudes,
# the spinner). Runs are sequential, so nothing of another run is still alive.
finish_app() {
    local pid="$1" root="$2"
    wait "$pid" 2>/dev/null
    pkill -TERM -f "$root/" 2>/dev/null
    pkill -TERM -f "$T/bin/" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -f "$root/" >/dev/null && ! pgrep -f "$T/bin/" >/dev/null; then break; fi
        sleep 0.3
    done
    pkill -KILL -f "$root/" 2>/dev/null
    pkill -KILL -f "$T/bin/" 2>/dev/null
}

holders_of() { pgrep -f "$1/bin/codd-holder-" | tr '\n' ' '; }
rusage() { "$PY" -I "$T/bin/rusage.py" "$@"; }

# Arithmetic on rusage samples (python: bash has no floats).
# cpu_pct <sample0> <sample1> <pid…>: the pids' CPU between the samples, % of one core.
cpu_pct() {
    "$PY" -I - "$@" <<'PY'
import sys
def parse(text):
    rows = dict(line.split(" ", 1) for line in text.splitlines() if line.strip())
    return int(rows.pop("now")), {k: int(v.split()[0]) for k, v in rows.items()}
t0, a = parse(sys.argv[1])
t1, b = parse(sys.argv[2])
pids = [p for p in sys.argv[3:] if p in a and p in b]
used = sum(b[p] - a[p] for p in pids)
print("%.3f %d" % (used / (t1 - t0) * 100 if t1 > t0 else 0.0, len(pids)))
PY
}
# footprint_mb <sample> <pid…>: "<sum MB> <max MB> <count>".
footprint_mb() {
    "$PY" -I - "$@" <<'PY'
import sys
rows = dict(line.split(" ", 1) for line in sys.argv[1].splitlines() if line.strip())
rows.pop("now", None)
values = [int(rows[p].split()[1]) / 1048576 for p in sys.argv[2:] if p in rows]
print("%.1f %.1f %d" % (sum(values), max(values) if values else 0.0, len(values)))
PY
}
median3() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
num() { awk -v v="$1" 'BEGIN { printf "%.1f", v }'; }
sub_mb() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", a - b }'; }
add_mb() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", a + b }'; }

# ---- launch --------------------------------------------------------------------------------------
if sel launch; then
    note "launch: 15 stopped sessions, 3 runs"
    R="$T/la"
    make_root "$R" && seed_root "$R" 15 || { echo "PERF launch root setup failed" >&2; exit 2; }
    values=(); rows=""
    for run in 1 2 3; do
        launch "$T/la-$run.log" 60 "$R" -codd-quit-after 6
        finish_app "$PID" "$R"
        line="$(grep -o 'perf launch-to-sidebar ms=[0-9.]* rows=[0-9]*' "$T/la-$run.log" | head -1)"
        if [[ -n "$line" ]]; then
            values+=("$(sed 's/.* ms=\([0-9.]*\).*/\1/' <<<"$line")")
            rows="$(sed 's/.* rows=//' <<<"$line")"
        fi
    done
    if [[ ${#values[@]} == 3 ]]; then
        emit launch_to_sidebar "$(median3 "${values[@]}")" "median of ${values[*]} ms, rows=$rows"
    else
        # Fallback until I1: -CODDMetrics's own launch metric (no delay, real holders), labeled so.
        why="no 'perf launch-to-sidebar' line"
        [[ $HAS_LAUNCH_LINE == 1 ]] || why="$why: the build lacks it (I1)"
        fallback=()
        for run in 1 2 3; do
            launch "$T/lm-$run.log" 90 "$R" -CODDMetrics YES -codd-real-holders YES
            finish_app "$PID" "$R"
            v="$(sed -n 's/^METRIC launch_to_sidebar_ms=\([0-9.]*\) rows=\([0-9]*\).*/\1 \2/p' "$T/lm-$run.log" | head -1)"
            [[ -n "$v" ]] && fallback+=("${v%% *}") && rows="${v##* }"
        done
        if [[ ${#fallback[@]} -gt 0 ]]; then
            skip launch_to_sidebar "$(median3 "${fallback[@]}")" \
                "$why; fallback = -CODDMetrics launch_to_sidebar_ms, median of ${fallback[*]} ms, rows=$rows"
        else
            skip launch_to_sidebar n/a "$why; the -CODDMetrics fallback printed nothing either"
        fi
    fi
fi

# ---- idle (and the 15-session memory sample) ------------------------------------------------------
# fifteen <name> <cpu start s> <flag…>: 12 shells + 3 resumed fake claudes; the memory sample at 20 s
# after launch, the CPU over 10 s from <cpu start> (12, or ≥ 20). Sets F_CPU (app %), F_HOLD
# (holders %), F_HOLDERS (count), F_MEM_APP, F_MEM_HOLD_SUM, F_MEM_HOLD_MAX (MB at 20 s).
fifteen() {
    local name="$1" cpu_at="$2"; shift 2
    local root="$T/$name" app s0 s1 s20 holders
    F_CPU=""; F_HOLD=""; F_HOLDERS=0; F_MEM_APP=""; F_MEM_HOLD_SUM=""; F_MEM_HOLD_MAX=""
    make_root "$root" && seed_root "$root" 3 || { echo "PERF $name root setup failed" >&2; return 1; }
    launch "$T/$name.log" $((cpu_at + 80)) "$root" -codd-spawn-shell "$WORK" -codd-spawn-count 12 -codd-resume-stopped YES \
        -codd-quit-after $((cpu_at > 12 ? cpu_at + 18 : 30)) "$@"
    app=$PID
    sleep 12
    holders="$(holders_of "$root")"
    if (( cpu_at > 12 )); then
        sleep 8
        # shellcheck disable=SC2086
        s20="$(rusage "$app" $holders)"
        sleep $((cpu_at - 20))
        # shellcheck disable=SC2086
        s0="$(rusage "$app" $holders)"
        sleep 10
        # shellcheck disable=SC2086
        s1="$(rusage "$app" $holders)"
    else
        # shellcheck disable=SC2086
        s0="$(rusage "$app" $holders)"
        sleep 8
        # shellcheck disable=SC2086
        s20="$(rusage "$app" $holders)"
        sleep 2
        # shellcheck disable=SC2086
        s1="$(rusage "$app" $holders)"
    fi
    finish_app "$app" "$root"
    read -r F_CPU _ < <(cpu_pct "$s0" "$s1" "$app")
    # shellcheck disable=SC2086
    read -r F_HOLD F_HOLDERS < <(cpu_pct "$s0" "$s1" $holders)
    read -r F_MEM_APP _ _ < <(footprint_mb "$s20" "$app")
    # shellcheck disable=SC2086
    read -r F_MEM_HOLD_SUM F_MEM_HOLD_MAX _ < <(footprint_mb "$s20" $holders)
    note "$name: app ${F_CPU}% holders ${F_HOLD}% (n=$F_HOLDERS) app ${F_MEM_APP} MB holders ${F_MEM_HOLD_SUM} MB"
}

if sel idle || sel memory; then
    if sel idle; then
        note "15 sessions, window visible (timers forced); CPU from 125 s (about 2.5 min)"
        fifteen iv 125 -CODDForceVisibleTimers YES
    else
        note "15 sessions, window visible (timers forced)"
        fifteen iv 12 -CODDForceVisibleTimers YES
    fi
    V_CPU="$F_CPU"; V_HOLD="$F_HOLD"; V_HOLDERS="$F_HOLDERS"
    MEM_APP="$F_MEM_APP"; MEM_HOLD_SUM="$F_MEM_HOLD_SUM"; MEM_HOLD_MAX="$F_MEM_HOLD_MAX"
fi
if sel idle; then
    note "15 sessions, main window closed"
    fifteen ih 12 -codd-close-main-window YES
    H_CPU="$F_CPU"; H_HOLD="$F_HOLD"; H_HOLDERS="$F_HOLDERS"
    emit idle_cpu_visible "$V_CPU" "10 s from 125 s after launch (rows past their seconds), holders=$V_HOLDERS of 15"
    emit idle_cpu_hidden "$H_CPU" "10 s from 12 s after launch, holders=$H_HOLDERS of 15"
    worse="$(awk -v a="${V_HOLD:-0}" -v b="${H_HOLD:-0}" 'BEGIN { printf "%.3f", (a > b ? a : b) }')"
    emit idle_cpu_holders "$worse" "visible run ${V_HOLD:-?} %, hidden run ${H_HOLD:-?} %, $V_HOLDERS / $H_HOLDERS holders summed"
fi

# ---- switch --------------------------------------------------------------------------------------
# switch_run <name> <shell count> [flag…]: sets S_P50 S_MAX S_N from the METRIC summary line.
switch_run() {
    local name="$1" count="$2"; shift 2
    local root="$T/$name" line
    S_P50=""; S_MAX=""; S_N=""
    make_root "$root" || return 1
    launch "$T/$name.log" 120 "$root" -CODDMetrics YES -codd-real-holders YES -CODDMetricsDelay 6 \
        -CODDMetricsPasses 3 -CODDMetricsVerbose YES -codd-spawn-shell "$WORK" -codd-spawn-count "$count" "$@"
    finish_app "$PID" "$root"
    line="$(grep -o 'METRIC session_switch_ms p50=[0-9.]* max=[0-9.]* n=[0-9]*' "$T/$name.log" | tail -1)"
    [[ -n "$line" ]] || return 1
    S_P50="$(sed 's/.*p50=\([0-9.]*\).*/\1/' <<<"$line")"
    S_MAX="$(sed 's/.*max=\([0-9.]*\).*/\1/' <<<"$line")"
    S_N="$(sed 's/.*n=//' <<<"$line")"
}

if sel switch; then
    note "switch: 15 shells in order (cold)"
    if switch_run sc 15; then
        spawned="$(grep -c 'spawned session=' "$T/sc.log")"
        if [[ "$S_N" == 15 ]]; then
            emit switch_cold_max "$S_MAX" "15 shells in order, last of 3 passes, p50 $S_P50 ms, spawned=$spawned"
        else
            skip switch_cold_max "$S_MAX" "expected 15 switches per pass, got n=$S_N (spawned=$spawned)"
        fi
    else
        skip switch_cold_max n/a "no METRIC session_switch_ms line (log $T/sc.log)"
    fi
    if [[ $HAS_METRICS_SESSIONS == 1 ]]; then
        note "switch: 4 of 15 shells (hot)"
        if switch_run sh 15 -CODDMetricsSessions 4 && [[ "$S_N" == 4 ]]; then
            emit switch_hot_p50 "$S_P50" "4 of 15 shells (-CODDMetricsSessions 4), last of 3 passes"
            emit switch_hot_max "$S_MAX" "4 of 15 shells (-CODDMetricsSessions 4), last of 3 passes, p50 $S_P50 ms"
        else
            skip switch_hot_p50 "${S_P50:-n/a}" "-CODDMetricsSessions 4 not honored (n=${S_N:-none})"
            skip switch_hot_max "${S_MAX:-n/a}" "-CODDMetricsSessions 4 not honored (n=${S_N:-none})"
        fi
    else
        # Fallback until I1: only 4 shells exist, so every switch after the first pass is hot.
        note "switch: 4 shells only (hot fallback)"
        if switch_run sh4 4; then
            skip switch_hot_p50 "$S_P50" "-CODDMetricsSessions missing (I1); fallback = 4 shells only, last of 3 passes"
            skip switch_hot_max "$S_MAX" "-CODDMetricsSessions missing (I1); fallback = 4 shells only, last of 3 passes"
        else
            skip switch_hot_p50 n/a "-CODDMetricsSessions missing (I1); the 4-shell fallback printed no METRIC line"
            skip switch_hot_max n/a "-CODDMetricsSessions missing (I1); the 4-shell fallback printed no METRIC line"
        fi
    fi
fi

# ---- memory --------------------------------------------------------------------------------------
TOTAL15=""
if sel memory; then
    note "memory: empty root"
    R="$T/mb"
    make_root "$R" || exit 2
    launch "$T/mb.log" 60 "$R" -codd-quit-after 24
    app=$PID
    sleep 20
    sample="$(rusage "$app")"
    finish_app "$app" "$R"
    read -r base _ _ < <(footprint_mb "$sample" "$app")
    emit memory_app_base "$base" "real mode, no sessions, 20 s after launch"
    if [[ -n "${MEM_APP:-}" && "${V_HOLDERS:-0}" -gt 0 ]]; then
        emit memory_holder_max "$MEM_HOLD_MAX" "largest of $V_HOLDERS holders, 20 s after launch"
        TOTAL15="$(add_mb "$MEM_APP" "$MEM_HOLD_SUM")"
        emit memory_total_15 "$TOTAL15" "app $MEM_APP MB + $V_HOLDERS holders $MEM_HOLD_SUM MB, 20 s after launch"
    else
        skip memory_holder_max n/a "the 15-session run measured nothing (log $T/iv.log)"
        skip memory_total_15 n/a "the 15-session run measured nothing (log $T/iv.log)"
    fi
fi

# ---- gpu -----------------------------------------------------------------------------------------
if sel gpu; then
    force=()
    [[ $HAS_FORCE_RENDER == 1 ]] && force=(-codd-force-render YES)
    note "gpu: mock mode, lamps pulse"
    R="$T/gl"
    make_root "$R" || exit 2
    launch "$T/gl.log" 60 "$R" -codd-mock -CODDForceVisibleTimers YES ${force[@]+"${force[@]}"} -codd-quit-after 40
    app=$PID
    sleep 5
    a="$(rusage "$app")"
    sleep 30
    b="$(rusage "$app")"
    finish_app "$app" "$R"
    read -r m5 _ _ < <(footprint_mb "$a" "$app")
    read -r m35 _ _ < <(footprint_mb "$b" "$app")
    if [[ -n "$m5" && -n "$m35" && "$m5" != 0.0 ]]; then
        lamp_note="footprint $m5 MB at 5 s, $m35 MB at 35 s"
        [[ $HAS_FORCE_RENDER == 1 ]] || lamp_note="$lamp_note; without -codd-force-render (I1) a covered window may pause the lamps"
        emit gpu_lamps_growth "$(sub_mb "$m35" "$m5")" "$lamp_note"
    else
        skip gpu_lamps_growth n/a "no footprint sample (log $T/gl.log)"
    fi

    # One shown shell: quiet, then a 10 Hz spinner; footprint 15 s after launch.
    for kind in quiet spin; do
        note "gpu: one $kind shell"
        R="$T/g$kind"
        make_root "$R" || exit 2
        argv="/bin/zsh -f"; [[ $kind == spin ]] && argv="$SPINNER"
        launch "$T/g$kind.log" 60 "$R" -codd-spawn-shell "$WORK" -codd-spawn-count 1 -codd-shell-argv "$argv" \
            ${force[@]+"${force[@]}"} -codd-quit-after 20
        app=$PID
        sleep 15
        sample="$(rusage "$app")"
        finish_app "$app" "$R"
        read -r mb _ _ < <(footprint_mb "$sample" "$app")
        if [[ $kind == quiet ]]; then QUIET_MB="$mb"; else SPIN_MB="$mb"; fi
    done
    if [[ -n "${QUIET_MB:-}" && -n "${SPIN_MB:-}" && "$QUIET_MB" != 0.0 && "$SPIN_MB" != 0.0 ]]; then
        extra="$(sub_mb "$SPIN_MB" "$QUIET_MB")"
        if [[ -n "$TOTAL15" ]]; then
            base_total="$TOTAL15"; base_note="memory_total_15 $TOTAL15 MB"
        else
            base_total="$QUIET_MB"; base_note="no memory_total_15 in this run: the quiet app $QUIET_MB MB"
        fi
        text="an animating terminal adds $extra MB (spinner $SPIN_MB MB - quiet $QUIET_MB MB), on top of $base_note"
        if [[ $HAS_FORCE_RENDER == 1 ]]; then
            emit gpu_animating_total "$(add_mb "$base_total" "$extra")" "$text"
        else
            skip gpu_animating_total "$(add_mb "$base_total" "$extra")" \
                "-codd-force-render missing (I1): whether the covered window drew is up to its occlusion state; $text"
        fi
    else
        skip gpu_animating_total n/a "no footprint sample (logs $T/gquiet.log, $T/gspin.log)"
    fi
fi

# ---- Summary -------------------------------------------------------------------------------------
FINISHED=1
trap - EXIT
stop_all
if [[ -n "${PERF_JSON:-}" ]]; then
    "$PY" -I - "$RESULTS" "$PERF_JSON" "${LOAD1:-}" "${CPUS:-}" "$BUILD" "$APP" "$ZRC" <<'PY'
import json, sys
results, out, load1, cpus, build, app, zrc = sys.argv[1:8]
metrics = []
with open(results, encoding="utf-8") as f:
    for line in f:
        name, value, unit, op, budget, result, note = line.rstrip("\n").split("\t")
        metrics.append({"name": name, "value": None if value == "n/a" else float(value), "unit": unit, "op": op,
                        "budget": float(budget), "result": result, "note": note})
summary = {r: sum(1 for m in metrics if m["result"] == r) for r in ("PASS", "FAIL", "SKIP")}
document = {"env": {"load1": load1, "cpus": cpus, "build": build, "app": app},
            "metrics": metrics, "zorderOk": zrc == "0",
            "summary": {"pass": summary["PASS"], "fail": summary["FAIL"], "skip": summary["SKIP"]}}
with open(out, "w", encoding="utf-8") as f:
    json.dump(document, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
fi
remove_temp
echo "PERF summary pass=$PASS fail=$FAIL skip=$SKIP"
[[ $FAIL == 0 && $ZRC == 0 ]] || exit 1
exit 0

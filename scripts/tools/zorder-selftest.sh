#!/bin/bash
# Self test of the window-stack tooling (docs/M5-PLAN.md §2.11): scripts/tools/zorder.sh stop and
# scripts/lib/zorder-guard.sh on simulated watcher logs, so a violation is proven to fail a script
# without launching CODD. LIVE=1 also runs the real watcher (no app is started): `zorder.sh run 2`
# and a start / stop round trip whose --exe-prefix names no process. Everything happens in one mktemp
# folder, removed at the end. Prints `ZORDERTEST ok|FAIL …` and `ZORDERTEST pass=<n> fail=<m>`; exit 1
# when a check failed.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
TOOL="$REPO/scripts/tools/zorder.sh"
LIB="$REPO/scripts/lib/zorder-guard.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/codd-zordertest.XXXXXX")" || exit 2
T="$(cd "$T" && pwd -P)" || exit 2
trap 'rm -rf -- "$T"' EXIT
PASS=0
FAIL=0
check() {
    local what="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); echo "ZORDERTEST ok   $what"; else FAIL=$((FAIL + 1)); echo "ZORDERTEST FAIL $what"; fi
}

# A log as the watcher writes it; pid 999999 is no zorder-watch, so stop signals nothing.
write_log() {
    local log="$1" violations="$2"
    {
        echo "zorder start seconds=3600 owner=CODD pid=999999 exe-prefix=/x/CODD.app/ ignore=2 never-ignore=1"
        if [[ "$violations" != none && "$violations" != 0 ]]; then
            echo "ABOVE 2026-10-18T12:00:00Z: CODD window above Safari[123]"
        fi
        [[ "$violations" == none ]] || echo "zorder samples=25 withOwner=10 violations=$violations ignored=1 stopped=signal"
    } >"$log"
}
status_is() { local want="$1"; shift; "$@" >/dev/null 2>&1; [[ $? == "$want" ]]; }
# The output is captured first: under pipefail a pipe into grep would report the command's own exit status.
output_has() { local want="$1" out; shift; out="$("$@" 2>&1)"; grep -qF -- "$want" <<<"$out"; }

# 1. zorder.sh stop reads the summary.
write_log "$T/clean.log" 0
write_log "$T/bad.log" 3
write_log "$T/none.log" none
check "stop: clean log exits 0" status_is 0 "$TOOL" stop "$T/clean.log"
check "stop: clean log prints the summary" output_has "violations=0 ignored=1" "$TOOL" stop "$T/clean.log"
check "stop: violations exit 1" status_is 1 "$TOOL" stop "$T/bad.log"
check "stop: violations print the ABOVE line" output_has "ABOVE 2026-10-18T12:00:00Z" "$TOOL" stop "$T/bad.log"
check "stop: no summary exits 1" status_is 1 "$TOOL" stop "$T/none.log"
check "start without --exe-prefix is refused (64)" status_is 64 "$TOOL" start "$T/x.log"

# 2. The guard, as a script uses it: the cleanup-trap pattern of the e2e scripts.
cat >"$T/script.sh" <<'EOF'
#!/bin/bash
# script.sh <lib> <log> <exit status of the checks>
set -uo pipefail
source "$1"
cleanup() {
    local rc=$?
    if ! zorder_guard_end && [[ $rc == 0 ]]; then rc=1; fi
    exit "$rc"
}
trap cleanup EXIT
ZORDER_GUARD_STATE=running   # as zorder_guard_begin leaves it, without a live watcher
ZORDER_GUARD_LOG="$2"
echo "E2E pass=3 fail=0"
exit "$3"
EOF
chmod +x "$T/script.sh"
check "guard: a clean run keeps exit 0" status_is 0 "$T/script.sh" "$LIB" "$T/clean.log" 0
check "guard: a violation fails a run whose checks passed (exit 1)" status_is 1 "$T/script.sh" "$LIB" "$T/bad.log" 0
check "guard: prints E2E zorder violations=3 (log …)" output_has "E2E zorder violations=3 (log " "$T/script.sh" "$LIB" "$T/bad.log" 0
check "guard: an earlier failure keeps its own status (2)" status_is 2 "$T/script.sh" "$LIB" "$T/bad.log" 2
check "guard: no summary fails the run" status_is 1 "$T/script.sh" "$LIB" "$T/none.log" 0
# The violation message names a copy of the log outside the run's temp folder (its cleanup removes it).
kept_log() {
    local out kept
    out="$("$T/script.sh" "$LIB" "$T/bad.log" 0 2>&1)"
    kept="$(sed -n 's/^E2E zorder violations=3 (log \(.*\))$/\1/p' <<<"$out")"
    [[ -f "$kept" && "$kept" != "$T/"* ]] || return 1
    rm -f "$kept"
}
check "guard: the kept log outlives the temp folder" kept_log
idempotent() (
    source "$LIB"
    ZORDER_GUARD_STATE=running
    ZORDER_GUARD_LOG="$T/bad.log"
    zorder_guard_end >/dev/null 2>&1
    local first=$? second
    second="$(zorder_guard_end 2>&1; echo "rc=$?")"
    rm -f "${TMPDIR:-/tmp}/codd-zorder-$(basename "$0" .sh)-$$.log"
    [[ $first == 1 && "$second" == "rc=1" ]]
)
check "guard: a second end returns the first result silently" idempotent
never_begun() ( source "$LIB"; zorder_guard_end )
check "guard: never begun returns 0" never_begun
disabled() ( source "$LIB"; ZORDER=0 zorder_guard_begin "$T" /bin/sh >/dev/null && zorder_guard_end )
check "guard: ZORDER=0 skips it" disabled
rm -f "${TMPDIR:-/tmp}"/codd-zorder-script-*.log 2>/dev/null

# 3. LIVE=1: the real watcher (window server only; no app is launched).
if [[ "${LIVE:-0}" == 1 ]]; then
    check "live: build" "$TOOL" build
    check "live: run 2 prints a summary" output_has "zorder samples=" "$TOOL" run 2
    pid="$("$TOOL" start "$T/live.log" --exe-prefix "$T/none.app/" --seconds 30)"
    sleep 1
    check "live: start prints the watcher pid" bash -c "ps -o comm= -p '$pid' | grep -q zorder-watch"
    check "live: stop ends it with violations=0" output_has "violations=0" "$TOOL" stop "$T/live.log"
    check "live: the watcher is gone" bash -c "! kill -0 '$pid' 2>/dev/null"
fi

echo "ZORDERTEST pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]

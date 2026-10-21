# Window-stack guard for the scripts that launch CODD (docs/M5-PLAN.md §2.11, D23). Sourced by bash:
#
#   source scripts/lib/zorder-guard.sh
#   zorder_guard_begin "$ROOT" "$APP"   # once APP is resolved and the cleanup trap is set, before the first launch
#   …
#   zorder_guard_end || rc=1            # in the cleanup / exit path, after every CODD of the run has quit
#
# begin starts scripts/tools/zorder.sh with --exe-prefix = the .app bundle of the binary (only this
# build's windows are the run's; the user's own CODD is another app like any other) and --watch-pid $$
# (the watcher ends by itself when the script dies without running its trap). end stops it and prints
# the summary line; when a window of the app rose above another app's normal window, or the watcher
# could not start or left no summary, it prints `E2E zorder violations=<n> (log <path>)` and returns 1,
# so the script fails even when every check passed. The log is copied out of <tmpdir> first (the
# cleanup removes that folder). end is idempotent: a later call returns the first result silently, and
# a guard that never began returns 0. ZORDER=0 skips the guard (manual debugging only: such a run says
# nothing about the window stack).

# A run started inside a CODD claude session inherits that session's variables: its tools would then
# report to the user's own CODD and run the user's own status line (m3 A12 measured 110 ms per
# statusline call). Every script that launches CODD sources this file, so they are dropped here.
unset CODD_STATUSLINE_CHAIN CODD_STATUSLINE_TIMEOUT_MS CODD_HOOK_URL CODD_HOOK_TOKEN CODD_SESSION_ID

ZORDER_GUARD_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" && pwd -P)/zorder.sh"
ZORDER_GUARD_STATE=""   # "" not begun, off, failed, running, done
ZORDER_GUARD_RESULT=0
ZORDER_GUARD_LOG=""

# zorder_guard_begin <tmpdir> <app binary>
zorder_guard_begin() {
    local tmpdir="$1" app="$2" dir abs bundle pid
    [[ -z "$ZORDER_GUARD_STATE" ]] || return 0
    if [[ "${ZORDER:-1}" == 0 ]]; then
        ZORDER_GUARD_STATE=off
        echo "E2E zorder skipped (ZORDER=0: the window stack is not checked)"
        return 0
    fi
    ZORDER_GUARD_LOG="${tmpdir%/}/zorder.log"
    dir="$(cd "$(dirname "$app")" 2>/dev/null && pwd -P)"
    abs="$dir/$(basename "$app")"
    case "$abs" in
        *.app/*) bundle="${abs%%.app/*}.app/" ;;
        *) bundle="$abs" ;;
    esac
    if [[ -z "$dir" ]] || ! pid="$("$ZORDER_GUARD_TOOL" start "$ZORDER_GUARD_LOG" --exe-prefix "$bundle" --watch-pid "$$")"; then
        ZORDER_GUARD_STATE=failed
        echo "E2E zorder watcher did not start (app $app)"
        return 1
    fi
    ZORDER_GUARD_STATE=running
    # Its first sample comes right after the start line: wait for it, so the first launch is watched.
    local _
    for _ in $(seq 30); do
        grep -q '^zorder start ' "$ZORDER_GUARD_LOG" 2>/dev/null && break
        sleep 0.1
    done
    echo "E2E zorder watching pid=$pid exe-prefix=$bundle"
}

# zorder_guard_end: prints the summary; returns 1 on a violation (see the header).
zorder_guard_end() {
    local out rc n
    case "$ZORDER_GUARD_STATE" in
        ""|off) return 0 ;;
        done) return "$ZORDER_GUARD_RESULT" ;;
        failed)
            ZORDER_GUARD_STATE=done
            ZORDER_GUARD_RESULT=1
            echo "E2E zorder violations=unknown (log $(zorder_guard_keep))"
            return 1
            ;;
    esac
    out="$("$ZORDER_GUARD_TOOL" stop "$ZORDER_GUARD_LOG" 2>&1)"
    rc=$?
    ZORDER_GUARD_STATE=done
    [[ -n "$out" ]] && printf '%s\n' "$out"
    if [[ $rc == 0 ]]; then
        ZORDER_GUARD_RESULT=0
        return 0
    fi
    ZORDER_GUARD_RESULT=1
    n="$(sed -n 's/^zorder samples=.* violations=\([0-9]*\).*/\1/p' <<<"$out" | tail -1)"
    echo "E2E zorder violations=${n:-unknown} (log $(zorder_guard_keep))"
    return 1
}

# Copies the log next to the temp folders (the run's own folder is removed by its cleanup) and prints
# where it is; prints the original path when the copy fails.
zorder_guard_keep() {
    local base="${TMPDIR:-/tmp}" kept
    kept="${base%/}/codd-zorder-$(basename "$0" .sh)-$$.log"
    if [[ -f "$ZORDER_GUARD_LOG" ]] && cp "$ZORDER_GUARD_LOG" "$kept" 2>/dev/null; then
        echo "$kept"
    else
        echo "$ZORDER_GUARD_LOG"
    fi
}

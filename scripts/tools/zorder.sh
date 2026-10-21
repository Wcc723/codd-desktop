#!/bin/bash
# Window-stack watcher front end (docs/M5-PLAN.md §2.11, D23). Repo-relative: works from any cwd.
#
#   zorder.sh build                                   # swiftc -O into build/tools/zorder-watch when missing or stale
#   zorder.sh start <log> --exe-prefix <dir> [--seconds <n>] [watcher options…]
#                                                     # background watcher, prints its pid (default 3600 s)
#   zorder.sh stop <log>                              # SIGINT, waits at most 5 s, prints the summary line;
#                                                     # exit 1 when violations > 0 or there is no summary
#   zorder.sh run <seconds> [watcher options…]        # foreground (exit 1 on a violation)
#
# start and run add `--ignore-prefix <repo>/build/ --ignore-prefix <repo>/.build --never-ignore-prefix
# <repo>/build/user-`: other agents' test builds and SwiftPM demos (codd-term-demo) order their windows
# back like a test CODD and are not the app under test, while the user's own build/user-* CODD always
# counts as another app. The app under test (--exe-prefix) wins over both. Watcher options:
# --exe-prefix, --ignore-prefix, --never-ignore-prefix (repeatable), --watch-pid <pid> (stop once that
# process is gone). See scripts/tools/zorder-watch.swift for the rules and the output lines.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
SRC="$REPO/scripts/tools/zorder-watch.swift"
BIN="$REPO/build/tools/zorder-watch"
DEFAULTS=(--ignore-prefix "$REPO/build/" --ignore-prefix "$REPO/.build" --never-ignore-prefix "$REPO/build/user-")

usage() {
    sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 64
}

# Builds into a temp name and renames, so two scripts starting at once never run a half-written binary.
build() {
    [[ -x "$BIN" && ! "$SRC" -nt "$BIN" ]] && return 0
    mkdir -p "$(dirname "$BIN")" || return 1
    local tmp="$BIN.tmp.$$"
    if ! swiftc -O -swift-version 6 -o "$tmp" "$SRC" >"$tmp.log" 2>&1; then
        echo "zorder build failed:" >&2
        cat "$tmp.log" >&2
        rm -f "$tmp" "$tmp.log"
        return 1
    fi
    rm -f "$tmp.log"
    mv -f "$tmp" "$BIN" && echo "zorder built $BIN" >&2
}

# summary <log>: the watcher's last summary line (empty when it wrote none).
summary() { grep -E '^zorder samples=' "$1" 2>/dev/null | tail -1; }

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift
case "$cmd" in
    build)
        build
        ;;
    start)
        log="${1:-}"
        [[ -n "$log" && "$log" != -* ]] || usage
        shift
        seconds=3600
        args=()
        have_exe=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --seconds) [[ $# -ge 2 && "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage; seconds="$2"; shift 2 ;;
                --exe-prefix) [[ $# -ge 2 && -n "$2" ]] || usage; have_exe=1; args+=("$1" "$2"); shift 2 ;;
                --ignore-prefix|--never-ignore-prefix|--watch-pid) [[ $# -ge 2 ]] || usage; args+=("$1" "$2"); shift 2 ;;
                *) usage ;;
            esac
        done
        # Without it the owner is every window NAMED CODD, the user's own CODD included.
        [[ "$have_exe" == 1 ]] || { echo "zorder start needs --exe-prefix <dir> (the app under test)" >&2; exit 64; }
        build || exit 1
        mkdir -p "$(dirname "$log")" || exit 1
        : >"$log" || exit 1
        # stdin from /dev/null and its own stdout: the caller's pipes close when the caller is done.
        "$BIN" "$seconds" "${DEFAULTS[@]}" ${args[@]+"${args[@]}"} </dev/null >"$log" 2>&1 &
        pid=$!
        echo "$pid" >"$log.pid"
        echo "$pid"
        ;;
    stop)
        log="${1:-}"
        [[ -n "$log" ]] || usage
        pid="$(cat "$log.pid" 2>/dev/null)"
        [[ -n "$pid" ]] || pid="$(sed -n 's/^zorder start .* pid=\([0-9]*\).*/\1/p' "$log" 2>/dev/null | head -1)"
        # Only ever signal our own watcher (a pid file can outlive its process and the pid be reused).
        if [[ -n "$pid" ]] && ps -o comm= -p "$pid" 2>/dev/null | grep -q 'zorder-watch'; then
            kill -INT "$pid" 2>/dev/null
            for _ in $(seq 50); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                echo "zorder watcher $pid did not stop within 5 s; killed" >&2
                kill -KILL "$pid" 2>/dev/null
            fi
        fi
        rm -f "$log.pid"
        line="$(summary "$log")"
        if [[ -z "$line" ]]; then
            echo "zorder no summary in $log" >&2
            exit 1
        fi
        violations="$(sed -n 's/.* violations=\([0-9]*\).*/\1/p' <<<"$line")"
        if [[ "${violations:-0}" != 0 ]]; then
            grep -E '^ABOVE ' "$log" | head -5 >&2
        fi
        echo "$line"
        [[ "${violations:-1}" == 0 ]]
        ;;
    run)
        seconds="${1:-}"
        [[ "$seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage
        shift
        build || exit 1
        exec "$BIN" "$seconds" "${DEFAULTS[@]}" "$@"
        ;;
    *)
        usage
        ;;
esac

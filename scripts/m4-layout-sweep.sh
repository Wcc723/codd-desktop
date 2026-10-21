#!/bin/bash
# M4 layout sweep: renders every screen of the main window, its sheets, the Settings sections and
# the menu bar panel at the sweep's window sizes and zoom levels into PNGs, for a person (or an
# agent) to look at. Mock mode only (SPEC §5 data, a temporary notebook): nothing on the user's
# data root, no holders, no claude. Every launch stays in the background, and `-codd-window-size`
# keeps the user's saved window frame and split positions untouched.
#
# Usage: CODD_APP=<…/CODD.app/Contents/MacOS/CODD> scripts/m4-layout-sweep.sh <out dir> [filter]
#   filter: only renders whose name contains it (e.g. `min20`, `notebook`, `settings`).
#   JOBS=<n> parallel launches (default 4), WAIT=<s> seconds before the snapshot (default 5).
#   CODD_APP defaults to the build/dd Debug build like the e2e scripts. The window-stack guard
#   (docs/M5-PLAN.md D23) watches every launch: its log is <out dir>/zorder.log, and the sweep exits 1
#   when a window of this build rose above another app's window.
#
# Matrix (M4 layout-sweep brief):
#   min13    the window's minimum size at UI 字級 13
#   min20    the window's minimum size at UI 字級 20 (the largest zoom)
#   live20   a live zoom: 854x560 at UI 字級 13, then 放大 ×7 to 20 once the screen shows (the window
#            grows to the new minimum; every view is refreshed in place, not rebuilt)
#   1280z20  1280x800 at UI 字級 20
#   2560z13  2560x1080 at UI 字級 13
#   sidebar-{min,max,collapsed}  the session pane at the minimum size with the sidebar so
#   settings-{min13,min20,default20}  every Settings section (`-codd-settings-all`)
#   dialog-*  the sheets (quit, switch, hooks, add account) at min13 and min20
set -u
export CODD_BACKGROUND=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${CODD_APP:-$ROOT/build/dd/Build/Products/Debug/CODD.app/Contents/MacOS/CODD}
OUT=${1:?usage: m4-layout-sweep.sh <out dir> [filter]}
FILTER=${2:-}
JOBS=${JOBS:-4}
WAIT=${WAIT:-5}
mkdir -p "$OUT"
[[ -x $APP ]] || { echo "no CODD binary at $APP (set CODD_APP)"; exit 1; }
source "$ROOT/scripts/lib/zorder-guard.sh"

PIDS=()
cleanup() {
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null; done
    # Stops the watcher of an interrupted sweep; after the normal end below it returns silently.
    zorder_guard_end
}
trap cleanup EXIT INT TERM
zorder_guard_begin "$OUT" "$APP"

throttle() {
    while (( $(jobs -rp | wc -l) >= JOBS )); do sleep 0.2; done
}

# run <name> <args…>: one background mock launch that writes <out>/<name>.png (and its sheets).
run() {
    local name=$1
    shift
    [[ -n $FILTER && $name != *$FILTER* ]] && return 0
    throttle
    local args=("$APP" -codd-mock -codd-background YES -codd-notifications NO
                -codd-quit-after "$WAIT" -codd-snapshot "$OUT/$name.png" "$@")
    "${args[@]}" > "$OUT/$name.log" 2>&1 &
    PIDS+=($!)
}

# Window size and zoom of each combo (one argument per array element).
combo_args() {
    case $1 in
        min13) printf '%s\n' -codd-window-size min ;;
        min20) printf '%s\n' -codd-window-size min -codd-set-pref appearance.uiFontSize=20 ;;
        live20) printf '%s\n' -codd-window-size 854x560 -codd-zoom in -codd-zoom in -codd-zoom in -codd-zoom in \
                    -codd-zoom in -codd-zoom in -codd-zoom in ;;
        1280z20) printf '%s\n' -codd-window-size 1280x800 -codd-set-pref appearance.uiFontSize=20 ;;
        2560z13) printf '%s\n' -codd-window-size 2560x1080 ;;
    esac
}

# Screens: name and their flags (`|` separates the arguments).
SCREENS=(
    "session|"
    "composer|-codd-composer-open|YES"
    "panel|-codd-open-panel|YES"
    "home|-codd-show|home"
    "notebook|-codd-show|note:rwd-punch-k7x2"
    "drawer|-codd-show|split"
    "files|-codd-show|files:orb-toolkit-frontend/src/pages/punch.vue"
    "cleanup|-codd-show|cleanup"
    "annotate|-codd-show|annotate:rwd-punch-k7x2:9f3a1c.png"
    "status|-codd-show|status"
    "newsession|-codd-show|new-session"
    "palette|-codd-palette-query|打卡"
    "menubar|-codd-show|menubar"
)

for combo in min13 min20 live20 1280z20 2560z13; do
    IFS=$'\n' read -r -d '' -a sizing < <(combo_args "$combo"; printf '\0')
    for screen in "${SCREENS[@]}"; do
        IFS='|' read -r -a parts <<< "$screen"
        name=${parts[0]}
        flags=("${parts[@]:1}")
        run "$combo-$name" "${sizing[@]}" ${flags[@]+"${flags[@]}"}
    done
done

for width in min max collapsed; do
    run "sidebar-$width" -codd-window-size min -codd-sidebar-width "$width"
done
run "sidebar-max20" -codd-window-size min -codd-sidebar-width max -codd-set-pref appearance.uiFontSize=20

for zoom in 13 20; do
    for dialog in quit switch hooks add; do
        run "dialog-$dialog-min$zoom" -codd-window-size min -codd-set-pref "appearance.uiFontSize=$zoom" -codd-show "dialog-$dialog"
    done
    run "settings-min$zoom" -codd-window-size min -codd-set-pref "appearance.uiFontSize=$zoom" -codd-show settings-general \
        -codd-settings-size min -codd-settings-all YES
done
run "settings-default20" -codd-window-size min -codd-set-pref appearance.uiFontSize=20 -codd-show settings-general \
    -codd-settings-all YES

wait
PIDS=()
count=$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')
echo "LAYOUTSWEEP pngs=$count dir=$OUT"
# Every launch has quit: a window-stack violation is the sweep's exit status.
zorder_guard_end

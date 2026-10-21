#!/bin/bash
# M5 holder compatibility (docs/M5-PLAN.md D19, §2.9): the CURRENT client code (codd-holder-compat,
# built from this working tree: HolderSpawner, SessionDirectory, HolderStream, RingFileReader)
# against codd-holder binaries built from older commits, over wire protocol v1. The working tree's
# own holder runs too, as a control target labeled `head`.
#
# Per commit: `git worktree add --detach build/m5-compat/wt-<short> <commit>` (never build/wt-*), a
# release build of only the `codd-holder` product with its own scratch path
# (build/m5-compat/scratch-<short>), the worktree removed again right after the build, then
# codd-holder-compat on a fresh mktemp root under $TMPDIR (short: socket paths must fit 104 bytes).
# Cleanup (also on failure or Ctrl+C, trap): `git worktree remove --force` of exactly the worktree
# paths this run created (never `git worktree prune`, never another worktree such as build/wt-m4),
# then the temp roots, logs and scratch folders unless KEEP=1. The client ends the holder and child
# it started itself (also on SIGINT / SIGTERM, and after a 150 s watchdog).
#
# No CODD launch, no claude, no network: each holder runs a /bin/sh child that turns on bracketed
# paste, prints compat-ready, echoes input lines and prints `stty size` on SIGWINCH.
#
#   scripts/m5-compat.sh                  # the first commit of the repo (the 1.0 holder), plus head
#   scripts/m5-compat.sh 1b64934 a0526d1  # other commits
#   KEEP=1 scripts/m5-compat.sh           # keep temp roots, logs and scratch folders (worktrees always go)
#
# Output: `COMPAT <short> build ok|FAIL <detail>` per target, then the client's
# `COMPAT <short> <check> ok|FAIL <detail>` lines (spawn meta welcome stream input resize reattach
# paste ring stop), `m5-compat: <short> build <n>s run <n>s` timing lines, and finally
# `COMPAT summary ok=<n> fail=<n>` (every ok / FAIL line counted). Exit 1 on any FAIL.

set -u
# Repo rule for every script; this one never starts CODD.
export CODD_BACKGROUND=1

REPO="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
OUT="$REPO/build/m5-compat"
CLIENT_SCRATCH="$REPO/.build-holder-compat"
TMPBASE="${TMPDIR:-/tmp}"
TMPBASE="${TMPBASE%/}"

if [ "$#" -gt 0 ]; then
  COMMITS=("$@")
else
  COMMITS=("$(git -C "$REPO" rev-list --max-parents=0 HEAD | tail -n 1)")
fi

OK=0
FAIL=0
CREATED_WT=()   # worktree paths this run added (removed in cleanup)
TEMP_PATHS=()   # temp roots and the log folder
SCRATCH=()      # build/m5-compat/scratch-<short>
CLEANED=0

report() { # <label> <check> ok|FAIL <detail…>
  local label=$1 check=$2 result=$3
  shift 3
  echo "COMPAT $label $check $result $*"
  if [ "$result" = ok ]; then OK=$((OK + 1)); else FAIL=$((FAIL + 1)); fi
}

# The first compiler error of a build log (or the last line when there is none), without the
# colour codes and OSC 8 links that swift build writes even into a file.
ESC=$'\033'
first_error() {
  local line
  line=$(grep -m1 -E 'error:' "$1" 2>/dev/null)
  [ -n "$line" ] || line=$(tail -n 1 "$1" 2>/dev/null)
  printf '%s' "${line:-no output}" \
    | sed -e "s/${ESC}\\[[0-9;]*[A-Za-z]//g" -e "s/${ESC}]8;;[^${ESC}]*${ESC}\\\\//g" \
    | tr -d '\r' | cut -c1-400
}

remove_worktree() { # <path>: only paths this run created
  git -C "$REPO" worktree remove --force "$1" >/dev/null 2>&1 \
    || echo "m5-compat: could not remove worktree $1 (remove it with: git worktree remove --force '$1')" >&2
}

cleanup() {
  [ "$CLEANED" = 1 ] && return
  CLEANED=1
  local path
  for path in ${CREATED_WT[@]+"${CREATED_WT[@]}"}; do
    remove_worktree "$path"
  done
  CREATED_WT=()
  if [ "${KEEP:-0}" = 1 ]; then
    for path in ${TEMP_PATHS[@]+"${TEMP_PATHS[@]}"} ${SCRATCH[@]+"${SCRATCH[@]}"}; do
      echo "m5-compat: kept $path"
    done
  else
    for path in ${TEMP_PATHS[@]+"${TEMP_PATHS[@]}"} ${SCRATCH[@]+"${SCRATCH[@]}"}; do
      rm -rf "$path"
    done
    rmdir "$OUT" 2>/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Worktrees registered under build/m5-compat/ (porcelain prints raw paths; the repo path has CJK).
our_worktrees() {
  git -C "$REPO" -c core.quotePath=false worktree list --porcelain | sed -n 's/^worktree //p' | grep -F "$OUT/"
}

LOGS=$(mktemp -d "$TMPBASE/cmplog.XXXXXX") || { echo "m5-compat: mktemp failed" >&2; exit 1; }
TEMP_PATHS+=("$LOGS")

# --- the current client (and the head holder) from the working tree ------------------------------

echo "m5-compat: building codd-holder-compat and the head codd-holder (scratch $CLIENT_SCRATCH)"
start=$SECONDS
if ! swift build --package-path "$REPO/Packages/CoddHolder" --scratch-path "$CLIENT_SCRATCH" \
     --product codd-holder-compat > "$LOGS/build-client.log" 2>&1; then
  report client build FAIL "$(first_error "$LOGS/build-client.log")"
  cleanup
  echo "COMPAT summary ok=$OK fail=$FAIL"
  exit 1
fi
CLIENT_BIN_DIR=$(swift build --package-path "$REPO/Packages/CoddHolder" --scratch-path "$CLIENT_SCRATCH" --show-bin-path 2>/dev/null)
CLIENT="$CLIENT_BIN_DIR/codd-holder-compat"
if [ ! -x "$CLIENT" ]; then
  report client build FAIL "no executable at $CLIENT"
  cleanup
  echo "COMPAT summary ok=$OK fail=$FAIL"
  exit 1
fi
HEAD_HOLDER=""
if swift build --package-path "$REPO/Packages/CoddHolder" --scratch-path "$CLIENT_SCRATCH" \
     --product codd-holder > "$LOGS/build-head.log" 2>&1 && [ -x "$CLIENT_BIN_DIR/codd-holder" ]; then
  HEAD_HOLDER="$CLIENT_BIN_DIR/codd-holder"
fi
CLIENT_BUILD_SECONDS=$((SECONDS - start))

# --- one target -----------------------------------------------------------------------------------

run_target() { # <label> <holder binary> <build seconds>
  local label=$1 holder=$2 build_seconds=$3 root out status started
  root=$(mktemp -d "$TMPBASE/cmp.XXXXXX") || { report "$label" run FAIL "mktemp failed"; return; }
  TEMP_PATHS+=("$root")
  out="$LOGS/run-$label.out"
  started=$SECONDS
  "$CLIENT" --holder "$holder" --root "$root" --label "$label" 2>&1 | tee "$out"
  status=${PIPESTATUS[0]}
  local tag lbl check result rest
  while read -r tag lbl check result rest; do
    [ "$tag" = COMPAT ] || continue
    case "$result" in
      ok) OK=$((OK + 1)) ;;
      FAIL) FAIL=$((FAIL + 1)) ;;
    esac
  done < "$out"
  if [ "$status" -ne 0 ] && ! grep -q "^COMPAT $label [^ ]* FAIL" "$out"; then
    report "$label" client FAIL "codd-holder-compat exited with status $status without a FAIL line"
  fi
  echo "m5-compat: $label build ${build_seconds}s run $((SECONDS - started))s"
}

# --- older commits ----------------------------------------------------------------------------------

mkdir -p "$OUT" || exit 1
for commit in "${COMMITS[@]}"; do
  short=$(git -C "$REPO" rev-parse --short=7 "$commit^{commit}" 2>/dev/null)
  if [ -z "$short" ]; then
    report "$commit" build FAIL "unknown commit"
    continue
  fi
  wt="$OUT/wt-$short"
  scratch="$OUT/scratch-$short"
  if [ -e "$wt" ]; then
    if our_worktrees | grep -qxF "$wt"; then
      # Left by an earlier run that was killed before its trap ran: our own namespace.
      echo "m5-compat: removing the stale worktree $wt"
      remove_worktree "$wt"
    else
      report "$short" build FAIL "$wt exists and is not a registered worktree; remove it by hand"
      continue
    fi
  fi
  echo "m5-compat: building codd-holder at $short (worktree $wt, scratch $scratch)"
  start=$SECONDS
  if ! git -C "$REPO" worktree add --detach "$wt" "$commit" > "$LOGS/worktree-$short.log" 2>&1; then
    report "$short" build FAIL "git worktree add: $(first_error "$LOGS/worktree-$short.log")"
    continue
  fi
  CREATED_WT+=("$wt")
  SCRATCH+=("$scratch")
  holder=""
  if swift build -c release --package-path "$wt/Packages/CoddHolder" --scratch-path "$scratch" \
       --product codd-holder > "$LOGS/build-$short.log" 2>&1; then
    bin_dir=$(swift build -c release --package-path "$wt/Packages/CoddHolder" --scratch-path "$scratch" --show-bin-path 2>/dev/null)
    if [ -x "$bin_dir/codd-holder" ]; then
      holder="$bin_dir/codd-holder"
    else
      report "$short" build FAIL "no codd-holder at $bin_dir"
    fi
  else
    report "$short" build FAIL "$(first_error "$LOGS/build-$short.log")"
  fi
  build_seconds=$((SECONDS - start))
  # The built binary lives in the scratch folder: the worktree is not needed any more.
  remove_worktree "$wt"
  remaining=()
  for path in ${CREATED_WT[@]+"${CREATED_WT[@]}"}; do
    [ "$path" = "$wt" ] || remaining+=("$path")
  done
  CREATED_WT=(${remaining[@]+"${remaining[@]}"})
  [ -n "$holder" ] || continue
  report "$short" build ok "${build_seconds}s release $holder"
  run_target "$short" "$holder" "$build_seconds"
done

# --- the working tree's own holder (control) --------------------------------------------------------

if [ -n "$HEAD_HOLDER" ]; then
  report head build ok "${CLIENT_BUILD_SECONDS}s debug $HEAD_HOLDER"
  run_target head "$HEAD_HOLDER" "$CLIENT_BUILD_SECONDS"
else
  report head build FAIL "$(first_error "$LOGS/build-head.log")"
fi

cleanup
leftover=$(our_worktrees)
if [ -n "$leftover" ]; then
  report cleanup worktrees FAIL "still registered: $(echo "$leftover" | tr '\n' ' ')"
fi
echo "COMPAT summary ok=$OK fail=$FAIL"
[ "$FAIL" -eq 0 ]

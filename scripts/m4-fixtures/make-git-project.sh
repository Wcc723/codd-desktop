#!/bin/bash
# Creates a made-up orb-toolkit-frontend-like git repo for the M4 file editor (docs/M4-PLAN.md C11,
# D24-D27, the FileEditor artboard): src/pages/punch.vue (the artboard's lines 13-49), PunchButton.vue,
# tailwind.config.js, package.json, .gitignore (node_modules/, .env.local), ignored node_modules/x and
# .env.local, CRLF / mixed-EOL / UTF-8 BOM / Big5 / UTF-16 LE / Latin-1 / NUL-byte files and a 6 MiB
# text file. Branch feat/punch-rwd is two commits ahead of a local bare upstream (<dir>/.git/
# fixture-upstream.git, so `↑2`); the working tree then has three modified files: punch.vue (the AI
# hunk `position: fixed; bottom: 0;` -> the artboard's four lines, `@@ -40,2 +40,4 @@`),
# PunchButton.vue and tailwind.config.js.
#
#   scripts/m4-fixtures/make-git-project.sh <dir>
#   -> prints <dir> (absolute)
#
# git runs only with GIT_CONFIG_GLOBAL=<empty temp file>, GIT_CONFIG_NOSYSTEM=1, HOME / XDG_CONFIG_HOME
# pointing at that temp folder (the user's git config, attributes and excludes never apply) and
# `-c core.fsmonitor=false` (no fsmonitor daemon); commits are fixture <fixture@localhost> with fixed
# dates, so the hashes are reproducible. No network: the upstream is a local path. Refuses (exit 1) a
# target inside ~/Library, ~/.claude*, ~/.codex or ~ outside $TMPDIR, or a non-empty <dir>; exit 2 on
# bad arguments. Leaves no process.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: make-git-project.sh <dir>
  Creates the fixture repo in <dir> (missing or empty) and prints its absolute path.
USAGE
    exit 2
}
[[ $# -eq 1 && -n "$1" && "$1" != -* ]] || usage

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PY=/usr/bin/python3
"$PY" -I "$HERE/_m4fix.py" check-target make-git-project "$1"
if [[ -e "$1" && ! -d "$1" ]]; then
    echo "make-git-project: $1 exists and is not a folder; refusing" >&2
    exit 1
fi
if [[ -d "$1" && -n "$(ls -A "$1")" ]]; then
    echo "make-git-project: $1 is not empty; refusing" >&2
    exit 1
fi
mkdir -p "$1"
REPO="$(cd "$1" && pwd -P)"
"$PY" -I "$HERE/_m4fix.py" check-target make-git-project "$REPO"

# Isolated git environment: an empty global config and a throwaway HOME, removed on exit.
GT="$(mktemp -d "${TMPDIR:-/tmp}/codd-m4git.XXXXXX")"
trap 'rm -rf -- "$GT"' EXIT
mkdir -p "$GT/home" "$GT/xdg"
: >"$GT/gitconfig"
while IFS= read -r name; do
    unset "$name"
done < <(compgen -e | grep '^GIT_' || true)
export GIT_CONFIG_GLOBAL="$GT/gitconfig" GIT_CONFIG_NOSYSTEM=1 HOME="$GT/home" XDG_CONFIG_HOME="$GT/xdg"
export GIT_TERMINAL_PROMPT=0 LC_ALL=C TZ=UTC

g() {
    git -C "$REPO" -c user.name=fixture -c user.email=fixture@localhost -c commit.gpgsign=false \
        -c tag.gpgsign=false -c init.defaultBranch=main -c core.fsmonitor=false -c core.autocrlf=false \
        -c core.hooksPath=/dev/null -c gc.auto=0 -c maintenance.auto=false -c core.untrackedCache=false "$@"
}
commit() {
    GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" g commit -q -m "$2"
}

g init -q --template= -b main
"$PY" -I "$HERE/_m4fix.py" git-stage "$REPO" A
g add -A
commit "2026-10-13T09:00:00+08:00" "init: orb-toolkit-frontend 打卡頁"
g switch -q -c feat/punch-rwd
UP="$REPO/.git/fixture-upstream.git"
git -c init.defaultBranch=main -c core.fsmonitor=false init -q --bare --template= "$UP"
g remote add origin "$UP"
g push -q -u origin feat/punch-rwd 2>/dev/null
"$PY" -I "$HERE/_m4fix.py" git-stage "$REPO" B
g add -A
commit "2026-10-14T14:20:00+08:00" "feat: 打卡紀錄卡片（窄螢幕）"
"$PY" -I "$HERE/_m4fix.py" git-stage "$REPO" C
g add -A
commit "2026-10-15T09:10:00+08:00" "fix: 打卡按鈕 loading 狀態"
"$PY" -I "$HERE/_m4fix.py" git-stage "$REPO" work
# Settle the index stat data now, so later read-only `git status --no-optional-locks` calls (CODD)
# never need to rewrite .git/index; modified files stay modified.
g update-index -q --refresh >/dev/null 2>&1 || true
echo "$REPO"

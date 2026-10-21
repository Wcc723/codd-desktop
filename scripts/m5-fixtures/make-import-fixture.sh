#!/bin/bash
# Writes a made-up Claude Code project history for CODD's onboarding import (docs/M5-PLAN.md D8, §2.5;
# m5-e2e O1): project folders under <workDir>, <claudeDir>/../.claude.json with their keys (plus
# unrelated keys and an oauthAccount with a made-up e-mail that CODD must never show), and transcript
# folders <claudeDir>/projects/<sanitized cwd>/ with 1-14 .jsonl files whose first line carries cwd and
# entrypoint (cli; sdk-cli for sdk-runner). File mtimes are set with `touch -t` relative to now, so the
# last-used order is fixed:
#
#   rank  project                                         transcripts  hidden
#   1     solo-tool/.claude-worktrees/solo-tool-wt1       1            worktree
#   2     clients/alpha-web                               14           none
#   3     labs/mcp                                        3            none      (prefix labs/)
#   4     sdk-runner                                      4            sdk
#   5     clients/alpha-api                               5            none
#   6     solo-tool                                       2            none
#   7     labs/x                                          1            none      (prefix labs/; key has a trailing slash)
#   8     clients/legacy-site                             0            none      (no transcript folder: sorted last)
#   -     gone-project                                    listed in .claude.json, folder missing: not a candidate
#
#   scripts/m5-fixtures/make-import-fixture.sh <claudeDir> <workDir>
#   -> prints `SOURCE <.claude.json>`, `EXPECT <rank> <path> transcripts=<n> hidden=<none|worktree|sdk>` per
#      candidate in rank order, and `ABSENT <path>` for the missing project.
#
# Paths are resolved with realpath first. <claudeDir> and <workDir> must be inside $TMPDIR, /tmp or
# /private/tmp (agent scratchpads live under /private/tmp) and never inside $HOME; <claudeDir>'s parent
# (which receives .claude.json) must not be the temp folder itself. Paths must be printable ASCII without
# quotes or backslashes (they go into JSON verbatim). A <claudeDir>/../.claude.json that already exists is
# never overwritten. Refusals exit 1, bad arguments exit 2. Starts no process besides coreutils.
set -u

usage() {
    cat >&2 <<'EOF'
usage: make-import-fixture.sh <claudeDir> <workDir>
  Writes made-up projects under <workDir>, <claudeDir>/../.claude.json and <claudeDir>/projects/*,
  then prints SOURCE / EXPECT / ABSENT lines (see the header of this script).
EOF
    exit 2
}

refuse() {
    echo "make-import-fixture: refused: $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || usage
[[ -n "$1" && -n "$2" ]] || usage

# realpath of a path whose tail may not exist yet (the existing head is resolved, the rest appended).
resolve() {
    local path=$1 rest=""
    [[ "$path" == /* ]] || path="$PWD/$path"
    while [[ "$path" != "/" && ! -d "$path" ]]; do
        rest="/$(basename "$path")$rest"
        path=$(dirname "$path")
    done
    local head
    head=$(cd "$path" && pwd -P) || return 1
    [[ "$head" == "/" ]] && head=""
    printf '%s%s\n' "$head" "$rest"
}

TEMP_ROOTS=()
for root in "${TMPDIR:-}" /tmp /private/tmp; do
    [[ -n "$root" && -d "$root" ]] || continue
    TEMP_ROOTS+=("$(cd "$root" && pwd -P)")
done
HOME_REAL=""
[[ -n "${HOME:-}" && -d "$HOME" ]] && HOME_REAL=$(cd "$HOME" && pwd -P)

inside_temp() {
    local path=$1 root
    for root in "${TEMP_ROOTS[@]}"; do
        [[ "$path" == "$root"/* ]] && return 0
    done
    return 1
}

is_temp_root() {
    local path=$1 root
    for root in "${TEMP_ROOTS[@]}"; do
        [[ "$path" == "$root" ]] && return 0
    done
    return 1
}

check_path() {
    local label=$1 path=$2
    local LC_ALL=C
    if [[ "$path" =~ [^\ -~] || "$path" == *\"* || "$path" == *\\* ]]; then
        refuse "$label must be printable ASCII without quotes or backslashes: $path"
    fi
    inside_temp "$path" || refuse "$label is not inside \$TMPDIR, /tmp or /private/tmp: $path"
    if [[ -n "$HOME_REAL" && ( "$path" == "$HOME_REAL" || "$path" == "$HOME_REAL"/* ) ]]; then
        refuse "$label is inside \$HOME: $path"
    fi
}

CLAUDE_DIR=$(resolve "$1") || refuse "cannot resolve $1"
WORK=$(resolve "$2") || refuse "cannot resolve $2"
check_path "claudeDir" "$CLAUDE_DIR"
check_path "workDir" "$WORK"
PARENT=$(dirname "$CLAUDE_DIR")
is_temp_root "$PARENT" && refuse "claudeDir's parent is the temp folder itself (it receives .claude.json): $PARENT"
CONFIG="$PARENT/.claude.json"
[[ -e "$CONFIG" || -L "$CONFIG" ]] && refuse "$CONFIG already exists"

P_WT="$WORK/solo-tool/.claude-worktrees/solo-tool-wt1"
P_WEB="$WORK/clients/alpha-web"
P_MCP="$WORK/labs/mcp"
P_SDK="$WORK/sdk-runner"
P_API="$WORK/clients/alpha-api"
P_SOLO="$WORK/solo-tool"
P_X="$WORK/labs/x"
P_LEGACY="$WORK/clients/legacy-site"
P_GONE="$WORK/gone-project"

for project in "$P_WT" "$P_WEB" "$P_MCP" "$P_SDK" "$P_API" "$P_SOLO" "$P_X" "$P_LEGACY"; do
    mkdir -p "$project" || refuse "cannot create $project"
    printf '# fixture project\n' > "$project/README.md"
done
mkdir -p "$CLAUDE_DIR/projects" || refuse "cannot create $CLAUDE_DIR/projects"

# Claude's folder name: every character outside [A-Za-z0-9] becomes "-" (the paths are ASCII here).
sanitize() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-'; }

stamp() { date -v-"$1"M +%Y%m%d%H%M.%S; }

# write_transcripts <cwd> <count> <minutes ago of the newest> <entrypoint>
write_transcripts() {
    local cwd=$1 count=$2 ago=$3 entry=$4
    local folder
    folder="$CLAUDE_DIR/projects/$(sanitize "$cwd")"
    [[ ${#folder} -lt 900 ]] || refuse "path too long: $folder"
    mkdir -p "$folder" || refuse "cannot create $folder"
    local i id file when
    for ((i = 0; i < count; i++)); do
        id=$(uuidgen | tr 'A-Z' 'a-z')
        file="$folder/$id.jsonl"
        when=$(date -u -v-"$((ago + i * 7))"M +%Y-%m-%dT%H:%M:%S.000Z)
        printf '{"type":"user","cwd":"%s","sessionId":"%s","entrypoint":"%s","version":"2.1.302","gitBranch":"main","timestamp":"%s","message":{"role":"user","content":"fixture prompt %d"}}\n' \
            "$cwd" "$id" "$entry" "$when" "$i" > "$file"
        printf '{"type":"assistant","cwd":"%s","sessionId":"%s","entrypoint":"%s","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}\n' \
            "$cwd" "$id" "$entry" "$when" >> "$file"
        touch -t "$(stamp "$((ago + i * 7))")" "$file"
    done
    touch -t "$(stamp "$ago")" "$folder"
}

write_transcripts "$P_WT" 1 30 cli
write_transcripts "$P_WEB" 14 60 cli
write_transcripts "$P_MCP" 3 180 cli
write_transcripts "$P_SDK" 4 300 sdk-cli
write_transcripts "$P_API" 5 1560 cli
write_transcripts "$P_SOLO" 2 3000 cli
write_transcripts "$P_X" 1 4440 cli

project_entry() { printf '    "%s": {"allowedTools": [], "hasTrustDialogAccepted": true, "lastCost": 0.12}' "$1"; }

{
    printf '{\n  "numStartups": 42,\n  "installMethod": "native",\n  "autoUpdates": false,\n'
    printf '  "oauthAccount": {"accountUuid": "00000000-0000-4000-8000-000000000000", "emailAddress": "fixture-user@example.com", "organizationName": "Fixture Org"},\n'
    printf '  "projects": {\n'
    first=1
    for key in "$P_WEB" "$P_API" "$P_LEGACY" "$P_MCP" "$P_X/" "$P_SOLO" "$P_WT" "$P_SDK" "$P_GONE"; do
        [[ $first -eq 1 ]] || printf ',\n'
        first=0
        project_entry "$key"
    done
    printf '\n  },\n  "theme": "dark"\n}\n'
} > "$CONFIG" || refuse "cannot write $CONFIG"
chmod 600 "$CONFIG"

echo "SOURCE $CONFIG"
echo "EXPECT 1 $P_WT transcripts=1 hidden=worktree"
echo "EXPECT 2 $P_WEB transcripts=14 hidden=none"
echo "EXPECT 3 $P_MCP transcripts=3 hidden=none"
echo "EXPECT 4 $P_SDK transcripts=4 hidden=sdk"
echo "EXPECT 5 $P_API transcripts=5 hidden=none"
echo "EXPECT 6 $P_SOLO transcripts=2 hidden=none"
echo "EXPECT 7 $P_X transcripts=1 hidden=none"
echo "EXPECT 8 $P_LEGACY transcripts=0 hidden=none"
echo "ABSENT $P_GONE"

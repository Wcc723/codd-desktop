#!/bin/bash
# Writes a temp Claude user settings file shaped like a real ~/.claude/settings.json
# (docs/M3-PLAN.md §1, C9): another hook tool's `hook-tap` handlers on 12 events (PermissionRequest
# timeout 600), two osascript `display notification` handlers (Notification, Stop), unrelated keys
# (env, permissions, enabledPlugins with non-ASCII strings) and a status line; with --legacy also
# the CODD web leftovers (status-writer.js handlers on 10 events in the official shape plus one old
# {matcher, command} entry, and the web status line wrapper chaining the user's command). Every path
# in it is fake and under <claudeDir>/../fixture-tools.
#
#   scripts/m3-fixtures/make-claude-settings.sh <claudeDir> [--legacy] [--user-statusline '<cmd>']
#       [--desktop-global <dataRoot>] [--project <cwd> '<cmd>'] [--force]
#   -> prints <claudeDir>/settings.json (and <cwd>/.claude/settings.json with --project)
#
# --user-statusline defaults to `printf 'USER-SL-%s' ok`; '' means the user has none.
# --desktop-global makes the status line CODD Desktop's own global wrapper (D11) around that command.
# --project also writes <cwd>/.claude/settings.json with only a statusLine (D35 precedence tests).
# Existing files are refused (exit 1) unless --force; so are targets inside ~ outside $TMPDIR,
# ~/Library, ~/.claude, ~/.claude.json, ~/.claude-swap-backup. Bad arguments exit 2.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PY="${PYTHON3:-}"
if [[ -z "$PY" ]]; then
    if [[ -x /usr/bin/python3 ]]; then PY=/usr/bin/python3; else PY=python3; fi
fi
exec "$PY" -I "$HERE/_m3fix.py" claude-settings "$@"

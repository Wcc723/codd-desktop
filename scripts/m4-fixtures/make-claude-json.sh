#!/bin/bash
# Writes a made-up ~/.claude.json-shaped file (docs/M4-PLAN.md C11, D18, D22) laid out like Claude
# Code writes it (JSON.stringify(x, null, 2), no final newline, mode 0600): top-level numStartups,
# projects with made-up paths and their mcpServers, top-level mcpServers (pencil-like stdio,
# stitch-like http), oauthAccount (the M3 fixtures' #3), odd number tokens (1e21, -0, 1.0,
# 12345678901234567890) and CJK strings. Every value is made up.
#
#   scripts/m4-fixtures/make-claude-json.sh <file> [--codd-foreign | --codd-ours <url> <token|@config.json>]
#       [--no-mcp-servers] [--project <cwd>]... [--project-codd <cwd>]... [--extra-projects N] [--force]
#   -> prints <file>
#
# --codd-ours takes the token literally or, as @<config.json>, reads CODD's mcpToken from that file
# (so no token is on the command line). Refuses (exit 1) a target inside ~/Library, ~/.claude*,
# ~/.codex or ~ outside $TMPDIR (the real ~/.claude.json included, through links) or an existing file
# without --force; exit 2 on bad arguments.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
exec /usr/bin/python3 -I "$HERE/_m4fix.py" claude-json "$@"

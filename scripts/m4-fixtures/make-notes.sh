#!/bin/bash
# Writes the M4 notes fixture (docs/M4-PLAN.md C11, §3.1-§3.4): the SPEC §5 notes n1-n7 (made-up
# design data) and the M4 test notes as §3.2 Markdown files with their .codd/ app state, n1's
# 750 x 1334 punch-page screenshot with the R6 annotations, a trashed note, history snapshots and a
# tombstone. README.md has the note table, the search and retention expectations and every option.
#
#   scripts/m4-fixtures/make-notes.sh <notesDir> [--count N] [--old <ISO now>] [--now <ISO>]
#       [--spec|--no-spec] [--session <uuid>] [--project <path>] [--two-images] [--text-annotation]
#       [--manifest <file>]
#   -> prints the created ids, one per line (the note without frontmatter has none)
#
# Refuses (exit 1) a target inside ~/Library, ~/.claude*, ~/.codex or ~ outside $TMPDIR, and a
# <notesDir> that already holds .md files; exit 2 on bad arguments. Starts no process but python.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
exec /usr/bin/python3 -I "$HERE/_m4fix.py" notes "$@"

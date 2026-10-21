#!/bin/bash
# Fake `claude` for CODD end-to-end runs (scripts/m1-e2e.sh): never talks to Anthropic and never
# uses quota. CODD starts it exactly like the real one (`-codd-claude-path`): through a holder,
# with `--session-id` / `--resume`, the per-session `--settings` hooks JSON and the
# CODD_SESSION_ID / CODD_HOOK_TOKEN / CODD_HOOK_URL environment.
#
# Script of one "turn":
#   1. DA1 query (ESC [ c) and wait up to 3 s for the terminal's reply (startup probe rule);
#   2. SessionStart through the codd-hook command named in --settings (the real command-hook path);
#   3. UserPromptSubmit → PreToolUse(Bash) → PermissionRequest(Bash) over curl with the env headers;
#   4. wait for one answer key on the PTY (the answer bar sends it), then PostToolUse → Stop;
#   5. stay alive like claude at its prompt, echoing input lines (the line FAKE-EXIT exits with 3).
# With --resume only SessionStart (source resume) is sent and it waits at the prompt.
set -u
settings="" session="" resume=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --settings) settings="${2:-}"; shift 2 ;;
        --session-id) session="${2:-}"; shift 2 ;;
        --resume) resume="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
claude_session="${resume:-$session}"
cwd="$(pwd)"
url="${CODD_HOOK_URL:-}"

event() { printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s"%s}' "$1" "$claude_session" "$cwd" "${2:-}"; }
post() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 2 -X POST -H 'Content-Type: application/json' \
        -H "X-CODD-Token: ${CODD_HOOK_TOKEN:-}" -H "X-CODD-Session: ${CODD_SESSION_ID:-}" --data-binary "$1" "$url"
}

saved="$(stty -g 2>/dev/null)"
restore() { [[ -n "$saved" ]] && stty "$saved" 2>/dev/null; }

# 1. Startup probe: the attached terminal must answer before anything else happens.
if [[ -t 0 ]]; then
    stty -echo -icanon min 0 time 30
    printf '\033[c'
    reply="$(dd bs=64 count=1 2>/dev/null)"
    restore
    case "$reply" in *'[?'*c*) echo "FAKE-DA1-OK" ;; *) echo "FAKE-DA1-MISSING" ;; esac
fi
printf '\033]0;fake claude\007'
echo "FAKE-CLAUDE session=$claude_session resume=${resume:-none} url=$url"

# 2. SessionStart via the command hook CODD baked into --settings. The SessionStart handler's own
#    "command" (since M3 the settings also carry statusLine.command, which sorts after hooks).
hook="$(printf '%s' "$settings" | sed -n 's/.*"SessionStart":\[{"hooks":\[{[^}]*"command":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')"
if [[ -n "$hook" && -x "$hook" ]]; then
    source="startup"
    [[ -n "$resume" ]] && source="resume"
    event SessionStart ",\"source\":\"$source\"" | "$hook" session-start --url "$url"
    echo "FAKE-SESSIONSTART hook=$hook"
else
    echo "FAKE-SESSIONSTART-MISSING hook=$hook"
fi

if [[ -z "$resume" ]]; then
    sleep 1
    echo "> fix the login bug"
    echo "FAKE prompt=$(post "$(event UserPromptSubmit ',"prompt":"fix the login bug"')")"
    sleep 1
    echo "FAKE pretool=$(post "$(event PreToolUse ',"tool_name":"Bash","tool_input":{"command":"npm test -- auth.spec.ts"}')")"
    sleep 1
    echo "FAKE permission=$(post "$(event PermissionRequest ',"tool_name":"Bash","tool_input":{"command":"npm test -- auth.spec.ts"}')")"
    echo "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No (esc)"
    if [[ -t 0 ]]; then
        stty -echo -icanon min 1 time 0
        key="$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        restore
    else
        key="none"
    fi
    echo "FAKE-ANSWER key=$key"
    echo "FAKE posttool=$(post "$(event PostToolUse ',"tool_name":"Bash"')")"
    sleep 1
    echo "FAKE stop=$(post "$(event Stop)")"
fi
echo "FAKE-CLAUDE-IDLE"
while IFS= read -r line; do
    [[ "$line" == FAKE-EXIT ]] && { echo "FAKE-CLAUDE-EXITING"; exit 3; }
    echo "fake: $line"
done

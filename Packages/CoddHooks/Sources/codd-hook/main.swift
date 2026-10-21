// codd-hook: Claude Code SessionStart command hook. Reads the hook JSON on stdin and POSTs it to the
// CODD endpoint (`--url`), with X-CODD-Token / X-CODD-Session from CODD_HOOK_TOKEN / CODD_SESSION_ID.
// Never writes to stdout, always exits 0 within 2 s (see CoddHookClient.HookCommandMain).
import CoddHookClient

HookCommandMain.main()

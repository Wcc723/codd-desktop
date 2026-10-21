// codd-statusline: Claude Code status-line command for CODD sessions (and the optional global one).
// Forwards stdin's rate_limits to POST /statusline and runs the user's own status line (the chain)
// with the same stdin; its output and exit status are ours. Never prints anything itself.
// See CoddHookClient.StatusLineMain.
import CoddHookClient

StatusLineMain.main()

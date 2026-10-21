/// CoddCore: the UI-free logic of CODD Desktop.
///
/// - Hooks: ``HookReducer`` (port of CODD web `configs/hooks/status-writer.js` `applyEvent`) and
///   ``ActivityMerger`` (port of `session-insights.js` `_activity`). The ``HookDialect/web`` dialect
///   is verified against golden fixtures produced by executing the original JavaScript
///   (`Tests/CoddCoreTests/Fixtures/gen`). The ``HookDialect/desktop`` dialect adds the documented
///   extensions: StopFailure → `error` with ``HookErrorKind``; PreCompact/PostCompact → `compacting`;
///   `idle_prompt` keeps `error`; a SubagentStart/Stop counter; registry `waitingFor` → reason.
/// - Registry: ``ClaudeRegistryReader`` / ``ClaudeRegistryEntry`` for `~/.claude/sessions/<pid>.json`.
/// - Title: ``TerminalTitle`` / ``TerminalTitleTracker`` for Claude's OSC title glyphs.
/// - Accounts: ``CswapClient`` (`cswap … --json`), ``AccountOrdering`` (SPEC R7) and
///   ``AutoSwitchPolicy`` (SPEC R8).
/// - Launch: ``LaunchBuilder``, ``ClaudeHookSettings``, ``SpawnEnvironmentBuilder``,
///   ``LoginShellEnvironmentCapture``.
/// - Process: ``CommandRunner`` and ``ProcessCommandRunner`` (`posix_spawn` in a new session,
///   close-on-exec by default, process-group kill on timeout) for cswap and the login shell.
/// - Models and storage: ``ProjectGroup``, ``Project``, ``SessionRecord``, ``SessionState``,
///   ``Layout``, ``LayoutStore``.
public enum CoddCoreInfo {
    public static let version = "0.1.0"
}

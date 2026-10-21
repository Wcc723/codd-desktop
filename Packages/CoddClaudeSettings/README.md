# CoddClaudeSettings

Reads and edits Claude Code settings files for CODD (M3 C3, docs/M3-PLAN.md D8, D10, D11, D35) and registers CODD's MCP server in Claude Code's user scope, `~/.claude.json` (M4 C10, docs/M4-PLAN.md D22, D23, §3.12). Apple frameworks only (Foundation, CryptoKit, Synchronization), no dependencies. Every function is synchronous blocking I/O: call it off the main actor.

| Part | Role |
|---|---|
| `OrderedJSON` | Lossless JSON: object key order, raw number tokens. `parse(_:)` is strict RFC 8259 (errors carry line and column only, depth limit 512); `serialized(indent:)` is byte-compatible with `JSON.stringify(v, null, indent)` |
| `ClaudeSettingsFile` | `load(_:maxBytes:)`: follows a symlink, missing file = `exists == false` with `{}`, detects the indent and the trailing newline, fingerprints the target (size, mtime ns, inode), notes whether the bytes are canonical |
| `ClaudeSettingsInstaller.inspect` | CODD web leftovers (`status-writer.js` handlers in both hook shapes), foreign tools (`osascript` 通知, else the program name, such as `hook-tap`) with blocking PermissionRequest timeouts, duplicate notification handlers, the status-line state |
| `ClaudeSettingsInstaller.plan` | The Hook 差異 preview for `.update`, `.removeLegacy`, `.uninstall`, `.disableDuplicateNotifications`, `.restore(url)`: 繁中 summary, unified diff of `hooks` / `statusLine` only (foreign handlers elided), +/- counts, backup name, the exact new text. Never writes |
| `ClaudeSettingsInstaller.apply` | Refuses a changed file (`changedSinceRead`), backs up the symlink target's bytes next to the given path (`COPYFILE_EXCL`, `-2`, `-3` on collision), writes through a temp file and a rename, keeps the mode |
| `ClaudeSettingsInstaller.backups(of:)` | `settings.json.codd-bak-*` next to the file, newest first |
| `DesktopStatusLine` | The D11 global wrapper `if [ -x '<bin>' ]; then '<bin>' --data-root '<root>' [--chain-b64 <b64>]; [else /bin/sh -c '<chain>';] fi` and its exact parser |
| `UserStatusLine` | The command a CODD session chains (D35 precedence: cwd `settings.local.json`, cwd `settings.json`, user settings), unwrapping CODD Desktop's own wrapper |
| `ClaudeUserConfigMCPInstaller` | M4: `inspect(ourURL:token:)` / `plan(_:)` / `apply(_:)` of `mcpServers.<name>` in `~/.claude.json` under Claude's own lock; see below |
| `CodexMCPSnippet` | M4: `toml(url:token:)`, the `~/.codex/config.toml` lines the Codex 註冊 dialog shows (CODD never writes `~/.codex`) |

Build and test (own scratch path):

```sh
swift test --package-path Packages/CoddClaudeSettings --scratch-path .build-m3-settings
# M4 C10 acceptance (own scratch path):
swift build --package-path Packages/CoddClaudeSettings --scratch-path .build-m4-claudecfg --build-tests 2>&1 | grep -E 'warning:|error:'
swift test --package-path Packages/CoddClaudeSettings --scratch-path .build-m4-claudecfg
```

Tests build every settings file in a temp directory; `Tests/CoddClaudeSettingsTests/Fixtures/` holds texts generated once with node's `JSON.stringify` (`numbers.json` by hand), with `@TMP@` / `@B64@` filled in at run time; `ClaudeJSONFixture.swift` generates made-up `.claude.json`-shaped files (about 2.4 MB of `projects` with CJK keys and values, `1e21`, `-0`, `1.0`, `12345678901234567890`, escapes, nested arrays, project-scope `mcpServers`, a stdio and an http user server). Nothing reads or writes `~/.claude` or `~/.claude.json`.

## Rules the installer keeps

- Only `hooks` and `statusLine` change. Every other key, the key order, number spellings, the indent and the trailing newline stay; a plan whose text would be identical has `changes == false` and `apply` writes nothing.
- Removing a handler drops its group only when the group became empty, the event key only when its array became empty, and `hooks` only when it became empty.
- A CODD wrapper whose `--chain-b64` does not round-trip is never rewritten (`chainUndecodable`).
- The diff never shows a line outside `hooks` / `statusLine` and never a kept foreign handler (`…（保留既有 n 組 hook）`). The handlers an action removes are shown, including the `osascript` duplicates of `停用重複通知`.
- A file that is not in `JSON.stringify` layout keeps its bytes until something changes; then the summary says the whole file will be re-laid out.

## `~/.claude.json` MCP registration (M4 C10, D22, D23)

```swift
public struct ClaudeUserConfigMCPEntry: Sendable, Equatable { name: String; url: String?; hasHeaders: Bool; tokenMatches: Bool? }
public struct ClaudeUserConfigMCPInspection: Sendable, Equatable { fileExists: Bool; parsable: Bool; serverNames: [String]; codd: ClaudeUserConfigMCPEntry?; fingerprint: SettingsFingerprint? }
public enum ClaudeUserConfigMCPAction: Sendable, Equatable { case register(name: String, url: String, token: String), remove(name: String)
                                                             var name: String; var backupReason: String /* mcp-register | mcp-remove */ }
public struct ClaudeUserConfigMCPPlan: Sendable, Equatable { action; diff: [DiffLine]; summary: String; upToDate: Bool; fingerprint: SettingsFingerprint?
                                                             baseMemberDigest: String?; addedLines: Int; removedLines: Int; backupName: String }
public struct ClaudeUserConfigMCPResult: Sendable, Equatable { backup: URL?; wrote: Bool; indexError: String? }
public enum ClaudeUserConfigMCPError: Error, Sendable, Equatable { case missingFile, invalidJSON(String), changedSinceRead, lockBusy, staleLock(String), notAnObject, io(String) }
public struct ClaudeUserConfigMCPInstaller: Sendable {
  public init(file: URL, backupsIndex: URL?, clock: @escaping @Sendable () -> Date = { Date() }, lockWait: Duration = .seconds(3))
  public var path: String      // file.path with `.` / `..` removed lexically (how Claude names its config)
  public var lockPath: String  // path + ".lock"
  public func inspect(ourURL: String, token: String?) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPInspection
  public func plan(_ action: ClaudeUserConfigMCPAction) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPPlan
  public func apply(_ plan: ClaudeUserConfigMCPPlan) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPResult
}
public enum CodexMCPSnippet { public static func toml(url: String, token: String) -> String }
```

`SettingsFingerprint` gained `sha256: String?` (default nil; the settings.json installer keeps comparing size, mtime and inode only).

**Inspect.** Reads the file (at most 64 MiB, symlinks followed) and runs the strict order-preserving parser over all of it. Missing file: `fileExists == false`. Not JSON: `parsable == false` (no throw). Top level not an object: `.notAnObject`. Only the top-level `mcpServers` is examined: `serverNames` are its keys in file order; `codd` is the entry whose `url` equals `ourURL` (the one named `codd` first when several do), else the entry named `codd` (another server under CODD's name), else nil; for it only `url`, whether `headers` is a non-empty object, and whether `headers["X-CODD-Token"]` (name compared case-insensitively, value compared in constant time) equals `token` (nil when no token is given) leave the call. The fingerprint carries the SHA-256.

**Plan.** `register(name, url, token)` makes `mcpServers.<name>` exactly `{"type":"http","url":url,"headers":{"X-CODD-Token":token}}`: it replaces an existing entry's value (the last occurrence, the one `JSON.parse` keeps), appends a new entry after the last server, or, when the file has no `mcpServers`, appends that member at the end of the top-level object (where assigning it and `JSON.stringify` would put it). `remove(name)` deletes every occurrence of the entry; an emptied `mcpServers` stays as `{}`. `upToDate` when nothing would change (the entry already equals the target value, member order ignored; nothing to remove; `mcpServers` missing or not an object for a removal). A `mcpServers` that is not an object refuses a registration with `.notAnObject`. Missing file `.missingFile`; invalid JSON `.invalidJSON("line L, column C")` (position only, the file is never touched). Summaries (one 繁中 line): `只會在 mcpServers 加入 codd，其他設定不變`, `會新增 mcpServers 並加入 codd，其他設定不變`, `只會更新 mcpServers 裡 codd 的 token，其他設定不變`, `只會更新 mcpServers 裡的 codd，其他設定不變`, `會取代 mcpServers 裡現有的 codd（原本指向其他伺服器），其他設定不變`, `只會從 mcpServers 移除 codd，其他設定不變`, `codd 已經註冊在 mcpServers，不需要變更`, `mcpServers 裡沒有 codd，不需要變更` (with the action's name).

**Diff.** Only the `mcpServers` member, rendered as `JSON.stringify(x, null, 2)` lays it out (the file's own indent unit) and numbered from the member's line in the file: `@@ -a,b +c,d @@  "mcpServers"`, two context lines, every other server's lines (also the `}` that becomes `},` when an entry is appended after it) collapsed into `…（保留既有 n 個 MCP server）`. Values under `headers` and `env`, and under any key named like a credential (`token`, `secret`, `password`, `authorization`, `cookie`, `apikey`, `credential`), are shown as `"••••"`; lines are matched on their real text, so a rotated token shows as one removed and one added `"X-CODD-Token": "••••"` line. `ClaudeUserConfigMCPAction`'s `description`, `debugDescription` and mirror also mask the token (`print(plan)`, `dump(plan)`), and the plan keeps a SHA-256 of the base member, not its bytes (they hold other servers' secrets).

**Apply.** Nothing for an `upToDate` plan. Otherwise: take the lock (below); re-read under it. Same fingerprint (size, mtime ns, inode, SHA-256) as the plan: the previewed edit. Different fingerprint: the file is parsed again; when it still parses, is an object and its `mcpServers` value hashes to the plan's `baseMemberDigest`, the same member edit is spliced into the fresh bytes (Claude rewrites `projects`, counters and caches every few seconds while sessions run; those bytes are kept as Claude wrote them, as its own locked read-merge-write does); a changed `mcpServers`, a file that no longer parses, a missing member that existed (or the reverse) refuse `.changedSinceRead` with nothing written. Then: refresh the lock's mtime; back up the target's bytes with `copyfile(COPYFILE_ALL | COPYFILE_EXCL)` next to the path given as `.claude.json.codd-bak-YYYYMMDD-HHMMSS` (the plan's name, local time of the plan's clock; `-2`, `-3`… on a collision, the settings.json convention, so `ClaudeSettingsInstaller.backups(of:)` lists both kinds); check the backup holds exactly the bytes read and the file is still that version; write a temp file next to the symlink's target with the target's mode, `F_FULLFSYNC`, and rename it only if the lock is still ours and the file is still the version read (a writer that ignores the lock makes the installer re-read and rebase, up to 3 times, then `.changedSinceRead`); record `{name, reason: "mcp-register" | "mcp-remove", at: ISO 8601 UTC with ms, settingsPath: "~/…"}` in `backupsIndex` (`{"v":1,"backups":[…]}`, newest 200, 0600, temp + rename, the format the App's settings.json entries use; an index failure is returned as `indexError`, the file stays written); release the lock. The lock is released on every path (`defer`).

**Bytes kept.** Edits splice bytes: the new value or member is written with the file's layout (indent unit read from the root, LF or CRLF, or compact when the root has no newline after `{`), the separator before an appended member copies the whitespace the object puts before its first key, a removed member takes the separator next to it. Every other byte stays, including other servers inside `mcpServers`, string escapes and number spellings; register then remove gives the original bytes back (unless the registration created `mcpServers`: `"mcpServers": {}` stays). The file keeps Claude's missing trailing newline.

### The `~/.claude.json` lock (verified in the 2.1.302 bundle, read only)

Found with a python `mmap` search of `~/.local/share/claude/versions/2.1.302` (no claude was run, `~/.claude.json` was not read). Minified names are those of that build:

- `Ku` is `saveGlobalConfig`: it queues `IO` on the in-process `global-config` write queue (`Fo`); `IO` calls `Uo` (`saveConfigWithLock`). On a lock failure `IO` falls back to an unlocked write (`Ls`), except when the lock is still held by a live process (`Ns`: `Config lock still held by a live process after retries; skipping the unlocked fallback write`).
- `Uo`: `y = ky()`, `mkdir(dirname(y))`, then ``N = `${y}.lock` `` and `R = await cl(y, {lockfilePath: N, onCompromised})`, retrying `ELOCKED` (`Un`) after `xGs = [200, 400, 800, 1600, 3200, 4000]` ms × (1 + random) (about 10 to 20 s in all), cut short by `lockRetrySignal` during the boot phase (`KO`, 1500 ms `zQs`); above 100 ms it logs `Lock acquisition took longer than expected - another Claude instance may be running` (`tengu_config_lock_contention`). Under the lock it re-reads the file (`Wu`, retrying read errors after 50 / 150 / 450 ms), applies the change to the fresh config, writes `gA(y, JSON.stringify(re, null, 2), {encoding: "utf-8", mode: 384, allowSymlink: true})` and releases in `finally`.
- `gA`: with `allowSymlink` it follows one `readlink` level and writes the target; the existing mode is kept (0600 = 384 for a new file); temp `.tmp.<pid>.<hex>` next to the target, `fsync`, `rename`. The text has no trailing newline.
- `ky()` is `T().getGlobalClaudeFile()` = `Y_()`: the legacy `~/.claude/.config.json` when it exists and is non-empty, else `B()` = `join(CLAUDE_CONFIG_DIR || homedir(), ".claude" + <suffix> + ".json")`: a lexical path, never realpath'd.
- `cl` (the chunk exporting `cl`, `Yqs`, `Gm`) wraps the bundled proper-lockfile `lock` (`Nt`) with its defaults: `stale: 1e4` (at least 2000), `update: stale / 2` clamped to [1000, stale / 2], `realpath: true`, `retries: 0`, so 10 s stale and a 5 s refresh. `Pe` realpaths the file (the file must exist), `ne` returns ``options.lockfilePath || `${file}.lock` ``: Claude passes `lockfilePath`, so the lock directory is `<path as Claude names it>.lock`, next to a symlink rather than its target. `De` acquires with `mkdir(lock)`; on success `probe` sets the directory's mtime to `ceil(now / 1 s) * 1 s + 5 ms` (up to a second ahead); on `EEXIST` it `stat`s the lock and `tt` calls it stale when `mtime < now - stale`, in which case `rt` removes it and acquisition is retried, else `ELOCKED` (`Lock file is already being held`). `he` runs every `update` ms: a lock whose mtime is no longer the one it set (or that is gone) is `ECOMPROMISED`, else it touches the mtime. `nt` (release) removes the directory; a signal-exit handler (`Dt`) removes held locks on exit.
- Not covered by the lock: two synchronous writers (`Ydn` and the project-config one before it) re-read and write `~/.claude.json` with `Yjo` without taking it, and when the server-side flag `tengu_hover_rest` pins `W()` and a storage backend is handed in, `Uo` delegates to `zO`, which writes through that backend's `update` with a content precondition (not examined further).

`UserConfigLock` takes the same lock: `mkdir("<path>.lock", 0777 & ~umask)` on the lexical path. `EEXIST` with a lock whose mtime is at most 10 s old (a future mtime, as Claude's `probe` sets, counts as fresh): poll every 50 ms until `lockWait` (default 3 s), then `.lockBusy`. Older than 10 s (at once or during the wait): `.staleLock("<lock path, ~ abbreviated> 看起來是殘留的鎖，請確認沒有 claude 在執行後再試")`, for the real file exactly `~/.claude.json.lock 看起來是殘留的鎖，請確認沒有 claude 在執行後再試`. CODD never removes a lock it did not create. It records the lock directory's device and inode, touches its mtime before the backup and the write (proper-lockfile's refresh, for a slow read of a large file), renames only while that directory is still its own (`.lockBusy` when another writer took it over) and removes it at the end only when it is still its own. Claude, finding CODD's lock, waits with its own backoff; CODD holds it for the re-read, the backup and the write (about 25 ms for the 2.4 MB fixture in a debug build).

**Limits.** The writers listed above that skip the lock can still land between CODD's last check and its `rename` (the window is the time between a `stat` and a `rename`); CODD's rename can likewise replace a lock-ignoring write made in that window. A stale lock (left by a crashed holder) blocks CODD until something removes it: a running claude removes it at its next config save (proper-lockfile's 10 s rule); otherwise the user deletes `~/.claude.json.lock`. A missing file is refused (Claude's own lock needs the file too: `realpath`). The App and this package both append to `claude-settings-backups.json` without a shared lock; two writes in the same instant can lose one entry. Numbers (debug, this Mac, 2.4 MB fixture): plan 0.09 s, apply 0.025 s, inspect 0.08 s.

**Codex.** `CodexMCPSnippet.toml(url:token:)` returns exactly

```toml
[mcp_servers.codd]
url = "http://127.0.0.1:47821/mcp"
http_headers = { "X-CODD-Token" = "<mcpToken>" }
```

with a final newline (values as TOML basic strings: `"`, `\` and control characters escaped).

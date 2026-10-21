# CoddMCP

CODD's MCP server for notes (M4 C2): a transport-free JSON-RPC handler. The hook server (CoddHooks, `POST /mcp` on the hook port) frames and authenticates each HTTP request and hands it to `MCPServer.handle(_:)`; the app supplies an `MCPNotesBackend` over CoddNotes (I2a). Foundation only, no dependencies, no MCP SDK (the Swift SDK lags the spec, D16): the JSON reader and writer are hand-written, so member order, number text and raw UTF-8 CJK are under our control.

| Part | Role |
|---|---|
| `MCPServer` | `handle(MCPHTTPRequest) async -> MCPHTTPResponse`, `events`, `supportedProtocolVersions` |
| `MCPNotesBackend` | What the app implements: search, list, read, append, write, create, resources, readResource, promptNote, capabilities |
| `MCPServerInfo` | `name` `codd`, `title` `CODD notes`, `version` (the app version), `instructions` |
| `MCPInstructions.notes` | The server instructions (English, about 2,300 characters, tested ≤ 4,096) |
| `MCPCaller` | `.session(UUID)` (a CODD session's token) or `.external` (the external token), set by the hook server |
| Request / result types | `MCPSearchRequest`, `MCPListRequest`, `MCPReadRequest`, `MCPAppendRequest`, `MCPWriteRequest`, `MCPCreateRequest`; `MCPNoteHit`, `MCPImage`, `MCPNoteContent`, `MCPWriteResult`, `MCPCreateResult`, `MCPResourceEntry`, `MCPBackendCapabilities` |
| `MCPBackendError` | `notFound`, `trashed(id:purgeAt:)`, `purged`, `accessDenied`, `invalid`, `tooLarge`, `unavailable`; `message(timeZone:)` is the text the model gets |
| `MCPEvent`, `MCPToolOutcome` | What happened, for client tracking (D21) and diagnostics |
| `MCPLimits` | The limits below as constants |

Build and test (own scratch path):

```sh
swift build --package-path Packages/CoddMCP --scratch-path .build-m4-mcp --build-tests
swift test --package-path Packages/CoddMCP --scratch-path .build-m4-mcp
```

## Wire contract

### HTTP

- **POST only.** `GET` (no server-initiated SSE stream) and `DELETE` (no sessions to end), and any other method, answer `405` with `Allow: POST` and no body.
- **Body.** One JSON-RPC 2.0 message, or a batch array (2025-03-26 style; accepted whatever the version).
- **Requests** are answered `200` with `Content-Type: application/json`. The JSON is UTF-8, `/` is never escaped (`codd://note/<id>`, paths), non-ASCII text is raw UTF-8 (no `\u` escapes for CJK), only `"`, `\` and C0 controls are escaped. Members appear in a fixed order (see the golden files).
- **Only notifications and / or responses** (a body with no request in it) → `202` with an empty body and no content type.
- **Invalid JSON** → `400` with `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: …"}}`. The reader is strict RFC 8259 (UTF-8 validated, a leading BOM skipped, nesting capped at 64 levels).
- **An invalid single message** (not an object, `jsonrpc` not `"2.0"`, no / non-string `method`, an `id` that is not a string or number) → `400` with `-32600` (the id echoed when one could be read). Inside a batch the element gets its `-32600` entry and the batch is `200`. An empty batch → `400` `-32600`.
- **Ids** are echoed exactly as sent (`7`, `"server-discover-probe-1"`, `1.50`).
- **Stateless (D16).** No `Mcp-Session-Id` is ever sent or required; every request stands alone, so an app relaunch, a port rebind or a token rotation never leaves a client with a dead session. No response carries extra headers except `Allow` on 405.
- The hook server owns everything else: Host / Origin rules, tokens, the 1 MiB body cap, 401 / 403 / 413, and 503 when a request takes over 10 s (CoddHooks README).

### Protocol versions

- Supported: `2025-11-25`, `2025-06-18`, `2025-03-26` (`MCPServer.supportedProtocolVersions`).
- `initialize` echoes `params.protocolVersion` when supported, else answers `2025-11-25`. Missing params count as unsupported; a non-string `protocolVersion` is `-32602`.
- The version of any other request is its `MCP-Protocol-Version` header, else `2025-03-26` (the spec default). `title`, `outputSchema` and `structuredContent` appear only for `2025-06-18` and later.
- An `MCP-Protocol-Version` header naming an unsupported version → `400` with `-32600` (`Bad Request: unsupported MCP-Protocol-Version … (supported: 2025-11-25, 2025-06-18, 2025-03-26)`), **except** for `initialize`, `server/discover` and `notifications/initialized`, which never look at the header: Claude Code 2.1.302 first probes `server/discover` (2026-07-28 era) and must always be able to fall back to the legacy handshake.
- `server/discover` → `200` with `-32601` (Claude's probe maps a JSON-RPC error to "legacy" and continues with `initialize`; a timeout would fail the connection).

### Methods

| Method | Result |
|---|---|
| `initialize` | `{protocolVersion, capabilities:{tools:{listChanged:false}, resources:{listChanged:false}, prompts:{listChanged:false}}, serverInfo:{name, title, version}, instructions}` (instructions omitted when empty, cut at 4,096 characters) |
| `ping` | `{}` |
| `notifications/*` | `202` (initialized, cancelled and any other notification) |
| `tools/list` | the tools below in this order; `notes_write` only when `capabilities(caller).writeEnabled`; no pagination (`nextCursor` never sent) |
| `tools/call` | a `CallToolResult` (below) |
| `resources/list` | `{resources:[{uri, name, mimeType:"text/markdown", annotations:{lastModified}}]}`, at most 200 (the backend's order: newest first); `annotations` only when the backend gives a date |
| `resources/templates/list` | `{resourceTemplates:[{uriTemplate:"codd://note/{id}", name:"note", title, description, mimeType:"text/markdown"}]}` |
| `resources/read` | `{contents:[{uri, mimeType:"text/markdown", text}]}` |
| `prompts/list` | one prompt `note` with the required argument `id` |
| `prompts/get` | `{description, messages:[{role:"user", content:{type:"text", text}}]}` |
| anything else (incl. `server/discover`, `logging/setLevel`, `completion/complete`, `resources/subscribe`) | `-32601` |

`params` must be an object when present (else `-32602`); unknown members are ignored.

### Errors

| Code | When |
|---|---|
| `-32700` | the body is not JSON (HTTP 400) |
| `-32600` | not a valid JSON-RPC message, an empty batch, an unsupported version header (HTTP 400) |
| `-32601` | unknown method, `server/discover` (HTTP 200) |
| `-32602` | bad `params` (no `name` / `uri`, wrong types, an unknown tool or prompt), and resource / prompt refusals with `data.state` (below) |
| `-32603` | the backend reported `tooLarge` / `unavailable` for a resource or prompt, or threw a non-backend error (`Internal error`) |

Resource and prompt refusals: `-32602`, message = the reason text, `data` = `{"state":"unknown"}` for `notFound`, `accessDenied` and `invalid` (OFF and out-of-scope notes look exactly like missing ones, so nothing leaks), `{"state":"trashed","purgeAt":"<RFC 3339>"}` (`purgeAt` when known), `{"state":"purged"}`.

### Tools (§3.10)

| Tool | Arguments (validated, then clamped) | Annotations / `_meta` |
|---|---|---|
| `notes_search` | `query` string (required, ≤ 1,000 characters; may be empty when `tags` or `kind` is given), `scope` `all` (default) or `project`, `tags` [string] (a single string accepted; `#` stripped, deduplicated), `kind` `note` / `prompt` / `scratch` (case-insensitive), `include_archived` bool (false), `limit` 1…20 (10) | read-only, `anthropic/alwaysLoad` |
| `notes_list` | `session` `"current"` or a UUID (lowercased), `project` `"current"` or a path, `kind`, `pinned` bool, `days` 1…3650 (no default), `include_archived` (false), `limit` 1…50 (20) | read-only |
| `notes_read` | `ref` string (required, trimmed, ≤ 500 characters; id, `codd://note/<id>`, `[[note:<id>]]`, `@x:codd://note/<id>`, parsed by the backend), `offset` ≥ 0 (0), `max_chars` 1,000…50,000 (12,000), `include_images` bool (true) | read-only, `anthropic/alwaysLoad`, `anthropic/maxResultSizeChars: 200000` |
| `notes_append` | `ref`, `markdown` (non-blank, ≤ 20,000 characters), `heading` (one line: newlines folded, ≤ 200 characters, blank = backend default) | `readOnlyHint false`, `destructiveHint false` |
| `notes_create` | `title` (required; one line: newlines folded, trimmed, a leading `#`…`######` heading marker dropped, non-empty, ≤ 200 characters), `body` (required, non-blank Markdown without the title line, ≤ 100,000 characters like `notes_append` / `notes_write`, schema `maxLength`; well under the hook server's 1 MiB request cap even as `\uXXXX` escapes, so the refusal with its notes_append hint always answers, never a bare 413), `tags` [string] (a single string accepted; each cleaned like the Notebook's tag editor: trimmed, `#` stripped at both ends, whitespace → `-`, NFC; empty ones dropped, deduplicated ignoring case; ≤ 20 tags of ≤ 64 characters), `kind` `note` (default) / `prompt` (case-insensitive; `scratch` refused) | `readOnlyHint false`, `destructiveHint false`, `idempotentHint false`; no `_meta` (Claude's normal permission prompt, which the user may turn into always-allow) |
| `notes_write` | `ref`, `markdown` (non-blank, ≤ 50,000 characters) | `destructiveHint true`, `anthropic/requiresUserInteraction` |

Read-only means `readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false`. Every tool has `annotations.title`; from 2025-06-18 also a top-level `title`, and search / list an `outputSchema`.

- **Lenient types.** `null` counts as absent; integers may come as `10`, `10.0` or `"10"`, booleans as `"true"` / `"false"`; a fraction, a non-numeric string or another type is invalid. Out-of-range numbers are clamped, never refused.
- **Invalid arguments** are not JSON-RPC errors: the result is `isError: true` with `Invalid arguments: …` (English, for the model to correct itself, as 2025-11-25 asks); the backend is not called.
- **notes_write while AI 可寫入 is OFF** (a client may hold an older `tools/list`): `isError` `notes_write 未開啟：使用者需要在 CODD 設定 › 筆記本 & MCP 打開「AI 可寫入」。可以改用 notes_append。`, checked before the arguments, the backend's `write` is never called.

Results:

- **search / list:** one text block, one line per hit plus its snippet (newlines folded) indented by three spaces:
  ```
  1. 打卡頁 RWD 跑版紀錄 · codd://note/rwd-punch-k7x2 · NOTE · updated 10/15 10:05
     iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。
  2. 舊的筆記 · codd://note/old-note-a1b2 · SCRATCH · updated 2025/10/9 16:53 · ARCHIVED
  ```
  (`M/d HH:mm` in the server's time zone, the year added when it is not the current one; non-active states appended.) Empty: `找不到符合「<query>」的筆記。` / `沒有符合條件的筆記。`. From 2025-06-18 also `structuredContent {results:[{id, uri, title, kind, tags, updated (RFC 3339 with offset), snippet, path, state}]}`, always present on success (Claude Code fails a call whose structured content is missing or does not match the `outputSchema`, so the schema uses plain types only). Hits beyond `limit` are dropped.
- **read:** `[text, image…, text?]`: the backend's §3.7 text, plus `\n\n（第 n–m 字，共 N 字；下一段 offset=m）` when `truncated` (`n` = offset + 1, `m` = `nextOffset`; `，共 N 字` only when the backend gives `totalChars`; without `nextOffset`: `（第 n 字起，內容已截斷）`); up to 4 `{type:"image", data:<base64>, mimeType}` blocks, at most 8 MiB of raw image bytes in total; then one text block `其他圖片（未附上，需要時用 Read 開啟）：` listing, one per line, the images not attached (over the cap, `include_images: false`) followed by the backend's `extraImagePaths`. Never `structuredContent`.
- **append / write:** one text block, the backend's `text` (default `已附加到 <uri>` / `已改寫 <uri>`).
- **create:** one text block, never `structuredContent`:
  ```
  已建立筆記 codd://note/<id>「<title>」（INBOX · AI APPEND）
  file: <absolute path of the new note>
  之後可以用 notes_append 附加內容到這則筆記。
  ```
  (`file:` only when the backend gives a path.) The contract the backend keeps: a new note in INBOX only (never an existing one read, edited or overwritten), linked to the calling session and its project, AI access APPEND, the creation recorded as AI activity.
- **Backend errors** → `isError: true`, one text block with `MCPBackendError.message(timeZone:)`:

  | Error | Text |
  |---|---|
  | `notFound(ref)` | `找不到筆記 <ref>` (ref cut at 200 characters) |
  | `trashed(purgeAt:)` | `這則筆記在 CODD 垃圾桶（2026-11-14 永久刪除），請使用者先還原` (without a date: `這則筆記在 CODD 垃圾桶，請使用者先還原`) |
  | `purged` | `這則筆記已永久刪除` |
  | `accessDenied(r)`, `invalid(r)`, `tooLarge(r)` | `r` verbatim (e.g. `這則筆記的 AI 存取是 READ，不能附加`) |
  | `unavailable(r)` | `CODD 筆記本目前無法使用：<r>` |

  Any other thrown error → `CODD 處理這個請求時發生內部錯誤，請稍後再試。` (its type name goes only to the event).

### Events

`MCPServer.events` (single consumer, newest 512 buffered): `.request(caller, method, at)` for every request and notification (not for responses, invalid messages or bodies refused for their version; client-chosen strings in events are clipped: method 100, uri 500, client name 200, client version 100 characters), then, when that request is answered, `.initialized(caller, clientName, clientVersion, protocolVersion, at)` (from `params.clientInfo`, the negotiated version), `.tool(caller, name, outcome, ms, at)` (`.ok`, `.isError(text)`, `.failed(typeName)`; not for unknown tools), `.resource(caller, uri, ok, at)` (resources/read). A successful `notes_create` adds `.created(caller, id, uri, title, at)` (the backend's values; id 100, uri 200, title 200 characters) right before its `.tool`; the app shows its toast from it. `at` comes from the injected clock.

## Golden responses

`Tests/CoddMCPTests/Fixtures/` holds the exact `initialize` response (`initialize.json`), the `tools/list` response for 2025-11-25 without `notes_write` (`tools-list.json`) and for 2025-03-26 with it (`tools-list-2025-03-26-write.json`), pretty-printed (two-space indent, `"key": value`: the same text as Python's `json.dumps(…, indent=2, ensure_ascii=False)`). The test compares the pretty form and checks the wire bytes are the compact form of the same document. After an intended change, run the suite once with `CODD_MCP_RECORD_GOLDEN=1` and review the fixture diff.

## Threading

`MCPServer` is a `final class: Sendable` with only immutable stored properties (the backend, the clock, the time zone, the event continuation). `handle(_:)` is `async` and nonisolated: many requests run at once (tested with 100); the backend is awaited, never on the main actor by this package. Messages of one batch run in order.

## Not supported

- No SSE: replies are always `application/json`, `GET` is 405, nothing is pushed to the client.
- No `listChanged` notifications (declared `false`): a client sees `notes_write` appear or disappear only at its next `tools/list` (Claude Code: reconnect via `/mcp`).
- No sessions, no resumability, no `resources/subscribe`, no `logging`, no `completion`, no pagination cursors, no progress notifications; `notifications/cancelled` is accepted and ignored (each request is one HTTP exchange).
- No image resources (`codd://note/{id}/assets/…`): images reach the model only through `notes_read`.
- The 2026-07-28 revision (`server/discover`) is not implemented; clients fall back to 2025-11-25.

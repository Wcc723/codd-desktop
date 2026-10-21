# CODD Notebook: how to remove old content

## 1. How other apps handle aging content

| App | What it does | Takeaway for CODD |
|---|---|---|
| **Apple Notes** | Deleted notes sit in "Recently Deleted" for 30 days, then are removed from every device. Deleting from there early cannot be undone. [1] | A 30-day trash is what macOS users already expect. |
| **Notion** | Trash keeps pages 30 days. Archived pages stay linkable ("Links to the page still work"). [2] | Archived notes should still open from their URL and over MCP. |
| **Google Keep** | Trash keeps notes 7 days. [3] | 7 days is short enough that people lose things. |
| **Raycast Notes** | Deleted notes can be restored for 60 days. Pinning is the only way to protect a note. [4] | Pinning works as an exemption. |
| **Raycast Clipboard** | "Keep history for" offers 1 Day / 1 Week / 1 Month / 3 Months / 6 Months / 1 Year / Unlimited. [5] | The settings knob should be a list of periods, not a number field. |
| **Maccy** | Limits history by count (default lowered from 999 to 200), not by age. [6] | A count cap is an alternative. It suits a "Recent files" list, not notes. |
| **Drafts** | Inbox, then Archive or Trash. Trash is purged after 30 days. "Flagged" is a separate property and can apply in Inbox or Archive. There is no built-in auto-archive: users build "unflagged and older than 3–7 days, then archive" with workspaces and Shortcuts. [7][8] | The Inbox/Archive/Trash model works. Users want auto-archive and keep building it themselves. |
| **Bear** | Archive hides notes ("do not appear in search results elsewhere") but you can still search inside it. [9] One unofficial forum report says Trash is never auto-emptied. [10] | Archive means hidden from default search, not deleted. |
| **Things 3** | "Every logged item stays in the Logbook indefinitely." Clearing it is manual. [11] | A permanent archive is acceptable. Clutter is about what you see, not disk space. |
| **Tot** | A hard limit of 7 notes ("dots") forces pruning. [12] | Scarcity is another approach. Too rigid for CODD. |
| **Arc** | Idle unpinned tabs auto-archive after 12 hours by default. Viewing a tab resets its timer. Pinned tabs are exempt. You can restore from "View Archive". Auto-archive cannot be turned off. [13] | The closest model for **sessions in the sidebar**. |
| **Safari** | "Automatically close tabs" after 1 day / 1 week / 1 month, counted from when you last viewed each tab. [14] | Count from last activity, not from when the item was created. |
| **Linear** | Auto-close marks stale issues Canceled (you can reopen them). Auto-archive runs on closed issues and applies within 24 hours. Deleted issues are kept 30 days. [15] | Two steps, and nothing is lost along the way. |
| **GitHub actions/stale** | Labels an item "Stale" after 60 days, closes it 7 days later. The timer resets on update. Some labels can be exempted. [16] | A "stale" marker shows up well before anything is removed. |
| **Slack** | Retention deletes run once a day and cannot be undone. [17] | Don't use irreversible auto-deletion for personal notes. |
| **macOS Finder** | "Remove items from the Trash after 30 days" is off by default and counts per item. [18] | A per-item countdown in Trash. |
| **Claude Code** | `cleanupPeriodDays` defaults to 30 (minimum 1, `0` is rejected). The sweep deletes transcripts "without showing a message", and those sessions disappear from `/resume`. Auto-memory files are excluded. [19][20] For `MEMORY.md`, Claude is told to "merge or drop stale entries". [21] | (a) A **session older than 30 days cannot be resumed anyway**. (b) Precedent for Claude condensing old notes. |

**What the earlier web version does today** (`~/GitHub/codd-web`):
- Deleting a session is only an in-memory flag: `apps/server/src/services/terminal-manager.js:297-305` and `apps/server/src/routes/sessions.js:220-225`.
- Terminal logs are appended forever (`terminal-manager.js:172-173`, set up at `apps/server/src/index.js:45-48`). `apps/server/data/sessions/` already holds 57 logs (2.3 MB) and nothing prunes them.
- The MCP tool `kanban_delete_card` (`apps/mcp/src/index.js:183-196`) runs a hard `DELETE FROM` (`apps/server/src/services/kanban-repo.js:90-94`). The AI can destroy data with no trash. **Don't repeat this.**
- Memory is already one file per day, `YYYY-MM-DD.md` (`apps/mcp/src/index.js:89-111`, `apps/server/src/services/channel-reader.js:282-305`). Per-day files make age-based handling easy.

## 2. Three strategies

### A. Inbox, then Archive, then Trash, based on time

**Rules**
- New notes start in Inbox.
- With no user activity for `staleAfter`, a note gets a "stale Nd" badge.
- With no activity for `archiveAfter`, it auto-moves to Archive. Automatic steps **never** go to Trash.
- Archive is kept forever.
- Trash only receives notes the user deletes. Each note is purged 30 days after it entered Trash.

**Defaults:** stale at 14 days, archive at 30 days, Trash purge at 30 days.

**User controls**
- Pin (never stale, never archived).
- Choose the period: Never / 7 / 14 / 30 / 60 / 90 days.
- A different period per folder.
- Undo (⌘Z) for every move.

**Screens needed**
- Pill on each note row: `stale 21d`.
- Banner when you open a stale note: "Untouched 21 days · Keep · Archive".
- Archive view with search.
- Trash view showing `deletes in 12d`.
- An undo toast after each move.

**Risks:** Very little data loss, since automatic steps only hide notes. Archive keeps growing, and pasted images grow fastest, so purged notes' images need cleanup.

**AI and MCP:** Archived notes are left out of `list_notes` unless `include_archived: true`, but still open by id or URL. Trashed notes cannot be read (see §3).

### B. Expiry by note type: Scratch vs Keep

**Rules**
- Each note is **Scratch** or **Keep**.
- Scratch covers notes from menu-bar quick capture and prompt drafts already "sent to session". It expires 7 days after last activity.
- Keep never expires.
- Choice to make: an expired Scratch note goes to Trash (aggressive, like Raycast Clipboard) or to Archive (safe).

**Defaults:** quick capture creates Scratch, ⌘N creates Keep. Scratch expires after 7 days.

**User controls**
- One keystroke switches between Scratch and Keep.
- Expiry period per type.
- Default type per capture surface.

**Screens needed**
- Type chip with a countdown: `⏳ 3d`.
- A notice on the menu-bar item the day before notes expire.

**Risks:** Higher. Notes get the wrong type, and anything that goes straight to Trash depends on the user noticing in time. Notes the AI reads often are still deleted on schedule.

**AI and MCP:** Each note carries `_meta: {"codd/kind":"scratch","codd/expiresAt":…}` so Claude knows it is temporary. The AI may *suggest* "keep" but cannot change a note's type itself.

### C. Periodic review, plus a Claude summary of old notes

**Rules**
- Nothing moves on its own.
- Weekly, CODD builds a list of candidates:
  - stale for more than 21 days
  - prompt drafts already sent
  - near-duplicates
  - images no note uses
  - links to local files that no longer exist
  - long running notes with dated sections older than 30 days
- In the Cleanup Review sheet you apply bulk actions: **Keep 30 days** / **Archive** / **Trash** / **Condense with Claude…**

**Condense flow**
1. CODD runs `claude -p` with the notebook MCP attached, under the currently selected cswap account.
2. Claude writes a summary note through `create_note({condensedFrom:[ids]})`. The note links back to its sources, e.g. "Condensed from 6 notes, 2026-09-01 to 09-20".
3. You review the diff.
4. **CODD**, not the AI, moves the originals to Archive and records `condensedInto` on each. Originals never go to Trash.

**Defaults:** weekly, at the first app launch after 09:00 Monday. The review only appears when there are at least 5 candidates.

**User controls**
- How often: Weekly / Biweekly / Monthly / Off.
- How many candidates before the review appears.
- Model and account used for condensing.

**Screens needed**
- A badge on the Notebook icon and the menu bar: `Cleanup · 14`.
- The review sheet: grouped list, a "why" column, preview pane, bulk action bar.
- A confirm-condense dialog with a preview of the summary.

**Risks:**
- Review fatigue: if you ignore the sheet, clutter stays.
- The summary can drop details. This is why originals are archived, not trashed.
- Condensing costs tokens.
- Secrets in notes get sent to the model.

**AI and MCP:** Claude Code's `MEMORY.md` already asks Claude to "merge or drop stale entries" [21], so this matches what users have seen.

## 3. MCP and local-URL behavior by state (applies to every strategy)

| State | Sidebar | `list_notes` / search | `get_note` / resource read | Local URL `http://127.0.0.1:<port>/n/<id>` |
|---|---|---|---|---|
| Fresh | yes | yes | yes | 200 |
| Stale | dimmed + pill | yes, with `_meta.codd/stale:true, ageDays` and the spec's `lastModified` annotation [22] | yes | 200 |
| Archived | Archive view | only with `include_archived` | yes, prefixed "Archived on …" (like Notion's working links) | 200 + banner |
| Condensed | Archive | no | yes, prefixed "Condensed into <URL>" | 200 + link to the summary |
| Trashed | Trash view | no | error `-32602` "Resource not found", `data:{state:"trashed",purgeAt}` [23] | 410 Gone, "In CODD Trash, restore to read" |
| Purged | none | no | `-32602`, `data:{state:"purged"}` | 410, kept for 90 days as a tombstone |

- **Notify Claude when notes move.** Send `notifications/resources/list_changed` whenever a note changes state [22].
- **What counts as activity.** Your edits, opening a note for 3 seconds or more, pinning, and send-to-session. **AI reads over MCP and fetches of the local URL do not count.** Otherwise Claude listing every note would keep them all alive forever. "AI read 2d ago" is still shown, and the review sheet uses it as a hint to keep.
- **Notes a live session uses.** A note fetched by a session that has not been archived is exempt from auto-archive while that session exists. The session id comes from an env var CODD injects into the MCP config.
- **Tombstones.** Keep them 90 days, which is longer than Claude Code's 30-day transcript life. URLs pasted into old transcripts then give a clear answer instead of a bare 404.
- **No hard delete for the AI.** MCP gets `archive_note` (soft, undoable) and no delete or purge. This fixes the `kanban_delete_card` problem.
- **Local files opened for editing.** Cleanup never touches the file on disk. Only the "Recent files" list ages: 20 entries at most, and an entry drops after 30 days unopened.

## 4. Recommendation

**Use A as the backbone, C's review sheet as the only place for bulk and destructive actions, and B's Scratch type for quick capture only.** Automatic steps only ever archive. The only automatic permanent deletion is purging Trash after 30 days, and only you put things in Trash.

| Setting | Default | Options |
|---|---|---|
| Mark stale after | **14 days** without activity | 7 / 14 / 30 / 60 / Never |
| Auto-archive after | **30 days** | Never / 14 / 30 / 60 / 90 |
| Scratch auto-archive (quick capture, sent prompt drafts) | **7 days** | 1 / 3 / 7 / 14 |
| Exempt | pinned notes; notes used by a live session | per-folder override |
| Archive kept | **forever** (searchable, MCP opt-in) | n/a |
| Trash purge | **30 days** per note | 7 / 30 / 60 |
| Tombstones (URL/MCP "deleted" answer) | **90 days** | n/a |
| Cleanup review | **Weekly**, Monday first launch after 09:00, only if **at least 5** candidates | Weekly / Biweekly / Monthly / Off |
| Condense with Claude | available, **manual only**; originals go to Archive | model and account picker |
| Unused-image cleanup | at Trash purge time | n/a |
| When cleanup runs | at launch, then every 24 h (like Slack, Linear and Claude Code) | n/a |

## 5. The same idea for old sessions, with one Cleanup screen

**Sessions follow the same steps.**
- Lifecycle: Running → Exited → Stale → Archived → Forgotten.
- **Defaults:** stale 3 days after exit with no focus, auto-archive at 7 days. Running and pinned sessions are exempt. This follows Arc's pinned tabs and Safari's last-viewed timer.
- Archived sessions collapse into an `Archived (12)` row under each project. They can be restored.

**Tie it to Claude Code's own 30-day deletion.**
- CODD reads each account's `cleanupPeriodDays`. With cswap, each `CLAUDE_CONFIG_DIR` has its own value.
- Five days before the transcript is deleted, the session shows `resume expires 4d`.
- When the `.jsonl` is gone, CODD marks the session `transcript gone`, archives it automatically, and forgets it after 30 more days.
- CODD **never deletes** files in `~/.claude/projects` itself. Claude Code's own sweep does that [19][20]. CODD can offer a link to raise `cleanupPeriodDays`.

**Clean up CODD's own terminal logs.** Delete the log of an archived session after 30 days. This is the problem seen in `terminal-manager.js:172-173`.

**One Cleanup screen** (shortcut to be decided), with three sections:
- Notes
- Sessions
- Files: unused images, terminal logs, missing local-file links

All three use the same badges (`stale 21d`, `archives in 3d`, `deletes in 12d`, `resume expires 4d`) and the same bulk action bar. A single **Settings › Cleanup** pane has two columns, Notes and Sessions. The menu-bar item shows one line: "Cleanup: 3 notes · 5 sessions". Behind it, one retention engine applies a policy to each kind of item: `{entity, staleAfterDays, archiveAfterDays, purgeDays, exemptIf}`.

## Sources
1. https://support.apple.com/en-gb/guide/icloud-iphone/mm2f42f05cb9/icloud
2. https://www.notion.com/help/duplicate-delete-and-restore-content
3. https://support.google.com/keep/answer/6262770?hl=en-GB
4. https://raycast.com/notes and https://www.macstories.net/reviews/raycast-overhauls-its-notes-feature/
5. https://manual.raycast.com/clipboard-history
6. https://newreleases.io/project/github/p0deje/Maccy/release/0.6.0
7. https://docs.getdrafts.com/drafts and https://scripting.getdrafts.com/classes/Workspace
8. https://forums.getdrafts.com/t/archive-old-drafts-automatically/14151
9. https://bear.app/faq/hide-notes-with-the-archive/
10. https://community.bear.app/t/deleting-from-trash/9548 (unofficial)
11. https://culturedcode.com/things/support/articles/4001304/
12. https://www.macworld.com/article/3531388/tot-pocket-review.html
13. https://resources.arc.net/hc/en-us/articles/19228855311127
14. https://support.apple.com/en-euro/guide/safari/tabs-ibrw1045/mac
15. https://linear.app/docs/delete-archive-issues and https://linear.app/changelog/2020-08-19-auto-close-and-auto-archive
16. https://github.rpi.edu/actions/stale (mirror of the actions/stale README)
17. https://slack.com/help/articles/203457187
18. https://support.apple.com/guide/mac-help/mchlp1093/mac
19. https://code.claude.com/docs/en/settings-reference (`cleanupPeriodDays`)
20. https://code.claude.com/docs/en/claude-directory ("Cleaned up automatically")
21. https://code.claude.com/docs/en/memory (MEMORY.md limits)
22. https://modelcontextprotocol.io/specification/2026-07-28/server/resources (`lastModified`, `list_changed`)
23. Same page, "Error Handling": `-32602`; clients should also accept the older `-32002`.
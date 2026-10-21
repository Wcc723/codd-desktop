import CoddCore
import Foundation

/// `-codd-dump-state <file>` (DEBUG): the sessions' states, the hook endpoint and the attention
/// count as JSON, rewritten whenever they change and at quit. End-to-end scripts poll it instead
/// of scraping the UI.
///
/// M2 (I1) keys: per session `unreachable` (Bool, D8) and `replayed` (its last screen came from the
/// ring file, D7); top level `problem` (`{message, sessionId?, ageSeconds}` or null), `windowVisible`
/// and `instance {pid, lock}` (the single-instance lock file, D9).
///
/// M2 (I2) keys: per session `external` (Bool), `externalPid`, `hostSession`, `hostTab` (D6),
/// `stale` (D15), `lastPrompt` (D20), `tag`, `pinned`; top level `projects [{id, name, cwd, group,
/// transient, collapsed, archivedCount, sessions}]` (tree order), `groupsInfo [{id, name, color,
/// collapsed}]`, `pinned [ids]`, `archived [ids]`, `profiles [{id, name, kind}]`, `defaultProfile`
/// (D5), `cleanupPeriodDays`, `claudeModel` (Claude's settings.json; null when unset).
///
/// M2 (I3) key: top level `sidebar {mode, filter, addingGroup, hoverCard, rows [{kind, id, section,
/// title, line2, stale, depth, count?, hint?, state?}]}`, the rows in display order with collapse
/// respected (`SidebarDump`).
///
/// M2 (I4) keys: per session `composer {open, draftLength, historyCount, loaded}` (D3; the counts are
/// 0 until the session's composer.json was read); top level `palette {shown, query, highlighted,
/// rows [{section, title, detail}]}` (⌘K, D14) and, while the home page is shown, `home {needsYou
/// [ids], done {id, count} | null, launch [cwd], stopped [{kind, id, title}]}`.
///
/// M2 (I5) key: top level `pane {session, tabs [{id, label, bell, running, selected, holderPid?}],
/// panelTabs [{id, label, bell, running, holderPid?}], panelSelected, panelOpen, panelMaximized,
/// composerOpen}` for the CODD session on screen (D11–D13, D25; absent on Home and for externals).
///
/// M2 (I6) keys, while the ⌘N sheet is open: top level `newSession {path, kind, start, profile,
/// command, copyCommand, sessionId, name, model, modelTitle, permission, remoteControl, tag, group,
/// transcript, destination, valid, advancedOpen, dropdownOpen, dropdown [{kind, title, detail,
/// chosen}], dropdownHighlighted, picker (loading|empty|noFolder|rows), error?}` and `resumePicker
/// [{id, title, branch, sizeBytes, ageDays, expiresInDays, disabled, selected}]` (D18; empty unless
/// the start is a resume and the list arrived).
///
/// M3 (I1a) key: top level `preferences {origin, loaded, readOnly, values {<leaf path>: <text>},
/// setPrefs [{assignment, applied, error}], saveProblem, savedAt}` (D14; `origin` is
/// `created` / `loaded` / `repaired(<paths>)` / `newerReadOnly(<v>)` / `corruptMovedAside(<name>)` /
/// `unreadable(<reason>)`, `memory` in mock mode, `loading` before the read).
///
/// M3 (I1b) keys (§6; never an e-mail, never a cswap profile path, D31): top level `accounts
/// {availability, note, cswapVersion, cswapPath, active, following, order [{id, slot, alias, plan,
/// active, five {remaining, resetsAt, started, source, capturedAt}, weekly {…}, pace, source,
/// sourceAt, sessionCount, pinnedCount, health, disabled, hasSessionProfile, profileStale, pseudo}],
/// switchState {state, to?, reason?, attempt?, message?}, lastSwitch {from, to, reason, at, outcome},
/// warnings, fallback}`, `quota {entries, lastAutoSwitchAt}` (quota.json's accounts), `statusline
/// {accepted, dropped, lastKey, lastAt, lastAccount, server {accepted, undecodable, lastAt},
/// registryExtra}`, `menuBar {accounts, total, expanded, title, paused, icon}`, and per session
/// `account` / `accountPinned`; `newSession.accountOptions [{id, title, enabled}]` is always there
/// (the ⌘N select as built), the sheet's other keys only while it is open.
///
/// M3 (I2) keys: `installer {settingsPath, inspection {state, exists, legacyEvents, legacyHandlers,
/// statusLine, current, chained, upToDate, duplicateNotifications, foreign}, plan {action, changes,
/// added, removed, removedEvents, addedEvents, statusLineAfter, foreignKept, backupName}, applied
/// {backup, action, at}}`, `status {shown, paused, section, updatedAt, hostSampled, sampleMs, p99,
/// accountsCards, unavailable, hooksPending}`, `autoSwitch {enabled, lastDecision, lastAutoSwitchAt,
/// notified, backgroundTools}`, `notifications {posted [{kind, title, suppressed}]}` (titles only),
/// `dialogs {shown, addAccount {step, ending}}`, `hostLine`, and per session `ephemeral`.
///
/// M5 (I1) keys (docs/M5-PLAN.md §5, `AppDelegate+Data`): `bundle {id, version, build,
/// legacyDefaultsMigrated, legacyDefaults, autosavesLayout}` and `dataFiles {preflight {ms, cacheWiped,
/// files}, issues, bannersShown}` (file names only, never contents). M5 (I2, `AppDelegate+Onboarding`):
/// `onboarding {shown, reason, source, step, steps, boot, import {…, rows, options}, applied, hooks,
/// notebook, accounts {availability, rows {slot, alias, active}}, notifications, completedAt, file}`
/// (aliases only: never an e-mail, never a token).
@MainActor
enum StateDump {
    struct Instance {
        var pid: Int32
        var lockPath: String?
    }

    static func object(store: HolderSessionStore, dockBadge: String?, hub: TerminalHub? = nil, windowVisible: Bool? = nil,
                       instance: Instance? = nil, services: AppServices? = nil, sidebar: [String: Any]? = nil,
                       composer: ((SessionID) -> [String: Any])? = nil, palette: [String: Any]? = nil,
                       home: [String: Any]? = nil, newSession: [String: Any]? = nil, resumePicker: [[String: Any]]? = nil,
                       pane: [String: Any]? = nil, preferences: [String: Any]? = nil,
                       accounts: (accounts: [String: Any], quota: [String: Any], statusline: [String: Any])? = nil,
                       accountOptions: [NewSessionAccountOption]? = nil, menuBar: [String: Any]? = nil,
                       extra: [String: Any] = [:]) -> [String: Any] {
        var hooks: [String: Any] = [:]
        switch store.hooks?.status {
        case .listening(let port)?: hooks["status"] = "listening"; hooks["port"] = Int(port)
        case .portInUse(let port, let otherCODD)?: hooks["status"] = otherCODD ? "port-in-use-codd" : "port-in-use"; hooks["port"] = Int(port)
        case .failed(let reason)?: hooks["status"] = "failed"; hooks["reason"] = reason
        case .starting?: hooks["status"] = "starting"
        case nil: hooks["status"] = "disabled"
        }
        if let stats = store.hooks?.statistics {
            hooks["accepted"] = stats.accepted
            hooks["rejected"] = Dictionary(uniqueKeysWithValues: stats.rejected.map { (String($0.key), $0.value) })
            if let last = stats.lastRejection { hooks["lastRejection"] = last }
        }
        hooks["events"] = store.hooks?.eventCount ?? 0
        let sessions = store.allSessions.sorted { $0.id < $1.id }.map { session -> [String: Any] in
            var row: [String: Any] = [
                "id": session.id, "kind": session.kind == .claude ? "claude" : "shell", "title": session.title,
                "state": session.state.rawValue, "project": store.project(session.projectID)?.name ?? "",
                "cwd": store.project(session.projectID)?.cwd ?? "",
            ]
            if let reason = session.waitingReason, session.state == .waiting { row["reason"] = reason.rawValue }
            if let reason = session.errorReason { row["error"] = reason }
            if let tool = session.tool { row["tool"] = tool }
            if let detail = session.detail { row["detail"] = detail }
            if let claude = session.claudeSessionID { row["claudeSessionId"] = claude }
            if let pid = session.pid { row["pid"] = Int(pid) }
            if let holder = store.runtime(session.id)?.holderPid { row["holderPid"] = Int(holder) }
            if let code = session.exitCode { row["exitCode"] = Int(code) }
            if let problem = session.launchError { row["launchError"] = problem }
            row["unreachable"] = session.unreachableSince != nil
            row["replayed"] = hub?.isReplayed(session.id) ?? false
            row["external"] = session.external
            if let info = session.externalInfo {
                row["externalPid"] = Int(info.pid)
                row["hostSession"] = info.hostSessionID.map { $0 as Any } ?? NSNull()
                row["hostTab"] = info.hostTabID.map { $0 as Any } ?? NSNull()
                if let kind = info.kind { row["externalKind"] = kind }
            }
            row["stale"] = session.isStale
            row["lastPrompt"] = session.lastPrompt.map { $0 as Any } ?? NSNull()
            row["tag"] = session.tag?.rawValue as Any? ?? NSNull()
            row["pinned"] = session.isPinned && store.pinnedSessionIDs.contains(session.id)
            row["account"] = session.accountID.map { $0 as Any } ?? NSNull()
            row["accountPinned"] = session.accountPinned
            row["ephemeral"] = store.isEphemeral(session.id)
            if let composer, !session.external { row["composer"] = composer(session.id) }
            return row
        }
        let attention = store.allSessions.filter { $0.state.needsAttention }.count
        var object: [String: Any] = ["hooks": hooks, "sessions": sessions, "attention": attention, "dockBadge": dockBadge ?? "",
                                     "groups": store.groups.map(\.name), "loaded": store.isLoaded]
        if let problem = store.problem {
            var entry: [String: Any] = ["message": problem.message,
                                        "ageSeconds": Int(max(0, store.clock.now().timeIntervalSince(problem.at)))]
            if let id = problem.sessionID { entry["sessionId"] = id }
            object["problem"] = entry
        } else {
            object["problem"] = NSNull()
        }
        object["projects"] = store.groups.flatMap { group in
            group.projectIDs.compactMap { store.project($0) }.map { project -> [String: Any] in
                ["id": project.id, "name": project.name, "cwd": project.cwd, "group": group.isUngrouped ? NSNull() : group.id as Any,
                 "transient": project.isTransient, "collapsed": project.isCollapsed, "archivedCount": project.archivedCount,
                 "sessions": project.sessionIDs]
            }
        }
        object["groupsInfo"] = store.groups.map { group -> [String: Any] in
            ["id": group.id, "name": group.name, "color": group.color?.rawValue as Any? ?? NSNull(), "collapsed": group.isCollapsed,
             "ungrouped": group.isUngrouped]
        }
        object["pinned"] = store.pinnedSessionIDs
        object["archived"] = store.archivedByID.keys.sorted()
        object["profiles"] = store.profiles.profiles.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] }
        object["defaultProfile"] = store.profiles.document.defaultProfileId
        object["cleanupPeriodDays"] = services?.claudeSettings.cleanupPeriodDays.map { $0 as Any } ?? NSNull()
        object["claudeModel"] = services?.claudeSettings.model.map { $0 as Any } ?? NSNull()
        if let windowVisible { object["windowVisible"] = windowVisible }
        if let sidebar { object["sidebar"] = sidebar }
        if let palette { object["palette"] = palette }
        if let home { object["home"] = home }
        if let pane { object["pane"] = pane }
        if newSession != nil || accountOptions != nil {
            var entry = newSession ?? [:]
            if let accountOptions {
                entry["accountOptions"] = accountOptions.map { ["id": $0.id, "title": $0.title, "enabled": $0.enabled] }
            }
            object["newSession"] = entry
        }
        if let accounts {
            object["accounts"] = accounts.accounts
            object["quota"] = accounts.quota
            var statusline = accounts.statusline
            if let stats = store.hooks?.statistics {
                statusline["server"] = ["accepted": stats.statusLinesAccepted, "undecodable": stats.statusLinesUndecodable,
                                        "lastAt": stats.lastStatusLineAt.map { JSDate.isoString($0) as Any } ?? NSNull()]
            }
            statusline["registryExtra"] = store.hooks?.extraRegistryCount ?? 0
            object["statusline"] = statusline
        }
        if let menuBar { object["menuBar"] = menuBar }
        if let resumePicker { object["resumePicker"] = resumePicker }
        if let preferences { object["preferences"] = preferences }
        if let instance {
            object["instance"] = ["pid": Int(instance.pid), "lock": instance.lockPath.map { $0 as Any } ?? NSNull()]
        }
        object["hostLine"] = store.hostLine.map { $0 as Any } ?? NSNull()
        object.merge(extra) { _, new in new }
        return object
    }

    /// Atomic write (a poller never reads half a file).
    static func write(_ object: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

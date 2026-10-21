# CoddPreferences

The preferences model and store of CODD (M3 D14, C10): `<dataRoot>/preferences.json`, every row of
the Settings artboard. Foundation and Synchronization only, no package dependencies.

- `CoddPreferences` (`Sendable`, `Equatable`, `Codable`): `version` 1 and the sections `general`,
  `appearance`, `sessions`, `notifications`, `accounts`, `notebook`, `cleanup`, `shortcuts`,
  `advanced`, `about`. Every nested type has a memberwise init whose defaults are the artboard's
  defaults (with M3 D15's exceptions: login item OFF, CRT OFF, no muted groups). Option lists and
  ranges for the UI sit next to the fields (`Sessions.staleAfterOptions`, `AutoSwitch.thresholdRange`, …).
- M4 (D30, D33): two leaves are stored but unused: `notebook.mcpPort` (MCP shares the hook
  server's port; Settings shows that port read-only) and `advanced.scrollbackRetentionDays` (the
  ADVANCED row mirrors `cleanup.scrollbackDeleteDays`, the value the retention engine obeys). Both
  keep round-tripping so M3 files are unchanged. `cleanup.condenseAccount` holds the Settings
  select's id (`follow` or a cswap number; nil = the first entry, 跟隨全域登入). No field was added
  in M4.
- Each section lists its fields once in a field table; decoding, encoding, `leafPaths` (71 paths),
  `value(atPath:)` and `set(_:atPath:)` / `apply(assignment:)` (the DEBUG `-codd-set-pref`) all
  come from it.
- `PreferencesStore(url:)`: `load()` never throws and is tolerant per field (a wrong type, an unknown
  enum value or an out-of-range number falls back to the default and is listed in
  `Origin.repaired`); unknown keys are kept through a save; a newer `version` is read-only
  (`Origin.newerReadOnly`, save throws); invalid JSON is moved aside to
  `preferences.json.corrupt-<epoch ms>`; `save(_:)` is atomic (temp file, F_FULLFSYNC, rename),
  0600, pretty printed with sorted keys, optionals written as explicit `null` (a missing key means
  the default). `migrateLegacyNotifications(from:into:)` maps M1/M2's UserDefaults switch.

```sh
swift test --package-path Packages/CoddPreferences --scratch-path .build-prefs
```

The app side is `App/Real/PreferencesService.swift` (load off the main actor, 300 ms debounced
save, flush at quit, DEBUG assignments that are never written).

// Xcode tool target entry point for codd-hook (project.yml target `codd-hook`), the SessionStart
// command hook of claude sessions CODD starts. All logic lives in Packages/CoddHooks
// (CoddHookClient); this mirrors Sources/codd-hook/main.swift.
import CoddHookClient

HookCommandMain.main()

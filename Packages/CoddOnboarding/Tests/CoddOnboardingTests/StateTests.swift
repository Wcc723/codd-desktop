import Foundation
import Testing
@testable import CoddOnboarding

@Suite("OnboardingGate (D5) and onboarding.json (§2.3)")
struct StateTests {
    static func tempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codd-onboarding-state-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a root is new without layout.json, panes.json, onboarding.json and sessions/*/meta.json")
    func gate() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(OnboardingGate.isNewDataRoot(root))
        #expect(OnboardingGate.isNewDataRoot(root.appendingPathComponent("missing")))
        let sessions = root.appendingPathComponent("sessions/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data().write(to: sessions.appendingPathComponent("composer.json"))
        try Data().write(to: root.appendingPathComponent("preferences.json"))
        #expect(OnboardingGate.isNewDataRoot(root))
        try Data().write(to: sessions.appendingPathComponent("meta.json"))
        #expect(!OnboardingGate.isNewDataRoot(root))
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("meta.json"))
        for name in OnboardingGate.markerFiles {
            let file = root.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file)
            #expect(!OnboardingGate.isNewDataRoot(root), "\(name)")
            try FileManager.default.removeItem(at: file)
        }
        // A dangling symlink still counts as "ran here before".
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("layout.json").path, withDestinationPath: "/nonexistent")
        #expect(!OnboardingGate.isNewDataRoot(root))
    }

    static func sample(completedAt: Date = Date(timeIntervalSince1970: 1_792_000_000)) -> OnboardingState {
        var flow = OnboardingFlow()
        flow.next()
        flow.next()
        flow.skip()
        return OnboardingState(flow: flow, finishing: .skipped, imported: .init(projects: 9, groups: 3), notifications: .granted,
                               appVersion: "1.0.0", build: "412", completedAt: completedAt)
    }

    @Test("written 0600, atomically, with sorted keys; read back equal")
    func saveAndLoad() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OnboardingStateStore(dataRoot: root)
        let state = Self.sample()
        try store.save(state)
        var info = stat()
        #expect(lstat(store.url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["onboarding.json"])
        let text = try String(contentsOf: store.url, encoding: .utf8)
        let keys = ["\"appVersion\"", "\"build\"", "\"completedAt\"", "\"imported\"", "\"notifications\"", "\"steps\"", "\"v\""]
        let positions = keys.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())
        #expect(text.contains("\"v\":1"))
        #expect(text.contains("\"import\":\"done\""))
        #expect(text.contains("\"hooks\":\"skipped\""))
        #expect(text.contains("\"notebook\":\"skipped\""))
        #expect(text.contains("\"accounts\":\"todo\""))
        #expect(text.contains("\"notifications\":\"granted\""))
        #expect(text.contains("\"completedAt\":\"2026-10-14T17:46:40Z\""))
        #expect(store.load() == state)
        #expect(store.existingVersion() == 1)
        try store.save(state)   // the current version is replaced
        #expect(store.load() == state)
    }

    @Test("a file with a newer v is never replaced")
    func newerRefused() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OnboardingStateStore(dataRoot: root)
        let newer = Data(#"{"v":2,"completedAt":"2027-01-01T00:00:00Z","future":true}"#.utf8)
        try newer.write(to: store.url)
        #expect(throws: OnboardingStateStore.StoreError.newerVersion(2)) { try store.save(Self.sample()) }
        #expect(try Data(contentsOf: store.url) == newer)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["onboarding.json"])
    }

    @Test("a missing or unreadable file loads as nil")
    func loadMissing() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OnboardingStateStore(dataRoot: root)
        #expect(store.load() == nil)
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load() == nil)
        #expect(store.existingVersion() == nil)
        try store.save(Self.sample())   // a corrupt file has no newer version: replaced
        #expect(store.load() != nil)
    }

    @Test("notifications map from the done step")
    func notifications() {
        #expect(OnboardingState.notifications(.asking) == .notAsked)
        #expect(OnboardingState.notifications(.suppressed) == .suppressed)
        #expect(OnboardingState.notifications(.denied) == .denied)
    }
}

import Foundation

/// One format step of one inventoried file: `from` → `from + 1`. The output must carry the
/// version member set to `from + 1` (the preflight checks it before anything is written).
public struct MigrationStep: Sendable {
    /// The inventory pattern it applies to (`"layout.json"`, `"sessions/*/composer.json"`).
    public let pattern: String
    public let from: Int
    public let migrate: @Sendable ([String: Any]) throws -> [String: Any]

    public init(pattern: String, from: Int, migrate: @escaping @Sendable ([String: Any]) throws -> [String: Any]) {
        self.pattern = pattern
        self.from = from
        self.migrate = migrate
    }
}

/// The registered steps. Empty at M5: every file is version 1 (a composer.json without `v`
/// counts as 1); the registry is exercised with synthetic steps in the tests.
public struct MigrationRegistry: Sendable {
    public let steps: [MigrationStep]

    public init(_ steps: [MigrationStep] = []) {
        self.steps = steps
    }

    public static let standard = MigrationRegistry()

    /// The steps `from` → … → `to` in order, or nil when one of them is missing (the file is
    /// then left as it is: `noMigration`). Empty when `from >= to`.
    public func chain(pattern: String, from: Int, to: Int) -> [MigrationStep]? {
        guard from < to else { return [] }
        var out: [MigrationStep] = []
        for version in from..<to {
            guard let step = steps.first(where: { $0.pattern == pattern && $0.from == version }) else { return nil }
            out.append(step)
        }
        return out
    }
}

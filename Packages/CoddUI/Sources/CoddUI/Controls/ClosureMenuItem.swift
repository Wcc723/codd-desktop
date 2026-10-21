import AppKit

/// NSMenuItem that runs a closure (keeps menu construction declarative).
public final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    public init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        let handler = self.handler
        MainActor.assumeIsolated { handler() }
    }
}

import Darwin

/// codd-holder-compat: the current client code against one `codd-holder` binary, e.g. one built
/// from an older commit (scripts/m5-compat.sh, docs/M5-PLAN.md D19 / §2.9). Not shipped.
let usage = """
    usage: codd-holder-compat --holder <codd-holder binary> --root <short temp dir> [--label <short>]

      Runs spawn, meta, welcome, stream, input, resize, reattach, paste, ring and stop against a
      holder spawned under <root> (socket <root>/run/s.sock must fit 104 bytes). One line per check:
      COMPAT <label> <check> ok|FAIL <detail>. Exit 0 when all pass, 1 on any FAIL, 64 on usage errors.

    """

/// `--key value` pairs; nil on anything else.
func parseOptions(_ arguments: [String]) -> CompatRun.Options? {
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        guard ["--holder", "--root", "--label"].contains(key), index + 1 < arguments.count else { return nil }
        values[key] = arguments[index + 1]
        index += 2
    }
    guard let holder = values["--holder"], !holder.isEmpty, var root = values["--root"], !root.isEmpty else { return nil }
    while root.count > 1, root.hasSuffix("/") { root.removeLast() }
    return CompatRun.Options(holder: holder, root: root, label: values["--label"] ?? "holder")
}

signal(SIGPIPE, SIG_IGN)
guard let options = parseOptions(Array(CommandLine.arguments.dropFirst())) else {
    Report.error(usage)
    exit(64)
}
guard Files.isDirectory(options.root) else {
    Report.error("codd-holder-compat: --root \(options.root) is not a directory\n")
    exit(64)
}
guard !options.label.isEmpty, !options.label.contains(where: { $0 == " " || $0.isNewline }) else {
    Report.error("codd-holder-compat: --label must be one word\n")
    exit(64)
}
let emergencySources = Emergency.shared.install(label: options.label, watchdogSeconds: CompatRun.watchdogSeconds)
let allPassed = CompatRun(options).run()
withExtendedLifetime(emergencySources) {}
exit(allPassed ? 0 : 1)

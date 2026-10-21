import CoddPosix
import Darwin

/// Entry point shared by the SwiftPM `codd-holder` executable and the Xcode tool target
/// (Tools/codd-holder/main.swift).
public enum HolderMain {
    /// Exit codes: 0 normal, 64 usage error, 71 startup failure (socket in use, ring locked, …).
    public static func run(arguments: [String] = CommandLine.arguments) -> Never {
        let options: HolderOptions
        do {
            options = try HolderOptions.parse(Array(arguments.dropFirst()))
        } catch {
            try? Descriptor.writeAll(2, "codd-holder: \(error)\n\(HolderOptions.usage)\n")
            exit(64)
        }
        let holder: Holder
        do {
            holder = try Holder(options: options)
        } catch {
            try? Descriptor.writeAll(2, "codd-holder: \(error)\n")
            exit(71)
        }
        exit(holder.run())
    }
}

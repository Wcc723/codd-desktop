import Foundation

/// A versioned JSON file holding the ``Layout`` (interim store; GRDB comes later).
///
/// Only the app writes it (one writer per store). Saves are atomic (temp + `rename`), mode 0600.
/// A file from a NEWER format version is never overwritten: ``load()`` throws
/// ``LayoutStoreError/unsupportedVersion(_:)`` and the caller must not save over it.
public struct LayoutStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/CODD/layout.json` (the documented data location; callers in
    /// tests must pass a temp URL instead).
    public static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CODD", isDirectory: true)
            .appendingPathComponent("layout.json", isDirectory: false)
    }

    /// Loads the layout; a missing file is an empty layout. Synchronous I/O: call off the main actor.
    public func load() throws -> Layout {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        } catch {
            throw LayoutStoreError.unreadable(String(describing: error))
        }
        guard let json = JSONValue.parse(data), let object = json.objectValue else {
            throw LayoutStoreError.corrupt("not a JSON object")
        }
        guard let version = object["version"]?.exactIntegerValue else {
            throw LayoutStoreError.corrupt("missing version")
        }
        guard version <= Layout.currentVersion else { throw LayoutStoreError.unsupportedVersion(version) }
        guard version >= 1 else { throw LayoutStoreError.corrupt("invalid version \(version)") }
        do {
            return try Self.decoder().decode(Layout.self, from: data)
        } catch {
            throw LayoutStoreError.corrupt(String(describing: error))
        }
    }

    /// M5 D14: a file from a NEWER format version, read as far as this version's decoder
    /// understands it (unknown members are ignored, rows that do not decode are skipped), so the
    /// app can show it read-only instead of an empty sidebar. ``save(_:)`` still refuses to replace
    /// it. Throws ``LayoutStoreError/corrupt(_:)`` when the file is not a newer layout or does not
    /// decode at all, ``LayoutStoreError/unreadable(_:)`` on an I/O error. Synchronous I/O.
    public func loadNewerReadOnly() throws -> Layout {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw LayoutStoreError.unreadable(String(describing: error))
        }
        guard let object = JSONValue.parse(data)?.objectValue, let version = object["version"]?.exactIntegerValue,
              version > Layout.currentVersion else {
            throw LayoutStoreError.corrupt("not a newer layout")
        }
        do {
            return try Self.decoder().decode(Layout.self, from: data)
        } catch {
            throw LayoutStoreError.corrupt(String(describing: error))
        }
    }

    /// Atomically writes the layout. Refuses (``LayoutStoreError/unsupportedVersion(_:)``) to
    /// replace a file written by a NEWER format version, even if the caller skipped ``load()`` — an
    /// older CODD build must never downgrade the user's data. Synchronous I/O: call off the main actor.
    public func save(_ layout: Layout) throws {
        if let existing = try? Data(contentsOf: fileURL),
           let version = JSONValue.parse(existing)?["version"]?.exactIntegerValue, version > Layout.currentVersion {
            throw LayoutStoreError.unsupportedVersion(version)
        }
        let data = try Self.encoder().encode(layout)
        try AtomicFile.write(data, to: fileURL)
    }

    /// Renames an unreadable file aside (`layout.json.corrupt-<epoch-ms>`) so a fresh layout can be
    /// saved without losing the original. Returns the new location.
    @discardableResult
    public func moveAside(now: Date = Date()) throws -> URL {
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(JSDate.milliseconds(now))")
        try FileManager.default.moveItem(at: fileURL, to: target)
        return target
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(JSDate.isoString(date))
        }
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let ms = JSDate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date \(s)")
            }
            return JSDate.date(milliseconds: ms)
        }
        return d
    }
}

public enum LayoutStoreError: Error, Equatable {
    case unreadable(String)
    case corrupt(String)
    /// Written by a newer CODD; do not overwrite.
    case unsupportedVersion(Int)
}

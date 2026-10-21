import Foundation

public enum QuotaStoreError: Error, Equatable {
    /// The file on disk was written by a newer CODD; it is never overwritten.
    case newerVersion(Int)
    case encode(String)
    case write(String)
}

/// `<dataRoot>/quota.json` (v1, 0600, atomic; D7). A cache: anything unreadable loads as an empty
/// book and is replaced by the next save, except a newer version, which loads empty and is kept.
/// Blocking I/O: call off the main actor (the app debounces saves by 2 s and flushes at quit).
public struct QuotaStore: Sendable {
    public static let fileName = "quota.json"
    /// A quota cache is a few KB; a larger file is not read.
    public static let maxFileBytes = 4 << 20

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `<dataRoot>/quota.json`.
    public init(dataRoot: URL) {
        self.init(url: dataRoot.appendingPathComponent(Self.fileName))
    }

    public func load() -> QuotaBook {
        guard let object = readObject(), let version = object["v"]?.exactIntegerValue,
              (1...QuotaBook.currentVersion).contains(version) else { return QuotaBook() }
        return QuotaBook(json: object)
    }

    /// Sorted keys, compact. Refuses to replace a file of a newer version.
    public func save(_ book: QuotaBook) throws(QuotaStoreError) {
        if let version = readObject()?["v"]?.exactIntegerValue, version > QuotaBook.currentVersion {
            throw .newerVersion(version)
        }
        let data: Data
        do {
            data = try book.json.jsonData()
        } catch {
            throw .encode(String(describing: error))
        }
        do {
            try AtomicFile.write(data, to: url, permissions: 0o600)
        } catch {
            throw .write(String(describing: error))
        }
    }

    private func readObject() -> JSONValue? {
        let bytes: [UInt8]? = ReadOnlyFile.with(url.path) { fd, info in
            guard info.size <= Self.maxFileBytes,
                  let data = ReadOnlyFile.read(fd, offset: 0, count: Int(info.size) + 1), data.count <= Self.maxFileBytes else { return nil }
            return data
        }
        guard let bytes, let value = JSONValue.parse(Data(bytes)), value.objectValue != nil else { return nil }
        return value
    }
}

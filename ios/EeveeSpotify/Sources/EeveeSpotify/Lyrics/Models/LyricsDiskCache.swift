import Foundation

/// Persistent native protobuf responses, separated by provider/options variant.
final class LyricsDiskCache {
    struct Entry: Codable {
        let data: Data
        let title: String?
        let artist: String?
    }
    private let root: URL
    private let lock = NSLock()
    private let maximumBytes = 2 * 1024 * 1024

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func path(trackID: String, variant: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for value in [trackID, variant] {
            guard !value.isEmpty, value.count <= 128,
                  value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
        }
        // Separate components prevent ambiguous track/variant concatenations.
        return root.appendingPathComponent(variant, isDirectory: true).appendingPathComponent(trackID + ".json")
    }
    func store(trackID: String, variant: String, data: Data, title: String?, artist: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let target = try path(trackID: trackID, variant: variant)
        guard !data.isEmpty, data.count <= maximumBytes else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoded = try JSONEncoder().encode(Entry(data: data, title: title, artist: artist))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: target, options: .atomic)
    }
    func load(trackID: String, variant: String) throws -> Entry? {
        lock.lock(); defer { lock.unlock() }
        let target = try path(trackID: trackID, variant: variant)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: target))
        guard !entry.data.isEmpty, entry.data.count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        return entry
    }
}

import Foundation

public struct OfflineTrack: Codable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var artist: String
    public var duration: Double
    public var lyrics: String?
    public var source: String
    public var audioExtension: String
    public init(id: String, title: String, artist: String, duration: Double, lyrics: String?, source: String, audioExtension: String = "mp3") {
        self.id = id; self.title = title; self.artist = artist; self.duration = duration
        self.lyrics = lyrics; self.source = source; self.audioExtension = audioExtension
    }
}

public final class OfflineLibrary {
    public let root: URL
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default
    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func validate(_ track: OfflineTrack) throws {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !track.id.isEmpty, track.id.count <= 128, track.id.unicodeScalars.allSatisfy({ safe.contains($0) }),
              ["mp3", "m4a", "aac", "wav", "flac", "caf"].contains(track.audioExtension) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }
    public func audioURL(for track: OfflineTrack) -> URL {
        // Callers only receive validated records from tracks()/store().
        root.appendingPathComponent(track.id).appendingPathComponent("audio." + track.audioExtension)
    }
    public func tracks() throws -> [OfflineTrack] {
        lock.lock(); defer { lock.unlock() }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("track.json")),
                  let track = try? JSONDecoder().decode(OfflineTrack.self, from: data),
                  (try? validate(track)) != nil,
                  folder.lastPathComponent == track.id,
                  fm.fileExists(atPath: audioURL(for: track).path) else { return nil }
            return track
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    public func store(_ track: OfflineTrack, audio: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try validate(track)
        let attributes = try fm.attributesOfItem(atPath: audio.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
        let staged = root.appendingPathComponent(".stage-" + UUID().uuidString)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: audio, to: staged.appendingPathComponent("audio." + track.audioExtension))
        try JSONEncoder().encode(track).write(to: staged.appendingPathComponent("track.json"), options: .atomic)
        let destination = root.appendingPathComponent(track.id)
        if fm.fileExists(atPath: destination.path) {
            let backup = root.appendingPathComponent(".backup-" + UUID().uuidString)
            try fm.moveItem(at: destination, to: backup)
            do { try fm.moveItem(at: staged, to: destination) }
            catch { try? fm.moveItem(at: backup, to: destination); throw error }
            try? fm.removeItem(at: backup)
        } else { try fm.moveItem(at: staged, to: destination) }
    }
    public func remove(_ track: OfflineTrack) throws {
        lock.lock(); defer { lock.unlock() }
        try validate(track)
        try fm.removeItem(at: root.appendingPathComponent(track.id))
    }
}

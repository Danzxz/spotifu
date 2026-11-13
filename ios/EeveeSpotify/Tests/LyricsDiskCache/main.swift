import Foundation
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let cache = try LyricsDiskCache(root: root)
let payload = Data("native protobuf".utf8)
try cache.store(trackID: "Track123", variant: "genius_1", data: payload, title: "Song", artist: "Artist")
let reopened = try LyricsDiskCache(root: root)
let entry = try reopened.load(trackID: "Track123", variant: "genius_1")!
precondition(entry.data == payload && entry.title == "Song" && entry.artist == "Artist")
let absent = try reopened.load(trackID: "Track123", variant: "lrclib_1")
precondition(absent == nil)
for invalid in ["../escape", "", String(repeating: "a", count: 129), "a/b"] {
    do { _ = try reopened.load(trackID: invalid, variant: "valid"); fatalError("invalid id accepted") } catch {}
    do { _ = try reopened.load(trackID: "valid", variant: invalid); fatalError("invalid variant accepted") } catch {}
}
do { try cache.store(trackID: "Track123", variant: "genius_1", data: Data(), title: nil, artist: nil); fatalError("empty accepted") } catch {}
let preserved = try reopened.load(trackID: "Track123", variant: "genius_1")
precondition(preserved?.data == payload)
print("Lyrics disk cache regression tests passed")

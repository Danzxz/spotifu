import Foundation

func assertData(_ data: Data) { assert(data == Data([1,2,3])) }

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let library = try OfflineLibrary(root: root)
let input = root.appendingPathComponent("input.mp3")
try Data([1,2,3]).write(to: input)
let track = OfflineTrack(id: "abc123", title: "Song", artist: "Artist", duration: 123, lyrics: "[00:01.2]Hello", source: "import")
try library.store(track, audio: input)
let reopened = try OfflineLibrary(root: root)
let ids = try reopened.tracks().map(\.id)
assert(ids == ["abc123"])
assertData(try Data(contentsOf: reopened.audioURL(for: track)))
let bad = OfflineTrack(id: "../escape", title: "x", artist: "x", duration: 0, lyrics: nil, source: "import")
do { try library.store(bad, audio: input); fatalError("Traversal accepted") } catch {}
let empty = root.appendingPathComponent("empty.mp3")
try Data().write(to: empty)
do { try library.store(track, audio: empty); fatalError("Empty audio accepted") } catch {}
assertData(try Data(contentsOf: reopened.audioURL(for: track)))
let lines = LyricLine.parse("[00:01.20][00:03.00]Hello\n[00:02]World")
assert(lines.map(\.time) == [1.2,2,3])
try reopened.remove(track)
let remaining = try reopened.tracks()
assert(remaining.isEmpty)
print("Offline persistence, traversal, failed replacement, deletion and lyric timing tests passed")

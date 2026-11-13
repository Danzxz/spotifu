import XCTest
@testable import SpotifuCore

final class LibraryTests: XCTestCase {
    func testImportSurvivesRestartAndRemovalDeletesAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: input)
        let library = try OfflineLibrary(root: root.appendingPathComponent("library"))
        let track = OfflineTrack(id: "abc123", title: "Song", artist: "Artist", duration: 123, lyrics: "[00:01.20]Hello", source: "import")
        try library.store(track, audio: input)
        let restarted = try OfflineLibrary(root: library.root)
        XCTAssertEqual(try restarted.tracks().map(\.id), ["abc123"])
        XCTAssertEqual(try Data(contentsOf: restarted.audioURL(for: track)), Data([1,2,3]))
        try restarted.remove(track)
        XCTAssertTrue(try restarted.tracks().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.audioURL(for: track).path))
    }

    func testRejectsTraversalAndEmptyAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try OfflineLibrary(root: root)
        let invalid = OfflineTrack(id: "../escape", title: "x", artist: "y", duration: 0, lyrics: nil, source: "import")
        XCTAssertThrowsError(try library.store(invalid, audio: root))
        let empty = root.appendingPathComponent("empty.mp3")
        try Data().write(to: empty)
        let track = OfflineTrack(id: "valid", title: "x", artist: "y", duration: 0, lyrics: nil, source: "import")
        XCTAssertThrowsError(try library.store(track, audio: empty))
        XCTAssertTrue(try library.tracks().isEmpty)
    }

    func testLyricsParsesMultipleTimestampsAndKeepsLastLine() {
        let lines = LyricLine.parse("[00:01.20][00:03.00]Hello\n[00:02]World")
        XCTAssertEqual(lines.map(\.time), [1.2, 2, 3])
        XCTAssertEqual(lines.map(\.text), ["Hello", "World", "Hello"])
    }
}

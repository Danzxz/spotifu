import Foundation
import AVFoundation
import Combine
import MediaPlayer
import Security
#if SWIFT_PACKAGE
import SpotifuCore
#endif

@MainActor public final class OfflineModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public static let shared = OfflineModel()
    @Published public var tracks: [OfflineTrack] = []
    @Published public var current: OfflineTrack?
    @Published public var position: Double = 0
    @Published public var duration: Double = 0
    @Published public var playing = false
    @Published public var error: String?
    @Published public var busy = false
    @Published public var candidates: [Candidate] = []
    @Published public var status = ""
    private var library: OfflineLibrary?
    private var audio: AVAudioPlayer?
    private var timer: AnyCancellable?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    public var endpoint: String { didSet { UserDefaults.standard.set(endpoint, forKey: "spotifu.endpoint") } }
    public var token: String { didSet { Self.saveToken(token) } }
    public var beforePlay: (() -> Void)?

    public override init() {
        endpoint = UserDefaults.standard.string(forKey: "spotifu.endpoint") ?? "http://127.0.0.1:8765"
        token = Self.readToken()
        super.init()
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            library = try OfflineLibrary(root: support.appendingPathComponent("Spotifu/Downloads"))
            try reload()
        } catch { self.error = error.localizedDescription }
        timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, let audio = self.audio else { return }
            self.position = audio.currentTime
            self.playing = audio.isPlaying
        }
    }
    public func reload() throws { tracks = try library?.tracks() ?? [] }
    public func importFile(_ url: URL, title: String, artist: String, id: String) throws {
        guard let library else { throw CocoaError(.fileWriteUnknown) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Validate the codec before marking a file downloaded.
        let probe = try AVAudioPlayer(contentsOf: url)
        let track = OfflineTrack(id: id.isEmpty ? UUID().uuidString : id, title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                                 artist: artist, duration: probe.duration, lyrics: nil, source: "import", audioExtension: url.pathExtension.lowercased())
        try library.store(track, audio: url)
        try reload()
    }
    public func remove(_ track: OfflineTrack) {
        do {
            if current?.id == track.id { stop() }
            try library?.remove(track); try reload()
        } catch { self.error = error.localizedDescription }
    }
    public func play(_ track: OfflineTrack) {
        do {
            guard let library else { throw CocoaError(.fileReadUnknown) }
            let player = try AVAudioPlayer(contentsOf: library.audioURL(for: track))
            beforePlay?()
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            audio?.stop()
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            audio = player; current = track; duration = player.duration; position = 0; playing = true
            configureRemoteCommands()
            updateNowPlaying()
        } catch { self.error = error.localizedDescription }
    }
    public func toggle() {
        guard let audio else { return }
        if audio.isPlaying { audio.pause() } else { audio.play() }
        playing = audio.isPlaying
        updateNowPlaying()
    }
    public func seek(_ time: Double) {
        audio?.currentTime = min(max(time, 0), duration); position = audio?.currentTime ?? 0
        updateNowPlaying()
    }
    public func stop() {
        audio?.stop(); audio = nil; current = nil; playing = false; position = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    public func next() {
        guard let current, let index = tracks.firstIndex(where: { $0.id == current.id }), index + 1 < tracks.count else { stop(); return }
        play(tracks[index + 1])
    }
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if flag { self.next() } else { self.stop() } }
    }
    private func updateNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
    }
    private func configureRemoteCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] {
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if command === center.playCommand { if !self.playing { self.toggle() } }
                    else if command === center.pauseCommand { if self.playing { self.toggle() } }
                    else { self.toggle() }
                }
                return .success
            }
            commandTargets.append((command, target))
        }
        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
        commandTargets.append((center.changePlaybackPositionCommand, seekTarget))
    }

    public struct Candidate: Decodable, Identifiable {
        public let title: String
        public let duration: Double
        public let url: String
        public let provider: String
        public let score: Double
        public var id: String { url }
    }
    private func request(path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let base = URL(string: endpoint), let scheme = base.scheme, let host = base.host,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(host)),
              base.user == nil, base.password == nil else { throw URLError(.badURL) }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
    private func json(path: String, body: [String: Any]? = nil) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(path: path, body: body))
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw NSError(domain: "Spotifu", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Server error"])
        }
        return data
    }
    public func search(title: String, artist: String, duration: Double) async {
        busy = true; defer { busy = false }
        do {
            struct Response: Decodable { let candidates: [Candidate] }
            candidates = try JSONDecoder().decode(Response.self, from: await json(path: "search", body: ["title": title, "artist": artist, "duration": duration])).candidates
            status = candidates.isEmpty ? "Совпадений нет. Можно вставить прямую ссылку источника." : "Выбери нужную запись; совпадение не гарантировано."
        } catch { self.error = error.localizedDescription }
    }
    public func download(url: String, id: String, title: String, artist: String, duration: Double) async {
        busy = true; defer { busy = false }
        do {
            struct Job: Decodable { let job: String }
            struct State: Decodable { let status: String; let audio: String?; let lyrics: String?; let error: String? }
            let job = try JSONDecoder().decode(Job.self, from: await json(path: url.isEmpty ? "auto-download" : "download", body: ["url": url, "title": title, "artist": artist, "duration": duration])).job
            for _ in 0..<180 {
                try Task.checkCancellation()
                let state = try JSONDecoder().decode(State.self, from: await json(path: "jobs/" + job))
                status = "Загрузка: " + state.status
                if state.status == "failed" { throw NSError(domain: "Spotifu", code: 2, userInfo: [NSLocalizedDescriptionKey: state.error ?? "Download failed"]) }
                if state.status == "ready" {
                    let (temp, response) = try await URLSession.shared.download(for: request(path: "audio/" + job))
                    defer { try? FileManager.default.removeItem(at: temp) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let probe = try AVAudioPlayer(contentsOf: temp)
                    guard let library else { throw CocoaError(.fileWriteUnknown) }
                    let track = OfflineTrack(id: id.isEmpty ? UUID().uuidString : id, title: title, artist: artist, duration: probe.duration, lyrics: state.lyrics, source: url, audioExtension: "m4a")
                    try library.store(track, audio: temp); try reload()
                    status = state.lyrics == nil ? "Аудио загружено. Текст не найден." : "Аудио и текст сохранены офлайн."
                    return
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            throw URLError(.timedOut)
        } catch { self.error = error.localizedDescription }
    }
    private static func readToken() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Spotifu", kSecAttrAccount as String: "resolver", kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    private static func saveToken(_ token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Spotifu", kSecAttrAccount as String: "resolver"]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

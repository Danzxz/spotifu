import Orion
import SwiftUI
import MediaPlayer
import CryptoKit

struct BaseLyricsGroup: HookGroup { }
struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }
struct LyricsErrorHandlingGroup: HookGroup { }

var lyricsState = LyricsLoadingState()
var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private struct LoadedTrackLyrics {
    var lyrics: Lyrics
    var state: LyricsLoadingState
    var metadata: (String, String)? = nil
}
private let lyricsRequests = LyricsRequestCoordinator<LoadedTrackLyrics>(source: UserDefaults.lyricsSource.rawValue)
private var scheduledLyricsPrefetch: DispatchWorkItem?
private let lyricsDiskCache: LyricsDiskCache? = {
    guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
    return try? LyricsDiskCache(root: support.appendingPathComponent("Spotifu/NativeLyrics"))
}()

private func lyricsCacheVariant(_ source: LyricsSource, _ options: LyricsOptions) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(options)) ?? Data()
    return String(source.rawValue) + "-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func savedTrackLyrics(_ id: String, source: LyricsSource, options: LyricsOptions) -> LoadedTrackLyrics? {
    if let entry = try? lyricsDiskCache?.load(trackID: id, variant: lyricsCacheVariant(source, options)),
       let lyrics = try? Lyrics(serializedBytes: entry.data) {
        var state = LyricsLoadingState(); state.loadedSuccessfully = true
        let metadata = entry.title.flatMap { title in entry.artist.map { (title, $0) } }
        return LoadedTrackLyrics(lyrics: lyrics, state: state, metadata: metadata)
    }
    // Downloaded audio already carries its LRC/plain text in the shared library.
    guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
          let library = try? OfflineLibrary(root: support.appendingPathComponent("Spotifu/Downloads")),
          let track = try? library.tracks().first(where: { $0.id == id }),
          let text = track.lyrics, !text.isEmpty else { return nil }
    let timed = LyricLine.parse(text)
    let lines = timed.isEmpty
        ? text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { LyricsLineDto(content: $0, offsetMs: nil) }
        : timed.map { LyricsLineDto(content: $0.text, offsetMs: Int($0.time * 1000)) }
    let dto = LyricsDto(lines: lines, timeSynced: !timed.isEmpty, romanization: .original, translation: nil)
    let lyrics = Lyrics.with { $0.data = dto.toSpotifyLyricsData(source: "Скачано") }
    var state = LyricsLoadingState(); state.loadedSuccessfully = true
    return LoadedTrackLyrics(lyrics: lyrics, state: state, metadata: (track.title, track.artist))
}

/// Called by the player observer, never by a lyrics HTTP request. Fetches may
/// be speculative or complete out of order; only playback selects the song.
func lyricsPlaybackDidChange(trackId: String?) {
    DispatchQueue.main.async {
        guard lyricsRequests.select(trackID: trackId, source: UserDefaults.lyricsSource.rawValue) else { return }
        scheduledLyricsPrefetch?.cancel()
        lyricsState = LyricsLoadingState()
        capturedTrackId = nil; capturedTrackTitle = nil; capturedArtistName = nil
        KaraokeLyricsStore.shared.notify()
        guard let trackId else { return }
        let work = DispatchWorkItem { prefetchLyricsIfNeeded(trackId: trackId) }
        scheduledLyricsPrefetch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }
}

func canPublishLyrics(trackId: String, generation: UInt64?) -> Bool {
    lyricsRequests.isCurrent(trackID: trackId, source: UserDefaults.lyricsSource.rawValue, generation: generation)
}

func invalidateLyricsForSourceChange() {
    scheduledLyricsPrefetch?.cancel()
    lyricsRequests.select(trackID: lyricsRequests.currentTrackID(), source: UserDefaults.lyricsSource.rawValue, force: true)
    KaraokeLyricsStore.shared.clear()
    MusixmatchLyricsRepository.shared.clearCache()
    lyricsState = LyricsLoadingState()
    if let trackId = lyricsRequests.currentTrackID() { prefetchLyricsIfNeeded(trackId: trackId) }
}

func extractTrackId(from path: String) -> String? {
    guard let range = path.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) else { return nil }
    let id = String(path[range].split(separator: "/").last ?? "")
    return id.isEmpty ? nil : id
}

/// Runs only on a worker. Snapshot UI metadata on main while it is free;
/// neither URLSession delegate below ever waits synchronously for this worker.
private func metadataForLyrics(_ trackId: String) -> (String, String)? {
    var metadata: (String, String)?
    DispatchQueue.main.sync {
        if capturedTrackId == trackId, let title = capturedTrackTitle, let artist = capturedArtistName {
            metadata = (title, artist)
        }
        if metadata == nil, let track = statefulPlayer?.currentTrack(), track.URI().spt_trackIdentifier() == trackId {
            metadata = (track.trackTitle(), track.artistName())
        }
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let external = info?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String
        let reported = KaraokePlaybackTracker.shared.playerReportedTrackId()
        if metadata == nil, external == "spotify:track:" + trackId || reported == trackId,
           let title = info?[MPMediaItemPropertyTitle] as? String,
           let artist = info?[MPMediaItemPropertyArtist] as? String, !title.isEmpty, !artist.isEmpty {
            metadata = (title, artist)
        }
    }
    if metadata == nil, let token = spotifyAccessToken { metadata = fetchTrackDetails(trackId: trackId, token: token) }
    return metadata
}

private func repository(for source: LyricsSource) throws -> LyricsRepository {
    switch source {
    case .genius: return GeniusLyricsRepository.shared
    case .lrclib: return LrclibLyricsRepository.shared
    case .musixmatch: return MusixmatchLyricsRepository.shared
    case .petit: return PetitLyricsRepository()
    case .spicylyrics: return SpicyLyricsRepository.shared
    case .notReplaced: throw LyricsError.invalidSource
    }
}

private func loadTrackLyrics(_ trackId: String, source: LyricsSource, options: LyricsOptions, generation: UInt64) throws -> LoadedTrackLyrics {
    guard canPublishLyrics(trackId: trackId, generation: generation) else { throw URLError(.cancelled) }
    let metadata = metadataForLyrics(trackId)
    let query = LyricsSearchQuery(title: metadata?.0 ?? "", primaryArtist: metadata?.1 ?? "", spotifyTrackId: trackId, requestGeneration: generation)
    var actualSource = source
    var primaryError: LyricsError?
    let dto = try lyricsWithFallback(primary: {
        do { return try repository(for: source).getLyrics(query, options: options) }
        catch { primaryError = error as? LyricsError ?? .unknownError; throw error }
    }, fallback: {
        guard source != .genius, let metadata, !metadata.0.isEmpty, !metadata.1.isEmpty else { throw LyricsError.noSuchSong }
        guard canPublishLyrics(trackId: trackId, generation: generation) else { throw URLError(.cancelled) }
        actualSource = .genius
        if primaryError == nil { primaryError = .noSuchSong }
        // Genius is plain text. Never manufacture timing for fallback lyrics.
        var plain = try GeniusLyricsRepository.shared.getLyrics(query, options: options)
        plain.timeSynced = false
        plain.lines = plain.lines.map { LyricsLineDto(content: $0.content, offsetMs: nil) }
        return plain
    }, isUsable: { !$0.lines.isEmpty })
    guard !dto.lines.isEmpty else { throw LyricsError.noSuchSong }
    guard canPublishLyrics(trackId: trackId, generation: generation) else { throw URLError(.cancelled) }
    var state = LyricsLoadingState()
    state.isEmpty = false; state.loadedSuccessfully = true; state.fallbackError = primaryError
    state.wasRomanized = dto.romanization == .romanized || (dto.romanization == .canBeRomanized && options.romanization)
    if actualSource.supportsCustomLyricsView,
       KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) == nil,
       let karaoke = KaraokeLyricsDto.lineSynced(from: dto, providerName: actualSource.description) {
        KaraokeLyricsStore.shared.set(trackId: trackId, lyrics: karaoke, generation: generation)
    }
    let lyrics = Lyrics.with { $0.data = dto.toSpotifyLyricsData(source: actualSource.description, romanize: options.romanization) }
    return LoadedTrackLyrics(lyrics: lyrics, state: state, metadata: metadata)
}

/// Async, single-flight and generation-checked. Callback always runs on main.
/// A provider can finish after a skip, but cannot publish that obsolete result.
func requestLyricsData(_ path: String, originalLyrics: Lyrics? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
    guard let id = extractTrackId(from: path) else { completion(.failure(LyricsError.noCurrentTrack)); return }
    let source = UserDefaults.lyricsSource
    guard source.isReplacingLyrics else { completion(.failure(LyricsError.invalidSource)); return }
    let options = UserDefaults.lyricsOptions
    let generation = lyricsRequests.currentGeneration()
    lyricsRequests.request(trackID: id, source: source.rawValue, load: { finish in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try loadTrackLyrics(id, source: source, options: options, generation: generation)
                if let data = try? loaded.lyrics.serializedData() {
                    try? lyricsDiskCache?.store(trackID: id, variant: lyricsCacheVariant(source, options), data: data, title: loaded.metadata?.0, artist: loaded.metadata?.1)
                }
                finish(.success(loaded))
            } catch {
                if (error as? URLError)?.code != .cancelled, let saved = savedTrackLyrics(id, source: source, options: options) {
                    finish(.success(saved))
                } else { finish(.failure(error)) }
            }
        }
    }, completion: { result in
        do {
            var loaded = try result.get()
            lyricsState = loaded.state
            if let metadata = loaded.metadata {
                capturedTrackId = id; capturedTrackTitle = metadata.0; capturedArtistName = metadata.1
            }
            let settings = UserDefaults.lyricsColors
            if settings.displayOriginalColors, let originalLyrics { loaded.lyrics.colors = originalLyrics.colors }
            else {
                let color: Color
                if settings.useStaticColor { color = Color(hex: settings.staticColor) }
                else if let background = backgroundViewModel?.color() { color = Color(background).normalized(settings.normalizationFactor) }
                else { color = .gray }
                loaded.lyrics.colors = LyricsColors.with { $0.backgroundColor = color.uInt32; $0.lineColor = Color.black.uInt32; $0.activeLineColor = Color.white.uInt32 }
            }
            completion(.success(try loaded.lyrics.serializedData()))
        } catch { completion(.failure(error)) }
    })
}

func prefetchLyricsIfNeeded(trackId: String) {
    guard UserDefaults.lyricsSource.isReplacingLyrics else { return }
    requestLyricsData("/color-lyrics/v2/track/" + trackId) { _ in }
}

func emptyLyricsData(originalLyrics: Lyrics? = nil) -> Data? {
    var value = Lyrics.with { $0.data = LyricsData.with {
        $0.timeSynchronized = false; $0.restriction = .unrestricted
        $0.lines = [LyricsLine.with { $0.content = "Текст не найден" }]
    } }
    if let originalLyrics { value.colors = originalLyrics.colors }
    return try? value.serializedData()
}

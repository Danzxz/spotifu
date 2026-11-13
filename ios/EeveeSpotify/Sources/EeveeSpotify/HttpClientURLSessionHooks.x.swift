import Foundation
import Orion

// Sibling delegate to SPTDataLoaderService. Some regions (e.g. gae2) ship
// bootstrap / customize / PAM responses through this delegate instead — without
// hooking both, server-rendered free-tier strings slip through.
class HttpClientURLSessionHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "Connectivity_HttpClientKit.HttpClientURLSession"

    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        captureAccessToken(from: task.currentRequest)

        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.flush(task, url: url)
        }

        if SpotifyResponsePatcher.shouldBlock(url) {
            orig.URLSession(session, dataTask: task, didReceiveData: SpotifyResponsePatcher.blockedResponseData(for: url))
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        if url.isLyrics, (error as? URLError)?.code == .cancelled {
            URLSessionHelper.shared.discardData(for: task)
            DispatchQueue.main.async { [self] in orig.URLSession(session, task: task, didCompleteWithError: error) }
            return
        }

        if url.isLyrics, BaseLyricsGroup.isActive, UserDefaults.lyricsSource.isReplacingLyrics {
            let buffer = URLSessionHelper.shared.obtainData(for: task)
            let original = buffer.flatMap { try? Lyrics(serializedBytes: $0) }
            requestLyricsData(url.path, originalLyrics: original) { [self] result in
                switch result {
                case .failure(let failure) where (failure as? URLError)?.code == .cancelled:
                    orig.URLSession(session, task: task, didCompleteWithError: failure)
                default:
                    let data = (try? result.get()) ?? emptyLyricsData(originalLyrics: original) ?? Data()
                    if task.response == nil, let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: ["Content-Type": "application/x-protobuf"]) {
                        orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: { _ in })
                    }
                    orig.URLSession(session, dataTask: task, didReceiveData: data)
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                }
            }
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // marked for modify but no body bytes (0-byte/early-completion/redirect).
            // Always forward completion or Spotify hangs and gets watchdog-killed.
            // Customize: fall back to the persisted copy — the in-memory cache is
            // empty on the first completion of a fresh process (warm relaunch 304).
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData
                ?? UserDefaults.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                // Some Spotify builds complete "modified" tasks with 0 body bytes.
                // We previously forwarded completion only, which can crash callers that
                // assume at least one didReceiveData before completion.
                writeDebugLog("[HCUS] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[HCUS] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil — no transform, but didReceiveData already
            // suppressed the original. Replay or consumer hangs.
            orig.URLSession(session, dataTask: task, didReceiveData: buffer)
            orig.URLSession(session, task: task, didCompleteWithError: nil)
        } catch {
            orig.URLSession(session, task: task, didCompleteWithError: error)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304 {
            // Warm relaunch: customize revalidates via ETag and returns 304 with no
            // body. The in-memory cache is empty in a fresh process, so fall back to
            // the persisted copy of the last patched response. Synthesizing a 200 and
            // replaying it keeps Spotify's disk-cached UNPATCHED config (ad flags) from
            // being consumed — the fingerprint behind relaunch crash/ads reports.
            // With no persisted copy yet (first-ever launch edge case) the 304 passes
            // through untouched; the next real 200 gets patched and persists.
            if let cached = SpotifyResponsePatcher.cachedCustomizeData
                ?? UserDefaults.cachedCustomizeData,
               let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) {
                orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                SpotifyResponsePatcher.markCustomizeTaskHandled(task.taskIdentifier)
                return
            }
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // Normalize the response only. Deliver the replacement once, from
        // didCompleteWithError, after the async provider fetch has finished.
        if let url = task.currentRequest?.url, url.isLyrics,
           BaseLyricsGroup.isActive, UserDefaults.lyricsSource.isReplacingLyrics,
           let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: ["Content-Type": "application/x-protobuf"]) {
            DispatchQueue.main.async { [self] in
                orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: handler)
            }
        } else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else { return }
        if SpotifyResponsePatcher.shouldBlock(url) { return }
        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.append(data, for: task)
        }
        if SpotifyResponsePatcher.shouldModify(url) {
            URLSessionHelper.shared.setOrAppend(data, for: task)
            return
        }
        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
}

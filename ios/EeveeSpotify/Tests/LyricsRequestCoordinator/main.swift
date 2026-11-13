import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let delivery = DispatchQueue(label: "lyrics.tests.delivery")
let gate = LyricsRequestCoordinator<String>(source: 0, deliveryQueue: delivery)
var firstA: ((Result<String, Error>) -> Void)?
var secondA: ((Result<String, Error>) -> Void)?
var b: ((Result<String, Error>) -> Void)?
let resultsLock = NSLock()
var displayed: [String] = []
var cancelled = 0
func consume(_ result: Result<String, Error>) {
    resultsLock.lock(); defer { resultsLock.unlock() }
    if case .success(let value) = result { displayed.append(value) }
    else { cancelled += 1 }
}
gate.select(trackID: "A", source: 0)
gate.request(trackID: "A", source: 0, load: { firstA = $0 }, completion: consume)
gate.select(trackID: "B", source: 0)
gate.request(trackID: "B", source: 0, load: { b = $0 }, completion: consume)
gate.select(trackID: "A", source: 0)
gate.request(trackID: "A", source: 0, load: { secondA = $0 }, completion: consume)
firstA?(.success("stale A")); b?(.success("stale B")); secondA?(.success("current A"))
delivery.sync {}
require(displayed == ["current A"], "A→B→A must reject the first A and B responses")
require(cancelled == 2, "Each superseded request completes exactly once")

var oldSource: ((Result<String, Error>) -> Void)?
gate.select(trackID: "C", source: 0)
gate.request(trackID: "C", source: 0, load: { oldSource = $0 }, completion: consume)
gate.select(trackID: "C", source: 1)
oldSource?(.success("wrong provider"))
gate.request(trackID: "C", source: 1, load: { $0(.success("new provider")) }, completion: consume)
delivery.sync {}
require(displayed == ["current A", "new provider"], "Changing provider invalidates in-flight work")

var finish: ((Result<String, Error>) -> Void)?
var starts = 0
gate.select(trackID: "D", source: 1)
for _ in 0..<2 {
    gate.request(trackID: "D", source: 1, load: { starts += 1; finish = $0 }, completion: consume)
}
finish?(.success("D")); finish?(.success("duplicate D"))
delivery.sync {}
require(starts == 1, "Prefetch and native request for one track must share one fetch")
require(displayed.suffix(2) == ["D", "D"], "Every subscriber gets one response; duplicate provider callback ignored")

delivery.suspend()
gate.select(trackID: "E", source: 1)
gate.request(trackID: "E", source: 1, load: { $0(.success("queued stale E")) }, completion: consume)
gate.select(trackID: "F", source: 1)
delivery.resume(); delivery.sync {}
require(!displayed.contains("queued stale E"), "Selection must be checked when delivering, not just when HTTP completes")

gate.select(trackID: "D", source: 1)
var revisits = 0
gate.request(trackID: "D", source: 1, load: { revisits += 1; $0(.success("D refreshed")) }, completion: consume)
delivery.sync {}
require(revisits == 1, "Returning to a track must refresh generation-bound karaoke, not reuse an old payload")
gate.select(trackID: "D", source: 1, force: true)
gate.request(trackID: "D", source: 1, load: { $0(.success("D with new options")) }, completion: consume)
delivery.sync {}
require(displayed.last == "D with new options", "Options changes must invalidate same-track cache")

enum Missing: Error { case absent }
var fallbacks = 0
let plain = try lyricsWithFallback(primary: { () throws -> [String] in throw Missing.absent }, fallback: { fallbacks += 1; return ["plain"] }, isUsable: { !$0.isEmpty })
require(plain == ["plain"] && fallbacks == 1, "Missing primary always invokes fallback")
let empty = try lyricsWithFallback(primary: { [String]() }, fallback: { fallbacks += 1; return ["plain"] }, isUsable: { !$0.isEmpty })
require(empty == ["plain"] && fallbacks == 2, "Empty primary must also invoke fallback")
let synced = try lyricsWithFallback(primary: { ["timed"] }, fallback: { fallbacks += 1; return ["plain"] }, isUsable: { !$0.isEmpty })
require(synced == ["timed"] && fallbacks == 2, "Successful primary keeps its timing")
print("Lyrics rapid-skip, source invalidation, single-flight and fallback tests passed")

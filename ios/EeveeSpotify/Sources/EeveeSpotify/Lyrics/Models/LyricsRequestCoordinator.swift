import Foundation

/// One generation per playback selection. A late A response cannot replace B,
/// including A→B→A, and prefetch/native consumers share one provider request.
final class LyricsRequestCoordinator<Value> {
    typealias Completion = (Result<Value, Error>) -> Void
    private struct Key: Hashable { let trackID: String; let source: Int }
    private struct Pending {
        let id: UUID
        let generation: UInt64
        var callbacks: [Completion]
    }
    private let lock = NSLock()
    private let deliveryQueue: DispatchQueue
    private var trackID: String?
    private var source: Int
    private var generation: UInt64 = 0
    private var pending: [Key: Pending] = [:]
    private var cache: [Key: Value] = [:]
    private var order: [Key] = []

    init(source: Int, deliveryQueue: DispatchQueue = .main) {
        self.source = source; self.deliveryQueue = deliveryQueue
    }
    @discardableResult
    func select(trackID: String?, source: Int, force: Bool = false) -> Bool {
        lock.lock()
        guard force || self.trackID != trackID || self.source != source else { lock.unlock(); return false }
        let callbacks = pending.values.flatMap { $0.callbacks }
        // Rich karaoke payloads belong to this playback generation. Reusing
        // the flattened cache on a revisit would leave that payload missing.
        cache.removeAll(); order.removeAll()
        self.trackID = trackID; self.source = source; generation &+= 1
        pending.removeAll()
        lock.unlock()
        for callback in callbacks { deliveryQueue.async { callback(.failure(URLError(.cancelled))) } }
        return true
    }
    func isCurrent(trackID: String, source: Int, generation revision: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.source == source && (self.trackID == nil || self.trackID == trackID)
            && (revision == nil || revision == generation)
    }
    func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return generation
    }
    func currentTrackID() -> String? {
        lock.lock(); defer { lock.unlock() }; return trackID
    }
    func request(trackID: String, source: Int,
                 load: @escaping (@escaping Completion) -> Void,
                 completion: @escaping Completion) {
        let key = Key(trackID: trackID, source: source)
        lock.lock()
        let revision = generation
        guard self.source == source, self.trackID == nil || self.trackID == trackID else {
            lock.unlock()
            deliveryQueue.async { completion(.failure(URLError(.cancelled))) }
            return
        }
        if let value = cache[key] {
            lock.unlock(); deliver(.success(value), generation: revision, callback: completion); return
        }
        if pending[key] != nil {
            pending[key]!.callbacks.append(completion); lock.unlock(); return
        }
        let id = UUID()
        pending[key] = Pending(id: id, generation: revision, callbacks: [completion])
        lock.unlock()
        load { [weak self] result in self?.finish(key, id: id, result: result) }
    }
    private func finish(_ key: Key, id: UUID, result: Result<Value, Error>) {
        lock.lock()
        guard let request = pending[key], request.id == id else { lock.unlock(); return }
        pending[key] = nil
        if case .success(let value) = result {
            cache[key] = value; order.removeAll { $0 == key }; order.append(key)
            if order.count > 32 { cache[order.removeFirst()] = nil }
        }
        lock.unlock()
        for callback in request.callbacks { deliver(result, generation: request.generation, callback: callback) }
    }
    private func deliver(_ result: Result<Value, Error>, generation revision: UInt64, callback: @escaping Completion) {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let valid = self.generation == revision; self.lock.unlock()
            callback(valid ? result : .failure(URLError(.cancelled)))
        }
    }
}

/// An empty successful response is a miss too. The fallback is mandatory;
/// successful primary results keep their own timing and provider identity.
func lyricsWithFallback<Value>(primary: () throws -> Value, fallback: () throws -> Value,
                               isUsable: (Value) -> Bool) throws -> Value {
    do { let value = try primary(); if isUsable(value) { return value } } catch { }
    return try fallback()
}

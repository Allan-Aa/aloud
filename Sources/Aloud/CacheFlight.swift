import Foundation

struct CacheFlightKey: Hashable, Sendable {
    let providerID: ProviderID
    let fingerprint: RequestFingerprint
    let scopeRevision: UUID
    init(providerID: ProviderID = .minimax, fingerprint: RequestFingerprint, scopeRevision: UUID) { self.providerID = providerID; self.fingerprint = fingerprint; self.scopeRevision = scopeRevision }
}

struct CacheWaiterID: RawRepresentable, Hashable, Sendable { let rawValue: UUID; init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
struct UnpublishedArtifact: Hashable, Sendable { let artifact: AudioArtifact; init(artifact: AudioArtifact) { self.artifact = artifact } }
struct PublishLease: Hashable, Sendable { fileprivate let id: UUID; fileprivate let key: CacheFlightKey; fileprivate let waiter: CacheWaiterID }
enum CacheFlightError: Error, Equatable { case cancelled, noReadyArtifact }

/// A synchronous cancellation bit shared with the commit turn.  Cancellation
/// never relies on an actor hop winning a race with rename.
final class CacheCancelRelay: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
    func withCommitPermission<T>(_ body: () throws -> T) throws -> T? {
        try lock.withLock { if value { return nil }; return try body() }
    }
}

/// Retains a ready artifact until its current waiters release it.  The producer
/// may never publish: cleanup/publishing are both owned by the caller/gate.
actor CacheFlight {
    struct CleanupOps: Sendable {
        let remove: @Sendable (URL) -> Void
        static let live = CleanupOps(remove: { try? FileManager.default.removeItem(at: $0) })
    }
    private enum State { case producing(Task<UnpublishedArtifact, Error>), ready(UnpublishedArtifact), failed }
    private struct Entry { let id: UUID; var state: State; var waiters: Set<CacheWaiterID>; var lease: PublishLease?; var supervisor: Task<Void, Never>? }
    private var entries: [CacheFlightKey: Entry] = [:]
    private var retired: [UUID: Task<Void, Never>] = [:]
    private let cleanup: CleanupOps

    init(cleanup: CleanupOps = .live) { self.cleanup = cleanup }

    func join(key: CacheFlightKey, waiter: CacheWaiterID, producer: @escaping @Sendable () async throws -> UnpublishedArtifact) async throws -> UnpublishedArtifact {
        try Task.checkCancellation()
        if entries[key] == nil {
            let task = Task { try await producer() }
            let id = UUID()
            entries[key] = Entry(id: id, state: .producing(task), waiters: [], lease: nil, supervisor: nil)
            let supervisor = Task { [weak self] in
                let result: Result<UnpublishedArtifact, Error>
                do { result = .success(try await task.value) } catch { result = .failure(error) }
                await self?.producerFinished(key: key, id: id, result: result)
            }
            entries[key]?.supervisor = supervisor
        }
        guard var entry = entries[key] else { throw CacheFlightError.cancelled }
        entry.waiters.insert(waiter); entries[key] = entry
        return try await withTaskCancellationHandler(operation: {
            let artifact = try await awaitReady(key: key)
            try Task.checkCancellation()
            return artifact
        }, onCancel: { Task { await self.cancel(key: key, waiter: waiter) } })
    }

    private func awaitReady(key: CacheFlightKey) async throws -> UnpublishedArtifact {
        guard let entry = entries[key] else { throw CacheFlightError.cancelled }
        switch entry.state {
        case .ready(let artifact): return artifact
        case .failed: throw CacheFlightError.noReadyArtifact
        case .producing(let task):
            let artifact = try await task.value
            // The joining waiter, not only the detached supervisor, makes the
            // flight ready before it returns. This closes task.value -> lease.
            guard var current = entries[key], current.id == entry.id else {
                if let supervisor = retired[entry.id] ?? entry.supervisor { await supervisor.value }
                throw CacheFlightError.cancelled
            }
            if case .producing = current.state {
                current.state = .ready(artifact)
                entries[key] = current
            }
            return artifact
        }
    }

    func acquirePublishLease(key: CacheFlightKey, waiter: CacheWaiterID) -> PublishLease? {
        guard var entry = entries[key], entry.waiters.contains(waiter), entry.lease == nil else { return nil }
        guard case .ready = entry.state else { return nil }
        let lease = PublishLease(id: UUID(), key: key, waiter: waiter)
        entry.lease = lease; entries[key] = entry
        return lease
    }

    /// Failed publish releases the lease for another still-current waiter.
    func releaseLease(_ lease: PublishLease) {
        guard var entry = entries[lease.key], entry.lease == lease else { return }
        entry.lease = nil; entries[lease.key] = entry
    }

    func cancel(key: CacheFlightKey, waiter: CacheWaiterID) { release(key: key, waiter: waiter) }
    func release(key: CacheFlightKey, waiter: CacheWaiterID) {
        guard var entry = entries[key] else { return }
        entry.waiters.remove(waiter)
        if entry.lease?.waiter == waiter { entry.lease = nil }
        if entry.waiters.isEmpty { discard(key: key, entry: entry) } else { entries[key] = entry }
    }

    private func producerFinished(key: CacheFlightKey, id: UUID, result: Result<UnpublishedArtifact, Error>) async {
        guard var entry = entries[key], entry.id == id else {
            if case .success(let artifact) = result {
                deferCleanupWithoutHoldingActor(key: key, artifact: artifact)
            }
            retired[id] = nil
            return
        }
        switch result {
        case .success(let artifact):
            entry.state = .ready(artifact)
            if entry.waiters.isEmpty { entries.removeValue(forKey: key); cleanup.remove(artifact.artifact.url) }
            else { entries[key] = entry }
        case .failure:
            entries.removeValue(forKey: key)
        }
    }
    private func discard(key: CacheFlightKey, entry: Entry) {
        // Keep a cancelled producer entry until its supervisor consumes a
        // cancellation-ignoring late result, then deletes that unique temp.
        if case .producing(let task) = entry.state {
            // Retire immediately. Its independently-started supervisor owns
            // the eventual result cleanup; a new join gets a new producer.
            task.cancel()
            if let supervisor = entry.supervisor { retired[entry.id] = supervisor }
            entries.removeValue(forKey: key); return
        }
        entries.removeValue(forKey: key)
        switch entry.state {
        case .ready(let artifact): cleanup.remove(artifact.artifact.url)
        case .producing, .failed: break
        }
    }
    private func currentEntryOwns(_ url: URL, for key: CacheFlightKey) -> Bool {
        guard let entry = entries[key], case .ready(let artifact) = entry.state else { return false }
        return artifact.artifact.url.standardizedFileURL == url.standardizedFileURL
    }
    /// A replacement producer may ignore cancellation or never finish. Its
    /// completion must not hold this actor turn or the retired join hostage.
    /// Until ownership resolves the old unique unpublished temp is quarantined.
    private func deferCleanupWithoutHoldingActor(key: CacheFlightKey, artifact: UnpublishedArtifact) {
        guard let current = entries[key] else { cleanup.remove(artifact.artifact.url); return }
        switch current.state {
        case .ready(let owned):
            if owned.artifact.url.standardizedFileURL != artifact.artifact.url.standardizedFileURL {
                cleanup.remove(artifact.artifact.url)
            }
        case .failed:
            cleanup.remove(artifact.artifact.url)
        case .producing(let task):
            Task.detached { [weak self] in
                _ = await task.result
                await self?.deferCleanupWithoutHoldingActor(key: key, artifact: artifact)
            }
        }
    }
    func waiterCount(key: CacheFlightKey) -> Int { entries[key]?.waiters.count ?? 0 }
}

/// Final cache writes are confined here. Registering an issued lease lets this
/// actor verify owner/current scope without an await between check and rename.
actor PublishCommitGate {
    struct FileOps: Sendable {
        let publish: @Sendable (URL, URL) throws -> Void
        static let live = FileOps(publish: { source, destination in
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: source) }
            else { try manager.moveItem(at: source, to: destination) }
        })
    }
    private struct Current: Equatable { let revision: UUID; let generation: SessionGeneration }
    private let cache: CanonicalAudioCache
    private let fileOps: FileOps
    private var current: [ProviderID: Current] = [:]
    private var active: [UUID: PublishLease] = [:]

    init(cache: CanonicalAudioCache = CanonicalAudioCache(), fileOps: FileOps = .live) { self.cache = cache; self.fileOps = fileOps }
    func advance(providerID: ProviderID, revision: UUID, generation: SessionGeneration) { current[providerID] = Current(revision: revision, generation: generation) }
    func register(_ lease: PublishLease) { active[lease.id] = lease }
    func revoke(_ lease: PublishLease) { active.removeValue(forKey: lease.id) }

    func commit(_ lease: PublishLease, artifact: UnpublishedArtifact, finalURL: URL, expectedRevision: UUID, expectedGeneration: SessionGeneration, cancellation: CacheCancelRelay) throws -> AudioArtifact? {
        defer { active.removeValue(forKey: lease.id) }
        let outcome: AudioArtifact?? = try cancellation.withCommitPermission { () throws -> AudioArtifact? in
            guard active[lease.id] == lease,
                  lease.key.scopeRevision == expectedRevision,
                  current[lease.key.providerID] == Current(revision: expectedRevision, generation: expectedGeneration),
                  finalURL.standardizedFileURL == cache.path(for: lease.key.fingerprint).standardizedFileURL else { return nil }
            _ = try WAVValidator.validate(artifact.artifact.url, purpose: artifact.artifact.purpose)
            try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
            try fileOps.publish(artifact.artifact.url, finalURL)
            return try WAVValidator.validate(finalURL, purpose: artifact.artifact.purpose)
        }
        return outcome ?? nil
    }
}

struct CanonicalAudioCache: Sendable {
    let directory: URL
    init(directory: URL = Store.cacheDir) { self.directory = directory }
    func path(for fingerprint: RequestFingerprint) -> URL { directory.appendingPathComponent(fingerprint.rawValue.map { String(format: "%02x", $0) }.joined()).appendingPathExtension("wav") }
    func hit(fingerprint: RequestFingerprint, purpose: SpeechPurpose) -> AudioArtifact? {
        let url = path(for: fingerprint)
        do { return try WAVValidator.validate(url, purpose: purpose) }
        catch { try? FileManager.default.removeItem(at: url); return nil }
    }
    func removeOrphans(olderThan cutoff: Date, fileManager: FileManager = .default) {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("aloud-temp-") && file.pathExtension == "wav" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]), values.isSymbolicLink != true, let date = values.contentModificationDate, date < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}

/// The Task 14/16 integration seam: it publishes one canonical chunk through
/// the flight/gate pair and never exposes a final-path write to providers.
actor CanonicalChunkCacheCoordinator {
    let flight: CacheFlight; let gate: PublishCommitGate; let cache: CanonicalAudioCache
    static let live = CanonicalChunkCacheCoordinator(cache: CanonicalAudioCache())
    init(cache: CanonicalAudioCache) { self.cache = cache; flight = CacheFlight(); gate = PublishCommitGate(cache: cache) }
    func advance(providerID: ProviderID, revision: UUID, generation: SessionGeneration) async { await gate.advance(providerID: providerID, revision: revision, generation: generation) }
    func resolve(key: CacheFlightKey, generation: SessionGeneration, purpose: SpeechPurpose, produce: @escaping @Sendable () async throws -> UnpublishedArtifact) async throws -> AudioArtifact {
        let relay = CacheCancelRelay()
        return try await withTaskCancellationHandler(operation: {
            try await resolveActive(key: key, generation: generation, purpose: purpose, relay: relay, produce: produce)
        }, onCancel: { relay.cancel() })
    }
    private func resolveActive(key: CacheFlightKey, generation: SessionGeneration, purpose: SpeechPurpose, relay: CacheCancelRelay, produce: @escaping @Sendable () async throws -> UnpublishedArtifact) async throws -> AudioArtifact {
        try Task.checkCancellation(); guard !relay.isCancelled else { throw CacheFlightError.cancelled }
        if let hit = cache.hit(fingerprint: key.fingerprint, purpose: purpose) { return hit }
        let waiter = CacheWaiterID()
        var lease: PublishLease?
        do {
            let artifact = try await flight.join(key: key, waiter: waiter, producer: produce)
            try Task.checkCancellation()
            guard let acquired = await flight.acquirePublishLease(key: key, waiter: waiter) else { throw CacheFlightError.noReadyArtifact }
            lease = acquired
            try Task.checkCancellation()
            await gate.register(acquired)
            try Task.checkCancellation()
            let final = cache.path(for: key.fingerprint)
            guard !relay.isCancelled else { throw CacheFlightError.cancelled }
            let result = try await gate.commit(acquired, artifact: artifact, finalURL: final, expectedRevision: key.scopeRevision, expectedGeneration: generation, cancellation: relay)
            lease = nil
            await flight.release(key: key, waiter: waiter)
            guard let result else { throw CacheFlightError.cancelled }
            return result
        } catch {
            if let lease { await gate.revoke(lease); await flight.releaseLease(lease) }
            await flight.release(key: key, waiter: waiter)
            throw error
        }
    }
}

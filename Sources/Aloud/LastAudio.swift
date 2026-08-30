import Foundation

enum LastAudioOrphanCleaner {
    static func remove(
        in directory: URL,
        olderThan cutoff: Date,
        fileManager: FileManager = .default
    ) {
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("aloud-last-audio-"), name.hasSuffix(".wav"),
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? fileManager.removeItem(at: candidate)
        }
    }
}

struct RetainedAudioHandle: Sendable {
    let id: UUID
    let artifact: AudioArtifact
    let generation: SessionGeneration
    let purpose: SpeechPurpose
    let evidence: PlaybackEvidence
}

struct AudioExportLease: Hashable, Sendable {
    let id: UUID
    let handleID: UUID
    let artifact: AudioArtifact
}

enum LastAudioError: Error, Equatable {
    case noRetainedAudio
    case shutdownInProgress
    case unsupportedPurpose
    case invalidArtifact
}

enum TerminationDecision: Equatable, Sendable {
    case proceed
    case cancelTermination
}

private final class LastAudioDrainSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var drained = false

    func markDrained() { lock.withLock { drained = true } }
    func value() -> Bool { lock.withLock { drained } }
}

struct TerminationDrain: Sendable {
    private let signal: LastAudioDrainSignal

    fileprivate init(signal: LastAudioDrainSignal) { self.signal = signal }

    var isDrained: Bool {
        signal.value()
    }

    func wait() async {
        while !signal.value() {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    static func wait(
        store: LastAudioArtifactStore,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) async -> TerminationDecision {
        let drain = await store.beginShutdown()
        enum Wake: Sendable { case drained, timeout }
        let wake = await withTaskGroup(of: Wake.self) { group in
            group.addTask {
                await drain.wait()
                return .drained
            }
            group.addTask {
                await sleep(timeout)
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
        switch wake {
        case .drained:
            if await store.commitShutdownIfDrained() { return .proceed }
            await store.cancelShutdownPreservingAudio()
            return .cancelTermination
        case .timeout:
            await store.cancelShutdownPreservingAudio()
            return .cancelTermination
        }
    }
}

actor LastAudioArtifactStore {
    static let shared = LastAudioArtifactStore()

    private struct Entry {
        let handle: RetainedAudioHandle
        var leaseCount: Int
        var retained: Bool
    }

    private var entries: [UUID: Entry] = [:]
    private var currentID: UUID?
    private var leases: [UUID: UUID] = [:]
    private var shutdownInProgress = false
    private var drainSignal: LastAudioDrainSignal?
    private let removeFile: @Sendable (URL) -> Void

    init(removeFile: @escaping @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
        self.removeFile = removeFile
    }

    @discardableResult
    func promote(
        _ artifact: AudioArtifact,
        generation: SessionGeneration,
        purpose: SpeechPurpose,
        evidence: PlaybackEvidence
    ) throws -> RetainedAudioHandle {
        let handle = try preparedHandle(
            artifact, generation: generation, purpose: purpose, evidence: evidence
        )
        return try transitionToPromoted(handle)
    }

    @discardableResult
    func promote(
        _ artifact: AudioArtifact,
        generation: SessionGeneration,
        purpose: SpeechPurpose,
        evidence: PlaybackEvidence,
        token: SessionCurrentToken,
        disarmingCleanup cleanupID: UUID? = nil
    ) throws -> RetainedAudioHandle {
        // File validation is deliberately completed before the actor state
        // transition. A rejected artifact therefore cannot partially replace
        // the current handle or disarm its unpublished-file cleanup.
        let handle = try preparedHandle(
            artifact, generation: generation, purpose: purpose, evidence: evidence
        )
        return try token.withCurrentCommitPermission {
            let promoted = try transitionToPromoted(handle)
            if let cleanupID { try token.disarmUnpublishedCleanup(cleanupID) }
            return promoted
        }
    }

    func currentArtifact() -> AudioArtifact? {
        currentID.flatMap { entries[$0]?.handle.artifact }
    }

    func currentHandle() -> RetainedAudioHandle? {
        currentID.flatMap { entries[$0]?.handle }
    }

    func acquireExportLease() throws -> AudioExportLease {
        guard !shutdownInProgress else { throw LastAudioError.shutdownInProgress }
        guard let currentID, var entry = entries[currentID], entry.retained else {
            throw LastAudioError.noRetainedAudio
        }
        entry.leaseCount += 1
        entries[currentID] = entry
        let lease = AudioExportLease(id: UUID(), handleID: currentID, artifact: entry.handle.artifact)
        leases[lease.id] = currentID
        return lease
    }

    func release(_ lease: AudioExportLease) {
        guard let handleID = leases.removeValue(forKey: lease.id), handleID == lease.handleID,
              var entry = entries[handleID] else { return }
        entry.leaseCount = max(0, entry.leaseCount - 1)
        entries[handleID] = entry
        removeIfUnretainedAndUnleased(handleID)
        finishDrainIfPossible()
    }

    func releaseCurrent() {
        guard !shutdownInProgress else { return }
        guard let id = currentID, var entry = entries[id] else { return }
        currentID = nil
        entry.retained = false
        entries[id] = entry
        removeIfUnretainedAndUnleased(id)
        finishDrainIfPossible()
    }

    func beginShutdown() -> TerminationDrain {
        if let drainSignal { return TerminationDrain(signal: drainSignal) }
        shutdownInProgress = true
        let signal = LastAudioDrainSignal()
        drainSignal = signal
        // Phase one only freezes ownership. The current handle and every entry
        // stay intact so a timeout can cancel termination without reconstructing
        // (or accidentally changing) the user's last-audio selection.
        finishDrainIfPossible()
        return TerminationDrain(signal: signal)
    }

    func cancelShutdownPreservingAudio() {
        guard shutdownInProgress else { return }
        shutdownInProgress = false
        drainSignal = nil
        // Now that deletion is no longer frozen, retire replaced artifacts.
        // The retained current entry is never considered by this cleanup.
        for id in Array(entries.keys) {
            removeIfUnretainedAndUnleased(id)
        }
    }

    /// Phase two is the only destructive shutdown transition. It succeeds only
    /// after every pre-existing export lease has drained.
    func commitShutdownIfDrained() -> Bool {
        guard shutdownInProgress,
              leases.isEmpty,
              entries.values.allSatisfy({ $0.leaseCount == 0 }) else { return false }
        let urls = entries.values.map(\.handle.artifact.url)
        entries.removeAll()
        leases.removeAll()
        currentID = nil
        shutdownInProgress = false
        drainSignal = nil
        urls.forEach(removeFile)
        return true
    }

    private func preparedHandle(
        _ artifact: AudioArtifact,
        generation: SessionGeneration,
        purpose: SpeechPurpose,
        evidence: PlaybackEvidence
    ) throws -> RetainedAudioHandle {
        guard case .reading(let origin) = purpose,
              origin == .speak || origin == .replay else {
            throw LastAudioError.unsupportedPurpose
        }
        guard artifact.isCanonical, artifact.purpose == purpose else {
            throw LastAudioError.invalidArtifact
        }
        do {
            _ = try WAVValidator.validate(artifact.url, purpose: purpose)
        } catch {
            throw LastAudioError.invalidArtifact
        }
        return RetainedAudioHandle(
            id: UUID(), artifact: artifact, generation: generation,
            purpose: purpose, evidence: evidence
        )
    }

    private func transitionToPromoted(_ handle: RetainedAudioHandle) throws -> RetainedAudioHandle {
        guard !shutdownInProgress else { throw LastAudioError.shutdownInProgress }

        if let priorID = currentID, var prior = entries[priorID] {
            prior.retained = false
            entries[priorID] = prior
            removeIfUnretainedAndUnleased(priorID)
        }
        entries[handle.id] = Entry(handle: handle, leaseCount: 0, retained: true)
        currentID = handle.id
        return handle
    }

    private func removeIfUnretainedAndUnleased(_ id: UUID) {
        guard !shutdownInProgress else { return }
        guard let entry = entries[id], !entry.retained, entry.leaseCount == 0 else { return }
        entries[id] = nil
        removeFile(entry.handle.artifact.url)
    }

    private func finishDrainIfPossible() {
        guard shutdownInProgress, leases.isEmpty, entries.values.allSatisfy({ $0.leaseCount == 0 }) else { return }
        drainSignal?.markDrained()
    }
}

protocol AudioExportFileOperations: Sendable {
    func copy(from source: URL, to temporary: URL) throws
    func atomicReplace(temporary: URL, destination: URL) throws
    func remove(_ url: URL)
}

struct LocalAudioExportFileOperations: @unchecked Sendable, AudioExportFileOperations {
    let fileManager: FileManager
    init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    func copy(from source: URL, to temporary: URL) throws {
        try fileManager.copyItem(at: source, to: temporary)
    }

    func atomicReplace(temporary: URL, destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    func remove(_ url: URL) { try? fileManager.removeItem(at: url) }
}

enum AudioExporter {
    static func saveAudio(
        from store: LastAudioArtifactStore,
        to destination: URL,
        files: AudioExportFileOperations = LocalAudioExportFileOperations()
    ) async throws -> AudioArtifact {
        let lease = try await store.acquireExportLease()
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".aloud-export-\(UUID().uuidString).wav")
        do {
            try files.copy(from: lease.artifact.url, to: temporary)
            _ = try WAVValidator.validate(temporary, purpose: lease.artifact.purpose)
            try files.atomicReplace(temporary: temporary, destination: destination)
            let artifact = try WAVValidator.validate(destination, purpose: lease.artifact.purpose)
            files.remove(temporary)
            await store.release(lease)
            return artifact
        } catch {
            files.remove(temporary)
            await store.release(lease)
            throw error
        }
    }
}

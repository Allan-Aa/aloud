import XCTest
import AppKit
@testable import Aloud

final class LastAudioTests: XCTestCase {
    func testOnlyVerifiedReadingSpeakOrReplayPromotes() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let old = try artifact(directory, "old.wav", purpose: .reading(.speak))
        let preview = try artifact(directory, "preview.wav", purpose: .preview)
        let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        try await store.promote(old, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
        await XCTAssertThrowsErrorAsync(
            try await store.promote(preview, generation: SessionGeneration(rawValue: 2), purpose: .preview, evidence: evidence)
        )
        let afterPreview = await store.currentArtifact()?.url
        XCTAssertEqual(afterPreview, old.url)

        let replay = try artifact(directory, "replay.wav", purpose: .reading(.replay))
        try await store.promote(replay, generation: SessionGeneration(rawValue: 3), purpose: .reading(.replay), evidence: evidence)
        let afterReplay = await store.currentArtifact()?.url
        XCTAssertEqual(afterReplay, replay.url)
    }

    func testReplacingRetainedArtifactDefersDeletionUntilExportLeaseReleases() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        let old = try artifact(directory, "old.wav", purpose: .reading(.speak))
        let new = try artifact(directory, "new.wav", purpose: .reading(.speak))
        try await store.promote(old, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
        let lease = try await store.acquireExportLease()
        try await store.promote(new, generation: SessionGeneration(rawValue: 2), purpose: .reading(.speak), evidence: evidence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path))
        await store.release(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.url.path))
    }

    func testExplicitReleaseDefersDeletionUntilLeaseFinishes() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        let audio = try artifact(directory, "audio.wav", purpose: .reading(.speak))
        try await store.promote(audio, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
        let lease = try await store.acquireExportLease()
        await store.releaseCurrent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
        await store.release(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
    }

    func testShutdownRejectsNewLeaseAndDrainWaitsForExistingLease() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        let audio = try artifact(directory, "audio.wav", purpose: .reading(.speak))
        try await store.promote(audio, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
        let lease = try await store.acquireExportLease()
        let drain = await store.beginShutdown()
        await XCTAssertThrowsErrorAsync(try await store.acquireExportLease())
        let drainedBeforeRelease = drain.isDrained
        XCTAssertFalse(drainedBeforeRelease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
        await store.release(lease)
        await drain.wait()
        let retainedAfterDrain = await store.currentArtifact()?.url
        XCTAssertEqual(retainedAfterDrain, audio.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
        let committed = await store.commitShutdownIfDrained()
        XCTAssertTrue(committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
    }

    func testTerminationTimeoutPreservesSourceAndCancelsTermination() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        let audio = try artifact(directory, "audio.wav", purpose: .reading(.speak))
        try await store.promote(audio, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
        _ = try await store.acquireExportLease()
        let decision = await TerminationDrain.wait(store: store, timeout: .milliseconds(1))
        XCTAssertEqual(decision, .cancelTermination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
        let retainedAfterTimeout = await store.currentArtifact()?.url
        XCTAssertEqual(retainedAfterTimeout, audio.url)
    }

    func testTerminationProceedsAfterCurrentArtifactIsReleasedAndDeleted() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let audio = try artifact(directory, "audio.wav", purpose: .reading(.speak))
        try await store.promote(audio, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence())
        let decision = await TerminationDrain.wait(store: store, timeout: .seconds(1))
        XCTAssertEqual(decision, .proceed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
    }

    func testStartupOrphanCleanupRemovesOnlyOldRegularLastAudioFiles() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let old = directory.url.appendingPathComponent("aloud-last-audio-old.wav")
        let fresh = directory.url.appendingPathComponent("aloud-last-audio-fresh.wav")
        let unrelated = directory.url.appendingPathComponent("keep.wav")
        let symlinkTarget = directory.url.appendingPathComponent("target.wav")
        let symlink = directory.url.appendingPathComponent("aloud-last-audio-link.wav")
        for url in [old, fresh, unrelated, symlinkTarget] { try WAVTestFixture.wav(samples: 480).write(to: url) }
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: old.path)

        LastAudioOrphanCleaner.remove(in: directory.url, olderThan: Date(timeIntervalSinceNow: -3_600))

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    func testTwentyLeaseReplaceExportShutdownInterleavingsKeepLeasedSource() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let store = LastAudioArtifactStore()
            let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
            let old = try artifact(directory, "old-\(round).wav", purpose: .reading(.speak))
            let new = try artifact(directory, "new-\(round).wav", purpose: .reading(.speak))
            try await store.promote(old, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
            let lease = try await store.acquireExportLease()
            try await store.promote(new, generation: SessionGeneration(rawValue: 2), purpose: .reading(.speak), evidence: evidence)
            _ = await store.beginShutdown()
            XCTAssertTrue(FileManager.default.fileExists(atPath: lease.artifact.url.path), "round=\(round)")
            await store.release(lease)
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path), "round=\(round)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: new.url.path), "round=\(round)")
            let committed = await store.commitShutdownIfDrained()
            XCTAssertTrue(committed, "round=\(round)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path), "round=\(round)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: new.url.path), "round=\(round)")
        }
    }

    func testTwentyBlockedExportsReplaceAndShutdownKeepSourceUntilAtomicExportCompletes() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let store = LastAudioArtifactStore()
            let old = try artifact(directory, "source-\(round).wav", purpose: .reading(.speak))
            let new = try artifact(directory, "new-\(round).wav", purpose: .reading(.speak))
            try await store.promote(old, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence())
            let destination = directory.url.appendingPathComponent("export-\(round).wav")
            let files = BlockingAudioExportFiles()
            let export = Task { try await AudioExporter.saveAudio(from: store, to: destination, files: files) }
            await files.waitUntilCopyEntered()
            try await store.promote(new, generation: SessionGeneration(rawValue: 2), purpose: .reading(.speak), evidence: evidence())
            let drain = await store.beginShutdown()
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path), "round=\(round)")
            files.releaseCopy()
            _ = try await export.value
            await drain.wait()
            let committed = await store.commitShutdownIfDrained()
            XCTAssertTrue(committed, "round=\(round)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path), "round=\(round)")
            XCTAssertNoThrow(try WAVValidator.validate(destination, purpose: .reading(.speak)))
        }
    }

    func testTwentyCancellationWinsBeforePromotionHaveZeroStalePromotions() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let store = LastAudioArtifactStore()
            let audio = try artifact(directory, "cancel-\(round).wav", purpose: .reading(.speak))
            let evidence = evidence()
            let gate = LastAudioGate()
            let coordinator = SpeechCoordinator()
            let start = Task {
                await coordinator.start(.reading(text: "x", origin: .speak, providerID: .minimax)) { token in
                    await gate.enterAndWait()
                    try await store.promote(
                        audio, generation: token.generation, purpose: .reading(.speak),
                        evidence: evidence, token: token
                    )
                }
            }
            await gate.waitUntilEntered()
            _ = coordinator.requestStop(reason: .userStopped)
            await gate.release()
            _ = await start.value
            await coordinator.stop()
            let retained = await store.currentArtifact()
            XCTAssertNil(retained, "round=\(round)")
        }
    }

    func testTwentyPromotionWinsBeforeCancellationRemainRetained() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let store = LastAudioArtifactStore()
            let audio = try artifact(directory, "promote-\(round).wav", purpose: .reading(.speak))
            let evidence = evidence()
            let promoted = LastAudioSignal()
            let hold = LastAudioGate()
            let coordinator = SpeechCoordinator()
            let start = Task {
                await coordinator.start(.reading(text: "x", origin: .speak, providerID: .minimax)) { token in
                    try await store.promote(
                        audio, generation: token.generation, purpose: .reading(.speak),
                        evidence: evidence, token: token
                    )
                    await promoted.fire()
                    await hold.enterAndWait()
                }
            }
            await promoted.wait()
            let stop = Task { await coordinator.stop() }
            await hold.release()
            await stop.value
            _ = await start.value
            let retained = await store.currentArtifact()?.url
            XCTAssertEqual(retained, audio.url, "round=\(round)")
        }
    }

    func testTwentyReleaseVersusTimeoutRacesPreserveExactCurrentArtifact() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let store = LastAudioArtifactStore()
            let old = try artifact(directory, "race-old-\(round).wav", purpose: .reading(.speak))
            let current = try artifact(directory, "race-current-\(round).wav", purpose: .reading(.speak))
            try await store.promote(old, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence())
            let lease = try await store.acquireExportLease()
            try await store.promote(current, generation: SessionGeneration(rawValue: 2), purpose: .reading(.speak), evidence: evidence())
            _ = await store.beginShutdown()

            async let release: Void = store.release(lease)
            async let timeout: Void = store.cancelShutdownPreservingAudio()
            _ = await (release, timeout)

            let retained = await store.currentArtifact()?.url
            XCTAssertEqual(retained, current.url, "round=\(round)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: current.url.path), "round=\(round)")
        }
    }

    func testRejectedPreviewPromotionLeavesRegisteredCleanupArmed() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let artifact = try artifact(directory, "preview-rejected.wav", purpose: .preview)
        try await assertRejectedPromotionCleansExactlyOnce(
            store: store, artifact: artifact, purpose: .preview
        )
    }

    func testInvalidArtifactPromotionLeavesRegisteredCleanupArmed() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let artifact = try artifact(directory, "invalid-rejected.wav", purpose: .reading(.speak))
        try Data("not wav".utf8).write(to: artifact.url)
        try await assertRejectedPromotionCleansExactlyOnce(
            store: store, artifact: artifact, purpose: .reading(.speak)
        )
    }

    func testShutdownRejectedPromotionLeavesRegisteredCleanupArmed() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let artifact = try artifact(directory, "shutdown-rejected.wav", purpose: .reading(.speak))
        _ = await store.beginShutdown()
        try await assertRejectedPromotionCleansExactlyOnce(
            store: store, artifact: artifact, purpose: .reading(.speak)
        )
    }

    @MainActor
    func testTerminationCoordinatorCoalescesRequestsAndRepliesProceedOnceOnMainThread() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let audio = try artifact(directory, "termination-proceed.wav", purpose: .reading(.speak))
        try await store.promote(audio, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence())
        let replies = AppTerminationReplySpy()
        let shutdowns = LastAudioCounter()
        let coordinator = AppTerminationCoordinator(
            store: store,
            timeout: .seconds(5),
            sleep: { duration in try? await Task.sleep(for: duration) },
            shutdownSpeech: { await shutdowns.increment() }
        )

        XCTAssertEqual(coordinator.requestTermination { replies.record($0) }, .terminateLater)
        XCTAssertEqual(coordinator.requestTermination { replies.record($0) }, .terminateLater)
        await replies.waitForReply()

        XCTAssertEqual(replies.values, [true])
        XCTAssertEqual(replies.mainThreadValues, [true])
        let shutdownCount = await shutdowns.value
        let retained = await store.currentArtifact()
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertNil(retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
    }

    @MainActor
    func testTerminationCoordinatorTimeoutRepliesCancelOnceAndPreservesCurrent() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let audio = try artifact(directory, "termination-timeout.wav", purpose: .reading(.speak))
        try await store.promote(audio, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence())
        let lease = try await store.acquireExportLease()
        let replies = AppTerminationReplySpy()
        let sleeps = TerminationSleepScript()
        let coordinator = AppTerminationCoordinator(
            store: store,
            timeout: .seconds(5),
            sleep: { duration in await sleeps.sleep(duration) },
            shutdownSpeech: {}
        )

        XCTAssertEqual(coordinator.requestTermination { replies.record($0) }, .terminateLater)
        XCTAssertEqual(coordinator.requestTermination { replies.record($0) }, .terminateLater)
        await replies.waitForReply()

        XCTAssertEqual(replies.values, [false])
        XCTAssertEqual(replies.mainThreadValues, [true])
        let retained = await store.currentArtifact()?.url
        XCTAssertEqual(retained, audio.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
        await store.release(lease)

        XCTAssertEqual(coordinator.requestTermination { replies.record($0) }, .terminateLater)
        await replies.waitForReply(count: 2)
        XCTAssertEqual(replies.values, [false, true])
        XCTAssertEqual(replies.mainThreadValues, [true, true])
        let retainedAfterSecondAttempt = await store.currentArtifact()
        XCTAssertNil(retainedAfterSecondAttempt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
    }

    private func artifact(_ directory: TemporaryDirectory, _ name: String, purpose: SpeechPurpose) throws -> AudioArtifact {
        let url = directory.url.appendingPathComponent(name)
        try WAVTestFixture.wav(samples: 480).write(to: url)
        return try WAVValidator.validate(url, purpose: purpose)
    }

    private func evidence() -> PlaybackEvidence {
        PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
    }

    private func assertRejectedPromotionCleansExactlyOnce(
        store: LastAudioArtifactStore,
        artifact: AudioArtifact,
        purpose: SpeechPurpose
    ) async throws {
        let cleanup = LastAudioCleanupCounter()
        let failed = LastAudioSignal()
        let coordinator = SpeechCoordinator()
        let playbackEvidence = evidence()
        let session = await coordinator.start(
            .reading(text: "rejected", origin: .speak, providerID: .minimax),
            work: { token in
                let cleanupID = try token.registerUnpublishedCleanup { cleanup.increment() }
                try await store.promote(
                    artifact, generation: token.generation, purpose: purpose,
                    evidence: playbackEvidence, token: token, disarmingCleanup: cleanupID
                )
            },
            onFailure: { _, _ in await failed.fire() }
        )
        XCTAssertNotNil(session)
        await failed.wait()
        XCTAssertEqual(cleanup.value, 1)
        let retained = await store.currentArtifact()
        XCTAssertNil(retained)
        await coordinator.stop()
    }
}

private final class BlockingAudioExportFiles: @unchecked Sendable, AudioExportFileOperations {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func copy(from source: URL, to temporary: URL) throws {
        lock.withLock {
            entered = true
            continuation?.resume()
            continuation = nil
        }
        release.wait()
        try FileManager.default.copyItem(at: source, to: temporary)
    }
    func atomicReplace(temporary: URL, destination: URL) throws {
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    func waitUntilCopyEntered() async {
        if lock.withLock({ entered }) { return }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if entered { return true }
                self.continuation = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func releaseCopy() { release.signal() }
}

private actor LastAudioGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor LastAudioSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func fire() {
        fired = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class LastAudioCleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor LastAudioCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor TerminationSleepScript {
    private var calls = 0
    func sleep(_ duration: Duration) async {
        calls += 1
        if calls == 1 { return }
        try? await Task.sleep(for: duration)
    }
}

@MainActor
private final class AppTerminationReplySpy {
    private(set) var values: [Bool] = []
    private(set) var mainThreadValues: [Bool] = []
    func record(_ value: Bool) {
        values.append(value)
        mainThreadValues.append(Thread.isMainThread)
    }
    func waitForReply(count: Int = 1) async {
        for _ in 0..<200 where values.count < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

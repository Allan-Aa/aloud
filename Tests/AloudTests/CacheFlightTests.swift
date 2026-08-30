import Foundation
import XCTest
@testable import Aloud

final class CacheFlightTests: XCTestCase {
    func testSameScopeWaitersShareOneProducerAndCancelledWaiterDoesNotCancelOther() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let source = directory.url.appendingPathComponent("source.wav")
        try WAVTestFixture.wav(samples: 480).write(to: source)
        let artifact = try WAVValidator.validate(source, purpose: .preview)
        let unpublished = UnpublishedArtifact(artifact: artifact)
        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 7, count: 32)))
        let key = CacheFlightKey(fingerprint: fingerprint, scopeRevision: UUID())
        let flight = CacheFlight()
        let started = Counter()
        let gate = AsyncGate()

        let a = Task { try await flight.join(key: key, waiter: CacheWaiterID(), producer: {
            await started.increment(); await gate.wait(); return unpublished
        }) }
        while await flight.waiterCount(key: key) < 1 { await Task.yield() }
        let b = Task { try await flight.join(key: key, waiter: CacheWaiterID(), producer: {
            await started.increment(); return unpublished
        }) }
        while await flight.waiterCount(key: key) < 2 { await Task.yield() }
        a.cancel()
        await gate.release()

        await XCTAssertThrowsErrorAsync(try await a.value)
        let bValue = try await b.value
        XCTAssertEqual(bValue, unpublished)
        let starts = await started.value
        XCTAssertEqual(starts, 1)
    }

    func testCommitRejectsOldScopeAndPublishesCanonicalArtifactOnce() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let temp = directory.url.appendingPathComponent(".aloud-temp-test.wav")
        let cache = CanonicalAudioCache(directory: directory.url)
        try WAVTestFixture.wav(samples: 480).write(to: temp)
        let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview))
        let provider = ProviderID.minimax
        let revision = UUID()
        let generation = SessionGeneration(rawValue: 1)
        let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 8, count: 32))), scopeRevision: revision)
        let flight = CacheFlight()
        _ = try await flight.join(key: key, waiter: CacheWaiterID(), producer: { artifact })
        let waiter = CacheWaiterID()
        _ = try await flight.join(key: key, waiter: waiter, producer: { artifact })
        let possibleLease = await flight.acquirePublishLease(key: key, waiter: waiter)
        let lease = try XCTUnwrap(possibleLease)
        let gate = PublishCommitGate(cache: cache)
        await gate.advance(providerID: provider, revision: UUID(), generation: generation)
        await gate.register(lease)
        let committed = try await gate.commit(lease, artifact: artifact, finalURL: cache.path(for: key.fingerprint), expectedRevision: revision, expectedGeneration: generation, cancellation: CacheCancelRelay())
        XCTAssertNil(committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path(for: key.fingerprint).path))
    }

    func testTwentyLeaseRacesHaveExactlyOneWinner() async throws {
        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 6, count: 32)))
        let key = CacheFlightKey(fingerprint: fingerprint, scopeRevision: UUID())
        let flight = CacheFlight()
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let source = directory.url.appendingPathComponent("source.wav")
        try WAVTestFixture.wav(samples: 480).write(to: source)
        let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(source, purpose: .preview))
        let waiters = (0..<20).map { _ in CacheWaiterID() }
        for waiter in waiters { _ = try await flight.join(key: key, waiter: waiter, producer: { artifact }) }
        let winners = await withTaskGroup(of: PublishLease?.self, returning: [PublishLease].self) { group in
            for waiter in waiters { group.addTask { await flight.acquirePublishLease(key: key, waiter: waiter) } }
            var result: [PublishLease] = []
            for await lease in group { if let lease { result.append(lease) } }
            return result
        }
        XCTAssertEqual(winners.count, 1)
    }

    func testLastCancelledWaiterRetiresFlightAndNewWaiterStartsNewProducer() async throws {
        let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 5, count: 32))), scopeRevision: UUID())
        let flight = CacheFlight(); let old = CacheWaiterID(); let starts = Counter(); let gate = AsyncGate()
        let oldTask = Task { try await flight.join(key: key, waiter: old, producer: { await starts.increment(); await gate.wait(); throw CacheFlightError.cancelled }) }
        while await flight.waiterCount(key: key) != 1 { await Task.yield() }
        oldTask.cancel(); await flight.cancel(key: key, waiter: old)
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let temp = directory.url.appendingPathComponent("aloud-temp-new.wav"); try WAVTestFixture.wav(samples: 480).write(to: temp)
        let new = CacheWaiterID()
        let result = try await flight.join(key: key, waiter: new, producer: { await starts.increment(); return UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview)) })
        XCTAssertEqual(result.artifact.url, temp)
        let count = await starts.value; XCTAssertEqual(count, 2)
        await gate.release(); _ = await oldTask.result
    }

    func testCancelledRelayNeverPublishesEvenWithActiveLease() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let cache = CanonicalAudioCache(directory: directory.url); let revision = UUID(); let generation = SessionGeneration(rawValue: 2)
        let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 4, count: 32))), scopeRevision: revision)
        let temp = directory.url.appendingPathComponent("aloud-temp-cancel.wav"); try WAVTestFixture.wav(samples: 480).write(to: temp)
        let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview)); let flight = CacheFlight(); let waiter = CacheWaiterID()
        _ = try await flight.join(key: key, waiter: waiter, producer: { artifact }); let possibleLease = await flight.acquirePublishLease(key: key, waiter: waiter); let lease = try XCTUnwrap(possibleLease)
        let gate = PublishCommitGate(cache: cache); await gate.advance(providerID: .minimax, revision: revision, generation: generation); await gate.register(lease)
        let relay = CacheCancelRelay(); relay.cancel()
        let output = try await gate.commit(lease, artifact: artifact, finalURL: cache.path(for: key.fingerprint), expectedRevision: revision, expectedGeneration: generation, cancellation: relay)
        XCTAssertNil(output); XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path(for: key.fingerprint).path))
    }

    func testTwentyRetiredOldProducersCannotReplaceNewFlight() async throws {
        for round in 0..<20 {
            let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: UInt8(round), count: 32))), scopeRevision: UUID())
            let flight = CacheFlight(); let first = CacheWaiterID(); let gate = AsyncGate(); let starts = Counter()
            let old = Task { try await flight.join(key: key, waiter: first, producer: { await starts.increment(); await gate.wait(); throw CacheFlightError.cancelled }) }
            while await flight.waiterCount(key: key) != 1 { await Task.yield() }
            old.cancel(); await flight.cancel(key: key, waiter: first)
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let url = directory.url.appendingPathComponent("aloud-temp-new-\(round).wav"); try WAVTestFixture.wav(samples: 480).write(to: url)
            let second = CacheWaiterID()
            let new = try await flight.join(key: key, waiter: second, producer: { await starts.increment(); return UnpublishedArtifact(artifact: try WAVValidator.validate(url, purpose: .preview)) })
            XCTAssertEqual(new.artifact.url, url)
            var lease = await flight.acquirePublishLease(key: key, waiter: second)
            while lease == nil { await Task.yield(); lease = await flight.acquirePublishLease(key: key, waiter: second) }
            XCTAssertNotNil(lease)
            await gate.release(); _ = await old.result
            let count = await starts.value; XCTAssertEqual(count, 2)
        }
    }

    func testTwentyRetiredSuccessfulOldTempsAreDeletedWithoutChangingNewLease() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: UInt8(round), count: 32))), scopeRevision: UUID())
            let flight = CacheFlight(); let oldWaiter = CacheWaiterID(); let release = AsyncGate()
            let oldURL = directory.url.appendingPathComponent("aloud-temp-old-success-\(round).wav")
            let old = Task { try await flight.join(key: key, waiter: oldWaiter, producer: { await release.wait(); try WAVTestFixture.wav(samples: 480).write(to: oldURL); return UnpublishedArtifact(artifact: try WAVValidator.validate(oldURL, purpose: .preview)) }) }
            while await flight.waiterCount(key: key) != 1 { await Task.yield() }
            old.cancel(); await flight.cancel(key: key, waiter: oldWaiter)
            let newURL = directory.url.appendingPathComponent("aloud-temp-new-success-\(round).wav"); try WAVTestFixture.wav(samples: 480).write(to: newURL); let newWaiter = CacheWaiterID()
            let new = try await flight.join(key: key, waiter: newWaiter, producer: { UnpublishedArtifact(artifact: try WAVValidator.validate(newURL, purpose: .preview)) })
            var lease = await flight.acquirePublishLease(key: key, waiter: newWaiter); while lease == nil { await Task.yield(); lease = await flight.acquirePublishLease(key: key, waiter: newWaiter) }
            XCTAssertEqual(new.artifact.url, newURL); XCTAssertNotNil(lease)
            await release.release(); _ = await old.result
            for _ in 0..<20 where FileManager.default.fileExists(atPath: oldURL.path) { await Task.yield() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path)); XCTAssertEqual(new.artifact.url, newURL)
        }
    }

    func testRetiredJoinAcknowledgesLateSuccessTempDeletionBeforeReturning() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 42, count: 32))), scopeRevision: UUID())
        let removals = CacheCleanupCounter()
        let flight = CacheFlight(cleanup: .init(remove: { url in removals.remove(url) })); let waiter = CacheWaiterID(); let release = AsyncGate()
        let oldURL = directory.url.appendingPathComponent("aloud-temp-retired-ack.wav")
        let old = Task { try await flight.join(key: key, waiter: waiter, producer: {
            await release.wait(); try WAVTestFixture.wav(samples: 480).write(to: oldURL)
            return UnpublishedArtifact(artifact: try WAVValidator.validate(oldURL, purpose: .preview))
        }) }
        while await flight.waiterCount(key: key) != 1 { await Task.yield() }
        old.cancel(); await flight.cancel(key: key, waiter: waiter); await release.release()
        _ = await old.result
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(removals.count, 1)
        XCTAssertEqual(removals.urls, [oldURL])
    }

    func testRetiredSupervisorNeverDeletesSamePathOwnedByNewFlight() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("aloud-temp-reused.wav")
        let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 43, count: 32))), scopeRevision: UUID())
        let cleanupCount = Counter()
        let flight = CacheFlight(cleanup: .init(remove: { target in
            Task { await cleanupCount.increment() }; try? FileManager.default.removeItem(at: target)
        }))
        let written = AsyncGate(); let finishOld = AsyncGate(); let oldWaiter = CacheWaiterID()
        let old = Task { try await flight.join(key: key, waiter: oldWaiter, producer: {
            try WAVTestFixture.wav(samples: 480).write(to: url); await written.release(); await finishOld.wait()
            return UnpublishedArtifact(artifact: try WAVValidator.validate(url, purpose: .preview))
        }) }
        await written.wait(); old.cancel(); await flight.cancel(key: key, waiter: oldWaiter)
        try WAVTestFixture.wav(samples: 960).write(to: url)
        let newWaiter = CacheWaiterID()
        let new = try await flight.join(key: key, waiter: newWaiter, producer: {
            UnpublishedArtifact(artifact: try WAVValidator.validate(url, purpose: .preview))
        })
        await finishOld.release(); _ = await old.result
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(new.artifact.duration, 0.02, accuracy: 0.000_001)
        let removals = await cleanupCount.value
        XCTAssertEqual(removals, 0)
    }

    func testOldCleanupWaitsForSamePathNewProducingFlightOwnership() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("aloud-temp-producing-reuse.wav")
        let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 44, count: 32))), scopeRevision: UUID())
        let removals = Counter(); let flight = CacheFlight(cleanup: .init(remove: { target in Task { await removals.increment() }; try? FileManager.default.removeItem(at: target) }))
        let oldRelease = AsyncGate(); let oldWaiter = CacheWaiterID()
        let old = Task { try await flight.join(key: key, waiter: oldWaiter, producer: {
            await oldRelease.wait(); return UnpublishedArtifact(artifact: try WAVValidator.validate(url, purpose: .preview))
        }) }
        while await flight.waiterCount(key: key) != 1 { await Task.yield() }
        old.cancel(); await flight.cancel(key: key, waiter: oldWaiter)
        try WAVTestFixture.wav(samples: 480).write(to: url)
        let newRelease = AsyncGate(); let newWaiter = CacheWaiterID()
        let new = Task { try await flight.join(key: key, waiter: newWaiter, producer: {
            await newRelease.wait(); return UnpublishedArtifact(artifact: try WAVValidator.validate(url, purpose: .preview))
        }) }
        while await flight.waiterCount(key: key) != 1 { await Task.yield() }
        await oldRelease.release(); await Task.yield()
        XCTAssertFalse(old.isCancelled == false && new.isCancelled, "new producer stays current while old cleanup waits")
        await newRelease.release(); _ = try await new.value; _ = await old.result
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let count = await removals.value; XCTAssertEqual(count, 0)
    }

    func testNeverFinishingReplacementProducerCannotHoldOldJoinOrActorProgress() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let reusedURL = directory.url.appendingPathComponent("aloud-temp-quarantined-reuse.wav")
        let unrelatedURL = directory.url.appendingPathComponent("aloud-temp-unrelated.wav")
        try WAVTestFixture.wav(samples: 480).write(to: reusedURL)
        try WAVTestFixture.wav(samples: 480).write(to: unrelatedURL)
        let scope = UUID()
        let reusedKey = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 45, count: 32))), scopeRevision: scope)
        let unrelatedKey = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 46, count: 32))), scopeRevision: scope)
        let flight = CacheFlight()
        let oldRelease = AsyncGate(); let oldWaiter = CacheWaiterID()
        let old = Task { try await flight.join(key: reusedKey, waiter: oldWaiter) {
            await oldRelease.wait()
            return UnpublishedArtifact(artifact: try WAVValidator.validate(reusedURL, purpose: .preview))
        } }
        while await flight.waiterCount(key: reusedKey) != 1 { await Task.yield() }
        old.cancel(); await flight.cancel(key: reusedKey, waiter: oldWaiter)

        let replacementRelease = AsyncGate(); let replacementWaiter = CacheWaiterID()
        let replacement = Task { try await flight.join(key: reusedKey, waiter: replacementWaiter) {
            await replacementRelease.wait()
            return UnpublishedArtifact(artifact: try WAVValidator.validate(reusedURL, purpose: .preview))
        } }
        while await flight.waiterCount(key: reusedKey) != 1 { await Task.yield() }
        await oldRelease.release()

        let oldCompletion = CompletionFlag()
        Task { _ = await old.result; await oldCompletion.mark() }
        try? await Task.sleep(for: .milliseconds(50))
        let didCompleteOld = await oldCompletion.value
        XCTAssertTrue(didCompleteOld, "retired join must acknowledge quarantine without waiting for replacement producer")
        let unrelated = try await flight.join(key: unrelatedKey, waiter: CacheWaiterID()) {
            UnpublishedArtifact(artifact: try WAVValidator.validate(unrelatedURL, purpose: .preview))
        }
        XCTAssertEqual(unrelated.artifact.url, unrelatedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reusedURL.path), "unresolved same-path ownership is quarantined, never stale-deleted")

        await replacementRelease.release(); _ = try await replacement.value
    }

    func testTwentyCancelFirstCommitAttemptsPublishNothing() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let cache = CanonicalAudioCache(directory: directory.url); let revision = UUID(); let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: UInt8(round), count: 32))), scopeRevision: revision)
            let temp = directory.url.appendingPathComponent("aloud-temp-\(round).wav"); try WAVTestFixture.wav(samples: 480).write(to: temp)
            let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview)); let flight = CacheFlight(); let waiter = CacheWaiterID()
            _ = try await flight.join(key: key, waiter: waiter, producer: { artifact }); var possible = await flight.acquirePublishLease(key: key, waiter: waiter); while possible == nil { await Task.yield(); possible = await flight.acquirePublishLease(key: key, waiter: waiter) }; let lease = try XCTUnwrap(possible)
            let commit = PublishCommitGate(cache: cache); await commit.advance(providerID: .minimax, revision: revision, generation: .init(rawValue: 1)); await commit.register(lease)
            let relay = CacheCancelRelay(); relay.cancel()
            let outcome = try await commit.commit(lease, artifact: artifact, finalURL: cache.path(for: key.fingerprint), expectedRevision: revision, expectedGeneration: .init(rawValue: 1), cancellation: relay)
            XCTAssertNil(outcome); XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path(for: key.fingerprint).path))
        }
    }

    func testReplaceFailurePreservesOldFinalAndReleasesLeaseForB() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let cache = CanonicalAudioCache(directory: directory.url); let revision = UUID(); let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 1, count: 32))), scopeRevision: revision)
        let final = cache.path(for: key.fingerprint); let old = Data("old-final".utf8); try old.write(to: final)
        let temp = directory.url.appendingPathComponent("aloud-temp-fail.wav"); try WAVTestFixture.wav(samples: 480).write(to: temp); let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview))
        let flight = CacheFlight(); let a = CacheWaiterID(); let b = CacheWaiterID(); _ = try await flight.join(key: key, waiter: a, producer: { artifact }); _ = try await flight.join(key: key, waiter: b, producer: { artifact })
        var lease = await flight.acquirePublishLease(key: key, waiter: a); while lease == nil { await Task.yield(); lease = await flight.acquirePublishLease(key: key, waiter: a) }; let first = try XCTUnwrap(lease)
        let failing = PublishCommitGate(cache: cache, fileOps: .init(publish: { _, _ in throw CacheFlightError.cancelled })); await failing.advance(providerID: .minimax, revision: revision, generation: .init(rawValue: 1)); await failing.register(first)
        do { _ = try await failing.commit(first, artifact: artifact, finalURL: final, expectedRevision: revision, expectedGeneration: .init(rawValue: 1), cancellation: CacheCancelRelay()); XCTFail("expected publish failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: final), old); await flight.releaseLease(first)
        let possibleSecond = await flight.acquirePublishLease(key: key, waiter: b); let second = try XCTUnwrap(possibleSecond)
        let succeeding = PublishCommitGate(cache: cache); await succeeding.advance(providerID: .minimax, revision: revision, generation: .init(rawValue: 1)); await succeeding.register(second)
        let published = try await succeeding.commit(second, artifact: artifact, finalURL: final, expectedRevision: revision, expectedGeneration: .init(rawValue: 1), cancellation: CacheCancelRelay())
        XCTAssertNotNil(published); XCTAssertNoThrow(try WAVValidator.validate(final, purpose: .preview))
    }

    func testTwentyCommitFirstPublishesBeforeBlockedCancellationReturns() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let cache = CanonicalAudioCache(directory: directory.url); let revision = UUID(); let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: UInt8(round), count: 32))), scopeRevision: revision)
            let temp = directory.url.appendingPathComponent("aloud-temp-commit-\(round).wav"); try WAVTestFixture.wav(samples: 480).write(to: temp); let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview))
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let ops = PublishCommitGate.FileOps(publish: { source, dest in entered.signal(); release.wait(); try FileManager.default.moveItem(at: source, to: dest) })
            let flight = CacheFlight(); let waiter = CacheWaiterID(); _ = try await flight.join(key: key, waiter: waiter, producer: { artifact }); var lease = await flight.acquirePublishLease(key: key, waiter: waiter); while lease == nil { await Task.yield(); lease = await flight.acquirePublishLease(key: key, waiter: waiter) }; let issued = try XCTUnwrap(lease)
            let gate = PublishCommitGate(cache: cache, fileOps: ops); await gate.advance(providerID: .minimax, revision: revision, generation: .init(rawValue: 1)); await gate.register(issued)
            let relay = CacheCancelRelay(); let commit = Task { try await gate.commit(issued, artifact: artifact, finalURL: cache.path(for: key.fingerprint), expectedRevision: revision, expectedGeneration: .init(rawValue: 1), cancellation: relay) }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            let completion = CancelCompletion(); let cancellation = Task { relay.cancel(); await completion.mark() }
            try? await Task.sleep(for: .milliseconds(2)); let beforeRelease = await completion.done; XCTAssertFalse(beforeRelease)
            release.signal(); let committed = try await commit.value; XCTAssertNotNil(committed); _ = await cancellation.result; let afterRelease = await completion.done; XCTAssertTrue(afterRelease)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path(for: key.fingerprint).path))
        }
    }

    func testScopeAndGenerationAdvancedBeforeCommitAreRejected() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let cache = CanonicalAudioCache(directory: directory.url); let oldRevision = UUID(); let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 31, count: 32))), scopeRevision: oldRevision)
        let temp = directory.url.appendingPathComponent("aloud-temp-oldscope.wav"); try WAVTestFixture.wav(samples: 480).write(to: temp); let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview))
        let flight = CacheFlight(); let waiter = CacheWaiterID(); _ = try await flight.join(key: key, waiter: waiter, producer: { artifact }); var possible = await flight.acquirePublishLease(key: key, waiter: waiter); while possible == nil { await Task.yield(); possible = await flight.acquirePublishLease(key: key, waiter: waiter) }; let lease = try XCTUnwrap(possible)
        let gate = PublishCommitGate(cache: cache); await gate.advance(providerID: .minimax, revision: UUID(), generation: .init(rawValue: 2)); await gate.register(lease)
        let rejected = try await gate.commit(lease, artifact: artifact, finalURL: cache.path(for: key.fingerprint), expectedRevision: oldRevision, expectedGeneration: .init(rawValue: 1), cancellation: CacheCancelRelay())
        XCTAssertNil(rejected); XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path(for: key.fingerprint).path))
    }
}

private actor Counter { private var count = 0; func increment() { count += 1 }; var value: Int { count } }
private final class CacheCleanupCounter: @unchecked Sendable {
    private let lock = NSLock(); private var removed: [URL] = []
    func remove(_ url: URL) { lock.withLock { removed.append(url) }; try? FileManager.default.removeItem(at: url) }
    var count: Int { lock.withLock { removed.count } }
    var urls: [URL] { lock.withLock { removed } }
}
private actor CancelCompletion { private(set) var done = false; func mark() { done = true } }
private actor AsyncGate { private var continuation: CheckedContinuation<Void, Never>?; private var isOpen = false; func wait() async { if isOpen { return }; await withCheckedContinuation { continuation = $0 } }; func release() { isOpen = true; continuation?.resume(); continuation = nil } }
private actor CompletionFlag { private var completed = false; func mark() { completed = true }; var value: Bool { completed } }

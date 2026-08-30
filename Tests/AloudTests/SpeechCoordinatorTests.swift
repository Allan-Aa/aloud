import XCTest
@testable import Aloud

final class SpeechCoordinatorTests: XCTestCase {
    func testStartCapturesExactlyOneEnvelopeAndAdvancesSameRevisionBeforeWork() async throws {
        let coordinator = SpeechCoordinator()
        let gate = AsyncGate()
        let capture = EnvelopeCaptureSpy()
        let advances = CacheAdvanceSpy()
        let revision = UUID()
        let envelope = CredentialEnvelope(providerID: .minimax, revision: revision, secret: Data([1, 2, 3]))

        let session = await coordinator.start(
            .reading(text: "fixture", origin: .speak, providerID: .minimax),
            captureEnvelope: { providerID in try await capture.capture(providerID, envelope: envelope) },
            advanceCacheScope: { providerID, revision, generation in await advances.record(providerID, revision, generation) },
            work: { token in
                XCTAssertEqual(token.envelope, envelope)
                await gate.enterAndWait()
                try await token.requireCurrent()
            }
        )
        XCTAssertNotNil(session)
        await gate.waitUntilEntered()
        let captureCount = await capture.count
        let advanceValues = await advances.values
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(advanceValues.count, 1)
        XCTAssertEqual(advanceValues.first?.0, .minimax)
        XCTAssertEqual(advanceValues.first?.1, revision)
        XCTAssertEqual(advanceValues.first?.2, session?.generation)

        let stopping = Task { await coordinator.stop() }
        await Task.yield()
        await gate.release()
        await stopping.value
    }

    func testStopSelectionDefaultCredentialShutdownAndReplacementLeaveZeroStaleEffects() async throws {
        for event in ScopeEvent.allCases {
            let coordinator = SpeechCoordinator()
            let gate = AsyncGate()
            let player = StopSpy()
            let effects = await MainActor.run { EffectBox() }
            let cleanup = LockedCounter()

            _ = await coordinator.start(
                .reading(text: "old", origin: .speak, providerID: .minimax),
                stopPlayer: { _ in await player.stop() },
                work: { token in
                    _ = try token.registerUnpublishedCleanup { cleanup.increment() }
                    await gate.enterAndWait()
                    for effect in EffectKind.allCases {
                        try await token.performCurrent { effects.record(effect) }
                    }
                }
            )
            await gate.waitUntilEntered()

            let cancellation = Task {
                switch event {
                case .replacement:
                    _ = await coordinator.start(
                        .preview(providerID: .minimax, phraseID: "fixed"),
                        stopPlayer: { _ in await player.stop() },
                        work: { _ in }
                    )
                case .stop:
                    await coordinator.stop(stopPlayer: { _ in await player.stop() })
                case .selection:
                    await coordinator.selectionDidChange(providerID: .minimax, stopPlayer: { _ in await player.stop() })
                case .defaultProvider:
                    await coordinator.defaultProviderDidChange(stopPlayer: { _ in await player.stop() })
                case .credential:
                    await coordinator.credentialWillChange(providerID: .minimax, stopPlayer: { _ in await player.stop() })
                case .shutdown:
                    await coordinator.shutdown(stopPlayer: { _ in await player.stop() })
                }
            }
            await player.waitUntilStopped(2)
            XCTAssertEqual(cleanup.value, 1, "event=\(event)")
            await gate.release()
            await cancellation.value
            let total = await MainActor.run { effects.total }
            XCTAssertEqual(total, 0, "event=\(event)")
        }
    }

    func testCancellationAtEveryAsyncBoundaryBlocksTheNextNamedSideEffect() async throws {
        for target in EffectKind.allCases {
            let coordinator = SpeechCoordinator()
            let boundary = NamedBoundary(target: target)
            let player = StopSpy()
            let effects = await MainActor.run { EffectBox() }
            _ = await coordinator.start(
                .reading(text: "fixture", origin: .speak, providerID: .minimax),
                stopPlayer: { _ in await player.stop() },
                work: { token in
                    for effect in EffectKind.allCases {
                        await boundary.pauseIfTarget(effect)
                        try await token.requireCurrent()
                        try await token.performCurrent { effects.record(effect) }
                    }
                }
            )
            await boundary.waitUntilPaused()
            let stopping = Task { await coordinator.stop(stopPlayer: { _ in await player.stop() }) }
            await player.waitUntilStopped(2)
            await boundary.resume()
            await stopping.value
            let values = await MainActor.run { effects.values }
            XCTAssertFalse(values.contains(target), "target=\(target)")
            XCTAssertEqual(values.filter { $0.rawValue >= target.rawValue }.count, 0)
        }
    }

    func testUnrelatedCredentialChangeDoesNotCancelCurrentProvider() async throws {
        let coordinator = SpeechCoordinator()
        let gate = AsyncGate()
        let effects = await MainActor.run { EffectBox() }
        let session = await coordinator.start(
            .reading(text: "fixture", origin: .speak, providerID: .minimax),
            work: { token in
                await gate.enterAndWait()
                try await token.performCurrent { effects.record(.play) }
            }
        )
        await gate.waitUntilEntered()
        await coordinator.credentialWillChange(providerID: .openAI)
        let unwrapped = try XCTUnwrap(session)
        let isCurrent = await coordinator.isCurrent(unwrapped)
        XCTAssertTrue(isCurrent)
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        let total = await MainActor.run { effects.total }
        XCTAssertEqual(total, 1)
        await coordinator.stop()
    }

    func testCredentialChangeForDrainingOldProviderDoesNotCancelNewProvider() async throws {
        let coordinator = SpeechCoordinator()
        let oldGate = AsyncGate()
        let newGate = AsyncGate()
        let effects = await MainActor.run { EffectBox() }
        _ = await coordinator.start(
            .reading(text: "old", origin: .speak, providerID: .minimax),
            work: { token in
                await oldGate.enterAndWait()
                try await token.performCurrent { effects.record(.cachePublish) }
            }
        )
        await oldGate.waitUntilEntered()
        let newSession = await coordinator.start(
            .reading(text: "new", origin: .speak, providerID: .openAI),
            work: { token in
                await newGate.enterAndWait()
                try await token.performCurrent { effects.record(.play) }
            }
        )
        await newGate.waitUntilEntered()
        let changingOld = Task { await coordinator.credentialWillChange(providerID: .minimax) }
        await Task.yield()
        let unwrapped = try XCTUnwrap(newSession)
        let currentBeforeDrain = await coordinator.isCurrent(unwrapped)
        XCTAssertTrue(currentBeforeDrain)
        await oldGate.release()
        await changingOld.value
        let currentAfterDrain = await coordinator.isCurrent(unwrapped)
        XCTAssertTrue(currentAfterDrain)
        await newGate.release()
        for _ in 0..<50 { await Task.yield() }
        let values = await MainActor.run { effects.values }
        XCTAssertEqual(values, [.play])
        await coordinator.stop()
    }

    func testTwentyReplacementRacesProduceOnlyNewestEffects() async throws {
        for round in 0..<20 {
            let coordinator = SpeechCoordinator()
            let gate = AsyncGate()
            let player = StopSpy()
            let effects = await MainActor.run { EffectBox() }
            _ = await coordinator.start(
                .reading(text: "old", origin: .speak, providerID: .minimax),
                stopPlayer: { _ in await player.stop() },
                work: { token in
                    await gate.enterAndWait()
                    try await token.performCurrent { effects.record(.cachePublish) }
                }
            )
            await gate.waitUntilEntered()
            let replacement = Task {
                await coordinator.start(
                    .reading(text: "new", origin: .speak, providerID: .minimax),
                    stopPlayer: { _ in await player.stop() },
                    work: { token in try await token.performCurrent { effects.record(.play) } }
                )
            }
            await player.waitUntilStopped(2)
            await gate.release()
            _ = await replacement.value
            for _ in 0..<100 {
                if await MainActor.run(body: { effects.total }) == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let values = await MainActor.run { effects.values }
            XCTAssertEqual(values, [.play], "round=\(round)")
        }
    }

    func testSynchronousSubmittedStopInvalidatesQueuedStartBeforeWorkCanRun() async {
        let coordinator = SpeechCoordinator()
        let effects = await MainActor.run { EffectBox() }
        coordinator.submit(
            SpeechCommand.reading(text: "queued", origin: .speak, providerID: .minimax),
            work: { token in try await token.performCurrent { effects.record(.play) } }
        )
        coordinator.requestStop(reason: .userStopped)
        for _ in 0..<50 { await Task.yield() }
        let total = await MainActor.run { effects.total }
        XCTAssertEqual(total, 0)
    }

    func testSubmitRegistersPendingBeforeStartGateSoStopDrainsIt() async {
        let launchGate = AsyncGate()
        let coordinator = SpeechCoordinator(pendingStartGate: { await launchGate.enterAndWait() })
        let stopReturned = AsyncSignal()
        let effects = await MainActor.run { EffectBox() }

        coordinator.submit(
            SpeechCommand.reading(text: "queued", origin: .speak, providerID: .minimax),
            work: { token in try await token.performCurrent { effects.record(.play) } }
        )
        await launchGate.waitUntilEntered()
        let stopping = Task {
            await coordinator.stop()
            await stopReturned.signal()
        }
        let stoppedBeforeRelease = await stopReturned.becomesTrue(withinMilliseconds: 20)
        XCTAssertFalse(stoppedBeforeRelease)
        await launchGate.release()
        await stopping.value

        let effectCount = await MainActor.run { effects.total }
        XCTAssertEqual(effectCount, 0)
        XCTAssertEqual(coordinator.pendingLedgerCount(), 0)
    }

    func testSubmitInputRegistersPendingBeforeStartGateSoShutdownDrainsIt() async {
        let launchGate = AsyncGate()
        let coordinator = SpeechCoordinator(pendingStartGate: { await launchGate.enterAndWait() })
        let shutdownReturned = AsyncSignal()
        let preparations = LockedCounter()

        coordinator.submitInput(providerID: ProviderID.minimax, prepare: { _ -> SpeechCoordinator.PreparedSubmission? in
            preparations.increment()
            return nil
        })
        await launchGate.waitUntilEntered()
        let shutdown = Task {
            await coordinator.shutdown()
            await shutdownReturned.signal()
        }
        let shutdownBeforeRelease = await shutdownReturned.becomesTrue(withinMilliseconds: 20)
        XCTAssertFalse(shutdownBeforeRelease)
        await launchGate.release()
        await shutdown.value

        XCTAssertEqual(preparations.value, 0)
        XCTAssertEqual(coordinator.pendingLedgerCount(), 0)
    }

    func testAsyncStartRegistersPendingBeforeStartGateSoCredentialChangeDrainsIt() async {
        let launchGate = AsyncGate()
        let coordinator = SpeechCoordinator(pendingStartGate: { await launchGate.enterAndWait() })
        let credentialReturned = AsyncSignal()
        let captures = LockedCounter()

        let starting = Task {
            await coordinator.start(
                SpeechCommand.reading(text: "queued", origin: .speak, providerID: .minimax),
                captureEnvelope: { _ -> CredentialEnvelope? in captures.increment(); return nil },
                work: { _ in XCTFail("cancelled start reached work") }
            )
        }
        await launchGate.waitUntilEntered()
        let changingCredential = Task {
            await coordinator.credentialWillChange(providerID: ProviderID.minimax)
            await credentialReturned.signal()
        }
        let credentialBeforeRelease = await credentialReturned.becomesTrue(withinMilliseconds: 20)
        XCTAssertFalse(credentialBeforeRelease)
        await launchGate.release()
        await changingCredential.value

        let session = await starting.value
        XCTAssertNil(session)
        XCTAssertEqual(captures.value, 0)
        XCTAssertEqual(coordinator.pendingLedgerCount(), 0)
    }

    func testCompletedPendingCannotInstallLateOrLeakLedger() async {
        let coordinator = SpeechCoordinator()
        let completed = AsyncSignal()
        coordinator.submit(
            .reading(text: "fast", origin: .speak, providerID: .minimax),
            work: { _ in await completed.signal() }
        )
        await completed.wait()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(coordinator.pendingLedgerCount(), 0)
        await coordinator.stop()
    }

    func testTwentySubmitWinsThenStopDrainsRegisteredOperationWithoutEffectOrLedgerLeak() async {
        for round in 0..<20 {
            let launchGate = AsyncGate()
            let coordinator = SpeechCoordinator(pendingStartGate: { await launchGate.enterAndWait() })
            let effects = await MainActor.run { EffectBox() }
            let stopBoundary = StopSpy()
            coordinator.submit(
                SpeechCommand.reading(text: "round-\(round)", origin: .speak, providerID: .minimax),
                work: { token in try await token.performCurrent { effects.record(.play) } }
            )
            await launchGate.waitUntilEntered()

            // requestStop issues the invalidating ticket synchronously before
            // returning. Waiting for the stop-player boundary proves the
            // submitted Stop has begun processing while the old operation is
            // still held behind the cancellation-ignoring launch gate.
            _ = coordinator.requestStop(
                reason: .userStopped,
                stopPlayer: { _ in await stopBoundary.stop() }
            )
            await stopBoundary.waitUntilStopped()
            await launchGate.release()
            for _ in 0..<100 {
                if coordinator.pendingLedgerCount() == 0 { break }
                await Task.yield()
            }
            await coordinator.stop()
            let effectCount = await MainActor.run { effects.total }
            XCTAssertEqual(effectCount, 0, "round=\(round)")
            XCTAssertEqual(coordinator.pendingLedgerCount(), 0, "round=\(round)")
        }
    }

    func testTwentyStopWinsThenNewSubmissionRunsAsNewerUserCommandWithoutLedgerLeak() async {
        for round in 0..<20 {
            let coordinator = SpeechCoordinator()
            let effects = await MainActor.run { EffectBox() }
            let completed = AsyncSignal()

            // requestStop issues its invalidating ticket synchronously. The
            // following submission is therefore a genuinely newer user action.
            coordinator.requestStop(reason: .userStopped)
            coordinator.submit(
                SpeechCommand.reading(text: "round-\(round)", origin: .speak, providerID: .minimax),
                work: { token in
                    try await token.performCurrent { effects.record(.play) }
                    await completed.signal()
                }
            )

            await completed.wait()
            for _ in 0..<20 {
                if coordinator.pendingLedgerCount() == 0 { break }
                await Task.yield()
            }
            let values = await MainActor.run { effects.values }
            XCTAssertEqual(values, [.play], "round=\(round)")
            XCTAssertEqual(coordinator.pendingLedgerCount(), 0, "round=\(round)")
            await coordinator.stop()
        }
    }

    func testSynchronousReplacementSubmissionInvalidatesActiveTokenBeforeActorHop() async throws {
        let coordinator = SpeechCoordinator()
        let gate = AsyncGate()
        let effects = await MainActor.run { EffectBox() }
        _ = await coordinator.start(
            .reading(text: "old", origin: .speak, providerID: .minimax),
            work: { token in
                await gate.enterAndWait()
                try await token.performCurrent { effects.record(.cachePublish) }
            }
        )
        await gate.waitUntilEntered()
        coordinator.submit(
            .reading(text: "new", origin: .speak, providerID: .minimax),
            work: { token in try await token.performCurrent { effects.record(.play) } }
        )
        await gate.release()
        for _ in 0..<100 {
            if await MainActor.run(body: { effects.total }) == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let values = await MainActor.run { effects.values }
        XCTAssertEqual(values, [.play])
        await coordinator.stop()
    }

    func testCredentialChangeCancelsAndDrainsPendingEnvelopeCaptureBeforeReturning() async {
        let coordinator = SpeechCoordinator()
        let capture = CancellableCaptureGate()
        let effects = await MainActor.run { EffectBox() }
        coordinator.submit(
            .reading(text: "queued", origin: .speak, providerID: .minimax),
            captureEnvelope: { _ in try await capture.capture() },
            work: { token in try await token.performCurrent { effects.record(.play) } }
        )
        await capture.waitUntilEntered()
        let changing = Task { await coordinator.credentialWillChange(providerID: .minimax) }
        await capture.waitUntilCancelled()
        await changing.value
        let didReturn = await capture.didReturn
        XCTAssertTrue(didReturn)
        let total = await MainActor.run { effects.total }
        XCTAssertEqual(total, 0)
    }

    func testUnpublishedCleanupRunsExactlyOnceOnFailureAndDisarmedArtifactSurvivesSuccess() async {
        enum FixtureFailure: Error { case failed }
        let coordinator = SpeechCoordinator()
        let failedCleanup = LockedCounter()
        let failedDone = AsyncSignal()
        _ = await coordinator.start(
            .reading(text: "failure", origin: .speak, providerID: .minimax),
            work: { token in
                _ = try token.registerUnpublishedCleanup { failedCleanup.increment() }
                throw FixtureFailure.failed
            },
            onFailure: { _, _ in await failedDone.signal() }
        )
        await failedDone.wait()
        XCTAssertEqual(failedCleanup.value, 1)

        let disarmedCleanup = LockedCounter()
        let successDone = AsyncSignal()
        _ = await coordinator.start(
            .reading(text: "success", origin: .speak, providerID: .minimax),
            work: { token in
                let id = try token.registerUnpublishedCleanup { disarmedCleanup.increment() }
                try token.disarmUnpublishedCleanup(id)
                await successDone.signal()
            }
        )
        await successDone.wait()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(disarmedCleanup.value, 0)
        await coordinator.stop()
    }

    func testOwnedArtifactTransferAndCleanupDisarmShareOneStopLinearizationPoint() async throws {
        let coordinator = SpeechCoordinator()
        let cleanup = LockedCounter()
        let transferred = AsyncSignal()
        let holdTransferredOwner = AsyncGate()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "aloud-transfer-stop-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("canonical.wav")
        try WAVTestFixture.wav(samples: 480).write(to: url)
        let audio = try WAVValidator.validate(url, purpose: .preview)

        _ = await coordinator.start(
            .preview(providerID: .minimax, phraseID: "owned-transfer"),
            work: { token in
                let owned = OwnedAudioArtifact(artifact: audio, cleanup: {
                    cleanup.increment()
                    try? FileManager.default.removeItem(at: url)
                })
                let id = try token.registerUnpublishedCleanup { owned.cleanupIfOwned() }
                defer { owned.cleanupIfOwned() }
                let unpublished = try token.transferUnpublishedArtifact(owned, cleanupID: id)
                await transferred.signal()
                await holdTransferredOwner.enterAndWait()
                try? FileManager.default.removeItem(at: unpublished.artifact.url)
            }
        )
        await transferred.wait()
        let stopping = Task { await coordinator.stop() }
        await holdTransferredOwner.release()
        await stopping.value

        XCTAssertEqual(cleanup.value, 0, "session cleanup must already be disarmed after ownership transfer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the explicit next owner must clean the transferred artifact")
    }

    func testCredentialChangeDrainsRetiredPendingProviderWithoutCancellingCurrentOtherProvider() async throws {
        let coordinator = SpeechCoordinator()
        let retiredCapture = CancellationIgnoringCaptureGate()
        let currentGate = AsyncGate()
        let effects = await MainActor.run { EffectBox() }
        let credentialReturned = AsyncSignal()

        coordinator.submit(
            .reading(text: "retired", origin: .speak, providerID: .minimax),
            captureEnvelope: { _ in try await retiredCapture.capture() },
            work: { token in try await token.performCurrent { effects.record(.cachePublish) } }
        )
        await retiredCapture.waitUntilEntered()
        coordinator.submit(
            .reading(text: "current", origin: .speak, providerID: .openAI),
            work: { token in
                await currentGate.enterAndWait()
                try await token.performCurrent { effects.record(.play) }
            }
        )
        await currentGate.waitUntilEntered()

        let changing = Task {
            await coordinator.credentialWillChange(providerID: .minimax)
            await credentialReturned.signal()
        }
        let returnedBeforeRelease = await credentialReturned.becomesTrue(withinMilliseconds: 20)
        XCTAssertFalse(returnedBeforeRelease)
        await retiredCapture.release()
        await changing.value
        let returnedAfterRelease = await credentialReturned.value
        XCTAssertTrue(returnedAfterRelease)

        await currentGate.release()
        for _ in 0..<100 where await MainActor.run(body: { effects.total }) == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let currentValues = await MainActor.run { effects.values }
        XCTAssertEqual(currentValues, [.play])
        await coordinator.stop()
    }

    func testCredentialChangeDrainsPendingAsyncStartCaptureBeforeReturning() async {
        let coordinator = SpeechCoordinator()
        let capture = CancellationIgnoringCaptureGate()
        let effects = await MainActor.run { EffectBox() }
        let credentialReturned = AsyncSignal()
        let starting = Task {
            await coordinator.start(
                .reading(text: "pending", origin: .speak, providerID: .minimax),
                captureEnvelope: { _ in try await capture.capture() },
                work: { token in try await token.performCurrent { effects.record(.play) } }
            )
        }
        await capture.waitUntilEntered()
        let changing = Task {
            await coordinator.credentialWillChange(providerID: .minimax)
            await credentialReturned.signal()
        }
        let returnedBeforeRelease = await credentialReturned.becomesTrue(withinMilliseconds: 20)
        XCTAssertFalse(returnedBeforeRelease)
        await capture.release()
        _ = await starting.value
        await changing.value
        let total = await MainActor.run { effects.total }
        XCTAssertEqual(total, 0)
    }

    func testStalePreparedStartCannotReplaceCurrentSameProviderCacheAdvancer() async throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let cache = CanonicalAudioCache(directory: directory.url)
        let cacheCoordinator = CanonicalChunkCacheCoordinator(cache: cache)
        let coordinator = SpeechCoordinator()
        let latePreparation = CancellationIgnoringPreparationGate()
        let oldAdvances = CacheAdvanceSpy()
        let currentAdvances = CacheAdvanceSpy()
        let currentWork = AsyncGate()
        let leaseIssued = AsyncSignal()
        let outcome = CacheCommitOutcome()

        coordinator.submit(
            .reading(text: "late", origin: .speak, providerID: .minimax, credentiallessScopeRevision: UUID()),
            captureEnvelope: { _ in
                await latePreparation.enterAndWait()
                return nil
            },
            advanceCacheScope: { providerID, revision, generation in
                await oldAdvances.record(providerID, revision, generation)
            },
            work: { _ in }
        )
        await latePreparation.waitUntilEntered()
        let currentRevision = UUID()
        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 79, count: 32)))
        let key = CacheFlightKey(providerID: .minimax, fingerprint: fingerprint, scopeRevision: currentRevision)
        _ = await coordinator.start(
            .reading(text: "current", origin: .speak, providerID: .minimax, credentiallessScopeRevision: currentRevision),
            advanceCacheScope: { providerID, revision, generation in
                await currentAdvances.record(providerID, revision, generation)
                await cacheCoordinator.advance(providerID: providerID, revision: revision, generation: generation)
            },
            work: { token in
                let temp = directory.url.appendingPathComponent("aloud-temp-current-advancer.wav")
                try WAVTestFixture.wav(samples: 480).write(to: temp)
                let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .reading(.speak)))
                let waiter = CacheWaiterID()
                _ = try await cacheCoordinator.flight.join(key: key, waiter: waiter, producer: { artifact })
                guard let lease = await cacheCoordinator.flight.acquirePublishLease(key: key, waiter: waiter) else {
                    throw CacheFlightError.noReadyArtifact
                }
                await cacheCoordinator.gate.register(lease)
                await leaseIssued.signal()
                await currentWork.enterAndWait()
                let committed = try await cacheCoordinator.gate.commit(
                    lease,
                    artifact: artifact,
                    finalURL: cache.path(for: fingerprint),
                    expectedRevision: currentRevision,
                    expectedGeneration: token.generation,
                    cancellation: CacheCancelRelay()
                )
                await outcome.set(committed != nil)
            }
        )
        await leaseIssued.wait()
        await latePreparation.release()
        for _ in 0..<20 { await Task.yield() }

        let stopping = Task { await coordinator.stop() }
        for _ in 0..<100 {
            if await currentAdvances.values.count == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let oldCount = await oldAdvances.snapshotCount()
        let currentCount = await currentAdvances.snapshotCount()
        XCTAssertEqual(oldCount, 0)
        XCTAssertEqual(currentCount, 2)
        await currentWork.release()
        await stopping.value
        let published = await outcome.snapshot()
        XCTAssertEqual(published, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path(for: fingerprint).path))
    }

    func testSubmitPathKeepsCacheScopeRegistrationsIndependentAcrossProviders() async throws {
        let coordinator = SpeechCoordinator()
        let miniAdvances = CacheAdvanceSpy()
        let openAIAdvances = CacheAdvanceSpy()
        let miniWork = AsyncGate()
        let openAIWork = AsyncGate()

        coordinator.submit(
            .reading(text: "mini", origin: .speak, providerID: .minimax, credentiallessScopeRevision: UUID()),
            advanceCacheScope: { providerID, revision, generation in
                await miniAdvances.record(providerID, revision, generation)
            },
            work: { _ in await miniWork.enterAndWait() }
        )
        await miniWork.waitUntilEntered()
        coordinator.submit(
            .reading(text: "openai", origin: .speak, providerID: .openAI, credentiallessScopeRevision: UUID()),
            advanceCacheScope: { providerID, revision, generation in
                await openAIAdvances.record(providerID, revision, generation)
            },
            work: { token in
                await openAIWork.enterAndWait()
                try await token.requireCurrent()
            }
        )
        await openAIWork.waitUntilEntered()
        let changingMini = Task { await coordinator.credentialWillChange(providerID: .minimax) }
        for _ in 0..<100 {
            if await miniAdvances.snapshotCount() == 3 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let miniCount = await miniAdvances.snapshotCount()
        let openAICount = await openAIAdvances.snapshotCount()
        XCTAssertEqual(miniCount, 3)
        XCTAssertEqual(openAICount, 1)
        await miniWork.release()
        await changingMini.value
        await openAIWork.release()
        await coordinator.stop()
    }

    func testCurrentEffectMaySynchronouslyStopWithoutDeadlockAndLaterOldEffectsAreRejected() async throws {
        let coordinator = SpeechCoordinator()
        let finished = AsyncSignal()
        let effects = await MainActor.run { EffectBox() }

        _ = await coordinator.start(
            .reading(text: "fixture", origin: .speak, providerID: .minimax),
            work: { token in
                try await token.performCurrent {
                    effects.record(.phase)
                    coordinator.requestStop(reason: .userStopped)
                    effects.record(.toast)
                }
                do {
                    try await token.performCurrent { effects.record(.health) }
                    XCTFail("stale effect was accepted")
                } catch is CancellationError {
                    await finished.signal()
                }
            }
        )
        await finished.wait()
        let values = await MainActor.run { effects.values }
        XCTAssertEqual(values, [.phase, .toast])
    }

    func testCurrentEffectMaySynchronouslySubmitReplacementWithoutDeadlock() async throws {
        let coordinator = SpeechCoordinator()
        let oldFinished = AsyncSignal()
        let replacementFinished = AsyncSignal()
        let effects = await MainActor.run { EffectBox() }

        _ = await coordinator.start(
            .reading(text: "old", origin: .speak, providerID: .minimax),
            work: { token in
                try await token.performCurrent {
                    effects.record(.phase)
                    coordinator.submit(
                        .reading(text: "new", origin: .speak, providerID: .minimax),
                        work: { replacementToken in
                            try await replacementToken.performCurrent { effects.record(.play) }
                            await replacementFinished.signal()
                        }
                    )
                    effects.record(.toast)
                }
                do {
                    try await token.performCurrent { effects.record(.health) }
                    XCTFail("stale effect was accepted")
                } catch is CancellationError {
                    await oldFinished.signal()
                }
            }
        )
        await oldFinished.wait()
        await replacementFinished.wait()
        let values = await MainActor.run { effects.values }
        XCTAssertEqual(values, [.phase, .toast, .play])
        await coordinator.stop()
    }

    func testStopAndCredentialInvalidationAdvanceActualPublishGateBeforeOldCommit() async throws {
        for action in CacheInvalidationAction.allCases {
            let directory = try TemporaryDirectory()
            defer { try? directory.remove() }
            let cache = CanonicalAudioCache(directory: directory.url)
            let cacheCoordinator = CanonicalChunkCacheCoordinator(cache: cache)
            let coordinator = SpeechCoordinator()
            let revision = UUID()
            let advances = CacheAdvanceSpy()
            let commitBarrier = AsyncGate()
            let leaseIssued = AsyncSignal()
            let outcome = CacheCommitOutcome()
            let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: action.byte, count: 32)))
            let key = CacheFlightKey(providerID: .minimax, fingerprint: fingerprint, scopeRevision: revision)

            let session = await coordinator.start(
                .reading(text: "fixture", origin: .speak, providerID: .minimax, credentiallessScopeRevision: revision),
                advanceCacheScope: { providerID, revision, generation in
                    await cacheCoordinator.advance(providerID: providerID, revision: revision, generation: generation)
                    await advances.record(providerID, revision, generation)
                },
                work: { token in
                    let temp = directory.url.appendingPathComponent("aloud-temp-old-\(action.rawValue).wav")
                    try WAVTestFixture.wav(samples: 480).write(to: temp)
                    let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .reading(.speak)))
                    let waiter = CacheWaiterID()
                    _ = try await cacheCoordinator.flight.join(key: key, waiter: waiter, producer: { artifact })
                    guard let lease = await cacheCoordinator.flight.acquirePublishLease(key: key, waiter: waiter) else {
                        throw CacheFlightError.noReadyArtifact
                    }
                    await cacheCoordinator.gate.register(lease)
                    await leaseIssued.signal()
                    await commitBarrier.enterAndWait()
                    let committed = try await cacheCoordinator.gate.commit(
                        lease,
                        artifact: artifact,
                        finalURL: cache.path(for: fingerprint),
                        expectedRevision: revision,
                        expectedGeneration: token.generation,
                        cancellation: CacheCancelRelay()
                    )
                    await outcome.set(committed != nil)
                }
            )
            XCTAssertNotNil(session)
            await leaseIssued.wait()

            let invalidating = Task {
                switch action {
                case .stop: await coordinator.stop()
                case .selection: await coordinator.selectionDidChange(providerID: .minimax)
                case .defaultProvider: await coordinator.defaultProviderDidChange()
                case .credential: await coordinator.credentialWillChange(providerID: .minimax)
                case .shutdown: await coordinator.shutdown()
                }
            }
            for _ in 0..<100 {
                if await advances.values.count == 2 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let advanceCount = await advances.values.count
            XCTAssertEqual(advanceCount, 2, "action=\(action)")
            await commitBarrier.release()
            await invalidating.value
            let published = await outcome.published
            XCTAssertEqual(published, false, "action=\(action)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path(for: fingerprint).path))
        }
    }

    @MainActor
    func testEnginePendingHookThenStopNeverStartsSpeech() async throws {
        let syntheses = LockedCounter()
        let engine = try makeTask14Engine(
            installCredentialHook: false,
            synthesize: { _, _, _, _ in syntheses.increment() }
        )
        engine.text = "must stay cancelled"
        engine.speak()
        engine.stop()
        await engine.installCredentialCancellationHook()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(syntheses.value, 0)
        XCTAssertTrue(engine.history.isEmpty)
    }

    @MainActor
    func testEnginePendingSelectionThenStopOrNewSpeakCannotResurrectOldText() async throws {
        for replacement in [false, true] {
            let selection = SelectionReadGate(text: "old selection")
            let syntheses = TextSynthesisSpy()
            let engine = try makeTask14Engine(
                readSelection: { try await selection.read() },
                synthesize: { text, _, _, _ in await syntheses.record(text) }
            )
            await engine.installCredentialCancellationHook()
            engine.readSelection()
            await selection.waitUntilEntered()
            if replacement {
                engine.text = "new request"
                engine.speak()
            } else {
                engine.stop()
            }
            await selection.release()
            for _ in 0..<100 { try await Task.sleep(for: .milliseconds(1)) }
            let values = await syntheses.values
            XCTAssertEqual(values, replacement ? ["new request"] : [])
            XCTAssertFalse(engine.history.contains { $0.text == "old selection" })
        }
    }

    @MainActor
    func testEngineShutdownDrainsCancellationIgnoringSelectionPreparation() async throws {
        let selection = SelectionReadGate(text: "late selection")
        let shutdownReturned = AsyncSignal()
        let engine = try makeTask14Engine(
            readSelection: { try await selection.read() },
            synthesize: { _, _, _, _ in XCTFail("late selection synthesized") }
        )
        await engine.installCredentialCancellationHook()
        engine.readSelection()
        await selection.waitUntilEntered()
        let shutdown = Task { @MainActor in
            await engine.shutdownSpeech()
            await shutdownReturned.signal()
        }
        let returnedBeforeRelease = await shutdownReturned.becomesTrue(withinMilliseconds: 20)
        XCTAssertFalse(returnedBeforeRelease)
        await selection.release()
        await shutdown.value
        XCTAssertTrue(engine.history.isEmpty)
    }

    func testCoordinatorStopDrainsCancellationIgnoringInputPreparation() async {
        let coordinator = SpeechCoordinator()
        let preparation = CancellationIgnoringPreparationGate()
        let stopReturned = AsyncSignal()
        let effects = await MainActor.run { EffectBox() }
        coordinator.submitInput(providerID: .minimax, prepare: { _ in
            await preparation.enterAndWait()
            return SpeechCoordinator.PreparedSubmission(
                command: .reading(text: "late", origin: .speak, providerID: .minimax),
                work: { token in try await token.performCurrent { effects.record(.play) } }
            )
        })
        await preparation.waitUntilEntered()
        let stopping = Task {
            await coordinator.stop()
            await stopReturned.signal()
        }
        let returnedBeforeRelease = await stopReturned.becomesTrue(withinMilliseconds: 20)
        XCTAssertFalse(returnedBeforeRelease)
        await preparation.release()
        await stopping.value
        let total = await MainActor.run { effects.total }
        XCTAssertEqual(total, 0)
    }

    func testFakePipelineUsesActualCanonicalCacheAndDownstreamFailuresNeverResynthesize() async throws {
        for scenario in PipelineScenario.allCases {
            let directory = try TemporaryDirectory()
            defer { try? directory.remove() }
            let cache = CanonicalAudioCache(directory: directory.url)
            let cacheCoordinator = CanonicalChunkCacheCoordinator(cache: cache)
            let coordinator = SpeechCoordinator()
            let effects = PipelineEffectSpy()
            let completed = AsyncSignal()
            let state = ProviderResponseState()
            let revision = UUID()
            let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: scenario.byte, count: 32)))
            let key = CacheFlightKey(providerID: .minimax, fingerprint: fingerprint, scopeRevision: revision)
            _ = await coordinator.start(
                .reading(text: "fixture", origin: .speak, providerID: .minimax, credentiallessScopeRevision: revision),
                advanceCacheScope: { providerID, revision, generation in
                    await cacheCoordinator.advance(providerID: providerID, revision: revision, generation: generation)
                },
                work: { token in
                    _ = try await coordinator.synthesizeWithRetry(
                        token: token,
                        contract: RetryContract(idempotency: .guaranteed, retryableHTTPStatuses: [500], maximumAttempts: 3, backoffMilliseconds: [0, 0]),
                        attempt: { attempt in
                            effects.record(.provider(attempt))
                            return .success("native")
                        }
                    )
                    await state.markSucceeded()
                    try await token.requireCurrent()
                    try await token.performCurrent { effects.record(.canonical) }
                    let artifact = try await cacheCoordinator.resolve(
                        key: key,
                        generation: token.generation,
                        purpose: .reading(.speak),
                        produce: {
                            if scenario == .canonicalFailure { throw PipelineFixtureError.canonical }
                            let temp = directory.url.appendingPathComponent("aloud-temp-\(scenario.rawValue).wav")
                            try WAVTestFixture.wav(samples: 480).write(to: temp)
                            return UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .reading(.speak)))
                        }
                    )
                    XCTAssertTrue(artifact.isCanonical)
                    try await token.performCurrent { effects.record(.cache) }
                    try await token.performCurrent { effects.record(.decode) }
                    if scenario == .decodeFailure { throw PipelineFixtureError.decode }
                    try await token.performCurrent { effects.record(.play) }
                    if scenario == .playFailure { throw PipelineFixtureError.play }
                    try await token.performCurrent { effects.record(.append) }
                    try await token.performCurrent { effects.record(.history) }
                    try await token.performCurrent { effects.record(.health) }
                    await completed.signal()
                },
                onFailure: { token, _ in
                    guard await state.succeeded else { return }
                    _ = try? await token.performCurrent { effects.record(.health) }
                    await completed.signal()
                }
            )
            await completed.wait()
            let values = effects.values
            XCTAssertEqual(values.filter { if case .provider = $0 { return true }; return false }.count, 1, "scenario=\(scenario)")
            XCTAssertEqual(values.filter { $0 == .history }.count, scenario == .success ? 1 : 0, "scenario=\(scenario)")
            XCTAssertEqual(values.filter { $0 == .health }.count, 1, "scenario=\(scenario)")
            if scenario == .success {
                XCTAssertEqual(values, [.provider(1), .canonical, .cache, .decode, .play, .append, .history, .health])
            }
        }
    }

    func testActualCanonicalPipelineCancellationAtEverySinkLeavesNoLaterStaleEffects() async throws {
        for target in RealPipelineSink.allCases {
            let directory = try TemporaryDirectory()
            defer { try? directory.remove() }
            let cache = CanonicalAudioCache(directory: directory.url)
            let cacheCoordinator = CanonicalChunkCacheCoordinator(cache: cache)
            let coordinator = SpeechCoordinator()
            let revision = UUID()
            let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: target.byte, count: 32)))
            let key = CacheFlightKey(providerID: .minimax, fingerprint: fingerprint, scopeRevision: revision)
            let boundary = RealPipelineBoundary(target: target)
            let effects = RealPipelineEffectSpy()

            _ = await coordinator.start(
                .reading(text: "fixture", origin: .speak, providerID: .minimax, credentiallessScopeRevision: revision),
                advanceCacheScope: { providerID, revision, generation in
                    await cacheCoordinator.advance(providerID: providerID, revision: revision, generation: generation)
                },
                work: { token in
                    await boundary.pauseIfTarget(.canonical)
                    try await token.performCurrent { effects.record(.canonical) }
                    let artifact = try await cacheCoordinator.resolve(
                        key: key,
                        generation: token.generation,
                        purpose: .reading(.speak),
                        produce: {
                            let temp = directory.url.appendingPathComponent("aloud-temp-boundary-\(target.rawValue).wav")
                            try WAVTestFixture.wav(samples: 480).write(to: temp)
                            return UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .reading(.speak)))
                        }
                    )
                    await boundary.pauseIfTarget(.cache)
                    try await token.performCurrent { effects.record(.cache) }
                    XCTAssertTrue(artifact.isCanonical)
                    for sink in [RealPipelineSink.decode, .play, .append, .history, .health] {
                        await boundary.pauseIfTarget(sink)
                        try await token.performCurrent { effects.record(sink) }
                    }
                }
            )
            await boundary.waitUntilPaused()
            let stopping = Task { await coordinator.stop() }
            await boundary.release()
            await stopping.value
            let values = effects.values
            XCTAssertFalse(values.contains(target), "target=\(target)")
            XCTAssertEqual(values.filter { $0.order >= target.order }.count, 0, "target=\(target)")
        }
    }
}

private enum ScopeEvent: CaseIterable { case replacement, stop, selection, defaultProvider, credential, shutdown }
private enum EffectKind: Int, CaseIterable, Sendable { case cachePublish, play, append, history, phase, toast, health }
private enum CacheInvalidationAction: String, CaseIterable {
    case stop, selection, defaultProvider, credential, shutdown
    var byte: UInt8 {
        switch self { case .stop: 41; case .selection: 42; case .defaultProvider: 43; case .credential: 44; case .shutdown: 45 }
    }
}
private enum PipelineScenario: String, CaseIterable {
    case canonicalFailure, decodeFailure, playFailure, success
    var byte: UInt8 {
        switch self { case .canonicalFailure: 51; case .decodeFailure: 52; case .playFailure: 53; case .success: 54 }
    }
}
private enum PipelineFixtureError: Error { case canonical, decode, play }
private enum PipelineEffect: Equatable, Sendable { case provider(Int), canonical, cache, decode, play, append, history, health }
private enum RealPipelineSink: String, CaseIterable, Sendable {
    case canonical, cache, decode, play, append, history, health
    var order: Int { Self.allCases.firstIndex(of: self)! }
    var byte: UInt8 { UInt8(61 + order) }
}

@MainActor
private final class EffectBox {
    private(set) var values: [EffectKind] = []
    var total: Int { values.count }
    func record(_ value: EffectKind) { values.append(value) }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private actor EnvelopeCaptureSpy {
    private(set) var count = 0
    func capture(_ providerID: ProviderID, envelope: CredentialEnvelope) throws -> CredentialEnvelope {
        count += 1
        XCTAssertEqual(providerID, envelope.providerID)
        return envelope
    }
}

private actor CacheAdvanceSpy {
    private(set) var values: [(ProviderID, UUID, SessionGeneration)] = []
    func record(_ providerID: ProviderID, _ revision: UUID, _ generation: SessionGeneration) { values.append((providerID, revision, generation)) }
    func snapshotCount() -> Int { values.count }
}

private actor StopSpy {
    private var count = 0
    private var waiter: (Int, CheckedContinuation<Void, Never>)?
    func stop() {
        count += 1
        if let waiter, count >= waiter.0 { waiter.1.resume(); self.waiter = nil }
    }
    func waitUntilStopped(_ expected: Int = 1) async {
        if count >= expected { return }
        await withCheckedContinuation { waiter = (expected, $0) }
    }
}

private actor AsyncGate {
    private var didEnter = false
    private var entered: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func enterAndWait() async {
        didEnter = true
        entered?.resume(); entered = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

private actor NamedBoundary {
    let target: EffectKind
    private var paused = false
    private var pausedWaiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    init(target: EffectKind) { self.target = target }
    func pauseIfTarget(_ effect: EffectKind) async {
        guard effect == target else { return }
        paused = true
        pausedWaiter?.resume(); pausedWaiter = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pausedWaiter = $0 }
    }
    func resume() { releaseContinuation?.resume(); releaseContinuation = nil }
}

private actor CancellableCaptureGate {
    private var entered = false
    private var cancelled = false
    private(set) var didReturn = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var cancelledWaiter: CheckedContinuation<Void, Never>?
    func capture() async throws -> CredentialEnvelope? {
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        do {
            while true { try await Task.sleep(for: .seconds(1)) }
        } catch is CancellationError {
            cancelled = true
            cancelledWaiter?.resume(); cancelledWaiter = nil
            didReturn = true
            throw CancellationError()
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancelledWaiter = $0 }
    }
}

private actor AsyncSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { signalled = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiter = $0 }
    }
    var value: Bool { signalled }
    nonisolated func becomesTrue(withinMilliseconds milliseconds: Int) async -> Bool {
        for _ in 0..<milliseconds {
            if await value { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await value
    }
}

private actor CancellationIgnoringCaptureGate {
    private let releaseGate = AsyncGate()
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    func capture() async throws -> CredentialEnvelope? {
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        await releaseGate.enterAndWait()
        return nil
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() async { await releaseGate.release() }
}

private actor CancellationIgnoringPreparationGate {
    private let gate = AsyncGate()
    func enterAndWait() async { await gate.enterAndWait() }
    func waitUntilEntered() async { await gate.waitUntilEntered() }
    func release() async { await gate.release() }
}

private actor CacheCommitOutcome {
    private(set) var published: Bool?
    func set(_ value: Bool) { published = value }
    func snapshot() -> Bool? { published }
}

private actor SelectionReadGate {
    let text: String
    private let gate = AsyncGate()
    init(text: String) { self.text = text }
    func read() async throws -> String { await gate.enterAndWait(); return text }
    func waitUntilEntered() async { await gate.waitUntilEntered() }
    func release() async { await gate.release() }
}

private actor TextSynthesisSpy {
    private(set) var values: [String] = []
    func record(_ text: String) { values.append(text) }
}

private final class PipelineEffectSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PipelineEffect] = []
    func record(_ effect: PipelineEffect) { lock.withLock { storage.append(effect) } }
    var values: [PipelineEffect] { lock.withLock { storage } }
}

private actor ProviderResponseState {
    private(set) var succeeded = false
    func markSucceeded() { succeeded = true }
}

private actor RealPipelineBoundary {
    let target: RealPipelineSink
    private var paused = false
    private var pausedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(target: RealPipelineSink) { self.target = target }
    func pauseIfTarget(_ sink: RealPipelineSink) async {
        guard sink == target else { return }
        paused = true
        pausedWaiter?.resume(); pausedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pausedWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private final class RealPipelineEffectSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RealPipelineSink] = []
    func record(_ sink: RealPipelineSink) { lock.withLock { storage.append(sink) } }
    var values: [RealPipelineSink] { lock.withLock { storage } }
}

@MainActor
private final class Task14Playback: EnginePlayback {
    var alive = false
    var paused = false
    var position = 0.0
    var duration = 0.0
    func play(file: URL, prefs: Prefs, streaming: Bool) throws { alive = true }
    func append(file: URL) throws {}
    func finishStream(prefs: Prefs) {}
    func stop() { alive = false }
    func togglePause() { paused.toggle() }
    func seek(relative: Double) {}
    func setSpeed(_ speed: Double) {}
}

@MainActor
private func makeTask14Engine(
    installCredentialHook: Bool = false,
    readSelection: @escaping @Sendable () async throws -> String = { "fixture" },
    synthesize: @escaping (String, String, Int, URL) async throws -> Void
) throws -> Engine {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-task14-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let operations = Store.Operations(dir: root, cacheDir: root, runtimeDir: root, read: { _ in nil }, write: { _, _ in })
    return Store.withOperations(operations) {
        Engine(
            player: Task14Playback(),
            speech: EngineSpeechDependencies(
                cachePath: { _, _, _ in root.appendingPathComponent("fixture.wav") },
                cacheHit: { _ in false },
                synthesize: synthesize,
                concat: { _, _, _ in },
                readSelection: readSelection
            ),
            credentialRegistry: CredentialScopeRegistry(),
            installCredentialHook: installCredentialHook
        )
    }
}

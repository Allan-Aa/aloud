import XCTest
@testable import Aloud

final class ProviderPreviewTests: XCTestCase {
    func testPreviewRunsThroughCoordinatorWithPreviewPurposeAndCurrentGeneration() async throws {
        let observed = PreviewSessionObservation()
        let transaction = ProviderPreviewTransaction(
            phraseCatalog: .builtIn,
            synthesize: { _, _ in
                OwnedNativeAudioArtifact(
                    artifact: NativeAudioArtifact(url: URL(fileURLWithPath: "/tmp/coordinated-preview.pcm"), format: .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview),
                    cleanup: {}
                )
            },
            startPlayback: { _ in },
            verifyPlayback: { PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()) }
        )
        let runner = ProviderPreviewCoordinator(coordinator: SpeechCoordinator(), transaction: transaction)
        let session = await runner.start(providerID: .openAI, phraseID: "zh-CN") { result in
            observed.finish(result)
        }
        XCTAssertEqual(session?.purpose, .preview)
        let result = try await observed.value()
        XCTAssertGreaterThan(result.secondTimePosition, result.firstTimePosition)
        XCTAssertEqual(observed.completionCount(), 1)
    }

    func testPreviewUsesFixedPhraseAndForbidsCacheHistoryLastAudio() async throws {
        let transaction = ProviderPreviewTransaction(
            phraseCatalog: .builtIn,
            synthesize: { text, policy in
                XCTAssertEqual(text, "这是语音试听。")
                XCTAssertEqual(policy, PreviewIsolationPolicy(cache: .bypass, history: .forbidden, lastAudio: .forbidden))
                return OwnedNativeAudioArtifact(artifact: NativeAudioArtifact(url: URL(fileURLWithPath: "/tmp/fake.pcm"), format: .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview), cleanup: {})
            },
            startPlayback: { _ in },
            verifyPlayback: { PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()) }
        )
        let evidence = try await transaction.runWithoutSessionForTesting(providerID: .openAI, phraseID: "zh-CN", editorText: "private editor", historyText: "private history")
        XCTAssertGreaterThan(evidence.secondTimePosition, evidence.firstTimePosition)
    }

    func testEveryInsufficientPlaybackPathFailsAndCleansTemp() async throws {
        let failures: [PreviewPlaybackFixture] = [.existingCache, .authPing, .durationOnly, .paused, .oneAdvance, .decodeError, .audioOutputError, .endFileError, .timeout]
        for failure in failures {
            let cleanup = PreviewCleanupCounter()
            let transaction = ProviderPreviewTransaction.fixture(failure: failure, cleanup: cleanup)
            await XCTAssertThrowsErrorAsync(try await transaction.runWithoutSessionForTesting(providerID: .minimax, phraseID: "zh-CN", editorText: "x", historyText: "y"))
            XCTAssertEqual(cleanup.value(), failure == .authPing ? 0 : 1, "\(failure)")
            XCTAssertEqual(cleanup.transportCount(), 1, "\(failure)")
        }
    }

    func testReplacementCancelsOldPreviewWithoutPublishingStaleCompletion() async throws {
        let barrier = PreviewBarrier()
        let oldCompletions = PreviewCompletionCounter()
        let newCompletions = PreviewCompletionCounter()
        let coordinator = SpeechCoordinator()
        let old = ProviderPreviewCoordinator(coordinator: coordinator, transaction: .fixture(barrier: barrier))
        let new = ProviderPreviewCoordinator(coordinator: coordinator, transaction: .successFixture())
        let oldStart = Task { await old.start(providerID: .openAI, phraseID: "zh-CN") { _ in oldCompletions.increment() } }
        await barrier.waitUntilEntered()
        _ = await new.start(providerID: .openAI, phraseID: "zh-CN") { _ in newCompletions.increment() }
        await barrier.release()
        _ = await oldStart.value
        for _ in 0..<100 where newCompletions.value() == 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(oldCompletions.value(), 0)
        XCTAssertEqual(newCompletions.value(), 1)
    }

    func testStopDefaultSelectionAndCredentialInvalidationPublishNoStaleCompletion() async throws {
        for invalidation in PreviewInvalidation.allCases {
            let barrier = PreviewBarrier()
            let completions = PreviewCompletionCounter()
            let coordinator = SpeechCoordinator()
            let runner = ProviderPreviewCoordinator(coordinator: coordinator, transaction: .fixture(barrier: barrier))
            let start = Task { await runner.start(providerID: .openAI, phraseID: "zh-CN") { _ in completions.increment() } }
            await barrier.waitUntilEntered()
            var invalidationTask: Task<Void, Never>?
            switch invalidation {
            case .stop: _ = coordinator.requestStop(reason: .userStopped)
            case .defaultProvider: invalidationTask = Task { await coordinator.defaultProviderDidChange() }
            case .selection: coordinator.requestSelectionChange(providerID: .openAI)
            case .credential: invalidationTask = Task { await coordinator.credentialWillChange(providerID: .openAI) }
            }
            await Task.yield()
            await barrier.release()
            await invalidationTask?.value
            _ = await start.value
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(completions.value(), 0, "\(invalidation)")
        }
    }

    func testCancellationIgnoringSynthesisCannotLaunchPlayerOrPublishPhase() async throws {
        let barrier = PreviewBarrier()
        let effects = PreviewPlayerEffects()
        let coordinator = SpeechCoordinator()
        let runner = ProviderPreviewCoordinator(
            coordinator: coordinator,
            transaction: ProviderPreviewTransaction(
                phraseCatalog: .builtIn,
                synthesize: { _, _ in
                    await barrier.enterAndWait()
                    return OwnedNativeAudioArtifact(
                        artifact: NativeAudioArtifact(url: URL(fileURLWithPath: "/tmp/ignored-cancel.pcm"), format: .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview),
                        cleanup: {}
                    )
                },
                startPlayback: { _ in effects.start() },
                verifyPlayback: { PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()) }
            ),
            stopAndDrainPlayer: { await effects.stopAndDrain() }
        )
        let start = Task { await runner.start(providerID: .openAI, phraseID: "zh-CN") { _ in effects.complete() } }
        await barrier.waitUntilEntered()
        let stopping = Task { await coordinator.stop() }
        await barrier.release()
        _ = await start.value
        await stopping.value
        XCTAssertEqual(effects.starts, 0)
        XCTAssertEqual(effects.completions, 0)
        XCTAssertEqual(effects.stops, 1)
    }

    func testPlaybackFailuresAndCancellationStopAndDrainPlayerExactlyOnce() async throws {
        for failure in [PreviewPlaybackFixture.decodeError, .audioOutputError, .endFileError, .timeout] {
            let effects = PreviewPlayerEffects()
            let coordinator = SpeechCoordinator()
            let runner = ProviderPreviewCoordinator(
                coordinator: coordinator,
                transaction: .fixture(failure: failure, cleanup: PreviewCleanupCounter(), effects: effects),
                stopAndDrainPlayer: { await effects.stopAndDrain() }
            )
            _ = await runner.start(providerID: .openAI, phraseID: "zh-CN") { _ in effects.complete() }
            for _ in 0..<100 where effects.completions == 0 { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertEqual(effects.starts, 1, "\(failure)")
            XCTAssertEqual(effects.stops, 1, "\(failure)")
        }
    }
}

private enum PreviewInvalidation: CaseIterable { case stop, defaultProvider, selection, credential }

private actor PreviewBarrier {
    private var entered: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enterAndWait() async { entered?.resume(); entered = nil; await withCheckedContinuation { releaseWaiter = $0 } }
    func waitUntilEntered() async { await withCheckedContinuation { entered = $0 } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private final class PreviewCompletionCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}

private final class PreviewSessionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<PlaybackEvidence, ProviderPreviewError>, Never>?
    private var stored: Result<PlaybackEvidence, ProviderPreviewError>?
    private var count = 0
    func finish(_ result: Result<PlaybackEvidence, ProviderPreviewError>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Result<PlaybackEvidence, ProviderPreviewError>, Never>? in
            count += 1
            stored = result
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume(returning: result)
    }
    func value() async throws -> PlaybackEvidence {
        let result: Result<PlaybackEvidence, ProviderPreviewError> = await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Result<PlaybackEvidence, ProviderPreviewError>? in
                if let stored { return stored }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
        return try result.get()
    }
    func completionCount() -> Int { lock.withLock { count } }
}

private enum PreviewPlaybackFixture: CaseIterable {
    case existingCache, authPing, durationOnly, paused, oneAdvance, decodeError, audioOutputError, endFileError, timeout
}

private final class PreviewCleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var transports = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
    func recordTransport() { lock.withLock { transports += 1 } }
    func transportCount() -> Int { lock.withLock { transports } }
}

private final class PreviewPlayerEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0, stopCount = 0, completionCount = 0
    func start() { lock.withLock { startCount += 1 } }
    func stopAndDrain() async { lock.withLock { stopCount += 1 } }
    func complete() { lock.withLock { completionCount += 1 } }
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var completions: Int { lock.withLock { completionCount } }
}

private extension ProviderPreviewTransaction {
    static func successFixture() -> ProviderPreviewTransaction {
        ProviderPreviewTransaction(
            phraseCatalog: .builtIn,
            synthesize: { _, _ in
                OwnedNativeAudioArtifact(artifact: NativeAudioArtifact(url: URL(fileURLWithPath: "/tmp/current-preview.pcm"), format: .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview), cleanup: {})
            },
            startPlayback: { _ in },
            verifyPlayback: { PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()) }
        )
    }
    static func fixture(barrier: PreviewBarrier) -> ProviderPreviewTransaction {
        ProviderPreviewTransaction(
            phraseCatalog: .builtIn,
            synthesize: { _, _ in
                await barrier.enterAndWait()
                return OwnedNativeAudioArtifact(artifact: NativeAudioArtifact(url: URL(fileURLWithPath: "/tmp/stale-preview.pcm"), format: .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview), cleanup: {})
            },
            startPlayback: { _ in },
            verifyPlayback: { PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()) }
        )
    }
    static func fixture(failure: PreviewPlaybackFixture, cleanup: PreviewCleanupCounter, effects: PreviewPlayerEffects? = nil) -> ProviderPreviewTransaction {
        ProviderPreviewTransaction(
            phraseCatalog: .builtIn,
            synthesize: { _, policy in
                cleanup.recordTransport()
                if failure == .authPing { throw ProviderPreviewError.insufficientPlaybackEvidence }
                return OwnedNativeAudioArtifact(
                    artifact: NativeAudioArtifact(url: URL(fileURLWithPath: "/tmp/fake-\(UUID().uuidString).pcm"), format: .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview),
                    cleanup: { cleanup.increment() }
                )
            },
            startPlayback: { _ in effects?.start() },
            verifyPlayback: {
                switch failure {
                case .existingCache, .durationOnly, .oneAdvance: return PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.1, observedAt: Date())
                case .paused: throw PlaybackVerificationError.paused
                case .decodeError: throw PlaybackVerificationError.decode
                case .audioOutputError: throw PlaybackVerificationError.audioOutput
                case .endFileError: throw PlaybackVerificationError.endFile
                case .timeout: throw PlaybackVerificationError.timeout
                case .authPing: throw ProviderPreviewError.insufficientPlaybackEvidence
                }
            }
        )
    }
}

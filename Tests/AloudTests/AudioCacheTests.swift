import Foundation
import XCTest
@testable import Aloud

final class AudioCacheTests: XCTestCase {
    func testCacheHitRevalidatesAndRejectsCorruptWAV() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 9, count: 32)))
        let cache = CanonicalAudioCache(directory: directory.url)
        let url = cache.path(for: fingerprint)
        try Data("not a wav".utf8).write(to: url)
        XCTAssertNil(cache.hit(fingerprint: fingerprint, purpose: .preview))
    }

    func testCachePathIsFingerprintNamespaceWithWAVExtension() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 1, count: 32)))
        let url = CanonicalAudioCache(directory: directory.url).path(for: fingerprint)
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("01010101"))
    }

    func testCommitReplacesPreexistingCorruptFinalWithValidatedTemp() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let temp = directory.url.appendingPathComponent(".aloud-temp-new.wav")
        let cache = CanonicalAudioCache(directory: directory.url)
        try WAVTestFixture.wav(samples: 480).write(to: temp)
        let final = cache.path(for: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 2, count: 32))))
        try Data("corrupt old final".utf8).write(to: final)
        let artifact = UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview))
        let revision = UUID(); let generation = SessionGeneration(rawValue: 4)
        let key = CacheFlightKey(fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 2, count: 32))), scopeRevision: revision)
        let flight = CacheFlight(); let waiter = CacheWaiterID()
        _ = try await flight.join(key: key, waiter: waiter, producer: { artifact })
        let possibleLease = await flight.acquirePublishLease(key: key, waiter: waiter)
        let lease = try XCTUnwrap(possibleLease)
        let gate = PublishCommitGate(cache: cache); await gate.advance(providerID: .minimax, revision: revision, generation: generation); await gate.register(lease)
        let committed = try await gate.commit(lease, artifact: artifact, finalURL: final, expectedRevision: revision, expectedGeneration: generation, cancellation: CacheCancelRelay())
        XCTAssertNotNil(committed)
        XCTAssertNoThrow(try WAVValidator.validate(final, purpose: .preview))
    }

    func testCoordinatorPublishesOnlyPerChunkArtifactAndSecondReadIsCacheHit() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let cache = CanonicalAudioCache(directory: directory.url)
        let coordinator = CanonicalChunkCacheCoordinator(cache: cache)
        let revision = UUID(); let generation = SessionGeneration(rawValue: 5)
        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 3, count: 32)))
        let key = CacheFlightKey(fingerprint: fingerprint, scopeRevision: revision)
        await coordinator.advance(providerID: .minimax, revision: revision, generation: generation)
        let calls = CacheCallCounter()
        let first = try await coordinator.resolve(key: key, generation: generation, purpose: .preview) {
            await calls.increment()
            let temp = directory.url.appendingPathComponent("aloud-temp-chunk.wav")
            try WAVTestFixture.wav(samples: 480).write(to: temp)
            return UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview))
        }
        let second = try await coordinator.resolve(key: key, generation: generation, purpose: .preview) {
            await calls.increment(); throw CacheFlightError.noReadyArtifact
        }
        XCTAssertEqual(first.url, second.url)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testEngineDependenciesExposeCanonicalChunkResolverForFutureProviders() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 4, count: 32)))
        let key = CacheFlightKey(fingerprint: fingerprint, scopeRevision: UUID())
        let dependencies = EngineSpeechDependencies(
            cachePath: { _, _, _ in directory.url.appendingPathComponent("legacy.wav") }, cacheHit: { _ in false },
            synthesize: { _, _, _, _ in }, concat: { _, _, _ in },
            canonicalChunkResolver: { _, _, _, producer in try await producer().artifact }
        )
        let temp = directory.url.appendingPathComponent("aloud-temp-engine.wav")
        try WAVTestFixture.wav(samples: 480).write(to: temp)
        let result = try await dependencies.canonicalChunkResolver(key, SessionGeneration(rawValue: 1), .preview) {
            UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview))
        }
        XCTAssertEqual(result.url, temp)
    }

    func testCorruptTruncatedAndOnlyEligibleOldOrphansAreRemoved() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let cache = CanonicalAudioCache(directory: directory.url)
        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 8, count: 32)))
        let corrupt = cache.path(for: fingerprint); try WAVTestFixture.wav(samples: 480).dropLast().write(to: corrupt)
        XCTAssertNil(cache.hit(fingerprint: fingerprint, purpose: .preview)); XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        let old = directory.url.appendingPathComponent("aloud-temp-old.wav"); let fresh = directory.url.appendingPathComponent("aloud-temp-fresh.wav"); let unrelated = directory.url.appendingPathComponent("keep.wav")
        try Data().write(to: old); try Data().write(to: fresh); try Data().write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        cache.removeOrphans(olderThan: Date(timeIntervalSinceNow: -60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testOldSymlinkOrphanIsKept() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let target = directory.url.appendingPathComponent("target.wav"); try Data("keep".utf8).write(to: target)
        let link = directory.url.appendingPathComponent("aloud-temp-link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        CanonicalAudioCache(directory: directory.url).removeOrphans(olderThan: Date().addingTimeInterval(60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path)); XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testTwoChunkFingerprintsPublishExactlyTwoFilesAndNoAggregate() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let cacheDirectory = directory.url.appendingPathComponent("cache", isDirectory: true); try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cache = CanonicalAudioCache(directory: cacheDirectory); let coordinator = CanonicalChunkCacheCoordinator(cache: cache); let revision = UUID()
        await coordinator.advance(providerID: .minimax, revision: revision, generation: .init(rawValue: 8))
        let first = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 11, count: 32))); let second = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 12, count: 32)))
        for (index, fingerprint) in [first, second].enumerated() {
            let temp = directory.url.appendingPathComponent("aloud-temp-chunk-\(index).wav"); try WAVTestFixture.wav(samples: 480).write(to: temp)
            _ = try await coordinator.resolve(key: .init(fingerprint: fingerprint, scopeRevision: revision), generation: .init(rawValue: 8), purpose: .preview) { UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview)) }
        }
        let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        XCTAssertEqual(Set(files.map { $0.standardizedFileURL }), Set([cache.path(for: first).standardizedFileURL, cache.path(for: second).standardizedFileURL]))
    }

    func testTwentyImmediateCoordinatorResolvesDoNotDependOnSupervisorScheduling() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let cache = CanonicalAudioCache(directory: directory.url); let coordinator = CanonicalChunkCacheCoordinator(cache: cache); let revision = UUID(); let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: UInt8(round), count: 32)))
            await coordinator.advance(providerID: .minimax, revision: revision, generation: .init(rawValue: 1))
            let temp = directory.url.appendingPathComponent("aloud-temp-immediate-\(round).wav"); try WAVTestFixture.wav(samples: 480).write(to: temp)
            let result = try await coordinator.resolve(key: .init(fingerprint: fingerprint, scopeRevision: revision), generation: .init(rawValue: 1), purpose: .preview) { UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview)) }
            XCTAssertEqual(result.url.standardizedFileURL, cache.path(for: fingerprint).standardizedFileURL)
        }
    }

    func testLongTextUsesProviderSplitterAndCachesOnlyPerChunkFingerprints() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let version = ContractVersion(rawValue: "v1")
        let limit = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 40, safetyMargin: 0, contractVersion: version)
        let capabilities = try ProviderCapabilities(inputLimits: [limit], outputFormat: .encoded(container: "wav", codec: "pcm"), contractVersion: version, requestOverhead: .init())
        let chunks = try await ProviderInputSplitter(capabilities: capabilities).split(String(repeating: "你好世界", count: 30))
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        let cacheDirectory = directory.url.appendingPathComponent("cache", isDirectory: true); try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cache = CanonicalAudioCache(directory: cacheDirectory); let coordinator = CanonicalChunkCacheCoordinator(cache: cache); let revision = UUID()
        await coordinator.advance(providerID: .openAI, revision: revision, generation: .init(rawValue: 9))
        let selection = ProviderSelection(providerID: .openAI, modelID: .init(rawValue: "tts-1"), voiceID: nil, rate: try XCTUnwrap(NormalizedRate(version: "rate-v1", value: 0)))
        let controls = try SynthesisControls(renderedFields: [], mappingVersion: "rate-v1", templateVersion: nil)
        var fingerprints: [RequestFingerprint] = []
        for (index, chunk) in chunks.enumerated() {
            let request = try SpeechRequest.make(id: .init(rawValue: UUID()), selection: selection, chunk: chunk, controls: controls, credentialScopeRevision: revision, capabilities: capabilities, outputFormatID: "wav-v1", canonicalizerVersion: "v1")
            fingerprints.append(request.requestFingerprint)
            let temp = directory.url.appendingPathComponent("aloud-temp-split-\(index).wav"); try WAVTestFixture.wav(samples: 480).write(to: temp)
            _ = try await coordinator.resolve(key: .init(providerID: .openAI, fingerprint: request.requestFingerprint, scopeRevision: revision), generation: .init(rawValue: 9), purpose: .preview) { UnpublishedArtifact(artifact: try WAVValidator.validate(temp, purpose: .preview)) }
        }
        XCTAssertGreaterThanOrEqual(Set(fingerprints).count, 2)
        let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        XCTAssertEqual(files.count, Set(fingerprints).count)
    }
}

private actor CacheCallCounter { private var count = 0; func increment() { count += 1 }; var value: Int { count } }

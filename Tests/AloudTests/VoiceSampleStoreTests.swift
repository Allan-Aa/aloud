import Foundation
import XCTest
@testable import Aloud

final class VoiceSampleStoreTests: XCTestCase {
    func testBundledManifestContainsAllValidatedSystemSamples() throws {
        let manifest = try BundledVoiceSampleManifest.bundled()
        let root = try XCTUnwrap(BundledVoiceSampleManifest.bundledRoot())

        XCTAssertEqual(manifest.entries.count, 332)
        XCTAssertEqual(Set(manifest.entries.map(\.stableVoiceID)).count, 332)
        XCTAssertTrue(manifest.entries.allSatisfy { entry in
            entry.providerID == .minimax
                && FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.fileName).path)
        })
    }

    func testBundledSampleResolvesWithoutCallingProducer() async throws {
        let root = try TemporaryDirectory()
        let bundled = root.url.appendingPathComponent("radio-host.m4a")
        try Data("bundled-audio".utf8).write(to: bundled)
        let identity = sampleIdentity(scope: UUID())
        let manifest = BundledVoiceSampleManifest(
            schemaVersion: 1,
            phraseVersion: "voice-sample-phrase-v1",
            encoding: .init(container: "m4a", codec: "aac-lc", bitrateKbps: 64, channels: 1),
            entries: [.init(
                providerID: .minimax,
                modelID: identity.modelID,
                stableVoiceID: identity.stableVoiceID,
                wireVoiceID: identity.wireVoiceID,
                languageTag: "zh-CN",
                fileName: bundled.lastPathComponent
            )]
        )
        let counter = SampleProducerCounter()
        let store = VoiceSampleStore(directory: root.url.appendingPathComponent("generated"), bundledRoot: root.url, manifest: manifest)

        let result = try await store.resolve(identity: identity) {
            await counter.increment()
            return VoiceSampleCandidate(url: bundled, fileExtension: "m4a")
        }

        XCTAssertEqual(result.url, bundled)
        XCTAssertTrue(result.isBundled)
        let bundledCalls = await counter.value
        XCTAssertEqual(bundledCalls, 0)
    }

    func testTwentyConcurrentMissesProduceOnceAndPersist() async throws {
        let root = try TemporaryDirectory()
        let source = root.url.appendingPathComponent("source.m4a")
        try Data("generated-audio".utf8).write(to: source)
        let identity = sampleIdentity(scope: UUID())
        let counter = SampleProducerCounter()
        let store = VoiceSampleStore(directory: root.url.appendingPathComponent("generated"), bundledRoot: root.url, manifest: .empty)

        let artifacts = try await withThrowingTaskGroup(of: VoiceSampleArtifact.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await store.resolve(identity: identity) {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(20))
                        return VoiceSampleCandidate(url: source, fileExtension: "m4a")
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        let concurrentCalls = await counter.value
        XCTAssertEqual(concurrentCalls, 1)
        XCTAssertEqual(Set(artifacts.map(\.url)).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(artifacts.first).url.path))

        _ = try await store.resolve(identity: identity) {
            await counter.increment()
            return VoiceSampleCandidate(url: source, fileExtension: "m4a")
        }
        let cachedCalls = await counter.value
        XCTAssertEqual(cachedCalls, 1)
    }

    func testPrivateSamplesAreCredentialScopedWhileBundledIdentityIsNot() async throws {
        let root = try TemporaryDirectory()
        let source = root.url.appendingPathComponent("source.m4a")
        try Data("generated-audio".utf8).write(to: source)
        let counter = SampleProducerCounter()
        let store = VoiceSampleStore(directory: root.url.appendingPathComponent("generated"), bundledRoot: root.url, manifest: .empty)

        let first = try await store.resolve(identity: sampleIdentity(scope: UUID())) {
            await counter.increment()
            return VoiceSampleCandidate(url: source, fileExtension: "m4a")
        }
        let second = try await store.resolve(identity: sampleIdentity(scope: UUID())) {
            await counter.increment()
            return VoiceSampleCandidate(url: source, fileExtension: "m4a")
        }

        XCTAssertNotEqual(first.url, second.url)
        let scopedCalls = await counter.value
        XCTAssertEqual(scopedCalls, 2)
    }

    func testClearGeneratedRemovesOnlyOwnedRegularSampleFiles() async throws {
        let root = try TemporaryDirectory()
        let generated = root.url.appendingPathComponent("generated")
        let source = root.url.appendingPathComponent("source.m4a")
        try Data("generated-audio".utf8).write(to: source)
        let store = VoiceSampleStore(directory: generated, bundledRoot: root.url, manifest: .empty)
        let artifact = try await store.resolve(identity: sampleIdentity(scope: UUID())) {
            VoiceSampleCandidate(url: source, fileExtension: "m4a")
        }
        let unrelated = generated.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)

        let removed = try await store.clearGenerated()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func sampleIdentity(scope: UUID?) -> VoiceSampleIdentity {
        VoiceSampleIdentity(
            providerID: .minimax,
            modelID: ModelID(rawValue: "speech-2.8-hd"),
            stableVoiceID: VoiceID(rawValue: "minimax.radio-host"),
            wireVoiceID: "Chinese (Mandarin)_Radio_Host",
            credentialScopeRevision: scope,
            rateContractVersion: "minimax-rate-v1",
            phraseVersion: "voice-sample-phrase-v1",
            outputFormatVersion: "aac-lc-64k-mono-v1"
        )
    }
}

private actor SampleProducerCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

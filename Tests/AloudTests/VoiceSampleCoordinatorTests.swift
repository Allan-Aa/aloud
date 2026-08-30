import Foundation
import XCTest
@testable import Aloud

@MainActor
final class VoiceSampleCoordinatorTests: XCTestCase {
    func testFirstToggleGeneratesAndPlaysSecondToggleStopsWithoutRegeneration() async throws {
        let root = try TemporaryDirectory()
        let source = root.url.appendingPathComponent("source.m4a")
        try Data("sample-audio".utf8).write(to: source)
        let identity = VoiceSampleIdentity(
            providerID: .minimax,
            modelID: ModelID(rawValue: "speech-2.8-hd"),
            stableVoiceID: VoiceID(rawValue: "minimax.test"),
            wireVoiceID: "test-wire",
            credentialScopeRevision: UUID(),
            rateContractVersion: "minimax-rate-v1",
            phraseVersion: VoiceSamplePhraseCatalog.version,
            outputFormatVersion: "voice-sample-audio-v1"
        )
        let store = VoiceSampleStore(directory: root.url.appendingPathComponent("generated"), bundledRoot: root.url, manifest: .empty)
        let coordinator = VoiceSampleCoordinator(store: store)
        let player = VoiceSamplePlayer()
        let counter = SampleCoordinatorCounter()

        coordinator.toggle(identity: identity, player: player, prefs: Prefs()) {
            await counter.increment()
            return VoiceSampleCandidate(url: source, fileExtension: "m4a")
        }
        try await waitUntil { coordinator.state == .playing(identity) }
        XCTAssertEqual(player.playedFiles.count, 1)
        let firstCalls = await counter.current()
        XCTAssertEqual(firstCalls, 1)

        coordinator.toggle(identity: identity, player: player, prefs: Prefs()) {
            await counter.increment()
            return VoiceSampleCandidate(url: source, fileExtension: "m4a")
        }
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(player.stopCount, 2)

        coordinator.toggle(identity: identity, player: player, prefs: Prefs()) {
            await counter.increment()
            return VoiceSampleCandidate(url: source, fileExtension: "m4a")
        }
        try await waitUntil { coordinator.state == .playing(identity) }
        let cachedCalls = await counter.current()
        XCTAssertEqual(cachedCalls, 1)
        XCTAssertEqual(player.playedFiles.count, 2)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for sample state")
    }
}

private actor SampleCoordinatorCounter {
    private var value = 0
    func increment() { value += 1 }
    func current() -> Int { value }
}

@MainActor
private final class VoiceSamplePlayer: EnginePlayback, @unchecked Sendable {
    var alive = false
    var paused = false
    var position = 0.0
    var duration = 0.0
    var playedFiles: [URL] = []
    var stopCount = 0
    func play(file: URL, prefs: Prefs, streaming: Bool) throws { playedFiles.append(file) }
    func playSample(file: URL, prefs: Prefs) throws { playedFiles.append(file) }
    func append(file: URL) throws {}
    func finishStream(prefs: Prefs) {}
    func stop() { stopCount += 1 }
    func stopAndWait() async {}
    func togglePause() {}
    func seek(relative: Double) {}
    func setSpeed(_ speed: Double) {}
}

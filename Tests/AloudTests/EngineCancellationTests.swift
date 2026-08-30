import XCTest
@testable import Aloud

@MainActor
final class EngineCancellationTests: XCTestCase {
    func testCredentialBeginCancelsCacheHitBeforeItCanPlayOrRecordHistory() async throws {
        let registry = CredentialScopeRegistry()
        let player = TestPlayback()
        let playGate = TestSynthesisBarrier()
        let engine = try makeEngine(player: player, registry: registry, cacheHit: true, synthesize: { _, _, _, _ in }, beforePlayback: { await playGate.enterAndWait() })
        await engine.installCredentialCancellationHook()
        engine.text = "old request"
        engine.speak()
        await playGate.waitUntilEntered()
        let begin = Task { await registry.begin(.minimax) }
        await Task.yield()
        await playGate.release()
        let token = await begin.value
        await registry.commit(token, .missing)
        await Task.yield()
        XCTAssertEqual(player.playCount, 0)
        XCTAssertTrue(engine.history.isEmpty)
        XCTAssertEqual(engine.phase, .idle)
    }

    func testCancellationAfterSynthesisReturnsPreventsPlay() async throws {
        let registry = CredentialScopeRegistry()
        let player = TestPlayback()
        let barrier = TestSynthesisBarrier()
        let engine = try makeEngine(player: player, registry: registry, cacheHit: false, synthesize: { _, _, _, _ in
            await barrier.enterAndWait()
        })
        engine.text = "synth request"
        engine.speak()
        await barrier.waitUntilEntered()
        engine.stop()
        await barrier.release()
        await Task.yield()
        XCTAssertEqual(player.playCount, 0)
        XCTAssertTrue(engine.history.isEmpty)
        XCTAssertEqual(engine.phase, .idle)
    }

    func testCancelledOldRequestCannotOverwriteNewPlayingPhase() async throws {
        let registry = CredentialScopeRegistry()
        let player = TestPlayback()
        let barrier = TestSynthesisBarrier()
        let engine = try makeEngine(player: player, registry: registry, cacheHit: false, synthesize: { text, _, _, _ in
            if text == "old request" { await barrier.enterAndWait() }
        })
        engine.text = "old request"
        engine.speak()
        await barrier.waitUntilEntered()
        engine.stop()
        engine.text = "new request"
        engine.speak()
        for _ in 0..<50 where engine.phase != .playing { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(engine.phase, .playing)
        await barrier.release()
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(engine.phase, .playing)
        XCTAssertTrue(engine.history.contains { $0.text == "new request" })
        XCTAssertFalse(engine.history.contains { $0.text == "old request" })
    }

    func testCredentialCancellationAtHistoryPrewriteBarrierLeavesOldRowOffDiskAndNewRequestRecords() async throws {
        let registry = CredentialScopeRegistry()
        let player = TestPlayback()
        let historyGate = FirstHistoryBarrier()
        let engine = try makeEngine(player: player, registry: registry, cacheHit: false, synthesize: { _, _, _, _ in }, beforeHistoryWrite: { await historyGate.waitOnFirstCall() })
        await engine.installCredentialCancellationHook()
        engine.text = "old request"
        engine.speak()
        await historyGate.waitUntilFirstEntered()
        let begin = Task { await registry.begin(.minimax) }
        await Task.yield()
        await historyGate.releaseFirst()
        let token = await begin.value
        await registry.commit(token, .missing)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(engine.history.contains { $0.text == "old request" })
        engine.text = "new request"
        engine.speak()
        for _ in 0..<50 where !engine.history.contains(where: { $0.text == "new request" }) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(engine.history.contains { $0.text == "new request" })
        XCTAssertFalse(engine.history.contains { $0.text == "old request" })
    }

    func testSpeakWaitsForCredentialHookInstallationBeforeStartingRequest() async throws {
        let registry = CredentialScopeRegistry()
        let player = TestPlayback()
        let calls = CallCounter()
        let engine = try makeEngine(player: player, registry: registry, cacheHit: false, synthesize: { _, _, _, _ in await calls.increment() }, installCredentialHook: false)
        engine.text = "early request"
        engine.speak()
        await Task.yield()
        let before = await calls.value
        XCTAssertEqual(before, 0)
        await engine.installCredentialCancellationHook()
        for _ in 0..<50 where await calls.value == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let after = await calls.value
        XCTAssertEqual(after, 1)
    }

    func testLegacyMiniMaxGateIsVisibleAndHasNoSynthesisPlaybackOrHistorySideEffects() async throws {
        let registry = CredentialScopeRegistry(); let player = TestPlayback(); let calls = CallCounter()
        let engine = try makeEngine(player: player, registry: registry, cacheHit: false, synthesize: { _, _, _, _ in await calls.increment() }, legacyMiniMaxDisabled: true)
        await engine.installCredentialCancellationHook()
        engine.text = "do not synthesize"; engine.speak(); await Task.yield()
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0); XCTAssertEqual(player.playCount, 0); XCTAssertTrue(engine.history.isEmpty)
        XCTAssertEqual(engine.toast, "旧音频格式升级中，请使用系统语音或等待新的语音提供商。")
    }

    func testCredentialBeginWaitsForSynchronousHistoryWriteAndDiskContainsLinearizedOldRow() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.json")
        let files = BlockingAtomicFileStore(url: url, initial: Data("[]".utf8))
        let registry = CredentialScopeRegistry(); let player = TestPlayback()
        let controller = HistoryMutationController(url: url, files: files)
        let engine = try makeEngine(player: player, registry: registry, cacheHit: false, synthesize: { _, _, _, _ in }, historyController: controller)
        await engine.installCredentialCancellationHook(); engine.text = "old request"; engine.speak()
        await files.waitUntilWriteEntered()
        let begin = Task { await registry.begin(.minimax) }
        await Task.yield(); XCTAssertFalse(begin.isCancelled)
        await files.releaseWrite()
        let token = await begin.value; await registry.commit(token, .missing)
        let disk = try JSONDecoder().decode([HistoryEntry].self, from: try files.read(url))
        XCTAssertTrue(disk.contains { $0.text == "old request" })
        XCTAssertFalse(engine.history.contains { $0.text == "old request" })
        XCTAssertEqual(engine.phase, .idle)
    }

    func testCredentialBeginBeforeAtomicWriteLeavesHistoryDiskExactlyUnchanged() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.json"); let initial = Data("[]".utf8)
        let files = BlockingAtomicFileStore(url: url, initial: initial, blocksWrites: false)
        let gate = FirstHistoryBarrier(); let registry = CredentialScopeRegistry()
        let controller = HistoryMutationController(url: url, files: files)
        let engine = try makeEngine(player: TestPlayback(), registry: registry, cacheHit: false, synthesize: { _, _, _, _ in }, beforeHistoryWrite: { await gate.waitOnFirstCall() }, historyController: controller)
        await engine.installCredentialCancellationHook(); engine.text = "old request"; engine.speak(); await gate.waitUntilFirstEntered()
        let begin = Task { await registry.begin(.minimax) }; await Task.yield(); await gate.releaseFirst()
        let token = await begin.value; await registry.commit(token, .missing)
        XCTAssertEqual(try files.read(url), initial)
        XCTAssertFalse(engine.history.contains { $0.text == "old request" })
    }

    private func makeEngine(
        player: TestPlayback,
        registry: CredentialScopeRegistry,
        cacheHit: Bool,
        synthesize: @escaping (String, String, Int, URL) async throws -> Void,
        beforePlayback: @escaping () async -> Void = {},
        beforeHistoryWrite: @escaping () async -> Void = {},
        installCredentialHook: Bool = true, historyController: HistoryMutationController? = nil, legacyMiniMaxDisabled: Bool = false
    ) throws -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-engine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if cacheHit { try WAVTestFixture.wav(samples: 480).write(to: root.appendingPathComponent("fake.wav")) }
        let operations = Store.Operations(dir: root, cacheDir: root, runtimeDir: root, read: { _ in nil }, write: { _, _ in })
        return Store.withOperations(operations) {
            Engine(player: player, speech: .init(
                cachePath: { _, _, _ in root.appendingPathComponent("fake.wav") },
                cacheHit: { _ in cacheHit }, synthesize: synthesize,
                concat: { _, _, _ in }, beforePlayback: beforePlayback, beforeHistoryWrite: beforeHistoryWrite, legacyMiniMaxDisabled: legacyMiniMaxDisabled
            ), credentialRegistry: registry, historyController: historyController, installCredentialHook: installCredentialHook)
        }
    }
}

private actor CallCounter { private var count = 0; func increment() { count += 1 }; var value: Int { count } }

private final class BlockingAtomicFileStore: @unchecked Sendable, AtomicFileStore {
    private let url: URL; private let lock = NSLock(); private var bytes: Data; private let blocksWrites: Bool
    private var entered: CheckedContinuation<Void, Never>?; private var didEnter = false
    private let release = DispatchSemaphore(value: 0)
    init(url: URL, initial: Data, blocksWrites: Bool = true) { self.url = url; self.bytes = initial; self.blocksWrites = blocksWrites }
    func read(_ url: URL) throws -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func atomicWrite(_ data: Data, to url: URL) throws { lock.lock(); didEnter = true; entered?.resume(); entered = nil; lock.unlock(); if blocksWrites { release.wait() }; lock.lock(); bytes = data; lock.unlock() }
    func atomicCopy(from: URL, to: URL) throws {}
    func atomicCopyIfAbsent(from: URL, to: URL) throws -> Bool { false }
    func waitUntilWriteEntered() async { lock.lock(); if didEnter { lock.unlock(); return }; lock.unlock(); await withCheckedContinuation { c in lock.lock(); entered = c; lock.unlock() } }
    func releaseWrite() async { release.signal() }
}

@MainActor
private final class TestPlayback: EnginePlayback {
    var alive = false; var paused = false; var position = 0.0; var duration = 0.0
    private(set) var playCount = 0
    func play(file: URL, prefs: Prefs, streaming: Bool) throws { playCount += 1; alive = true }
    func append(file: URL) throws {}
    func finishStream(prefs: Prefs) {}
    func stop() { alive = false }
    func togglePause() { paused.toggle() }
    func seek(relative: Double) {}
    func setSpeed(_ speed: Double) {}
}

private actor TestSynthesisBarrier {
    private var entered: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func enterAndWait() async { didEnter = true; entered?.resume(); entered = nil; await withCheckedContinuation { released = $0 } }
    func waitUntilEntered() async { if didEnter { return }; await withCheckedContinuation { entered = $0 } }
    func release() { released?.resume(); released = nil }
}

private actor FirstHistoryBarrier {
    private var count = 0; private var entered: CheckedContinuation<Void, Never>?; private var released: CheckedContinuation<Void, Never>?
    func waitOnFirstCall() async {
        count += 1
        guard count == 1 else { return }
        entered?.resume(); entered = nil
        await withCheckedContinuation { released = $0 }
    }
    func waitUntilFirstEntered() async { if count > 0 { return }; await withCheckedContinuation { entered = $0 } }
    func releaseFirst() { released?.resume(); released = nil }
}

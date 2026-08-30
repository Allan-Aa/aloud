import XCTest
@testable import Aloud

final class PrefsSideEffectCoordinatorTests: XCTestCase {
    func testWriteFailureRunsNoSideEffectsForAllFourOperations() async throws {
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = makeCoordinator(files)
        files.clearWrites()
        files.failWrites = true
        let effects = RecordingPrefsEffects()

        await XCTAssertThrowsErrorAsync(try await coordinator.commit({ $0.playbackSpeed = 1.5 }, apply: { _ in await effects.record("speed") }, compensate: { _ in try await effects.recordThrowing("undo-speed") }))
        await XCTAssertThrowsErrorAsync(try await coordinator.commit({ $0.menuBarOnly = true }, apply: { _ in await effects.record("menu") }, compensate: { _ in try await effects.recordThrowing("undo-menu") }))
        await XCTAssertThrowsErrorAsync(try await coordinator.commit({ $0.hkReadSelection = .togglePause }, apply: { _ in await effects.record("hotkey") }, compensate: { _ in try await effects.recordThrowing("undo-hotkey") }))
        await XCTAssertThrowsErrorAsync(try await coordinator.commit({ $0.launchAtLogin = true }, apply: { _ in await effects.record("launch") }, compensate: { _ in try await effects.recordThrowing("undo-launch") }))
        let values = await effects.values()
        XCTAssertEqual(values, [])
    }

    func testSuccessfulOperationsPersistBeforeEachSideEffect() async throws {
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = makeCoordinator(files)
        files.clearWrites()
        let effects = RecordingPrefsEffects()

        _ = try await coordinator.commit({ $0.playbackSpeed = 1.5 }, apply: { _ in await effects.record("speed") }, compensate: { _ in })
        _ = try await coordinator.commit({ $0.menuBarOnly = true }, apply: { _ in await effects.record("menu") }, compensate: { _ in })
        _ = try await coordinator.commit({ $0.hkReadSelection = .togglePause }, apply: { _ in await effects.record("hotkey") }, compensate: { _ in })
        _ = try await coordinator.commit({ $0.launchAtLogin = true }, apply: { _ in await effects.record("launch") }, compensate: { _ in })
        XCTAssertEqual(files.writes.count, 4)
        let values = await effects.values()
        XCTAssertEqual(values, ["speed", "menu", "hotkey", "launch"])
    }

    func testLaunchFailureRollsBackPersistedPreference() async throws {
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = makeCoordinator(files)
        files.clearWrites()
        let effects = RecordingPrefsEffects(failOn: "launch")

        await XCTAssertThrowsErrorAsync(try await coordinator.commit({ $0.launchAtLogin = true }, apply: { _ in try await effects.recordThrowing("launch") }, compensate: { _ in try await effects.recordThrowing("undo-launch") }))
        let visible = await coordinator.visiblePrefs()
        XCTAssertFalse(visible.launchAtLogin)
        XCTAssertEqual(files.writes.count, 2)
        let values = await effects.values()
        XCTAssertEqual(values, ["launch", "undo-launch"])
    }

    func testLaunchFailureWithRollbackWriteFailureReturnsConsistencyError() async throws {
        let files = FailingSecondWriteStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = PrefsSideEffectCoordinator(controller: PrefsMutationController(store: ProviderSettingsStore.open(url: url, files: files)))
        let effects = RecordingPrefsEffects(failOn: "launch")

        files.resetWrites()
        do {
            _ = try await coordinator.commit({ $0.launchAtLogin = true }, apply: { _ in try await effects.recordThrowing("launch") }, compensate: { _ in try await effects.recordThrowing("undo-launch") })
            XCTFail("Expected consistency error")
        } catch PrefsSideEffectCoordinator.Error.rollbackPersistenceFailed {}
        catch { XCTFail("Unexpected \(error)") }
    }

    func testCompensationFailureKeepsOldPrefsAndNeedsReconcile() async throws {
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = makeCoordinator(files)
        files.clearWrites()
        let effects = RecordingPrefsEffects(failOn: "hotkey")

        do {
            _ = try await coordinator.commit({ $0.hkReadSelection = .togglePause }, apply: { _ in try await effects.recordThrowing("hotkey") }, compensate: { _ in await effects.record("undo-hotkey"); throw RecordingPrefsEffects.TestError.failed })
            XCTFail("Expected compensation failure")
        } catch let error as PrefsSideEffectCoordinator.Error {
            XCTAssertEqual(error.outcome.actualPrefs.hkReadSelection, .readSelection)
            XCTAssertEqual(error.outcome.state, .needsReconcile)
        }
    }

    func testReconcileRetriesCurrentPreferenceAndClearsState() async throws {
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = makeCoordinator(files)
        let effects = RecordingPrefsEffects(failOn: "launch")
        files.clearWrites()
        _ = try? await coordinator.commit({ $0.launchAtLogin = true }, apply: { _ in try await effects.recordThrowing("launch") }, compensate: { _ in try await effects.recordThrowing("undo-launch") })

        let current = try await coordinator.reconcileCurrent { prefs in await effects.record("reconcile-\(prefs.launchAtLogin)") }
        XCTAssertFalse(current.launchAtLogin)
        let outcome = await coordinator.consistencyOutcome()
        XCTAssertEqual(outcome.state, .stable)
    }

    func testLaunchCompensationFailurePublishesOldPrefsAndNeedsReconcile() async throws {
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = makeCoordinator(files)
        let effects = RecordingPrefsEffects(failOn: "launch")
        files.clearWrites()

        do {
            _ = try await coordinator.commit({ $0.launchAtLogin = true }, apply: { _ in try await effects.recordThrowing("launch") }, compensate: { _ in await effects.record("undo-launch"); throw RecordingPrefsEffects.TestError.failed })
            XCTFail("Expected compensation failure")
        } catch let error as PrefsSideEffectCoordinator.Error {
            XCTAssertFalse(PrefsConsistencyReducer.visiblePrefs(after: error).launchAtLogin)
            XCTAssertEqual(error.outcome.state, .needsReconcile)
            XCTAssertEqual(PrefsConsistencyReducer.message(after: error), "系统状态恢复失败，请重试协调")
        }
    }

    func testRollbackFailureReducerPublishesPersistedCandidate() async throws {
        let files = FailingSecondWriteStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = PrefsSideEffectCoordinator(controller: PrefsMutationController(store: ProviderSettingsStore.open(url: url, files: files)))
        let effects = RecordingPrefsEffects(failOn: "launch")
        files.resetWrites()

        do {
            _ = try await coordinator.commit({ $0.launchAtLogin = true }, apply: { _ in try await effects.recordThrowing("launch") }, compensate: { _ in try await effects.recordThrowing("undo-launch") })
            XCTFail("Expected rollback failure")
        } catch let error as PrefsSideEffectCoordinator.Error {
            XCTAssertTrue(PrefsConsistencyReducer.visiblePrefs(after: error).launchAtLogin)
            XCTAssertEqual(error.outcome.state, .needsReconcile)
            XCTAssertEqual(PrefsConsistencyReducer.message(after: error), "配置已保存但系统应用失败，请重试协调")
        }
    }

    func testTransactionsAreFIFOAcrossApplyRollbackCompensationAndNextCommit() async throws {
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = makeCoordinator(files)
        files.clearWrites()
        let effects = SuspendedEffects()

        let first = Task { try? await coordinator.commit(
            { $0.menuBarOnly = true },
            apply: { _ in await effects.startedFirst(); await effects.waitUntilReleased(); throw RecordingPrefsEffects.TestError.failed },
            compensate: { _ in try await effects.record("A-compensate") }
        ) }
        await effects.waitForFirstStart()
        let second = Task { try? await coordinator.commit(
            { $0.cacheDays = 30 },
            apply: { _ in try await effects.record("B-apply") },
            compensate: { _ in }
        ) }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(files.writes.count, 1)
        let beforeRelease = await effects.entries()
        XCTAssertEqual(beforeRelease, ["A-apply"])

        await effects.releaseFirst()
        _ = await first.value
        _ = await second.value

        let final = await coordinator.visiblePrefs()
        XCTAssertEqual(final.cacheDays, 30)
        XCTAssertFalse(final.menuBarOnly)
        let entries = await effects.entries()
        let outcome = await coordinator.consistencyOutcome()
        XCTAssertEqual(entries, ["A-apply", "A-compensate", "B-apply"])
        XCTAssertEqual(outcome.state, .stable)
    }

    func testInitialOutcomeHydratesActualPersistedPrefs() async throws {
        var persisted = PrefsV1.defaults
        persisted.menuBarOnly = true
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(persisted)])
        let coordinator = makeCoordinator(files)

        let outcome = await coordinator.consistencyOutcome()
        XCTAssertTrue(outcome.actualPrefs.menuBarOnly)
        XCTAssertEqual(outcome.state, .stable)
    }

    func testCancelledWaiterDoesNotPersistOrApplyAndLaterCommitRuns() async throws {
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let coordinator = makeCoordinator(files)
        files.clearWrites()
        let effects = SuspendedEffects()
        let first = Task { try? await coordinator.commit(
            { $0.menuBarOnly = true },
            apply: { _ in await effects.startedFirst(); await effects.waitUntilReleased(); throw RecordingPrefsEffects.TestError.failed },
            compensate: { _ in try await effects.record("A-compensate") }
        ) }
        await effects.waitForFirstStart()
        let cancelled = Task { try? await coordinator.commit(
            { $0.cacheDays = 30 },
            apply: { _ in try await effects.record("cancelled-apply") },
            compensate: { _ in }
        ) }
        await Task.yield()
        cancelled.cancel()
        await Task.yield()
        XCTAssertEqual(files.writes.count, 1)
        let beforeRelease = await effects.entries()
        XCTAssertEqual(beforeRelease, ["A-apply"])
        await effects.releaseFirst()
        _ = await first.value
        _ = await cancelled.value

        _ = try await coordinator.commit({ $0.cacheDays = 31 }, apply: { _ in try await effects.record("C-apply") }, compensate: { _ in })
        let final = await coordinator.visiblePrefs()
        let entries = await effects.entries()
        XCTAssertEqual(final.cacheDays, 31)
        XCTAssertEqual(entries, ["A-apply", "A-compensate", "C-apply"])
    }

    func testGateCancelReleaseRaceDoesNotDeadlock() async throws {
        for _ in 0..<20 {
            let gate = PrefsTransactionGate()
            let lease = try await gate.acquire()
            let waiter = Task { () -> Bool in
                do {
                    let waitingLease = try await gate.acquire()
                    let cancelled = Task.isCancelled
                    await gate.release(waitingLease)
                    return !cancelled
                } catch is CancellationError { return false }
                catch { return false }
            }
            waiter.cancel()
            await gate.release(lease)
            _ = await waiter.value
            let next = try await gate.acquire()
            await gate.release(next)
        }
    }

    private let url = URL(fileURLWithPath: "/test/prefs.json")
    private func makeCoordinator(_ files: RecordingAtomicFileStore) -> PrefsSideEffectCoordinator {
        PrefsSideEffectCoordinator(controller: PrefsMutationController(store: ProviderSettingsStore.open(url: url, files: files)))
    }
}

actor SuspendedEffects {
    private var entriesStorage: [String] = []
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func startedFirst() async {
        entriesStorage.append("A-apply")
        started?.resume(); started = nil
    }
    func waitForFirstStart() async {
        if entriesStorage.contains("A-apply") { return }
        await withCheckedContinuation { started = $0 }
    }
    func waitUntilReleased() async { await withCheckedContinuation { release = $0 } }
    func releaseFirst() { release?.resume(); release = nil }
    func record(_ value: String) throws { entriesStorage.append(value) }
    func entries() -> [String] { entriesStorage }
}

actor RecordingPrefsEffects {
    private var entries: [String] = []
    private let failOn: String?
    init(failOn: String? = nil) { self.failOn = failOn }
    func record(_ entry: String) { entries.append(entry) }
    func recordThrowing(_ entry: String) throws { entries.append(entry); if entry == failOn { throw TestError.failed } }
    func values() -> [String] { entries }
    enum TestError: Swift.Error { case failed }
}

final class FailingSecondWriteStore: @unchecked Sendable, AtomicFileStore {
    private let lock = NSLock(); private var files: [URL: Data]; private var writes = 0
    init(initial: [URL: Data]) { files = initial }
    func resetWrites() { lock.withLock { writes = 0 } }
    func read(_ url: URL) throws -> Data { try lock.withLock { guard let data = files[url] else { throw AtomicFileStoreError.notFound }; return data } }
    func atomicWrite(_ data: Data, to url: URL) throws { try lock.withLock { writes += 1; if writes == 2 { throw RecordingPrefsEffects.TestError.failed }; files[url] = data } }
    func atomicCopy(from source: URL, to destination: URL) throws { try atomicWrite(read(source), to: destination) }
}

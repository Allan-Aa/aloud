import XCTest
@testable import Aloud

final class ProviderSettingsStoreTests: XCTestCase {
    func testFailedMigrationPreservesOriginalBytesAndBlocksAutosave() async throws {
        let original = Data("[]".utf8)
        let prefsURL = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [prefsURL: original])
        let store = ProviderSettingsStore.open(url: prefsURL, files: files, clock: FixedClock("2026-08-13T10-20-30Z"))

        let mode = await store.mode
        let recovery = await store.recovery
        XCTAssertEqual(mode, .readOnlyRecovery)
        XCTAssertEqual(recovery?.bytes, original)
        try await store.updateInMemory { $0.menuBarOnly = true }
        XCTAssertEqual(files.writes, [])
        XCTAssertEqual(files.data(at: prefsURL), original)
        let inMemory = await store.prefsSnapshot()
        XCTAssertTrue(inMemory.menuBarOnly)
    }

    func testBackupAndResetUsesExactUTCSiblingNameBeforeReplacingPrefs() async throws {
        let original = Data("[]".utf8)
        let prefsURL = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [prefsURL: original])
        let store = ProviderSettingsStore.open(url: prefsURL, files: files, clock: FixedClock("2026-08-13T10-20-30Z"))

        try await store.backupAndReset()

        let backupURL = URL(fileURLWithPath: "/test/prefs.json.backup-2026-08-13T10-20-30Z")
        XCTAssertEqual(files.data(at: backupURL), original)
        XCTAssertEqual(try JSONDecoder().decode(PrefsV1.self, from: try XCTUnwrap(files.data(at: prefsURL))), .defaults)
        let mode = await store.currentMode()
        XCTAssertEqual(mode, .ready)
    }

    func testBackupFailureLeavesRecoveryAndOriginalFileUntouched() async throws {
        let original = Data("[]".utf8)
        let prefsURL = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [prefsURL: original])
        let store = ProviderSettingsStore.open(url: prefsURL, files: files, clock: FixedClock("2026-08-13T10-20-30Z"))
        files.failWrites = true

        await XCTAssertThrowsErrorAsync(try await store.backupAndReset())
        let mode = await store.currentMode()
        XCTAssertEqual(mode, .readOnlyRecovery)
        XCTAssertEqual(files.data(at: prefsURL), original)
        XCTAssertEqual(files.writes, [])
    }

    func testValidMigrationReplacesPrefsAndReadyUpdatesPersistAtomically() async throws {
        let source = try Fixture.data(named: "legacy-prefs-v0.json")
        let prefsURL = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [prefsURL: source])
        let store = ProviderSettingsStore.open(url: prefsURL, files: files, clock: FixedClock("2026-08-13T10-20-30Z"))

        let mode = await store.currentMode()
        XCTAssertEqual(mode, .ready)
        XCTAssertEqual(files.writes.count, 1)
        try await store.updateInMemory { $0.menuBarOnly = false }
        XCTAssertEqual(files.writes.count, 2)
        XCTAssertFalse(try JSONDecoder().decode(PrefsV1.self, from: try XCTUnwrap(files.data(at: prefsURL))).menuBarOnly)
    }

    func testWriteFailureLeavesReadyStoreMemoryAndDiskUnchanged() async throws {
        let prefsURL = URL(fileURLWithPath: "/test/prefs.json")
        let initial = try JSONEncoder().encode(PrefsV1.defaults)
        let files = RecordingAtomicFileStore(initial: [prefsURL: initial])
        let store = ProviderSettingsStore.open(url: prefsURL, files: files, clock: FixedClock("2026-08-13T10-20-30Z"))
        let persistedBeforeFailure = try XCTUnwrap(files.data(at: prefsURL))
        files.failWrites = true

        await XCTAssertThrowsErrorAsync(try await store.updateInMemory { $0.menuBarOnly = true })
        let snapshot = await store.prefsSnapshot()
        XCTAssertEqual(snapshot, .defaults)
        XCTAssertEqual(files.data(at: prefsURL), persistedBeforeFailure)
    }

    func testBackupUsesCapturedRecoveryBytesWhenSourceChangesAfterOpen() async throws {
        let original = Data("[]".utf8)
        let changed = Data(#"{"voice":"changed"}"#.utf8)
        let prefsURL = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [prefsURL: original])
        let store = ProviderSettingsStore.open(url: prefsURL, files: files, clock: FixedClock("2026-08-13T10-20-30Z"))
        files.overwrite(changed, at: prefsURL)

        try await store.backupAndReset()

        let backup = URL(fileURLWithPath: "/test/prefs.json.backup-2026-08-13T10-20-30Z")
        XCTAssertEqual(files.data(at: backup), original)
        let recovery = await store.recoverySnapshot()
        XCTAssertEqual(recovery, nil)
    }

    func testRepairBacksUpRecoverySnapshotThenMakesStoreReady() async throws {
        let original = Data("[]".utf8)
        let prefsURL = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [prefsURL: original])
        let store = ProviderSettingsStore.open(url: prefsURL, files: files, clock: FixedClock("2026-08-13T10-20-30Z"))

        try await store.repair(with: .defaults)

        let backup = URL(fileURLWithPath: "/test/prefs.json.backup-2026-08-13T10-20-30Z")
        XCTAssertEqual(files.data(at: backup), original)
        let mode = await store.currentMode()
        let recovery = await store.recoverySnapshot()
        XCTAssertEqual(mode, .ready)
        XCTAssertNil(recovery)
    }
}

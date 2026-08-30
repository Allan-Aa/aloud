import XCTest
@testable import Aloud

final class PasteboardTransportTests: XCTestCase {
    func testSuccessFailureAndCancellationRestoreEveryItemAndTypeByteForByte() async throws {
        for outcome in PasteboardFixtureOutcome.allCases {
            let original = [
                PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8), "com.example.custom": Data([0, 1, 2])]),
                PasteboardItem(types: ["public.rtf": Data([3, 4, 5])]),
            ]
            let client = RecordingPasteboardClient(items: original)
            let transport = PasteboardTransport(client: client, timeout: .milliseconds(20))
            do {
                _ = try await transport.readSelection {
                    if outcome == .success { client.replaceWithCopiedText("selected") }
                    if outcome == .failure { throw PasteboardFixtureError.failed }
                    if outcome == .cancelled { throw CancellationError() }
                }
                XCTAssertEqual(outcome, .success)
            } catch {}
            XCTAssertEqual(client.items, original, "\(outcome)")
        }
    }

    func testUserCopyBeforeCopierFailureOrCancellationIsNeverRestored() async {
        for outcome in [PasteboardFixtureOutcome.failure, .cancelled] {
            let client = RecordingPasteboardClient(items: [PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8)])])
            let transport = PasteboardTransport(client: client, timeout: .milliseconds(20))
            await XCTAssertThrowsErrorAsync(try await transport.readSelection {
                client.replaceWithCopiedText("user-copy")
                if outcome == .failure { throw PasteboardFixtureError.failed }
                throw CancellationError()
            })
            XCTAssertEqual(client.string, "user-copy")
        }
    }

    func testFirstPostDispatchUserCopyRevokesBeforeTargetAdoption() async {
        let original = [PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8)])]
        let client = RecordingPasteboardClient(items: original)
        let monitor = RecordingCopyInterferenceMonitor()
        let transport = PasteboardTransport(client: client, timeout: .milliseconds(30), interference: monitor)
        let copier: @Sendable (PasteboardOperationOwnership) async throws -> Void = { ownership in
            ownership.copyCommandDispatched()
            monitor.physicalCopy(); client.replaceWithCopiedText("user-copy")
            Task { try? await Task.sleep(for: .milliseconds(3)); client.replaceWithCopiedText("target") }
            throw CancellationError()
        }
        await XCTAssertThrowsErrorAsync(try await transport.readSelection(using: copier))
        XCTAssertEqual(client.string, "target", "revoked operation may not restore over any later clipboard content")
        XCTAssertEqual(monitor.stopCount, 1)
    }

    func testCopierOwnedMutationThenFailureOrCancellationRestoresOnlyWithMarkerAndExactCount() async {
        for outcome in [PasteboardFixtureOutcome.failure, .cancelled] {
            let original = [PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8), "custom": Data([1, 2])])]
            let client = RecordingPasteboardClient(items: original)
            let transport = PasteboardTransport(client: client, timeout: .milliseconds(20))
            await XCTAssertThrowsErrorAsync(try await transport.readSelection { ownership in
                client.replaceWithCopiedText("owned-copy")
                try ownership.claimCurrentPasteboard()
                if outcome == .failure { throw PasteboardFixtureError.failed }
                throw CancellationError()
            })
            XCTAssertEqual(client.items, original, "\(outcome)")
        }
    }

    func testConcurrentUserCopyAfterOwnedClaimPreventsFailureRestore() async {
        let client = RecordingPasteboardClient(items: [PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8)])])
        let transport = PasteboardTransport(client: client, timeout: .milliseconds(20))
        await XCTAssertThrowsErrorAsync(try await transport.readSelection { ownership in
            client.replaceWithCopiedText("owned-copy")
            try ownership.claimCurrentPasteboard()
            client.replaceWithCopiedText("user-copy")
            throw PasteboardFixtureError.failed
        })
        XCTAssertEqual(client.string, "user-copy")
    }

    func testCancellationAfterCopyDispatchDrainsDelayedTargetWriteAndRestoresOriginal() async {
        let original = [PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8)])]
        let client = RecordingPasteboardClient(items: original)
        let transport = PasteboardTransport(client: client, timeout: .milliseconds(100))
        let cancelCopier: @Sendable (PasteboardOperationOwnership) async throws -> Void = { ownership in
            ownership.copyCommandDispatched()
            Task { try? await Task.sleep(for: .milliseconds(10)); client.replaceWithCopiedText("delayed-target") }
            throw CancellationError()
        }
        await XCTAssertThrowsErrorAsync(try await transport.readSelection(using: cancelCopier))
        XCTAssertEqual(client.items, original)
    }

    func testProductionOrderingInstallsMarkerBeforeCopierAndUsesNoPreSendClear() async throws {
        let client = RecordingPasteboardClient(items: [PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8)])])
        let transport = PasteboardTransport(client: client, timeout: .milliseconds(50))
        _ = try await transport.readSelection { ownership in
            XCTAssertTrue(client.containsOperationMarker(ownership.marker))
            XCTAssertEqual(client.replacementCount, 1, "marker install is the only pre-send pasteboard mutation")
            client.replaceWithCopiedText("target")
            ownership.copyCommandDispatched()
        }
    }

    func testUserCopyAfterDelayedTargetWasAdoptedPreventsRestore() async {
        let original = [PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8)])]
        let client = RecordingPasteboardClient(items: original)
        let transport = PasteboardTransport(client: client, timeout: .milliseconds(100))
        client.afterMarkerInstallNumber = 2
        client.afterSelectedMarkerInstall = { client.replaceWithCopiedText("user-copy") }
        let failingCopier: @Sendable (PasteboardOperationOwnership) async throws -> Void = { ownership in
            ownership.copyCommandDispatched()
            Task {
                try? await Task.sleep(for: .milliseconds(5)); client.replaceWithCopiedText("delayed-target")
            }
            throw CancellationError()
        }
        await XCTAssertThrowsErrorAsync(try await transport.readSelection(using: failingCopier))
        XCTAssertEqual(client.string, "user-copy")
    }

    func testConcurrentUserCopyIsNeverOverwritten() async throws {
        let client = RecordingPasteboardClient(items: [PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8)])])
        let transport = PasteboardTransport(client: client, timeout: .milliseconds(20))
        client.afterNextStringRead = { client.replaceWithCopiedText("user-new-copy") }
        let value = try await transport.readSelection {
            client.replaceWithCopiedText("selected")
        }
        XCTAssertEqual(value, "selected")
        XCTAssertEqual(client.string, "user-new-copy")
    }

    func testNonTextAndTimeoutFailAndRestoreOwnedSnapshot() async {
        for fixture in [PasteboardNoTextFixture.nonText, .timeout] {
            let original = [PasteboardItem(types: ["com.example.binary": Data([9, 8, 7])])]
            let client = RecordingPasteboardClient(items: original)
            let transport = PasteboardTransport(client: client, timeout: .milliseconds(2))
            await XCTAssertThrowsErrorAsync(try await transport.readSelection {
                if fixture == .nonText { client.replace(items: original) }
            })
            XCTAssertEqual(client.items, original)
        }
    }

    func testProductionEventClassifierUsesStableNonceAndExactSourceUserDataPath() throws {
        let marker = PasteboardOperationMarker(try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-8123-456789ABCDEF")))
        let classifier = SystemCopyInterferenceClassifier(operation: marker)
        XCTAssertEqual(classifier.expectedSourceUserData, 0x0123456789ABCDEF)
        XCTAssertFalse(classifier.isInterference(FakeCopyEvent(keyCode: 8, command: true, sourceUserData: classifier.expectedSourceUserData)))
        XCTAssertTrue(classifier.isInterference(FakeCopyEvent(keyCode: 8, command: true, sourceUserData: classifier.expectedSourceUserData + 1)))
        XCTAssertFalse(classifier.isInterference(FakeCopyEvent(keyCode: 7, command: true, sourceUserData: 0)))
        XCTAssertFalse(classifier.isInterference(FakeCopyEvent(keyCode: 8, command: false, sourceUserData: 0)))

        let sameMarker = PasteboardOperationMarker(try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-8123-456789ABCDEF")))
        XCTAssertEqual(SystemCopyInterferenceClassifier(operation: sameMarker).expectedSourceUserData, classifier.expectedSourceUserData)
    }

    func testProductionMonitorStopLifecycleRunsExactlyOnce() {
        let count = LockedInt()
        let lifecycle = CopyInterferenceStopLifecycle { count.increment() }
        lifecycle.stop(); lifecycle.stop(); lifecycle.stop()
        XCTAssertEqual(count.value, 1)
    }
}

private enum PasteboardFixtureOutcome: CaseIterable { case success, failure, cancelled }
private enum PasteboardNoTextFixture { case nonText, timeout }
private enum PasteboardFixtureError: Error { case failed }
private struct FakeCopyEvent: CopyEventAccessing {
    let keyCode: UInt16; let command: Bool; let sourceUserData: Int64
}
private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock(); private var number = 0
    func increment() { lock.withLock { number += 1 } }
    var value: Int { lock.withLock { number } }
}

private final class RecordingCopyInterferenceMonitor: @unchecked Sendable, CopyInterferenceMonitor {
    private let lock = NSLock(); private var handler: (@Sendable () -> Void)?; private var stops = 0
    var stopCount: Int { lock.withLock { stops } }
    func start(operation: PasteboardOperationMarker, onInterference: @escaping @Sendable () -> Void) -> any CopyInterferenceLease {
        lock.withLock { handler = onInterference }
        return RecordingCopyInterferenceLease { [weak self] in self?.lock.withLock { self?.stops += 1; self?.handler = nil } }
    }
    func physicalCopy() { lock.withLock { handler }?() }
}
private struct RecordingCopyInterferenceLease: CopyInterferenceLease { let action: @Sendable () -> Void; func stop() { action() } }

private final class RecordingPasteboardClient: @unchecked Sendable, PasteboardClient {
    private let lock = NSLock()
    private var storedItems: [PasteboardItem]
    private var count = 0
    private var markerInstallCount = 0
    var afterNextStringRead: (() -> Void)?
    var afterMarkerInstallNumber: Int?
    var afterSelectedMarkerInstall: (() -> Void)?
    init(items: [PasteboardItem]) { storedItems = items }
    var items: [PasteboardItem] { lock.withLock { storedItems } }
    var changeCount: Int { lock.withLock { count } }
    var string: String? { try? nonEmptyString() }
    var replacementCount: Int { changeCount }
    func snapshotAllItems() throws -> PasteboardSnapshot { PasteboardSnapshot(items: items) }
    func restore(_ snapshot: PasteboardSnapshot) throws { replace(items: snapshot.items) }
    func installOperationMarker(_ marker: PasteboardOperationMarker) throws {
        var current = items
        var types = current.first?.types ?? [:]
        types["app.aloud.pasteboard-operation"] = Data(marker.rawValue.uuidString.utf8)
        if current.isEmpty { current = [PasteboardItem(types: types)] } else { current[0] = PasteboardItem(types: types) }
        replace(items: current)
        let hook: (() -> Void)? = lock.withLock {
            markerInstallCount += 1
            return markerInstallCount == afterMarkerInstallNumber ? afterSelectedMarkerInstall : nil
        }
        hook?()
    }
    func containsOperationMarker(_ marker: PasteboardOperationMarker) -> Bool {
        items.contains { $0.types["app.aloud.pasteboard-operation"] == Data(marker.rawValue.uuidString.utf8) }
    }
    func nonEmptyString() throws -> String {
        let value: String? = lock.withLock {
            storedItems.lazy.compactMap { $0.types["public.utf8-plain-text"] }.compactMap { String(data: $0, encoding: .utf8) }.first
        }
        guard let value, !value.isEmpty else { throw PasteboardTransportError.noText }
        let hook = lock.withLock { () -> (() -> Void)? in defer { afterNextStringRead = nil }; return afterNextStringRead }
        hook?()
        return value
    }
    func replaceWithCopiedText(_ value: String) { replace(items: [PasteboardItem(types: ["public.utf8-plain-text": Data(value.utf8)])]) }
    func replace(items: [PasteboardItem]) { lock.withLock { storedItems = items; count += 1 } }
}

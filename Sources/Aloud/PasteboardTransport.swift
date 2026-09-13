import Foundation

struct PasteboardItem: Equatable, Sendable {
    let types: [String: Data]
}

struct PasteboardSnapshot: Equatable, Sendable {
    let items: [PasteboardItem]
}

struct PasteboardOperationMarker: RawRepresentable, Equatable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID) { self.rawValue = rawValue }
    init(_ rawValue: UUID) { self.rawValue = rawValue }
}

protocol CopyEventAccessing {
    var keyCode: UInt16 { get }
    var command: Bool { get }
    var sourceUserData: Int64 { get }
}

/// Shared by the CGEvent writer and NSEvent monitor. UUID bytes, rather than
/// Swift's randomized `hashValue`, provide one stable 63-bit operation tag.
struct SystemCopyInterferenceClassifier: Sendable {
    let expectedSourceUserData: Int64
    init(operation: PasteboardOperationMarker) {
        var uuid = operation.rawValue.uuid
        let value = withUnsafeBytes(of: &uuid) { bytes in
            bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        expectedSourceUserData = Int64(value & 0x7fff_ffff_ffff_ffff)
    }
    func isInterference(_ event: any CopyEventAccessing) -> Bool {
        event.keyCode == 8 && event.command && event.sourceUserData != expectedSourceUserData
    }
}

final class CopyInterferenceStopLifecycle: @unchecked Sendable {
    private let lock = NSLock(); private var action: (@Sendable () -> Void)?
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func stop() { lock.withLock { defer { action = nil }; return action }?() }
}

protocol PasteboardClient: Sendable {
    var changeCount: Int { get }
    func snapshotAllItems() throws -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot) throws
    func nonEmptyString() throws -> String
    func installOperationMarker(_ marker: PasteboardOperationMarker) throws
    func containsOperationMarker(_ marker: PasteboardOperationMarker) -> Bool
}
protocol CopyInterferenceLease: Sendable { func stop() }
protocol CopyInterferenceMonitor: Sendable {
    func start(operation: PasteboardOperationMarker, onInterference: @escaping @Sendable () -> Void) -> any CopyInterferenceLease
}
private struct NoCopyInterferenceLease: CopyInterferenceLease { func stop() {} }
struct NoCopyInterferenceMonitor: CopyInterferenceMonitor {
    func start(operation: PasteboardOperationMarker, onInterference: @escaping @Sendable () -> Void) -> any CopyInterferenceLease { NoCopyInterferenceLease() }
}

#if canImport(AppKit)
import AppKit

final class SystemPasteboardClient: @unchecked Sendable, PasteboardClient {
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }
    func snapshotAllItems() throws -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItem(types: Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            }))
        })
    }
    func restore(_ snapshot: PasteboardSnapshot) throws {
        pasteboard.clearContents()
        let items = snapshot.items.map { saved in
            let item = NSPasteboardItem()
            for (type, bytes) in saved.types { item.setData(bytes, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        guard items.isEmpty || pasteboard.writeObjects(items) else { throw PasteboardTransportError.noText }
    }
    func nonEmptyString() throws -> String {
        guard let value = pasteboard.string(forType: .string), !value.isEmpty else { throw PasteboardTransportError.noText }
        return value
    }
    func installOperationMarker(_ marker: PasteboardOperationMarker) throws {
        let snapshot = try snapshotAllItems()
        var items = snapshot.items
        let markerType = "app.aloud.pasteboard-operation"
        let markerData = Data(marker.rawValue.uuidString.utf8)
        if items.isEmpty { items = [PasteboardItem(types: [markerType: markerData])] }
        else {
            var types = items[0].types
            types[markerType] = markerData
            items[0] = PasteboardItem(types: types)
        }
        try restore(PasteboardSnapshot(items: items))
    }
    func containsOperationMarker(_ marker: PasteboardOperationMarker) -> Bool {
        guard let snapshot = try? snapshotAllItems() else { return false }
        return snapshot.items.contains { $0.types["app.aloud.pasteboard-operation"] == Data(marker.rawValue.uuidString.utf8) }
    }
}
#endif

enum PasteboardTransportError: Error, Equatable, Sendable {
    case noText, timeout, ownershipLost, restoreFailed
}

final class PasteboardOperationOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private let client: any PasteboardClient
    let marker: PasteboardOperationMarker
    private var expectedChangeCount: Int?
    private var copyBaseline: Int?
    private var commandWasDispatched = false
    private var revoked = false

    init(client: any PasteboardClient, marker: PasteboardOperationMarker) {
        self.client = client; self.marker = marker
    }

    func claimCurrentPasteboard() throws {
        try lock.withLock {
            guard !revoked else { throw PasteboardTransportError.ownershipLost }
            try client.installOperationMarker(marker)
            expectedChangeCount = client.changeCount
        }
    }

    /// Installs ownership before the asynchronous Command-C event can mutate
    /// the pasteboard. The later target write is adopted only after the copier
    /// explicitly reports that the event was dispatched.
    func prepareForCopy() throws {
        try claimCurrentPasteboard()
        lock.withLock { copyBaseline = expectedChangeCount }
    }

    func copyCommandDispatched() { lock.withLock { commandWasDispatched = true } }
    func revoke() { lock.withLock { revoked = true; expectedChangeCount = nil } }
    var dispatched: Bool { lock.withLock { commandWasDispatched } }

    func adoptExpectedTargetWriteIfObserved() throws -> Bool {
        let state = lock.withLock { (copyBaseline, commandWasDispatched, revoked) }
        guard !state.2, state.1, let baseline = state.0,
              client.changeCount != baseline,
              !client.containsOperationMarker(marker) else { return false }
        try claimCurrentPasteboard()
        return true
    }

    var isClaimed: Bool { lock.withLock { expectedChangeCount != nil } }
    func requireNotRevoked() throws {
        guard lock.withLock({ !revoked }) else {
            throw PasteboardTransportError.ownershipLost
        }
    }
    func requireCurrentOwnership() throws {
        guard stillOwnsPasteboard() else {
            throw PasteboardTransportError.ownershipLost
        }
    }
    func stillOwnsPasteboard() -> Bool {
        guard let expected = lock.withLock({ revoked ? nil : expectedChangeCount }) else { return false }
        return client.changeCount == expected && client.containsOperationMarker(marker)
    }
}

actor PasteboardTransport {
    private let client: any PasteboardClient
    private let timeout: Duration
    private let interference: any CopyInterferenceMonitor
    private var activeMarker: PasteboardOperationMarker?

    init(client: any PasteboardClient, timeout: Duration = .seconds(3), interference: any CopyInterferenceMonitor = NoCopyInterferenceMonitor()) {
        self.client = client
        self.timeout = timeout
        self.interference = interference
    }

    func readSelection(using copier: @Sendable () async throws -> Void) async throws -> String {
        try await readSelection { _ in try await copier() }
    }

    func readSelection(using copier: @Sendable (PasteboardOperationOwnership) async throws -> Void) async throws -> String {
        let marker = PasteboardOperationMarker(UUID())
        let snapshot = try client.snapshotAllItems()
        let ownership = PasteboardOperationOwnership(client: client, marker: marker)
        activeMarker = marker
        try ownership.prepareForCopy()
        let interferenceLease = interference.start(operation: marker) { ownership.revoke() }
        defer {
            interferenceLease.stop()
            if activeMarker == marker, ownership.stillOwnsPasteboard() {
                try? client.restore(snapshot)
            }
            if activeMarker == marker { activeMarker = nil }
        }
        do { try await copier(ownership) }
        catch {
            if ownership.dispatched { try? await drainExpectedWrite(ownership) }
            throw error
        }
        try Task.checkCancellation()
        if !ownership.dispatched { ownership.copyCommandDispatched() }
        try await drainExpectedWrite(ownership)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try ownership.requireCurrentOwnership()
            do {
                let text = try client.nonEmptyString()
                try ownership.requireCurrentOwnership()
                try restoreAndValidate(snapshot, ownership: ownership)
                return text
            }
            catch PasteboardTransportError.noText {
                try ownership.requireCurrentOwnership()
                try await Task.sleep(for: .milliseconds(10))
                try Task.checkCancellation()
            }
        }
        try restoreAndValidate(snapshot, ownership: ownership)
        throw PasteboardTransportError.timeout
    }

    private func restoreAndValidate(
        _ snapshot: PasteboardSnapshot,
        ownership: PasteboardOperationOwnership
    ) throws {
        try ownership.requireCurrentOwnership()
        do {
            try client.restore(snapshot)
            guard try client.snapshotAllItems() == snapshot else {
                throw PasteboardTransportError.restoreFailed
            }
        } catch {
            throw PasteboardTransportError.restoreFailed
        }
    }

    private func drainExpectedWrite(_ ownership: PasteboardOperationOwnership) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try ownership.requireNotRevoked()
            if try ownership.adoptExpectedTargetWriteIfObserved() { return }
            // Deliberately ignore task cancellation while draining the one
            // already-dispatched pasteboard write; restoration happens after.
            try? await Task.sleep(for: .milliseconds(2))
        }
        try ownership.requireNotRevoked()
    }
}

import CryptoKit
import CoreFoundation
import Foundation

enum PrefsMigrationError: Error {
    case invalidRoot
    case unsupportedSchema(Int)
}

enum AtomicFileStoreError: Error, Equatable { case notFound, destinationExists }

struct LegacyPrefsV0 {
    let object: [String: Any]

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PrefsMigrationError.invalidRoot
        }
        self.object = object
    }

    func value<T: Decodable>(_ key: String, default fallback: T) -> T {
        guard let raw = object[key], JSONSerialization.isValidJSONObject([raw]),
              let data = try? JSONSerialization.data(withJSONObject: [raw]),
              let value = try? JSONDecoder().decode([T].self, from: data).first else {
            return fallback
        }
        return value
    }

    func migrate() -> PrefsV1 {
        let defaults = PrefsV1.defaults
        let legacyVoice: String = value("voice", default: "minimax:Chinese (Mandarin)_Radio_Host|default")
        let voice = legacyVoice.hasPrefix("minimax:") ? String(legacyVoice.dropFirst("minimax:".count)) : legacyVoice
        let rate: Int = value("rate", default: 50)
        let normalizedRate = NormalizedRate(version: "legacy-minimax-rate-v1", value: rate) ?? defaults.selections[.minimax]!.rate

        var prefs = defaults
        prefs.selections[.minimax] = ProviderSelection(
            providerID: .minimax,
            modelID: ModelID(rawValue: "speech-2.8-hd"),
            voiceID: VoiceID(rawValue: voice),
            rate: normalizedRate
        )
        prefs.playbackSpeed = value("playbackSpeed", default: defaults.playbackSpeed)
        prefs.stripMarkdown = value("stripMarkdown", default: defaults.stripMarkdown)
        prefs.skipCode = value("skipCode", default: defaults.skipCode)
        prefs.mpvBin = value("mpvBin", default: defaults.mpvBin)
        prefs.ffmpegBin = value("ffmpegBin", default: defaults.ffmpegBin)
        prefs.cacheLimitMB = value("cacheLimitMB", default: defaults.cacheLimitMB)
        prefs.cacheDays = value("cacheDays", default: defaults.cacheDays)
        prefs.launchAtLogin = value("launchAtLogin", default: defaults.launchAtLogin)
        prefs.menuBarOnly = value("menuBarOnly", default: defaults.menuBarOnly)
        prefs.hotkeyChime = value("hotkeyChime", default: defaults.hotkeyChime)
        prefs.hkReadSelection = value("hkReadSelection", default: defaults.hkReadSelection)
        prefs.hkReadClipboard = value("hkReadClipboard", default: defaults.hkReadClipboard)
        prefs.hkTogglePause = value("hkTogglePause", default: defaults.hkTogglePause)
        return prefs
    }
}

enum PrefsDecoder {
    static func decodeByVersion(_ data: Data) throws -> PrefsV1 {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PrefsMigrationError.invalidRoot
        }
        if let schema = object["schemaVersion"] {
            guard let version = strictJSONInteger(schema) else { throw PrefsMigrationError.invalidRoot }
            guard version == 1 else { throw PrefsMigrationError.unsupportedSchema(version) }
            return try JSONDecoder().decode(PrefsV1.self, from: data)
        }
        return try LegacyPrefsV0(data: data).migrate()
    }

    private static func strictJSONInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integerTypes: Set<String> = ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]
        guard integerTypes.contains(String(cString: number.objCType)) else { return nil }
        let integer = number.int64Value
        return Int(exactly: integer)
    }
}

extension PrefsV1 {
    static let legacyFieldNames = [
        "voice", "rate", "playbackSpeed", "stripMarkdown", "skipCode", "mpvBin", "ffmpegBin",
        "cacheLimitMB", "cacheDays", "launchAtLogin", "menuBarOnly", "hotkeyChime",
        "hkReadSelection", "hkReadClipboard", "hkTogglePause"
    ]

    func value(for legacyField: String) -> Data? {
        let value: Any
        switch legacyField {
        case "voice": value = "minimax:" + (selections[.minimax]?.voiceID?.rawValue ?? "")
        case "rate": value = selections[.minimax]?.rate.value ?? 50
        case "playbackSpeed": value = playbackSpeed
        case "stripMarkdown": value = stripMarkdown
        case "skipCode": value = skipCode
        case "mpvBin": value = mpvBin
        case "ffmpegBin": value = ffmpegBin
        case "cacheLimitMB": value = cacheLimitMB
        case "cacheDays": value = cacheDays
        case "launchAtLogin": value = launchAtLogin
        case "menuBarOnly": value = menuBarOnly
        case "hotkeyChime": value = hotkeyChime
        case "hkReadSelection": return encodedHotkey(hkReadSelection)
        case "hkReadClipboard": return encodedHotkey(hkReadClipboard)
        case "hkTogglePause": return encodedHotkey(hkTogglePause)
        default: return nil
        }
        return try? JSONSerialization.data(withJSONObject: [value])
    }

    private func encodedHotkey(_ hotkey: HotkeySpec) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(hotkey)
    }
}

protocol AtomicFileStore: Sendable {
    func read(_ url: URL) throws -> Data
    func atomicWrite(_ data: Data, to url: URL) throws
    func atomicCopy(from source: URL, to destination: URL) throws
    func atomicCopyIfAbsent(from source: URL, to destination: URL) throws
}

extension AtomicFileStore {
    func atomicCopyIfAbsent(from source: URL, to destination: URL) throws {
        throw AtomicFileStoreError.destinationExists
    }
}

struct LocalAtomicFileStore: AtomicFileStore {
    private static let exclusiveCopyLock = NSLock()
    func read(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AtomicFileStoreError.notFound }
        return try Data(contentsOf: url)
    }
    func atomicWrite(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
    func atomicCopy(from source: URL, to destination: URL) throws {
        try atomicWrite(try read(source), to: destination)
    }
    func atomicCopyIfAbsent(from source: URL, to destination: URL) throws {
        try Self.exclusiveCopyLock.withLock {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw AtomicFileStoreError.destinationExists }
            try atomicCopy(from: source, to: destination)
        }
    }
}

protocol PrefsClock: Sendable { func backupTimestamp() -> String }

struct SystemPrefsClock: PrefsClock {
    func backupTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}

struct RecoverySnapshot: Equatable, Sendable {
    let url: URL
    let bytes: Data
    let sha256: Data
}

actor ProviderSettingsStore {
    enum Mode: Equatable { case ready, readOnlyRecovery }
    enum DurableMutationError: Error, Equatable, Sendable { case recoveryRequiresRepair }

    private let url: URL
    private let files: any AtomicFileStore
    private let clock: any PrefsClock
    private(set) var mode: Mode
    private(set) var prefs: PrefsV1
    private(set) var recovery: RecoverySnapshot?

    private init(url: URL, files: any AtomicFileStore, clock: any PrefsClock, mode: Mode, prefs: PrefsV1, recovery: RecoverySnapshot?) {
        self.url = url
        self.files = files
        self.clock = clock
        self.mode = mode
        self.prefs = prefs
        self.recovery = recovery
    }

    static func open(url: URL, files: any AtomicFileStore = LocalAtomicFileStore(), clock: any PrefsClock = SystemPrefsClock()) -> ProviderSettingsStore {
        do {
            let bytes = try files.read(url)
            let decoded = try PrefsDecoder.decodeByVersion(bytes)
            let encoded = try JSONEncoder().encode(decoded)
            if encoded != bytes { try files.atomicWrite(encoded, to: url) }
            return ProviderSettingsStore(url: url, files: files, clock: clock, mode: .ready, prefs: decoded, recovery: nil)
        } catch {
            if case AtomicFileStoreError.notFound = error {
                return ProviderSettingsStore(url: url, files: files, clock: clock, mode: .ready, prefs: .defaults, recovery: nil)
            }
            let original = (try? files.read(url)) ?? Data()
            let recovery = RecoverySnapshot(url: url, bytes: original, sha256: Data(SHA256.hash(data: original)))
            return ProviderSettingsStore(url: url, files: files, clock: clock, mode: .readOnlyRecovery, prefs: .defaults, recovery: recovery)
        }
    }

    func updateInMemory(_ mutate: @Sendable (inout PrefsV1) -> Void) throws {
        var candidate = prefs
        mutate(&candidate)
        guard mode == .ready else {
            prefs = candidate
            return
        }
        try persistAtomically(candidate)
        prefs = candidate
    }

    func updateLegacy(_ mutate: @Sendable (inout Prefs) -> Void) throws -> Prefs {
        var legacy = LegacyPrefsBridge.legacy(from: prefs)
        mutate(&legacy)
        let candidate = LegacyPrefsBridge.providerPrefs(from: legacy, existing: prefs)
        guard mode == .ready else {
            prefs = candidate
            return legacy
        }
        try persistAtomically(candidate)
        prefs = candidate
        return legacy
    }

    /// Disclosure authorization is a durable consent decision. Unlike ordinary
    /// recovery-mode UI changes, it must never exist in memory unless the same
    /// exact candidate was atomically persisted first.
    func persistOpenAIDisclosureAck(_ ack: OpenAIDisclosureAck) throws {
        guard mode == .ready else { throw DurableMutationError.recoveryRequiresRepair }
        var candidate = prefs
        candidate.openAIDisclosureAck = ack
        try persistAtomically(candidate)
        prefs = candidate
    }

    func replace(with newPrefs: PrefsV1) throws {
        guard mode == .ready else {
            prefs = newPrefs
            return
        }
        try persistAtomically(newPrefs)
        prefs = newPrefs
    }

    func backupAndReset() throws {
        guard let recovery else { return }
        let backupName = recovery.url.lastPathComponent + ".backup-" + clock.backupTimestamp()
        let backup = recovery.url.deletingLastPathComponent().appendingPathComponent(backupName)
        try files.atomicWrite(recovery.bytes, to: backup)
        try files.atomicWrite(try JSONEncoder().encode(PrefsV1.defaults), to: recovery.url)
        prefs = .defaults
        mode = .ready
        self.recovery = nil
    }

    func currentMode() -> Mode { mode }
    func prefsSnapshot() -> PrefsV1 { prefs }
    func recoverySnapshot() -> RecoverySnapshot? { recovery }

    func repair(with repaired: PrefsV1) throws {
        guard let recovery else {
            try replace(with: repaired)
            return
        }
        let backup = recovery.url.deletingLastPathComponent().appendingPathComponent(
            recovery.url.lastPathComponent + ".backup-" + clock.backupTimestamp()
        )
        let bytes = try JSONEncoder().encode(repaired)
        try files.atomicWrite(recovery.bytes, to: backup)
        try files.atomicWrite(bytes, to: recovery.url)
        prefs = repaired
        mode = .ready
        self.recovery = nil
    }

    private func persistAtomically(_ prefs: PrefsV1) throws {
        try files.atomicWrite(try JSONEncoder().encode(prefs), to: url)
    }
}

actor PrefsMutationController {
    private let store: ProviderSettingsStore
    private var hydrated = false
    private var visible = Prefs()

    init(store: ProviderSettingsStore) { self.store = store }

    func hydrate() async throws -> Prefs {
        guard !hydrated else { return visible }
        return await syncFromStore()
    }

    func syncFromStore() async -> Prefs {
        visible = LegacyPrefsBridge.legacy(from: await store.prefs)
        hydrated = true
        return visible
    }

    func mutate(_ mutation: @Sendable (inout Prefs) -> Void) async throws -> Prefs {
        visible = try await store.updateLegacy(mutation)
        hydrated = true
        return visible
    }

    func visiblePrefs() -> Prefs { visible }

    func replaceVisible(with replacement: Prefs) async throws {
        let existing = await store.prefs
        try await store.replace(with: LegacyPrefsBridge.providerPrefs(from: replacement, existing: existing))
        visible = replacement
    }
}

actor PrefsSideEffectCoordinator {
    enum ConsistencyState: Equatable, Sendable { case stable, needsReconcile }
    struct Outcome: Equatable, Sendable {
        let actualPrefs: Prefs
        let state: ConsistencyState
    }
    enum Error: Swift.Error {
        case effectFailed(Outcome)
        case compensationFailed(Outcome)
        case rollbackPersistenceFailed(Outcome)

        var outcome: Outcome {
            switch self {
            case let .effectFailed(outcome), let .compensationFailed(outcome), let .rollbackPersistenceFailed(outcome): return outcome
            }
        }
    }

    private let controller: PrefsMutationController
    private let transactionGate = PrefsTransactionGate()
    private var outcome: Outcome?
    init(controller: PrefsMutationController) { self.controller = controller }

    func commit(
        _ mutation: @Sendable (inout Prefs) -> Void,
        apply: @escaping @Sendable (Prefs) async throws -> Void,
        compensate: @escaping @Sendable (Prefs) async throws -> Void
    ) async throws -> Prefs {
        let lease = try await transactionGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await commitLocked(mutation, apply: apply, compensate: compensate)
            await transactionGate.release(lease)
            return result
        } catch {
            await transactionGate.release(lease)
            throw error
        }
    }

    private func commitLocked(
        _ mutation: @Sendable (inout Prefs) -> Void,
        apply: @escaping @Sendable (Prefs) async throws -> Void,
        compensate: @escaping @Sendable (Prefs) async throws -> Void
    ) async throws -> Prefs {
        let previous = try await controller.hydrate()
        let candidate = try await controller.mutate(mutation)
        do {
            try await apply(candidate)
            outcome = Outcome(actualPrefs: candidate, state: .stable)
            return candidate
        } catch {
            do {
                try await controller.replaceVisible(with: previous)
            } catch {
                let failed = Outcome(actualPrefs: candidate, state: .needsReconcile)
                outcome = failed
                throw Error.rollbackPersistenceFailed(failed)
            }
            do {
                try await compensate(previous)
                let restored = Outcome(actualPrefs: previous, state: .stable)
                outcome = restored
                throw Error.effectFailed(restored)
            } catch {
                if case Error.effectFailed = error { throw error }
                let failed = Outcome(actualPrefs: previous, state: .needsReconcile)
                outcome = failed
                throw Error.compensationFailed(failed)
            }
        }
    }

    func visiblePrefs() async -> Prefs { await controller.visiblePrefs() }
    func consistencyOutcome() async -> Outcome {
        if let outcome { return outcome }
        let actual: Prefs
        do { actual = try await controller.hydrate() }
        catch { actual = await controller.visiblePrefs() }
        let initialized = Outcome(actualPrefs: actual, state: .stable)
        outcome = initialized
        return initialized
    }

    func reconcileCurrent(apply: @escaping @Sendable (Prefs) async throws -> Void) async throws -> Prefs {
        let lease = try await transactionGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await reconcileLocked(apply: apply)
            await transactionGate.release(lease)
            return result
        } catch {
            await transactionGate.release(lease)
            throw error
        }
    }

    private func reconcileLocked(apply: @escaping @Sendable (Prefs) async throws -> Void) async throws -> Prefs {
        let current = await controller.visiblePrefs()
        do {
            try await apply(current)
            outcome = Outcome(actualPrefs: current, state: .stable)
            return current
        } catch {
            let failed = Outcome(actualPrefs: current, state: .needsReconcile)
            outcome = failed
            throw Error.effectFailed(failed)
        }
    }
}

actor PrefsTransactionGate {
    struct Lease: Sendable { fileprivate let id: UUID }
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Lease, Swift.Error> }
    private var held = false
    private var waiters: [Waiter] = []

    func acquire() async throws -> Lease {
        try Task.checkCancellation()
        let id = UUID()
        guard held else { held = true; return Lease(id: id) }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
    }

    func release(_ lease: Lease) {
        if waiters.isEmpty { held = false }
        else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: Lease(id: waiter.id))
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

enum PrefsConsistencyReducer {
    static func visiblePrefs(after error: PrefsSideEffectCoordinator.Error) -> Prefs { error.outcome.actualPrefs }
    static func message(after error: PrefsSideEffectCoordinator.Error) -> String {
        switch error {
        case .effectFailed: return "设置应用失败，已恢复原设置"
        case .compensationFailed: return "系统状态恢复失败，请重试协调"
        case .rollbackPersistenceFailed: return "配置已保存但系统应用失败，请重试协调"
        }
    }
}

enum LegacyPrefsBridge {
    static func legacy(from prefs: PrefsV1) -> Prefs {
        let selection = prefs.selections[.minimax] ?? PrefsV1.defaults.selections[.minimax]!
        return Prefs(
            voice: "minimax:" + (selection.voiceID?.rawValue ?? "Chinese (Mandarin)_Radio_Host|default"),
            rate: selection.rate.value,
            playbackSpeed: prefs.playbackSpeed,
            stripMarkdown: prefs.stripMarkdown,
            skipCode: prefs.skipCode,
            mpvBin: prefs.mpvBin,
            ffmpegBin: prefs.ffmpegBin,
            cacheLimitMB: prefs.cacheLimitMB,
            cacheDays: prefs.cacheDays,
            launchAtLogin: prefs.launchAtLogin,
            menuBarOnly: prefs.menuBarOnly,
            hotkeyChime: prefs.hotkeyChime,
            hkReadSelection: prefs.hkReadSelection,
            hkReadClipboard: prefs.hkReadClipboard,
            hkTogglePause: prefs.hkTogglePause
        )
    }

    static func providerPrefs(from legacy: Prefs, existing: PrefsV1) -> PrefsV1 {
        var prefs = existing
        let voice = legacy.voice.hasPrefix("minimax:") ? String(legacy.voice.dropFirst("minimax:".count)) : legacy.voice
        prefs.selections[.minimax] = ProviderSelection(
            providerID: .minimax,
            modelID: ModelID(rawValue: "speech-2.8-hd"),
            voiceID: VoiceID(rawValue: voice),
            rate: NormalizedRate(version: existing.selections[.minimax]?.rate.version ?? "legacy-minimax-rate-v1", value: legacy.rate) ?? PrefsV1.defaults.selections[.minimax]!.rate
        )
        prefs.playbackSpeed = legacy.playbackSpeed
        prefs.stripMarkdown = legacy.stripMarkdown
        prefs.skipCode = legacy.skipCode
        prefs.mpvBin = legacy.mpvBin
        prefs.ffmpegBin = legacy.ffmpegBin
        prefs.cacheLimitMB = legacy.cacheLimitMB
        prefs.cacheDays = legacy.cacheDays
        prefs.launchAtLogin = legacy.launchAtLogin
        prefs.menuBarOnly = legacy.menuBarOnly
        prefs.hotkeyChime = legacy.hotkeyChime
        prefs.hkReadSelection = legacy.hkReadSelection
        prefs.hkReadClipboard = legacy.hkReadClipboard
        prefs.hkTogglePause = legacy.hkTogglePause
        return prefs
    }
}

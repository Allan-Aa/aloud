import Foundation

enum HistoryContentResolution: String, Codable, Hashable, Sendable { case valid, skipped, missing }
enum HistorySelectionResolution: String, Codable, Hashable, Sendable { case resolved, unresolvedLegacyVoice }
enum HistoryDiagnosticReason: String, Codable, Hashable, Sendable { case malformedRow, invalidRoot, replacementVerificationFailed, restorationFailed }

struct HistoryDiagnosticEvent: Equatable, Sendable {
    let failureCount: Int
    let indexes: [Int]
    let reason: HistoryDiagnosticReason
}

protocol HistoryDiagnostics: Sendable { func record(_ event: HistoryDiagnosticEvent) }

final class HistoryDiagnosticsRecorder: @unchecked Sendable, HistoryDiagnostics {
    private let lock = NSLock()
    private var values: [HistoryDiagnosticEvent] = []
    var events: [HistoryDiagnosticEvent] { lock.withLock { values } }
    var rendered: String { events.map { "history failures=\($0.failureCount) indexes=\($0.indexes) reason=\($0.reason.rawValue)" }.joined(separator: "\n") }
    func record(_ event: HistoryDiagnosticEvent) { lock.withLock { values.append(event) } }
}

struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let version: Int
    let text: String?
    let contentResolution: HistoryContentResolution
    let seconds: Int
    let providerID: ProviderID
    let modelID: ModelID
    let voiceID: VoiceID?
    let rate: NormalizedRate
    let displayLabelSnapshot: String
    let selectionResolution: HistorySelectionResolution
    let date: Date?
    let legacyAgoSnapshot: String?

    init(id: UUID, version: Int, text: String?, contentResolution: HistoryContentResolution, seconds: Int, providerID: ProviderID, modelID: ModelID, voiceID: VoiceID?, rate: NormalizedRate, displayLabelSnapshot: String, selectionResolution: HistorySelectionResolution, date: Date?, legacyAgoSnapshot: String?) {
        self.id = id; self.version = version; self.text = text; self.contentResolution = contentResolution
        self.seconds = seconds; self.providerID = providerID; self.modelID = modelID; self.voiceID = voiceID
        self.rate = rate; self.displayLabelSnapshot = displayLabelSnapshot; self.selectionResolution = selectionResolution
        self.date = date; self.legacyAgoSnapshot = legacyAgoSnapshot
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), version: try values.decode(Int.self, forKey: .version),
                  text: try values.decodeIfPresent(String.self, forKey: .text), contentResolution: try values.decode(HistoryContentResolution.self, forKey: .contentResolution),
                  seconds: try values.decode(Int.self, forKey: .seconds), providerID: try values.decode(ProviderID.self, forKey: .providerID), modelID: try values.decode(ModelID.self, forKey: .modelID),
                  voiceID: try values.decodeIfPresent(VoiceID.self, forKey: .voiceID), rate: try values.decode(NormalizedRate.self, forKey: .rate),
                  displayLabelSnapshot: try values.decode(String.self, forKey: .displayLabelSnapshot), selectionResolution: try values.decode(HistorySelectionResolution.self, forKey: .selectionResolution),
                  date: try values.decodeIfPresent(Date.self, forKey: .date), legacyAgoSnapshot: try values.decodeIfPresent(String.self, forKey: .legacyAgoSnapshot))
        guard isValid else { throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "invalid history v1 semantics") }
    }

    private var isValid: Bool {
        guard version == 1, seconds >= 0, !providerID.rawValue.isEmpty, !modelID.rawValue.isEmpty else { return false }
        switch contentResolution { case .valid: guard text != nil else { return false }; case .missing, .skipped: guard text == nil else { return false } }
        switch selectionResolution { case .resolved: return voiceID != nil; case .unresolvedLegacyVoice: return voiceID == nil }
    }
}

extension HistoryEntry {
    func agoText(_ language: Lang) -> String {
        guard let date else { return legacyAgoSnapshot ?? "" }
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return language == .zh ? "刚刚" : "just now"
        case ..<3600: return language == .zh ? "\(Int(seconds / 60)) 分钟前" : "\(Int(seconds / 60))m ago"
        case ..<86400: return language == .zh ? "\(Int(seconds / 3600)) 小时前" : "\(Int(seconds / 3600))h ago"
        case ..<172_800: return language == .zh ? "昨天" : "yesterday"
        default: return language == .zh ? "\(Int(seconds / 86400)) 天前" : "\(Int(seconds / 86400))d ago"
        }
    }
}

enum HistoryAction: Hashable, Sendable { case search, copy, load, replay }

struct HistoryActionPolicy: Equatable, Sendable {
    let actions: Set<HistoryAction>
    init(entry: HistoryEntry) { actions = HistoryEligibility(for: entry).actions }
    func allows(_ action: HistoryAction) -> Bool { actions.contains(action) }
}

enum ReplayBlockReason: Error, Equatable, Sendable { case contentUnavailable, selectionUnresolved, providerUnavailable, credentialMissing, selectionInvalid }
enum ReplayDecision: Equatable, Sendable {
    case ready(selection: ProviderSelection, billingProviderID: ProviderID)
    case blocked(ReplayBlockReason)

    static func evaluate(entry: HistoryEntry, currentSelection: ProviderSelection?, providerAvailable: Bool, credentialConfigured: Bool, storedSelectionValid: Bool) -> ReplayDecision {
        _ = currentSelection
        guard entry.contentResolution == .valid, entry.text != nil else { return .blocked(.contentUnavailable) }
        guard entry.selectionResolution == .resolved, let voice = entry.voiceID else { return .blocked(.selectionUnresolved) }
        guard providerAvailable else { return .blocked(.providerUnavailable) }
        guard credentialConfigured else { return .blocked(.credentialMissing) }
        guard storedSelectionValid else { return .blocked(.selectionInvalid) }
        return .ready(
            selection: ProviderSelection(providerID: entry.providerID, modelID: entry.modelID, voiceID: voice, rate: entry.rate),
            billingProviderID: entry.providerID
        )
    }
}

struct HistoryEligibility: Equatable, Sendable {
    let actions: Set<HistoryAction>
    let contentMessage: String?
    let selectionMessage: String?

    init(for entry: HistoryEntry) {
        guard entry.contentResolution == .valid, entry.text != nil else {
            actions = []
            contentMessage = entry.contentResolution == .skipped ? "内容不可用（已跳过）" : "无保存正文"
            selectionMessage = nil
            return
        }
        contentMessage = nil
        if entry.selectionResolution == .unresolvedLegacyVoice {
            actions = [.search, .copy, .load]
            selectionMessage = "选择音色/配置"
        } else {
            actions = [.search, .copy, .load, .replay]
            selectionMessage = nil
        }
    }

    func allows(_ action: HistoryAction) -> Bool { actions.contains(action) }
}

enum LegacyVoiceMapV1 {
    static let voices: [String: VoiceID] = [
        "电台主持": VoiceID(rawValue: "minimax.radio-host.default"),
        "Radio Host": VoiceID(rawValue: "minimax.radio-host.default"),
        "电台主持 · 流畅": VoiceID(rawValue: "minimax.radio-host.fluent"),
        "Radio Host · fluent": VoiceID(rawValue: "minimax.radio-host.fluent"),
        "松弛女孩": VoiceID(rawValue: "minimax.laid-back-girl.default"),
        "Laid-back Girl": VoiceID(rawValue: "minimax.laid-back-girl.default"),
        "松弛女孩 · 流畅": VoiceID(rawValue: "minimax.laid-back-girl.fluent"),
        "Laid-back Girl · fluent": VoiceID(rawValue: "minimax.laid-back-girl.fluent")
    ]
}

/// The persisted v0 wire shape is intentionally decoded row-by-row instead of as an array.
struct LegacyHistoryV0: Sendable { let rawRows: [Data?] }

struct HistoryRowDecode: Sendable { let entry: HistoryEntry?; let reason: HistoryDiagnosticReason? }

struct HistoryRepository: Sendable {
    let entries: [HistoryEntry]
    let canContinue: Bool

    static func open(url: URL, files: any AtomicFileStore = LocalAtomicFileStore(), diagnostics: (any HistoryDiagnostics)? = nil) -> HistoryRepository {
        guard let bytes = try? files.read(url) else { return HistoryRepository(entries: [], canContinue: true) }
        guard let raw = try? JSONSerialization.jsonObject(with: bytes), let rows = raw as? [Any] else {
            diagnostics?.record(.init(failureCount: 1, indexes: [], reason: .invalidRoot))
            return HistoryRepository(entries: [], canContinue: false)
        }
        let legacy = LegacyHistoryV0(rawRows: rows.map { JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil })
        var decoded: [HistoryEntry] = []
        var failed: [Int] = []
        var migrated = false
        for (index, rawRow) in rows.enumerated() {
            guard index < legacy.rawRows.count, JSONSerialization.isValidJSONObject(rawRow), let row = legacy.rawRows[index] else {
                decoded.append(skippedEntry()); failed.append(index); continue
            }
            if let entry = try? JSONDecoder().decode(HistoryEntry.self, from: row) {
                decoded.append(entry)
            } else {
                let result = decodeLegacyRow(row)
                migrated = true
                if let entry = result.entry { decoded.append(entry) }
                else { decoded.append(skippedEntry()); failed.append(index) }
            }
        }
        if !failed.isEmpty { diagnostics?.record(.init(failureCount: failed.count, indexes: failed, reason: .malformedRow)) }
        guard failed.isEmpty else { return HistoryRepository(entries: decoded, canContinue: false) }
        guard migrated else { return HistoryRepository(entries: decoded, canContinue: true) }
        let repository = HistoryRepository(entries: decoded, canContinue: true)
        return HistoryRepository(entries: decoded, canContinue: repository.persistMigration(source: bytes, to: url, files: files, diagnostics: diagnostics))
    }

    static func decodeLegacyRow(_ data: Data) -> HistoryRowDecode {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = strictInt(object["seconds"]),
              let voice = object["voice"] as? String,
              let rateValue = strictInt(object["rate"]),
              let rate = NormalizedRate(version: "legacy-minimax-rate-v1", value: rateValue) else {
            return HistoryRowDecode(entry: nil, reason: .malformedRow)
        }
        let text: String?
        let content: HistoryContentResolution
        if let supplied = object["text"] {
            guard let string = supplied as? String else { return HistoryRowDecode(entry: nil, reason: .malformedRow) }
            text = string; content = .valid
        } else { text = nil; content = .missing }
        let date: Date?
        if let supplied = object["date"], !(supplied is NSNull) {
            if let string = supplied as? String, let decoded = ISO8601DateFormatter().date(from: string) {
                date = decoded
            } else if let number = supplied as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite {
                date = Date(timeIntervalSinceReferenceDate: number.doubleValue)
            } else {
                return HistoryRowDecode(entry: nil, reason: .malformedRow)
            }
        } else { date = nil }
        let id: UUID
        if let rawID = object["id"] {
            guard let string = rawID as? String, let decoded = UUID(uuidString: string) else { return HistoryRowDecode(entry: nil, reason: .malformedRow) }
            id = decoded
        } else { id = UUID() }
        let voiceID = LegacyVoiceMapV1.voices[voice]
        return HistoryRowDecode(entry: HistoryEntry(
            id: id, version: 1, text: text, contentResolution: content, seconds: seconds,
            providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"), voiceID: voiceID,
            rate: rate, displayLabelSnapshot: voice,
            selectionResolution: voiceID == nil ? .unresolvedLegacyVoice : .resolved,
            date: date, legacyAgoSnapshot: object["ago"] as? String
        ), reason: nil)
    }

    private static func skippedEntry() -> HistoryEntry {
        HistoryEntry(id: UUID(), version: 1, text: nil, contentResolution: .skipped, seconds: 0,
                     providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"), voiceID: nil,
                     rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 0)!,
                     displayLabelSnapshot: "", selectionResolution: .unresolvedLegacyVoice,
                     date: nil, legacyAgoSnapshot: nil)
    }

    private static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integerTypes: Set<String> = ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]
        guard integerTypes.contains(String(cString: number.objCType)) else { return nil }
        return Int(exactly: number.int64Value)
    }

    private func persistMigration(source: Data, to url: URL, files: any AtomicFileStore, diagnostics: (any HistoryDiagnostics)?) -> Bool {
        var suffix = 1
        var backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".backup-history-v1")
        let replacement = try? JSONEncoder().encode(entries)
        guard let replacement else { return false }
        while true {
            do { try files.atomicCopyIfAbsent(from: url, to: backup); break }
            catch AtomicFileStoreError.destinationExists { suffix += 1; backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".backup-history-v1-\(suffix)") }
            catch { return false }
        }
        do {
            try files.atomicWrite(replacement, to: url)
            guard let written = try? files.read(url), let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: written), decoded == entries else {
                if (try? files.atomicWrite(source, to: url)) == nil || (try? files.read(url)) != source { diagnostics?.record(.init(failureCount: 1, indexes: [], reason: .restorationFailed)) }
                else { diagnostics?.record(.init(failureCount: 1, indexes: [], reason: .replacementVerificationFailed)) }
                return false
            }
        } catch {
            if (try? files.atomicWrite(source, to: url)) == nil || (try? files.read(url)) != source { diagnostics?.record(.init(failureCount: 1, indexes: [], reason: .restorationFailed)) }
            else { diagnostics?.record(.init(failureCount: 1, indexes: [], reason: .replacementVerificationFailed)) }
        }
        return (try? files.read(url)) == replacement
    }
}

enum HistoryMutationError: Error, Sendable, Equatable { case recoveryRequired, persistenceFailed, restorationFailed }

actor HistoryMutationController {
    private let url: URL
    private let files: any AtomicFileStore
    private var entries: [HistoryEntry]
    private var writable: Bool

    init(url: URL, files: any AtomicFileStore = LocalAtomicFileStore()) {
        self.url = url; self.files = files
        let loaded = HistoryRepository.open(url: url, files: files)
        self.entries = loaded.entries; self.writable = loaded.canContinue
    }

    func snapshot() -> [HistoryEntry] { entries }

    func append(_ entry: HistoryEntry) throws -> [HistoryEntry] {
        guard writable else { throw HistoryMutationError.recoveryRequired }
        var candidate = entries
        candidate.insert(entry, at: 0)
        if candidate.count > 50 { candidate.removeLast(candidate.count - 50) }
        let encoded = try JSONEncoder().encode(candidate)
        let source = try? files.read(url)
        do {
            try files.atomicWrite(encoded, to: url)
            guard let written = try? files.read(url), let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: written), decoded == candidate else {
                throw HistoryMutationError.persistenceFailed
            }
            entries = candidate
            return entries
        } catch {
            do { try restore(source) }
            catch let restoreError as HistoryMutationError { throw restoreError }
            throw HistoryMutationError.persistenceFailed
        }
    }

    /// The speech task supplies a cancellation preflight immediately before
    /// persistence, keeping an obsolete request from publishing a history row.
    func append(
        _ entry: HistoryEntry,
        preflight: @escaping @Sendable () async throws -> Void
    ) async throws -> [HistoryEntry] {
        try await preflight()
        try Task.checkCancellation()
        return try append(entry)
    }

    private func restore(_ source: Data?) throws {
        guard let source else { writable = false; throw HistoryMutationError.restorationFailed }
        do {
            try files.atomicWrite(source, to: url)
            guard try files.read(url) == source else { writable = false; throw HistoryMutationError.restorationFailed }
        } catch { writable = false; throw HistoryMutationError.restorationFailed }
    }
}

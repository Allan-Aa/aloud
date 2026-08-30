import CryptoKit
import Foundation

struct VoiceSampleIdentity: Hashable, Codable, Sendable {
    let providerID: ProviderID
    let modelID: ModelID
    let stableVoiceID: VoiceID
    let wireVoiceID: String
    let credentialScopeRevision: UUID?
    let rateContractVersion: String
    let phraseVersion: String
    let outputFormatVersion: String
}

struct BundledVoiceSampleManifest: Codable, Equatable, Sendable {
    struct Encoding: Codable, Equatable, Sendable {
        let container: String
        let codec: String
        let bitrateKbps: Int
        let channels: Int
    }

    struct Entry: Codable, Equatable, Sendable {
        let providerID: ProviderID
        let modelID: ModelID
        let stableVoiceID: VoiceID
        let wireVoiceID: String
        let languageTag: String
        let fileName: String
    }

    let schemaVersion: Int
    let phraseVersion: String
    let encoding: Encoding
    let entries: [Entry]

    static let empty = BundledVoiceSampleManifest(
        schemaVersion: 1,
        phraseVersion: "voice-sample-phrase-v1",
        encoding: .init(container: "m4a", codec: "aac-lc", bitrateKbps: 64, channels: 1),
        entries: []
    )

    func entry(for identity: VoiceSampleIdentity) -> Entry? {
        entries.first {
            $0.providerID == identity.providerID
                && $0.modelID == identity.modelID
                && $0.stableVoiceID == identity.stableVoiceID
                && $0.wireVoiceID == identity.wireVoiceID
        }
    }

    static func bundled() throws -> BundledVoiceSampleManifest {
        guard let root = bundledRoot(),
              let url = [
                root.appendingPathComponent("manifest.json"),
                root.appendingPathComponent("VoiceSamples/manifest.json"),
              ].first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw VoiceSampleError.missingManifest
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    static func bundledRoot() -> URL? {
        guard let resourceURL = Bundle.module.resourceURL else { return nil }
        let nested = resourceURL.appendingPathComponent("VoiceSamples", isDirectory: true)
        return FileManager.default.fileExists(atPath: nested.appendingPathComponent("manifest.json").path)
            ? nested
            : resourceURL
    }
}

struct VoiceSampleCandidate: Sendable {
    let url: URL
    let fileExtension: String
    let cleanup: @Sendable () -> Void

    init(url: URL, fileExtension: String, cleanup: @escaping @Sendable () -> Void = {}) {
        self.url = url
        self.fileExtension = fileExtension
        self.cleanup = cleanup
    }
}

struct VoiceSampleArtifact: Hashable, Sendable {
    let url: URL
    let isBundled: Bool
}

enum VoiceSamplePlaybackState: Equatable, Sendable {
    case idle
    case generating(VoiceSampleIdentity)
    case playing(VoiceSampleIdentity)
    case failed(VoiceSampleIdentity)

    var activeIdentity: VoiceSampleIdentity? {
        switch self {
        case .idle: return nil
        case .generating(let identity), .playing(let identity), .failed(let identity): return identity
        }
    }
}

@MainActor
final class VoiceSampleCoordinator {
    private let store: VoiceSampleStore
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var stateDidChange: ((VoiceSamplePlaybackState) -> Void)?
    private(set) var state: VoiceSamplePlaybackState = .idle {
        didSet { stateDidChange?(state) }
    }

    init(store: VoiceSampleStore) { self.store = store }

    func toggle(
        identity: VoiceSampleIdentity,
        player: any EnginePlayback,
        prefs: Prefs,
        produce: @escaping @Sendable () async throws -> VoiceSampleCandidate
    ) {
        if state.activeIdentity == identity {
            stop(player: player)
            return
        }
        task?.cancel()
        let generation = UUID()
        self.generation = generation
        player.stop()
        state = .generating(identity)
        let store = store
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await player.stopAndWait()
            do {
                let artifact = try await store.resolve(identity: identity, produce: produce)
                try Task.checkCancellation()
                try player.playSample(file: artifact.url, prefs: prefs)
                guard self.generation == generation else { return }
                self.state = .playing(identity)
            } catch is CancellationError {
                if self.generation == generation { self.state = .idle }
            } catch {
                if self.generation == generation { self.state = .failed(identity) }
            }
        }
    }

    func stop(player: any EnginePlayback) {
        task?.cancel()
        task = nil
        generation = UUID()
        player.stop()
        state = .idle
        Task { await player.stopAndWait() }
    }
}

enum VoiceSampleError: Error, Equatable {
    case missingManifest
    case missingBundledFile
    case emptyAudio
    case unsupportedFileExtension
}

enum VoiceSamplePhraseCatalog {
    static let version = "voice-sample-phrase-v1"
    static func phrase(languageTag: String) -> String {
        switch languageTag.split(separator: "-").first.map(String.init)?.lowercased() {
        case "ja": return "自然で聞きやすい音声サンプルです。"
        case "ko": return "자연스럽고 듣기 편한 음성 샘플입니다."
        case "es": return "Esta es una muestra de voz clara y natural."
        case "fr": return "Voici un exemple de voix claire et naturelle."
        case "de": return "Dies ist eine klare und natürliche Stimmprobe."
        case "pt": return "Esta é uma amostra de voz clara e natural."
        case "it": return "Questo è un esempio di voce chiara e naturale."
        case "ru": return "Это образец чистого и естественного голоса."
        case "ar": return "هذا نموذج صوتي واضح وطبيعي."
        case "tr": return "Bu, net ve doğal bir ses örneğidir."
        case "vi": return "Đây là mẫu giọng nói rõ ràng và tự nhiên."
        case "id": return "Ini adalah contoh suara yang jelas dan alami."
        case "th": return "นี่คือตัวอย่างเสียงที่ชัดเจนและเป็นธรรมชาติ"
        case "nl": return "Dit is een helder en natuurlijk stemvoorbeeld."
        case "uk": return "Це приклад чистого й природного голосу."
        case "pl": return "To jest próbka wyraźnego i naturalnego głosu."
        case "ro": return "Acesta este un exemplu de voce clară și naturală."
        case "el": return "Αυτό είναι ένα καθαρό και φυσικό δείγμα φωνής."
        case "cs": return "Toto je ukázka jasného a přirozeného hlasu."
        case "fi": return "Tämä on selkeä ja luonnollinen ääninäyte."
        case "hi": return "यह एक स्पष्ट और स्वाभाविक आवाज़ का नमूना है।"
        case "yue": return "呢段係清晰自然嘅聲音樣本。"
        case "en": return "This is a clear and natural voice sample."
        default: return "这是一段清晰自然的音色样音。"
        }
    }
}

actor VoiceSampleStore {
    private static let generatedExtensions: Set<String> = ["m4a", "mp3", "wav", "caf"]

    let directory: URL
    let bundledRoot: URL
    let manifest: BundledVoiceSampleManifest
    private var inFlight: [VoiceSampleIdentity: Task<VoiceSampleArtifact, Error>] = [:]

    init(
        directory: URL = Store.dir.appendingPathComponent("Voice Samples", isDirectory: true),
        bundledRoot: URL? = BundledVoiceSampleManifest.bundledRoot(),
        manifest: BundledVoiceSampleManifest? = try? .bundled()
    ) {
        self.directory = directory
        self.bundledRoot = bundledRoot ?? URL(fileURLWithPath: "/missing-bundled-voice-samples")
        self.manifest = manifest ?? .empty
    }

    func resolve(
        identity: VoiceSampleIdentity,
        produce: @escaping @Sendable () async throws -> VoiceSampleCandidate
    ) async throws -> VoiceSampleArtifact {
        if let entry = manifest.entry(for: identity) {
            let url = bundledRoot.appendingPathComponent(entry.fileName)
            guard Self.isNonemptyRegularFile(url) else { throw VoiceSampleError.missingBundledFile }
            return VoiceSampleArtifact(url: url, isBundled: true)
        }
        if let hit = generatedHit(identity: identity) { return hit }
        if let task = inFlight[identity] { return try await task.value }

        let directory = directory
        let digest = try Self.digest(identity)
        let task = Task<VoiceSampleArtifact, Error> {
            let candidate = try await produce()
            defer { candidate.cleanup() }
            let ext = candidate.fileExtension.lowercased()
            guard Self.generatedExtensions.contains(ext) else { throw VoiceSampleError.unsupportedFileExtension }
            guard Self.isNonemptyRegularFile(candidate.url) else { throw VoiceSampleError.emptyAudio }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let final = directory.appendingPathComponent(digest).appendingPathExtension(ext)
            if Self.isNonemptyRegularFile(final) { return VoiceSampleArtifact(url: final, isBundled: false) }
            let temporary = directory.appendingPathComponent(".sample-\(UUID().uuidString)").appendingPathExtension(ext)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: candidate.url, to: temporary)
            try FileManager.default.moveItem(at: temporary, to: final)
            return VoiceSampleArtifact(url: final, isBundled: false)
        }
        inFlight[identity] = task
        do {
            let artifact = try await task.value
            inFlight[identity] = nil
            return artifact
        } catch {
            inFlight[identity] = nil
            throw error
        }
    }

    func clearGenerated() throws -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for url in urls where Self.generatedExtensions.contains(url.pathExtension.lowercased()) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    private func generatedHit(identity: VoiceSampleIdentity) -> VoiceSampleArtifact? {
        guard let digest = try? Self.digest(identity),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }
        for url in urls where url.deletingPathExtension().lastPathComponent == digest {
            guard Self.generatedExtensions.contains(url.pathExtension.lowercased()), Self.isNonemptyRegularFile(url) else { continue }
            return VoiceSampleArtifact(url: url, isBundled: false)
        }
        return nil
    }

    private static func digest(_ identity: VoiceSampleIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isNonemptyRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
    }
}

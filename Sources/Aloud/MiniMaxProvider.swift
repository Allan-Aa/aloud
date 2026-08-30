import Foundation

struct MiniMaxHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

protocol MiniMaxHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse
}

struct URLSessionMiniMaxHTTPClient: MiniMaxHTTPClient {
    let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let audited = try await PreviewAccessAudit.access(.network, auditedValue: MiniMaxHTTPResponse(statusCode: 200, body: Data())) {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MiniMaxProviderError.invalidResponse }
            return MiniMaxHTTPResponse(statusCode: http.statusCode, body: data)
        }
        return audited
    }
}

struct MiniMaxWireVoice: Equatable, Hashable, Sendable {
    let voiceID: String
    let emotion: String?
}

enum MiniMaxVoiceCatalogV1 {
    enum DisabledReason: String, Equatable, Hashable, Sendable {
        case fluentNotVerifiedForSpeech28HD
    }

    /// All stable IDs remain recognizable for prefs/history migration. Only
    /// `availableMapping` may be rendered into a live request.
    static let migrationMapping: [VoiceID: MiniMaxWireVoice] = [
        VoiceID(rawValue: "minimax.radio-host.default"):
            MiniMaxWireVoice(voiceID: "Chinese (Mandarin)_Radio_Host", emotion: nil),
        VoiceID(rawValue: "minimax.radio-host.fluent"):
            MiniMaxWireVoice(voiceID: "Chinese (Mandarin)_Radio_Host", emotion: "fluent"),
        VoiceID(rawValue: "minimax.laid-back-girl.default"):
            MiniMaxWireVoice(voiceID: "Chinese (Mandarin)_Laid_BackGirl", emotion: nil),
        VoiceID(rawValue: "minimax.laid-back-girl.fluent"):
            MiniMaxWireVoice(voiceID: "Chinese (Mandarin)_Laid_BackGirl", emotion: "fluent"),
    ]

    static let availableMapping: [VoiceID: MiniMaxWireVoice] = migrationMapping.filter {
        $0.value.emotion == nil
    }
    static let disabledReasons: [VoiceID: DisabledReason] = migrationMapping.reduce(into: [:]) { result, entry in
        if entry.value.emotion == "fluent" {
            result[entry.key] = .fluentNotVerifiedForSpeech28HD
        }
    }

    static let contractOwnedResources = ContractOwnedResources(
        builtInVoices: Set(availableMapping.keys),
        builtInControls: [CatalogControlsID(rawValue: MiniMaxRateMappingV1.version)]
    )
}

/// Adapter-local HTTP wire contract. This is deliberately separate from the
/// Task 9 release catalog: that catalog establishes provider/model
/// availability, while this version locks the exact request renderer used by
/// this adapter.
enum MiniMaxWireContractV1 {
    static let endpoint = URL(string: "https://api.minimax.io/v1/t2a_v2")!
    static let modelID = ModelID(rawValue: "speech-2.8-hd")
    static let version = ContractVersion(rawValue: "minimax-t2a-http-v1")
    static let outputFormatID = "mp3-32000hz-128000bps-mono-v1"
    static let retryContract = RetryContract(
        idempotency: .notGuaranteed,
        retryableHTTPStatuses: [],
        maximumAttempts: 1,
        backoffMilliseconds: []
    )
    static let capabilities: ProviderCapabilities = {
        // The official contract says fewer than 10,000 "characters" without
        // defining its counting unit. Until a paid boundary probe is approved,
        // every request must satisfy both conservative interpretations.
        let scalarLimit = try! InputLimit(
            endpoint: "/v1/t2a_v2:text:unicode-scalars", unit: .unicodeScalars,
            maximum: 9_999, safetyMargin: 0, contractVersion: version
        )
        let byteLimit = try! InputLimit(
            endpoint: "/v1/t2a_v2:text:utf8-bytes", unit: .utf8Bytes,
            maximum: 9_999, safetyMargin: 0, contractVersion: version
        )
        return try! ProviderCapabilities(
            inputLimits: [scalarLimit, byteLimit], outputFormat: .encoded(container: "mp3", codec: "mp3"),
            contractVersion: version
        )
    }()
}

enum MiniMaxVoiceManagementContractV1 {
    static let endpoint = URL(string: "https://api.minimax.io/v1/get_voice")!
    static let maximumResponseBytes = 2_000_000
}

struct MiniMaxVoiceCatalogLoad: Sendable {
    let snapshot: AccountCatalogSnapshot
    let voices: [MiniMaxVoiceDescriptor]
}

private struct MiniMaxGetVoiceRequest: Encodable {
    let voiceType = "all"

    private enum CodingKeys: String, CodingKey {
        case voiceType = "voice_type"
    }
}

struct MiniMaxGetVoiceResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let voiceID: String
        let voiceName: String?

        private enum CodingKeys: String, CodingKey {
            case voiceID = "voice_id"
            case voiceName = "voice_name"
        }
    }

    let systemVoices: [Entry]
    let clonedVoices: [Entry]
    let generatedVoices: [Entry]
    let baseResponse: MiniMaxResponseEnvelope.BaseResponse

    private enum CodingKeys: String, CodingKey {
        case systemVoices = "system_voice"
        case clonedVoices = "voice_cloning"
        case generatedVoices = "voice_generation"
        case baseResponse = "base_resp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemVoices = try container.decodeIfPresent([Entry].self, forKey: .systemVoices) ?? []
        clonedVoices = try container.decodeIfPresent([Entry].self, forKey: .clonedVoices) ?? []
        generatedVoices = try container.decodeIfPresent([Entry].self, forKey: .generatedVoices) ?? []
        baseResponse = try container.decode(
            MiniMaxResponseEnvelope.BaseResponse.self, forKey: .baseResponse
        )
    }
}

enum MiniMaxRateMappingV1 {
    static let version = "minimax-rate-v1"

    static func speed(for rate: NormalizedRate) -> Double {
        min(2, max(0.5, 1 + Double(rate.value) / 100))
    }

    static func controls(for rate: NormalizedRate) throws -> SynthesisControls {
        let speed = speed(for: rate)
        let rendered: String
        switch speed {
        case 0.5: rendered = "0.5"
        case 1: rendered = "1"
        case 2: rendered = "2"
        default: rendered = String(speed)
        }
        return try SynthesisControls(
            renderedFields: [SynthesisControlField(name: "speed", value: rendered)],
            mappingVersion: version,
            templateVersion: nil
        )
    }
}

struct MiniMaxRequestBody: Encodable, Equatable, Sendable {
    struct VoiceSetting: Encodable, Equatable, Sendable {
        let voiceID: String
        let speed: Double
        let volume: Int
        let pitch: Int
        let emotion: String?

        private enum CodingKeys: String, CodingKey {
            case voiceID = "voice_id"
            case speed
            case volume = "vol"
            case pitch
            case emotion
        }
    }

    struct AudioSetting: Encodable, Equatable, Sendable {
        let sampleRate: Int
        let bitrate: Int
        let format: String

        private enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case bitrate
            case format
        }
    }

    let model: String
    let text: String
    let stream: Bool
    let languageBoost: String
    let outputFormat: String
    let voiceSetting: VoiceSetting
    let audioSetting: AudioSetting

    private enum CodingKeys: String, CodingKey {
        case model, text, stream
        case languageBoost = "language_boost"
        case outputFormat = "output_format"
        case voiceSetting = "voice_setting"
        case audioSetting = "audio_setting"
    }
}

struct MiniMaxResponseEnvelope: Decodable, Equatable, Sendable {
    struct Payload: Decodable, Equatable, Sendable { let audio: String? }
    struct BaseResponse: Decodable, Equatable, Sendable {
        let statusCode: Int
        let statusMessage: String?
        private enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case statusMessage = "status_msg"
        }
    }
    let data: Payload?
    let baseResponse: BaseResponse
    private enum CodingKeys: String, CodingKey {
        case data
        case baseResponse = "base_resp"
    }
}

enum MiniMaxProviderError: Error, Equatable, Sendable {
    case credentialMissing
    case credentialMismatch
    case credentialBlocked(CredentialBlockReason)
    case unsupportedSelection
    case disabledSelection(MiniMaxVoiceCatalogV1.DisabledReason)
    case invalidRequest
    case credentialRejected
    case transport
    case httpStatus(Int)
    case service(Int)
    case invalidResponse
    case audioMissing
    case nativeWriteFailed
}

extension MiniMaxProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .credentialMissing: return "MiniMax 尚未配置凭据。"
        case .credentialMismatch: return "MiniMax 凭据已变化，请重新朗读。"
        case .credentialBlocked: return "MiniMax 凭据需要重新从 1Password 导入或手动输入。"
        case .unsupportedSelection: return "MiniMax 当前模型或音色不可用。"
        case .disabledSelection(.fluentNotVerifiedForSpeech28HD): return "流畅音色尚未验证支持 speech-2.8-hd，请改用默认音色。"
        case .invalidRequest: return "MiniMax 朗读请求未通过本地验证。"
        case .credentialRejected: return "MiniMax 拒绝了当前凭据。"
        case .transport: return "无法连接 MiniMax。"
        case .httpStatus: return "MiniMax 服务暂时不可用。"
        case .service: return "MiniMax 未能生成音频。"
        case .invalidResponse, .audioMissing: return "MiniMax 返回了无效音频。"
        case .nativeWriteFailed: return "MiniMax 音频暂存失败。"
        }
    }
}

enum MiniMaxErrorClassifier {
    static func response(_ envelope: MiniMaxResponseEnvelope) -> MiniMaxProviderError? {
        switch envelope.baseResponse.statusCode {
        case 0: return nil
        case 1004, 2049: return .credentialRejected
        case let code: return .service(code)
        }
    }
}

struct MiniMaxProvider: VoiceProvider {
    let id = ProviderID.minimax
    let capabilities = MiniMaxWireContractV1.capabilities
    let httpClient: any MiniMaxHTTPClient
    let nativeDirectory: URL
    let voiceDirectory: MiniMaxVoiceDirectory
    private let beforeVoiceCatalogCommit: @Sendable () async -> Void

    init(
        httpClient: any MiniMaxHTTPClient,
        nativeDirectory: URL,
        voiceDirectory: MiniMaxVoiceDirectory = MiniMaxVoiceDirectory(),
        beforeVoiceCatalogCommit: @escaping @Sendable () async -> Void = {}
    ) {
        self.httpClient = httpClient
        self.nativeDirectory = nativeDirectory
        self.voiceDirectory = voiceDirectory
        self.beforeVoiceCatalogCommit = beforeVoiceCatalogCommit
    }

    func measureInput(_ text: String, requestOverhead: RequestOverhead) async throws -> InputMeasurement {
        guard requestOverhead == capabilities.requestOverhead else { throw InputValidationError.invalidLimit }
        return try await InputMeasurement.measure(
            text, limits: capabilities.inputLimits, requestOverhead: requestOverhead
        )
    }

    func split(_ text: String, selection: ProviderSelection) async throws -> [ValidatedSpeechChunk] {
        try await validate(selection)
        return try await ProviderInputSplitter(capabilities: capabilities) { text, overhead in
            try await measureInput(text, requestOverhead: overhead)
        }.split(text)
    }

    func loadCatalog(using credential: ProviderCredential) async throws -> AccountCatalogSnapshot {
        try await loadVoiceCatalog(using: credential).snapshot
    }

    func loadVoiceCatalog(
        using credential: ProviderCredential,
        publication: ProviderAccountEvidenceStore.PublicationToken? = nil
    ) async throws -> MiniMaxVoiceCatalogLoad {
        let envelope = try envelope(from: credential, expectedRevision: nil)
        guard let key = String(data: envelope.secret, encoding: .utf8), !key.isEmpty else {
            throw MiniMaxProviderError.credentialMissing
        }
        try Task.checkCancellation()
        let operation: MiniMaxVoiceDirectoryOperation
        if let publication {
            guard let currentOperation = await voiceDirectory.begin(
                revision: envelope.revision, publication: publication
            ) else {
                throw CancellationError()
            }
            operation = currentOperation
        } else {
            operation = await voiceDirectory.begin(revision: envelope.revision)
        }

        var request = URLRequest(url: MiniMaxVoiceManagementContractV1.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { request.httpBody = try encoder.encode(MiniMaxGetVoiceRequest()) }
        catch { throw MiniMaxProviderError.invalidRequest }

        let response: MiniMaxHTTPResponse
        do { response = try await httpClient.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MiniMaxProviderError.transport }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw MiniMaxProviderError.credentialRejected
            }
            throw MiniMaxProviderError.httpStatus(response.statusCode)
        }
        guard response.body.count <= MiniMaxVoiceManagementContractV1.maximumResponseBytes else {
            throw MiniMaxProviderError.invalidResponse
        }

        let decoded: MiniMaxGetVoiceResponse
        do { decoded = try JSONDecoder().decode(MiniMaxGetVoiceResponse.self, from: response.body) }
        catch { throw MiniMaxProviderError.invalidResponse }
        switch decoded.baseResponse.statusCode {
        case 0: break
        case 1004, 2049: throw MiniMaxProviderError.credentialRejected
        case let code: throw MiniMaxProviderError.service(code)
        }

        let candidates = try voiceCandidates(from: decoded)
        try Task.checkCancellation()
        await beforeVoiceCatalogCommit()
        guard let voices = await voiceDirectory.commit(candidates, operation: operation) else {
            throw CancellationError()
        }
        return MiniMaxVoiceCatalogLoad(
            snapshot: try accountSnapshot(voices: voices, revision: envelope.revision),
            voices: voices
        )
    }

    func voiceDescriptors(revision: UUID) async -> [MiniMaxVoiceDescriptor] {
        await voiceDirectory.descriptors(revision: revision)
    }

    func synthesize(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact {
        try await PreviewAccessAudit.access(
            .provider,
            auditedValue: OwnedNativeAudioArtifact(
                artifact: NativeAudioArtifact(
                    url: URL(fileURLWithPath: "/preview-audit/no-audio.mp3"),
                    format: capabilities.outputFormat,
                    purpose: .reading(.speak)
                ),
                cleanup: {}
            )
        ) {
            try await synthesizeAudited(request, credential: credential)
        }
    }

    private func synthesizeAudited(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact {
        try Task.checkCancellation()
        let envelope = try envelope(from: credential, expectedRevision: request.credentialScopeRevision)
        guard request.selection.modelID == MiniMaxWireContractV1.modelID,
              request.selection.providerID == .minimax,
              request.outputFormatID == MiniMaxWireContractV1.outputFormatID,
              request.controls.mappingVersion == MiniMaxRateMappingV1.version,
              request.controls == (try MiniMaxRateMappingV1.controls(for: request.selection.rate)) else {
            if let stableVoice = request.selection.voiceID,
               let reason = MiniMaxVoiceCatalogV1.disabledReasons[stableVoice] {
                throw MiniMaxProviderError.disabledSelection(reason)
            }
            throw MiniMaxProviderError.invalidRequest
        }
        guard let stableVoice = request.selection.voiceID,
              let wireVoice = await voiceDirectory.resolve(
                stableVoice, revision: envelope.revision
              ) else {
            throw MiniMaxProviderError.unsupportedSelection
        }
        guard let key = String(data: envelope.secret, encoding: .utf8), !key.isEmpty else {
            throw MiniMaxProviderError.credentialMissing
        }

        let speed = MiniMaxRateMappingV1.speed(for: request.selection.rate)
        let body = MiniMaxRequestBody(
            model: MiniMaxWireContractV1.modelID.rawValue,
            text: request.chunk.text,
            stream: false,
            languageBoost: "Chinese",
            outputFormat: "hex",
            voiceSetting: .init(
                voiceID: wireVoice.voiceID, speed: speed, volume: 1, pitch: 0,
                emotion: wireVoice.emotion
            ),
            audioSetting: .init(sampleRate: 32_000, bitrate: 128_000, format: "mp3")
        )
        var urlRequest = URLRequest(url: MiniMaxWireContractV1.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { urlRequest.httpBody = try encoder.encode(body) }
        catch { throw MiniMaxProviderError.invalidRequest }

        let response: MiniMaxHTTPResponse
        do { response = try await httpClient.send(urlRequest) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MiniMaxProviderError.transport }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw MiniMaxProviderError.httpStatus(response.statusCode)
        }
        let decoded: MiniMaxResponseEnvelope
        do { decoded = try JSONDecoder().decode(MiniMaxResponseEnvelope.self, from: response.body) }
        catch { throw MiniMaxProviderError.invalidResponse }
        if let error = MiniMaxErrorClassifier.response(decoded) { throw error }
        guard let hex = decoded.data?.audio,
              let audio = Data(hexString: hex), !audio.isEmpty else {
            throw MiniMaxProviderError.audioMissing
        }
        try Task.checkCancellation()

        let output = nativeDirectory.appendingPathComponent("aloud-minimax-native-\(UUID().uuidString).mp3")
        do {
            try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
            try audio.write(to: output, options: [.atomic])
            try Task.checkCancellation()
            return OwnedNativeAudioArtifact(
                artifact: NativeAudioArtifact(
                    url: output, format: capabilities.outputFormat, purpose: .reading(.speak)
                )
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw MiniMaxProviderError.nativeWriteFailed
        }
    }

    private func validate(_ selection: ProviderSelection) async throws {
        guard selection.providerID == .minimax,
              selection.modelID == MiniMaxWireContractV1.modelID,
              let voice = selection.voiceID else {
            throw MiniMaxProviderError.unsupportedSelection
        }
        if let reason = MiniMaxVoiceCatalogV1.disabledReasons[voice] {
            throw MiniMaxProviderError.disabledSelection(reason)
        }
        if MiniMaxVoiceCatalogV1.availableMapping[voice] != nil { return }
        guard await voiceDirectory.containsInCurrentCatalog(voice) else {
            throw MiniMaxProviderError.unsupportedSelection
        }
    }

    private func voiceCandidates(
        from response: MiniMaxGetVoiceResponse
    ) throws -> [MiniMaxVoiceCandidate] {
        let groups: [(MiniMaxVoiceKind, [MiniMaxGetVoiceResponse.Entry])] = [
            (.system, response.systemVoices),
            (.cloned, response.clonedVoices),
            (.generated, response.generatedVoices),
        ]
        var candidates: [MiniMaxVoiceCandidate] = []
        for (kind, entries) in groups {
            for entry in entries {
                guard !entry.voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MiniMaxProviderError.invalidResponse
                }
                let name = entry.voiceName?.trimmingCharacters(in: .whitespacesAndNewlines)
                candidates.append(MiniMaxVoiceCandidate(
                    kind: kind,
                    wireID: entry.voiceID,
                    displayName: name?.isEmpty == false ? name : nil
                ))
            }
        }
        return candidates
    }

    private func accountSnapshot(
        voices: [MiniMaxVoiceDescriptor], revision: UUID
    ) throws -> AccountCatalogSnapshot {
        let scope = try RelationshipScope(
            providerID: .minimax,
            credentialRevision: revision,
            contractVersion: MiniMaxWireContractV1.version,
            parentModelID: MiniMaxWireContractV1.modelID,
            controlsSchema: MiniMaxRateMappingV1.version,
            queryParameters: ["voice_type": "all"]
        )
        let refreshID = CatalogRefreshID(rawValue: UUID())
        let fetchedAt = Date()
        let authoritySource = MiniMaxVoiceManagementContractV1.endpoint.absoluteString
        let voiceIDs = Set(voices.map(\.stableID)).subtracting(
            MiniMaxVoiceCatalogV1.contractOwnedResources.builtInVoices
        )
        let voiceKey = AccountResourceKey(
            dimension: .voice, parentModelID: MiniMaxWireContractV1.modelID
        )
        let voiceEvidence = AccountResourceEvidence(
            scopeRevision: revision,
            contractVersion: MiniMaxWireContractV1.version,
            fetchedAt: fetchedAt,
            refreshID: refreshID,
            authoritySource: authoritySource,
            coverage: .authoritativeComplete,
            values: voiceIDs
        )
        let relationships = Set(voiceIDs.map {
            AccountRelationshipTuple(
                modelID: MiniMaxWireContractV1.modelID,
                voiceID: $0,
                controlsID: nil,
                controlsVersion: nil
            )
        })
        let relationshipEvidence = AccountRelationshipEvidence(
            scope: scope,
            scopeRevision: revision,
            contractVersion: MiniMaxWireContractV1.version,
            fetchedAt: fetchedAt,
            refreshID: refreshID,
            authoritySource: authoritySource,
            coverage: .authoritativeComplete,
            paginationComplete: true,
            values: relationships,
            rejections: []
        )
        return AccountCatalogSnapshot(
            voiceEvidence: [scope: [voiceKey: voiceEvidence]],
            relationshipEvidence: [scope: relationshipEvidence]
        )
    }

    private func envelope(from credential: ProviderCredential, expectedRevision: UUID?) throws -> CredentialEnvelope {
        guard case let .apiKey(providerID, envelope) = credential else {
            throw MiniMaxProviderError.credentialMissing
        }
        guard providerID == .minimax, envelope.providerID == .minimax else {
            throw MiniMaxProviderError.credentialMismatch
        }
        if let expectedRevision, envelope.revision != expectedRevision {
            throw MiniMaxProviderError.credentialMismatch
        }
        return envelope
    }
}

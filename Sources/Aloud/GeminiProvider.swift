import Foundation

enum GeminiAuthRoute: Equatable, Sendable { case manualAPIKey }
enum GeminiCardAction: Equatable, Sendable { case saveManualAPIKey, preview }
enum GeminiReleaseBlockReason: Equatable, Sendable {
    case featureFlagDisabled
    case releaseApprovalRequired
    case contractEvidenceMissing
    case realE2EEvidenceMissing
}

struct GeminiReleaseEvaluation: Equatable, Sendable {
    let availability: ProviderAvailabilityKind
    let permitsSynthesis: Bool
    let isDisplayed: Bool
    let includedInProviderTotals: Bool
    let blockReason: GeminiReleaseBlockReason?
}

struct GeminiReleaseGate: Sendable {
    let featureFlag: Bool
    let releaseApproved: Bool
    let catalogEvidence: CatalogValidatedEvidence?
    let realE2EEvidenceID: String?

    let authRoute = GeminiAuthRoute.manualAPIKey
    let cardActions: [GeminiCardAction] = [.saveManualAPIKey, .preview]
    let billingText = "费用计入 API Key 关联的 Google Cloud 项目，不是 Gemini 网页订阅。"

    /// Shipping configuration is intentionally fail-closed. Release approval and
    /// real end-to-end evidence require a later explicit product integration and
    /// cannot be populated from preferences or arbitrary runtime strings.
    static func production(
        featureFlags: FeatureFlags,
        catalog: ProviderContractCatalog
    ) -> GeminiReleaseGate {
        GeminiReleaseGate(
            featureFlag: featureFlags.geminiExperimentalEnabled,
            releaseApproved: false,
            catalogEvidence: catalog.validatedEvidence(
                providerID: .gemini,
                modelID: GeminiWireContractV1.modelID
            ),
            realE2EEvidenceID: nil
        )
    }

    func evaluate() -> GeminiReleaseEvaluation {
        let reason: GeminiReleaseBlockReason?
        if !featureFlag { reason = .featureFlagDisabled }
        else if !releaseApproved { reason = .releaseApprovalRequired }
        else if !GeminiWireContractV1.matches(catalogEvidence) { reason = .contractEvidenceMissing }
        else if realE2EEvidenceID?.isEmpty != false { reason = .realE2EEvidenceMissing }
        else { reason = nil }
        return GeminiReleaseEvaluation(
            availability: .experimental,
            permitsSynthesis: reason == nil,
            isDisplayed: true,
            includedInProviderTotals: featureFlag,
            blockReason: reason
        )
    }
}

struct GeminiHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

protocol GeminiHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> GeminiHTTPResponse
}

struct URLSessionGeminiHTTPClient: GeminiHTTPClient {
    func send(_ request: URLRequest) async throws -> GeminiHTTPResponse {
        try await PreviewAccessAudit.access(
            .network,
            auditedValue: GeminiHTTPResponse(statusCode: 200, body: Data())
        ) {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GeminiProviderError.invalidResponse
            }
            return GeminiHTTPResponse(statusCode: http.statusCode, body: data)
        }
    }
}

enum GeminiWireContractV1 {
    static let modelID = ModelID(rawValue: "gemini-2.5-pro-preview-tts")
    static let endpoint = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro-preview-tts:generateContent"
    )!
    static let version = ContractVersion(rawValue: "gemini-generate-content-2.5-v1")
    /// The current overview is tracked for drift, while the route-specific page below
    /// is the controlled source for the phase-one generateContent wire contract.
    static let currentCanonicalDocsURL = URL(
        string: "https://ai.google.dev/gemini-api/docs/speech-generation"
    )!
    static let evidenceSourceURL = URL(
        string: "https://ai.google.dev/gemini-api/docs/generate-content/speech-generation"
    )!
    static let controlledEvidenceSnapshot =
        "model|gemini|gemini-2.5-pro-preview-tts|availability=experimental;endpoint=/v1beta/models/gemini-2.5-pro-preview-tts:generateContent;inputTokens=8192;output=pcm-s16le-24000-mono"
    static let requiredEvidenceDigest = "237bcae7c97b83dbd1dfa274c83abf811a12f00f9e80642428cf6fb25d0da006"
    static let outputFormatID = "pcm-s16le-24000-mono-v1"
    static let inputTokenLimit = 8_192
    static let requestOverhead = RequestOverhead(
        instruction: "Synthesize the transcript exactly as written.",
        style: "Transcript:",
        rate: "Pace: very slowly and deliberately."
    )
    static let capabilities: ProviderCapabilities = {
        let conservative = try! InputLimit(
            endpoint: "/v1beta/models/gemini-2.5-pro-preview-tts:generateContent:input",
            unit: .conservativeTokens,
            maximum: inputTokenLimit,
            safetyMargin: 64,
            contractVersion: version
        )
        return try! ProviderCapabilities(
            inputLimits: [conservative],
            outputFormat: .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true),
            contractVersion: version,
            requestOverhead: requestOverhead
        )
    }()

    static func matches(_ validated: CatalogValidatedEvidence?) -> Bool {
        guard let validated else { return false }
        return validated.providerID == .gemini &&
            validated.modelID == modelID &&
            validated.kind == .model &&
            validated.snapshot == controlledEvidenceSnapshot &&
            validated.evidence.sourceURL == evidenceSourceURL &&
            validated.evidence.evidenceDigest == requiredEvidenceDigest &&
            validated.evidence.contractVersion == ContractVersion(rawValue: "provider-contracts-v1")
    }
}

enum GeminiVoiceCatalogV1 {
    static let voices: Set<VoiceID> = [
        "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede",
        "Callirrhoe", "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba",
        "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar",
        "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi",
        "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat",
    ].reduce(into: []) { $0.insert(VoiceID(rawValue: "gemini.\($1)")) }

    static let contractOwnedResources = ContractOwnedResources(
        builtInVoices: voices,
        builtInControls: [CatalogControlsID(rawValue: GeminiRateMappingV1.version)]
    )

    static func wireName(for voiceID: VoiceID) -> String? {
        guard voices.contains(voiceID), voiceID.rawValue.hasPrefix("gemini.") else { return nil }
        return String(voiceID.rawValue.dropFirst("gemini.".count))
    }
}

enum GeminiRateMappingV1 {
    static let version = "gemini-rate-v1"
    static let templateVersion = "gemini-pace-prompt-v1"

    static func directive(for rate: NormalizedRate) throws -> String {
        guard rate.version == version else { throw InputValidationError.invalidLimit }
        switch rate.value {
        case ...(-67): return "very slowly and deliberately"
        case -66 ... -1: return "slowly"
        case 0: return "at a natural pace"
        case 1 ... 66: return "quickly"
        default: return "very quickly"
        }
    }

    static func controls(for rate: NormalizedRate) throws -> SynthesisControls {
        try SynthesisControls(
            renderedFields: [SynthesisControlField(name: "pace", value: directive(for: rate))],
            mappingVersion: version,
            templateVersion: templateVersion
        )
    }
}

private struct GeminiGenerateContentBody: Encodable {
    struct Content: Encodable { let parts: [Part] }
    struct Part: Encodable { let text: String }
    struct GenerationConfig: Encodable {
        struct SpeechConfig: Encodable {
            struct VoiceConfig: Encodable {
                struct PrebuiltVoiceConfig: Encodable { let voiceName: String }
                let prebuiltVoiceConfig: PrebuiltVoiceConfig
            }
            let voiceConfig: VoiceConfig
        }
        let responseModalities: [String]
        let speechConfig: SpeechConfig
    }
    let contents: [Content]
    let generationConfig: GenerationConfig
    let model: String
}

enum GeminiAPIKeyRequestBuilder {
    static func build(
        text: String,
        voiceName: String,
        rate: NormalizedRate,
        apiKey: String
    ) throws -> URLRequest {
        let directive = try GeminiRateMappingV1.directive(for: rate)
        let prompt = "Synthesize the transcript exactly as written. Pace: \(directive).\n\nTranscript:\n\(text)"
        let body = GeminiGenerateContentBody(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(
                responseModalities: ["AUDIO"],
                speechConfig: .init(
                    voiceConfig: .init(
                        prebuiltVoiceConfig: .init(voiceName: voiceName)
                    )
                )
            ),
            model: GeminiWireContractV1.modelID.rawValue
        )
        var request = URLRequest(url: GeminiWireContractV1.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }
}

enum GeminiErrorCategory: Equatable, Sendable {
    case credentialRejected
    case permissionDenied
    case projectNotConfigured
    case unsupportedSelection
    case invalidRequest
    case resourceExhausted
    case serviceUnavailable
    case unknown
}

struct GeminiClassifiedError: Error, Equatable, Sendable {
    let category: GeminiErrorCategory
    let technicalCode: String
    let callToAction: String
    let health: ProviderHealth
    let shouldRejectCredential: Bool
}

extension GeminiClassifiedError: LocalizedError {
    var errorDescription: String? { callToAction }
}

enum GeminiErrorClassifier {
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let reason: String?
            private enum CodingKeys: String, CodingKey { case reason }
        }
        struct Body: Decodable {
            let status: String?
            let details: [Detail]?
        }
        let error: Body
    }

    static func classify(status: Int, body: Data) -> GeminiClassifiedError {
        let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: body).error
        let grpcStatus = decoded?.status?.uppercased()
        let reasons = Set(decoded?.details?.compactMap { $0.reason?.uppercased() } ?? [])
        if status == 400, reasons.contains("API_KEY_INVALID") {
            return result(
                .credentialRejected,
                code: "gemini.credential-rejected",
                action: "Gemini API Key 无效，请检查后重新输入。",
                health: .explicitRejected,
                rejects: true
            )
        }
        if status == 400, grpcStatus == "FAILED_PRECONDITION" {
            return result(
                .projectNotConfigured,
                code: "gemini.project-not-configured",
                action: "请检查 API Key 关联 Google Cloud 项目的地区与计费设置。"
            )
        }
        if status == 400 {
            return result(.invalidRequest, code: "gemini.invalid-request", action: "Gemini 请求未通过服务验证。")
        }
        if status == 403 {
            return result(.permissionDenied, code: "gemini.permission-denied", action: "当前 API Key 或项目没有 Gemini TTS 权限。")
        }
        if status == 404, grpcStatus == "NOT_FOUND" {
            return result(.unsupportedSelection, code: "gemini.selection-not-found", action: "当前 Gemini 模型或音色不可用。")
        }
        if status == 429, grpcStatus == "RESOURCE_EXHAUSTED" {
            return result(.resourceExhausted, code: "gemini.resource-exhausted", action: "稍后重试或检查 Google Cloud 项目用量。")
        }
        if status == 408 || status >= 500 {
            return result(.serviceUnavailable, code: "gemini.service-unavailable", action: "Gemini 服务暂时不可用，请稍后重试。")
        }
        return result(.unknown, code: "gemini.unknown", action: "Gemini 请求失败，请检查项目设置。")
    }

    private static func result(
        _ category: GeminiErrorCategory,
        code: String,
        action: String,
        health: ProviderHealth = .recoverableFailure,
        rejects: Bool = false
    ) -> GeminiClassifiedError {
        GeminiClassifiedError(
            category: category,
            technicalCode: code,
            callToAction: action,
            health: health,
            shouldRejectCredential: rejects
        )
    }
}

enum GeminiProviderError: Error, Equatable, Sendable {
    case releaseBlocked(GeminiReleaseBlockReason)
    case credentialMissing
    case credentialMismatch
    case unsupportedSelection
    case invalidRequest
    case transport
    case classified(GeminiClassifiedError)
    case invalidResponse
    case audioMissing
    case nativeWriteFailed
}

extension GeminiProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .releaseBlocked: return "Gemini 实验功能尚未满足发布条件。"
        case .credentialMissing: return "Gemini 尚未配置 API Key。"
        case .credentialMismatch: return "Gemini 凭据已变化，请重新朗读。"
        case .unsupportedSelection: return "当前 Gemini 模型或音色不可用。"
        case .invalidRequest: return "Gemini 朗读请求未通过本地验证。"
        case .transport: return "无法连接 Gemini。"
        case .classified(let error): return error.localizedDescription
        case .invalidResponse, .audioMissing: return "Gemini 返回了无效音频。"
        case .nativeWriteFailed: return "Gemini 音频暂存失败。"
        }
    }
}

struct GeminiProvider: VoiceProvider {
    let id = ProviderID.gemini
    let capabilities = GeminiWireContractV1.capabilities
    let releaseGate: GeminiReleaseGate
    let httpClient: any GeminiHTTPClient
    let nativeDirectory: URL
    private let afterHTTPReturn: @Sendable () async -> Void
    private let afterNativeWrite: @Sendable () async -> Void

    init(
        releaseGate: GeminiReleaseGate,
        httpClient: any GeminiHTTPClient,
        nativeDirectory: URL,
        afterHTTPReturn: @escaping @Sendable () async -> Void = {},
        afterNativeWrite: @escaping @Sendable () async -> Void = {}
    ) throws {
        self.releaseGate = releaseGate
        self.httpClient = httpClient
        self.nativeDirectory = nativeDirectory
        self.afterHTTPReturn = afterHTTPReturn
        self.afterNativeWrite = afterNativeWrite
    }

    func measureInput(_ text: String, requestOverhead: RequestOverhead) async throws -> InputMeasurement {
        guard requestOverhead == capabilities.requestOverhead else {
            throw InputValidationError.invalidLimit
        }
        return try await InputMeasurement.measure(
            text,
            limits: capabilities.inputLimits,
            requestOverhead: requestOverhead
        )
    }

    func split(_ text: String, selection: ProviderSelection) async throws -> [ValidatedSpeechChunk] {
        try validate(selection)
        return try await ProviderInputSplitter(capabilities: capabilities) { text, overhead in
            try await measureInput(text, requestOverhead: overhead)
        }.split(text)
    }

    func loadCatalog(using credential: ProviderCredential) async throws -> AccountCatalogSnapshot {
        _ = try envelope(from: credential, expectedRevision: nil)
        return .empty
    }

    func synthesize(
        _ request: SpeechRequest,
        credential: ProviderCredential
    ) async throws -> OwnedNativeAudioArtifact {
        try await PreviewAccessAudit.access(
            .provider,
            auditedValue: OwnedNativeAudioArtifact(
                artifact: NativeAudioArtifact(
                    url: URL(fileURLWithPath: "/preview-audit/no-gemini-audio.pcm"),
                    format: capabilities.outputFormat,
                    purpose: .reading(.speak)
                ),
                cleanup: {}
            )
        ) {
            try await synthesizeAudited(request, credential: credential)
        }
    }

    private func synthesizeAudited(
        _ request: SpeechRequest,
        credential: ProviderCredential
    ) async throws -> OwnedNativeAudioArtifact {
        try Task.checkCancellation()
        let release = releaseGate.evaluate()
        guard release.permitsSynthesis else {
            throw GeminiProviderError.releaseBlocked(release.blockReason!)
        }
        try validate(request.selection)
        guard request.outputFormatID == GeminiWireContractV1.outputFormatID,
              request.controls == (try GeminiRateMappingV1.controls(for: request.selection.rate)),
              let voiceID = request.selection.voiceID,
              let voiceName = GeminiVoiceCatalogV1.wireName(for: voiceID) else {
            throw GeminiProviderError.invalidRequest
        }
        let envelope = try envelope(from: credential, expectedRevision: request.credentialScopeRevision)
        guard let key = String(data: envelope.secret, encoding: .utf8), !key.isEmpty else {
            throw GeminiProviderError.credentialMissing
        }
        let urlRequest: URLRequest
        do {
            urlRequest = try GeminiAPIKeyRequestBuilder.build(
                text: request.chunk.text,
                voiceName: voiceName,
                rate: request.selection.rate,
                apiKey: key
            )
        } catch {
            throw GeminiProviderError.invalidRequest
        }

        let response: GeminiHTTPResponse
        do { response = try await httpClient.send(urlRequest) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GeminiProviderError.transport }
        await afterHTTPReturn()
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw GeminiProviderError.classified(
                GeminiErrorClassifier.classify(status: response.statusCode, body: response.body)
            )
        }
        let audio = try Self.decodeAudio(response.body)
        try Task.checkCancellation()

        let output = nativeDirectory.appendingPathComponent("aloud-gemini-native-\(UUID().uuidString).pcm")
        do {
            try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
            try audio.write(to: output, options: [.atomic])
            await afterNativeWrite()
            try Task.checkCancellation()
            return OwnedNativeAudioArtifact(
                artifact: NativeAudioArtifact(
                    url: output,
                    format: capabilities.outputFormat,
                    purpose: .reading(.speak)
                )
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw GeminiProviderError.nativeWriteFailed
        }
    }

    private static func decodeAudio(_ body: Data) throws -> Data {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        struct InlineData: Decodable { let mimeType: String; let data: String }
                        let inlineData: InlineData?
                    }
                    let parts: [Part]
                }
                let content: Content?
            }
            let candidates: [Candidate]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: body),
              let inline = decoded.candidates.first?.content?.parts.compactMap(\.inlineData).first,
              inline.mimeType.lowercased().replacingOccurrences(of: " ", with: "") == "audio/l16;codec=pcm;rate=24000",
              let audio = Data(base64Encoded: inline.data),
              !audio.isEmpty,
              audio.count.isMultiple(of: 2) else {
            throw GeminiProviderError.invalidResponse
        }
        return audio
    }

    private func validate(_ selection: ProviderSelection) throws {
        guard selection.providerID == .gemini,
              selection.modelID == GeminiWireContractV1.modelID,
              selection.rate.version == GeminiRateMappingV1.version,
              let voice = selection.voiceID,
              GeminiVoiceCatalogV1.voices.contains(voice) else {
            throw GeminiProviderError.unsupportedSelection
        }
    }

    private func envelope(
        from credential: ProviderCredential,
        expectedRevision: UUID?
    ) throws -> CredentialEnvelope {
        guard case let .apiKey(providerID, envelope) = credential else {
            throw GeminiProviderError.credentialMissing
        }
        guard providerID == .gemini, envelope.providerID == .gemini else {
            throw GeminiProviderError.credentialMismatch
        }
        if let expectedRevision, envelope.revision != expectedRevision {
            throw GeminiProviderError.credentialMismatch
        }
        return envelope
    }
}

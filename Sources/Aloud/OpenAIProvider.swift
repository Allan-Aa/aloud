import Foundation

enum OpenAIDisclosurePolicy {
    static let version = 1
    static let text = "此声音由 AI 生成，并非真人声音。"
}

struct OpenAIDisclosureEvaluation: Equatable, Sendable {
    let blocksSynthesis: Bool
    let disclosureVisible: Bool
    let disclosureText: String
}

enum OpenAIDisclosureGate {
    static func evaluate(
        modelID: ModelID,
        voiceID: VoiceID,
        ack: OpenAIDisclosureAck?,
        purpose: SpeechPurpose
    ) -> OpenAIDisclosureEvaluation {
        let accepted = ack?.matches(
            policyVersion: OpenAIDisclosurePolicy.version,
            modelID: modelID,
            voiceID: voiceID
        ) == true
        return OpenAIDisclosureEvaluation(
            blocksSynthesis: !accepted,
            disclosureVisible: true,
            disclosureText: OpenAIDisclosurePolicy.text
        )
    }

    static func confirm(
        modelID: ModelID,
        voiceID: VoiceID,
        explicitlyAccepted: Bool
    ) -> OpenAIDisclosureAck? {
        guard explicitlyAccepted else { return nil }
        return OpenAIDisclosureAck(
            policyVersion: OpenAIDisclosurePolicy.version,
            modelID: modelID,
            voiceID: voiceID
        )
    }
}

enum OpenAIDisclosureAuthorizationError: Error, Equatable, Sendable {
    case acknowledgementRequired(OpenAIDisclosureEvaluation)
}

/// Transaction seam used by Speak and Preview entry points. It reads the same
/// persisted prefs object used by the UI, blocks the operation before its
/// closure runs, and saves only the exact non-secret acknowledgement tuple.
actor OpenAIDisclosureCoordinator {
    private let store: ProviderSettingsStore
    private let beforeAuthorizationRead: @Sendable () async -> Void

    init(store: ProviderSettingsStore, beforeAuthorizationRead: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.beforeAuthorizationRead = beforeAuthorizationRead
    }

    func performIfAuthorized<Output: Sendable>(
        modelID: ModelID,
        voiceID: VoiceID,
        purpose: SpeechPurpose,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        await beforeAuthorizationRead()
        let prefs = await store.prefsSnapshot()
        let evaluation = OpenAIDisclosureGate.evaluate(
            modelID: modelID,
            voiceID: voiceID,
            ack: prefs.openAIDisclosureAck,
            purpose: purpose
        )
        guard !evaluation.blocksSynthesis else {
            throw OpenAIDisclosureAuthorizationError.acknowledgementRequired(evaluation)
        }
        return try await operation()
    }

    func confirm(
        modelID: ModelID,
        voiceID: VoiceID,
        explicitlyAccepted: Bool
    ) async throws -> OpenAIDisclosureAck? {
        guard let ack = OpenAIDisclosureGate.confirm(
            modelID: modelID,
            voiceID: voiceID,
            explicitlyAccepted: explicitlyAccepted
        ) else { return nil }
        try await store.persistOpenAIDisclosureAck(ack)
        return ack
    }
}

struct OpenAIHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
    let retryAfter: Duration?

    init(statusCode: Int, body: Data, retryAfter: Duration? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.retryAfter = retryAfter
    }
}

protocol OpenAIHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse
}

struct URLSessionOpenAIHTTPClient: OpenAIHTTPClient {
    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse {
        try await PreviewAccessAudit.access(
            .network,
            auditedValue: OpenAIHTTPResponse(statusCode: 200, body: Data())
        ) {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAIProviderError.invalidResponse
            }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init)
                .map(Duration.seconds)
            return OpenAIHTTPResponse(
                statusCode: http.statusCode,
                body: data,
                retryAfter: retryAfter
            )
        }
    }
}

enum OpenAIWireContractError: Error, Equatable, Sendable {
    case unsupportedModel
}

enum OpenAIWireContractV1 {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    static let version = ContractVersion(rawValue: "openai-speech-http-v1")
    static let outputFormatID = "openai-wav-v1"
    static let tts1 = ModelID(rawValue: "tts-1")
    static let tts1HD = ModelID(rawValue: "tts-1-hd")
    static let deprecatedGPT = ModelID(rawValue: "gpt-4o-mini-tts")

    static let supportedModels: Set<ModelID> = [tts1, tts1HD]

    static func capabilities(for modelID: ModelID) throws -> ProviderCapabilities {
        guard supportedModels.contains(modelID) || modelID == deprecatedGPT else {
            throw OpenAIWireContractError.unsupportedModel
        }
        // The endpoint calls this a 4,096-character maximum without stating
        // whether characters mean extended graphemes, Unicode scalars, or wire
        // bytes. Until a separately authorized boundary probe resolves that
        // ambiguity, every chunk satisfies all three conservative readings.
        var limits: Set<InputLimit> = try Set([
            InputLimit(
                endpoint: "/v1/audio/speech:input:graphemes",
                unit: .graphemes,
                maximum: 4_096,
                safetyMargin: 0,
                contractVersion: version
            ),
            InputLimit(
                endpoint: "/v1/audio/speech:input:unicode-scalars",
                unit: .unicodeScalars,
                maximum: 4_096,
                safetyMargin: 0,
                contractVersion: version
            ),
            InputLimit(
                endpoint: "/v1/audio/speech:input:utf8-bytes",
                unit: .utf8Bytes,
                maximum: 4_096,
                safetyMargin: 0,
                contractVersion: version
            ),
        ])
        if modelID == deprecatedGPT {
            limits.insert(try InputLimit(
                endpoint: "/v1/audio/speech:gpt-4o-mini-tts-input",
                unit: .conservativeTokens,
                maximum: 2_000,
                safetyMargin: 64,
                contractVersion: version
            ))
        }
        return try ProviderCapabilities(
            inputLimits: limits,
            outputFormat: .encoded(container: "wav", codec: "pcm"),
            contractVersion: version
        )
    }
}

enum OpenAIVoiceCatalogV1 {
    static let voices: Set<VoiceID> = [
        "alloy", "ash", "ballad", "cedar", "coral", "echo", "fable",
        "marin", "nova", "onyx", "sage", "shimmer", "verse",
    ].reduce(into: []) { result, wireID in
        result.insert(VoiceID(rawValue: "openai.\(wireID)"))
    }

    static let contractOwnedResources = ContractOwnedResources(
        builtInVoices: voices,
        builtInControls: [CatalogControlsID(rawValue: OpenAIRateMappingV1.version)]
    )

    static func wireID(for voiceID: VoiceID) -> String? {
        guard voices.contains(voiceID), voiceID.rawValue.hasPrefix("openai.") else { return nil }
        return String(voiceID.rawValue.dropFirst("openai.".count))
    }
}

enum OpenAIRateMappingV1 {
    static let version = "openai-rate-v1"

    static func speed(for rate: NormalizedRate) -> Double {
        if rate.value < 0 {
            return 1 + Double(rate.value) * 0.0075
        }
        return 1 + Double(rate.value) * 0.03
    }

    static func controls(for rate: NormalizedRate) throws -> SynthesisControls {
        guard rate.version == version else { throw InputValidationError.invalidLimit }
        return try SynthesisControls(
            renderedFields: [
                SynthesisControlField(name: "speed", value: canonical(speed(for: rate)))
            ],
            mappingVersion: version,
            templateVersion: nil
        )
    }

    private static func canonical(_ speed: Double) -> String {
        if speed.rounded() == speed { return String(Int(speed)) }
        return String(format: "%.4f", speed)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}

private struct OpenAISpeechRequestBody: Encodable, Sendable {
    let model: String
    let voice: String
    let input: String
    let responseFormat: String
    let speed: Double

    private enum CodingKeys: String, CodingKey {
        case model, voice, input, speed
        case responseFormat = "response_format"
    }
}

enum OpenAIProviderError: Error, Equatable, Sendable {
    case credentialMissing
    case credentialMismatch
    case unsupportedSelection
    case invalidRequest
    case transport
    case httpStatus(Int)
    case classified(OpenAIClassifiedError)
    case invalidResponse
    case nativeWriteFailed
}

extension OpenAIProviderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .credentialMissing: return "OpenAI 尚未配置 API Key。"
        case .credentialMismatch: return "OpenAI 凭据已变化，请重新朗读。"
        case .unsupportedSelection: return "当前 OpenAI 模型或音色不可用。"
        case .invalidRequest: return "OpenAI 朗读请求未通过本地验证。"
        case .transport: return "无法连接 OpenAI。"
        case .httpStatus: return "OpenAI 服务暂时不可用。"
        case .classified(let error): return error.localizedDescription
        case .invalidResponse: return "OpenAI 返回了无效音频。"
        case .nativeWriteFailed: return "OpenAI 音频暂存失败。"
        }
    }
}

struct OpenAIProvider: VoiceProvider {
    let id = ProviderID.openAI
    let modelID: ModelID
    let capabilities: ProviderCapabilities
    let httpClient: any OpenAIHTTPClient
    let nativeDirectory: URL
    private let afterHTTPReturn: @Sendable () async -> Void
    private let afterNativeWrite: @Sendable () async -> Void

    init(
        modelID: ModelID,
        httpClient: any OpenAIHTTPClient,
        nativeDirectory: URL,
        afterHTTPReturn: @escaping @Sendable () async -> Void = {},
        afterNativeWrite: @escaping @Sendable () async -> Void = {}
    ) throws {
        guard OpenAIWireContractV1.supportedModels.contains(modelID) else {
            throw OpenAIProviderError.unsupportedSelection
        }
        self.modelID = modelID
        self.capabilities = try OpenAIWireContractV1.capabilities(for: modelID)
        self.httpClient = httpClient
        self.nativeDirectory = nativeDirectory
        self.afterHTTPReturn = afterHTTPReturn
        self.afterNativeWrite = afterNativeWrite
    }

    func measureInput(
        _ text: String,
        requestOverhead: RequestOverhead
    ) async throws -> InputMeasurement {
        guard requestOverhead == capabilities.requestOverhead else {
            throw InputValidationError.invalidLimit
        }
        return try InputMeasurement.measureTextOnly(text, limits: capabilities.inputLimits)
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
                    url: URL(fileURLWithPath: "/preview-audit/no-openai-audio.wav"),
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
        try validate(request.selection)
        guard request.selection.modelID == modelID,
              request.outputFormatID == OpenAIWireContractV1.outputFormatID,
              request.controls == (try OpenAIRateMappingV1.controls(for: request.selection.rate)),
              let stableVoice = request.selection.voiceID,
              let wireVoice = OpenAIVoiceCatalogV1.wireID(for: stableVoice) else {
            throw OpenAIProviderError.invalidRequest
        }
        let envelope = try envelope(
            from: credential,
            expectedRevision: request.credentialScopeRevision
        )
        guard let key = String(data: envelope.secret, encoding: .utf8), !key.isEmpty else {
            throw OpenAIProviderError.credentialMissing
        }

        let body = OpenAISpeechRequestBody(
            model: modelID.rawValue,
            voice: wireVoice,
            input: request.chunk.text,
            responseFormat: "wav",
            speed: OpenAIRateMappingV1.speed(for: request.selection.rate)
        )
        var urlRequest = URLRequest(url: OpenAIWireContractV1.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { urlRequest.httpBody = try encoder.encode(body) }
        catch { throw OpenAIProviderError.invalidRequest }

        let response: OpenAIHTTPResponse
        do { response = try await httpClient.send(urlRequest) }
        catch is CancellationError { throw CancellationError() }
        catch { throw OpenAIProviderError.transport }
        await afterHTTPReturn()
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 429 {
                throw OpenAIProviderError.classified(OpenAIErrorClassifier.classify(
                    status: response.statusCode,
                    body: response.body,
                    retryAfter: response.retryAfter,
                    contract: .production
                ))
            }
            throw OpenAIProviderError.httpStatus(response.statusCode)
        }
        guard Self.isWAV(response.body) else { throw OpenAIProviderError.invalidResponse }
        try Task.checkCancellation()

        let output = nativeDirectory.appendingPathComponent(
            "aloud-openai-native-\(UUID().uuidString).wav"
        )
        do {
            try FileManager.default.createDirectory(
                at: nativeDirectory,
                withIntermediateDirectories: true
            )
            try response.body.write(to: output, options: [.atomic])
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
            throw OpenAIProviderError.nativeWriteFailed
        }
    }

    private func validate(_ selection: ProviderSelection) throws {
        guard selection.providerID == .openAI,
              selection.modelID == modelID,
              let voice = selection.voiceID,
              OpenAIVoiceCatalogV1.voices.contains(voice),
              selection.rate.version == OpenAIRateMappingV1.version else {
            throw OpenAIProviderError.unsupportedSelection
        }
    }

    private func envelope(
        from credential: ProviderCredential,
        expectedRevision: UUID?
    ) throws -> CredentialEnvelope {
        guard case let .apiKey(providerID, envelope) = credential else {
            throw OpenAIProviderError.credentialMissing
        }
        guard providerID == .openAI, envelope.providerID == .openAI else {
            throw OpenAIProviderError.credentialMismatch
        }
        if let expectedRevision, envelope.revision != expectedRevision {
            throw OpenAIProviderError.credentialMismatch
        }
        return envelope
    }

    private static func isWAV(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.prefix(4) == Data("RIFF".utf8) && data[8..<12] == Data("WAVE".utf8)
    }
}

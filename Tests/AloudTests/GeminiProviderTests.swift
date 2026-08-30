import XCTest
@testable import Aloud

final class GeminiProviderTests: XCTestCase {
    func testClosedReleaseGateBlocksBeforeFakeTransport() async throws {
        let client = RecordingGeminiHTTPClient(results: [])
        let provider = try GeminiProvider(
            releaseGate: GeminiReleaseGate.production(
                featureFlags: .defaults,
                catalog: try ProviderContractCatalog.bundled()
            ),
            httpClient: client,
            nativeDirectory: try GeminiTestDirectory().url
        )
        let revision = UUID()
        let selection = ProviderSelection(
            providerID: .gemini,
            modelID: ModelID(rawValue: "gemini-2.5-pro-preview-tts"),
            voiceID: VoiceID(rawValue: "gemini.Kore"),
            rate: NormalizedRate(version: "gemini-rate-v1", value: 0)!
        )
        let chunks = try await provider.split("x", selection: selection)
        let chunk = try XCTUnwrap(chunks.first)
        let request = try SpeechRequest.make(
            id: SpeechRequestID(rawValue: UUID()),
            selection: selection,
            chunk: chunk,
            controls: GeminiRateMappingV1.controls(for: selection.rate),
            credentialScopeRevision: revision,
            capabilities: provider.capabilities,
            outputFormatID: GeminiWireContractV1.outputFormatID,
            canonicalizerVersion: "canonical-wav-v1"
        )

        await XCTAssertThrowsErrorAsync(
            try await ProviderSynthesisGate(provider: provider).synthesize(
                request,
                credential: .apiKey(
                    providerID: .gemini,
                    envelope: CredentialEnvelope(
                        providerID: .gemini,
                        revision: revision,
                        secret: Data("fixture".utf8)
                    )
                )
            )
        )
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testAllTrueGateSendsExactAPIKeyGenerateContentRequestAndReturnsOwnedPCM() async throws {
        let directory = try GeminiTestDirectory()
        let pcm = Data([0, 1, 2, 3])
        let client = RecordingGeminiHTTPClient(results: [
            .success(.init(statusCode: 200, body: geminiAudioResponse(pcm)))
        ])
        let provider = try openGeminiProvider(client: client, directory: directory.url)
        let revision = UUID()
        let request = try await makeGeminiRequest(provider: provider, revision: revision, text: "公开测试句", rate: 0)
        let key = "fixture-key-\(UUID().uuidString)"
        let artifact = try await ProviderSynthesisGate(provider: provider).synthesize(
            request,
            credential: .apiKey(
                providerID: .gemini,
                envelope: CredentialEnvelope(
                    providerID: .gemini,
                    revision: revision,
                    secret: Data(key.utf8)
                )
            )
        )
        defer { artifact.cleanupIfOwned() }

        let requests = await client.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(sent.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro-preview-tts:generateContent")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-goog-api-key"), key)
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["contents", "generationConfig", "model"])
        XCTAssertEqual(object["model"] as? String, "gemini-2.5-pro-preview-tts")
        let generation = try XCTUnwrap(object["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let prompt = try XCTUnwrap(parts.first?["text"] as? String)
        XCTAssertEqual(prompt, "Synthesize the transcript exactly as written. Pace: at a natural pace.\n\nTranscript:\n公开测试句")
        XCTAssertEqual(artifact.format, .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true))
        XCTAssertEqual(try Data(contentsOf: artifact.url), pcm)
    }

    func testResponseParserRejectsWrongMimeMalformedBase64OddOrMissingAudioWithoutTemp() async throws {
        let bodies = [
            geminiAudioResponse(Data([0, 1]), mimeType: "audio/wav"),
            geminiRawAudioResponse(data: "%%%", mimeType: "audio/L16;codec=pcm;rate=24000"),
            geminiAudioResponse(Data([0]), mimeType: "audio/L16;codec=pcm;rate=24000"),
            Data(#"{"candidates":[{"content":{"parts":[]}}]}"#.utf8),
        ]
        for body in bodies {
            let directory = try GeminiTestDirectory()
            let client = RecordingGeminiHTTPClient(results: [.success(.init(statusCode: 200, body: body))])
            let provider = try openGeminiProvider(client: client, directory: directory.url)
            let revision = UUID()
            let request = try await makeGeminiRequest(provider: provider, revision: revision, text: "x", rate: 0)
            do {
                _ = try await synthesizeGemini(provider: provider, request: request, revision: revision)
                XCTFail("invalid response must fail")
            } catch let error as GeminiProviderError {
                XCTAssertEqual(error, .invalidResponse)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [])
        }
    }

    func testProviderClassifierIsContentFreeAndRejectsOnlyDocumentedInvalidKeyReason() async throws {
        let canary = "gemini-private-\(UUID().uuidString)"
        let fixtures: [(Int, String, String?, GeminiErrorCategory, Bool)] = [
            (400, "INVALID_ARGUMENT", "API_KEY_INVALID", .credentialRejected, true),
            (400, "FAILED_PRECONDITION", nil, .projectNotConfigured, false),
            (403, "PERMISSION_DENIED", nil, .permissionDenied, false),
            (404, "NOT_FOUND", nil, .unsupportedSelection, false),
            (429, "RESOURCE_EXHAUSTED", nil, .resourceExhausted, false),
            (503, "UNAVAILABLE", nil, .serviceUnavailable, false),
        ]
        for (statusCode, status, reason, expected, rejects) in fixtures {
            let directory = try GeminiTestDirectory()
            let body = geminiErrorResponse(status: status, reason: reason, message: canary)
            let client = RecordingGeminiHTTPClient(results: [.success(.init(statusCode: statusCode, body: body))])
            let provider = try openGeminiProvider(client: client, directory: directory.url)
            let revision = UUID()
            let request = try await makeGeminiRequest(provider: provider, revision: revision, text: "x", rate: 0)
            do {
                _ = try await synthesizeGemini(provider: provider, request: request, revision: revision)
                XCTFail("HTTP error must classify")
            } catch GeminiProviderError.classified(let classified) {
                XCTAssertEqual(classified.category, expected)
                XCTAssertEqual(classified.shouldRejectCredential, rejects)
                XCTAssertFalse(classified.technicalCode.contains(canary))
                XCTAssertFalse(classified.callToAction.contains(canary))
                XCTAssertFalse(classified.localizedDescription.contains(canary))
            }
            let requestCount = await client.requestCount()
            XCTAssertEqual(requestCount, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [])
        }
    }

    func testMissingCredentialAndUnsupportedModelOrVoiceFailBeforeTransport() async throws {
        let directory = try GeminiTestDirectory()
        let client = RecordingGeminiHTTPClient(results: [])
        let provider = try openGeminiProvider(client: client, directory: directory.url)
        let revision = UUID()
        let validRequest = try await makeGeminiRequest(provider: provider, revision: revision, text: "x", rate: 0)
        await XCTAssertThrowsErrorAsync(
            try await ProviderSynthesisGate(provider: provider).synthesize(validRequest, credential: .none)
        )

        for selection in [
            ProviderSelection(
                providerID: .gemini,
                modelID: ModelID(rawValue: "unknown-model"),
                voiceID: VoiceID(rawValue: "gemini.Kore"),
                rate: NormalizedRate(version: GeminiRateMappingV1.version, value: 0)!
            ),
            ProviderSelection(
                providerID: .gemini,
                modelID: GeminiWireContractV1.modelID,
                voiceID: VoiceID(rawValue: "gemini.Unknown"),
                rate: NormalizedRate(version: GeminiRateMappingV1.version, value: 0)!
            ),
        ] {
            await XCTAssertThrowsErrorAsync(try await provider.split("x", selection: selection))
        }
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [])
    }

    func testCredentialProviderOrRevisionMismatchFailsBeforeTransport() async throws {
        let client = RecordingGeminiHTTPClient(results: [])
        let provider = try openGeminiProvider(client: client, directory: try GeminiTestDirectory().url)
        let revision = UUID()
        let request = try await makeGeminiRequest(provider: provider, revision: revision, text: "x", rate: 0)
        let credentials = [
            ProviderCredential.apiKey(
                providerID: .openAI,
                envelope: CredentialEnvelope(providerID: .openAI, revision: revision, secret: Data("fixture".utf8))
            ),
            ProviderCredential.apiKey(
                providerID: .gemini,
                envelope: CredentialEnvelope(providerID: .gemini, revision: UUID(), secret: Data("fixture".utf8))
            ),
        ]
        for credential in credentials {
            do {
                _ = try await ProviderSynthesisGate(provider: provider).synthesize(request, credential: credential)
                XCTFail("credential mismatch must fail")
            } catch let error as GeminiProviderError {
                XCTAssertEqual(error, .credentialMismatch)
            }
        }
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testCancellationAfterHTTPReturnAndNativeWriteLeavesNoTemp() async throws {
        for window in GeminiCancellationWindow.allCases {
            let directory = try GeminiTestDirectory()
            let barrier = GeminiAsyncBarrier()
            let client = RecordingGeminiHTTPClient(results: [
                .success(.init(statusCode: 200, body: geminiAudioResponse(Data([0, 1]))))
            ])
            let gate = openGeminiReleaseGate()
            let provider: GeminiProvider
            switch window {
            case .afterHTTPReturn:
                provider = try GeminiProvider(
                    releaseGate: gate,
                    httpClient: client,
                    nativeDirectory: directory.url,
                    afterHTTPReturn: { await barrier.reach() }
                )
            case .afterNativeWrite:
                provider = try GeminiProvider(
                    releaseGate: gate,
                    httpClient: client,
                    nativeDirectory: directory.url,
                    afterNativeWrite: { await barrier.reach() }
                )
            }
            let revision = UUID()
            let request = try await makeGeminiRequest(provider: provider, revision: revision, text: "x", rate: 0)
            let task = Task { try await synthesizeGemini(provider: provider, request: request, revision: revision) }
            await barrier.waitUntilReached()
            task.cancel()
            await barrier.release()
            await XCTAssertThrowsErrorAsync(try await task.value)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [], "window=\(window)")
        }
    }

    func testTokenLimitRateFingerprintsVoicesAndCatalogContracts() async throws {
        let provider = try openGeminiProvider(
            client: RecordingGeminiHTTPClient(results: []),
            directory: try GeminiTestDirectory().url
        )
        let tokenLimit = try XCTUnwrap(provider.capabilities.inputLimits.first)
        XCTAssertEqual(tokenLimit.unit, .conservativeTokens)
        XCTAssertEqual(tokenLimit.maximum, 8_192)
        XCTAssertGreaterThan(tokenLimit.safetyMargin, 0)
        XCTAssertEqual(GeminiVoiceCatalogV1.voices.count, 30)
        XCTAssertEqual(try GeminiRateMappingV1.directive(for: .init(version: "gemini-rate-v1", value: -100)!), "very slowly and deliberately")
        XCTAssertEqual(try GeminiRateMappingV1.directive(for: .init(version: "gemini-rate-v1", value: 0)!), "at a natural pace")
        XCTAssertEqual(try GeminiRateMappingV1.directive(for: .init(version: "gemini-rate-v1", value: 100)!), "very quickly")
        let revision = UUID()
        let fingerprints = try await [-100, 0, 100].asyncMap {
            try await makeGeminiRequest(provider: provider, revision: revision, text: "x", rate: $0).requestFingerprint
        }
        XCTAssertEqual(Set(fingerprints).count, 3)
        let catalog = try await provider.loadCatalog(
            using: .apiKey(
                providerID: .gemini,
                envelope: CredentialEnvelope(providerID: .gemini, revision: revision, secret: Data("fixture".utf8))
            )
        )
        XCTAssertEqual(catalog, .empty)
        let bundled = try ProviderContractCatalog.bundled()
        XCTAssertEqual(bundled.providerAvailability(for: .gemini).maturity, .preview)
        XCTAssertEqual(bundled.contract(for: .gemini)?.nativeAudio.container, "pcm")
        XCTAssertEqual(bundled.contract(for: .gemini)?.nativeAudio.sampleRate, 24_000)
    }

    func testConservativeTokenSplitterPreservesGraphemeBoundariesAndEveryChunkProof() async throws {
        let provider = try openGeminiProvider(
            client: RecordingGeminiHTTPClient(results: []),
            directory: try GeminiTestDirectory().url
        )
        let pattern = "你e\u{301}😀👨‍👩‍👧‍👦"
        let text = String(repeating: pattern, count: 600)
        let selection = ProviderSelection(
            providerID: .gemini,
            modelID: GeminiWireContractV1.modelID,
            voiceID: VoiceID(rawValue: "gemini.Kore"),
            rate: NormalizedRate(version: GeminiRateMappingV1.version, value: 0)!
        )
        let chunks = try await provider.split(text, selection: selection)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        for chunk in chunks {
            for (limit, value) in chunk.measurements.values {
                XCTAssertLessThanOrEqual(value, limit.maximum)
            }
        }
        let originalGraphemes = Array(text)
        let splitGraphemes = chunks.flatMap { Array($0.text) }
        XCTAssertEqual(splitGraphemes, originalGraphemes)
    }
}

private func geminiProviderCatalogEvidence() -> CatalogValidatedEvidence {
    try! XCTUnwrap(
        try! ProviderContractCatalog.bundled().validatedEvidence(
            providerID: .gemini,
            modelID: GeminiWireContractV1.modelID
        )
    )
}

private actor RecordingGeminiHTTPClient: GeminiHTTPClient {
    private var results: [Result<GeminiHTTPResponse, Error>]
    private var requests: [URLRequest] = []
    init(results: [Result<GeminiHTTPResponse, Error>]) { self.results = results }
    func send(_ request: URLRequest) async throws -> GeminiHTTPResponse {
        requests.append(request)
        guard !results.isEmpty else { throw GeminiProviderError.transport }
        return try results.removeFirst().get()
    }
    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [URLRequest] { requests }
}

private enum GeminiCancellationWindow: CaseIterable { case afterHTTPReturn, afterNativeWrite }

private actor GeminiAsyncBarrier {
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func reach() async {
        reached = true
        reachedWaiters.forEach { $0.resume() }
        reachedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private func openGeminiReleaseGate() -> GeminiReleaseGate {
    GeminiReleaseGate(
        featureFlag: true,
        releaseApproved: true,
        catalogEvidence: geminiProviderCatalogEvidence(),
        realE2EEvidenceID: "gemini-e2e-fixture-v1"
    )
}

private func openGeminiProvider(
    client: RecordingGeminiHTTPClient,
    directory: URL
) throws -> GeminiProvider {
    try GeminiProvider(releaseGate: openGeminiReleaseGate(), httpClient: client, nativeDirectory: directory)
}

private func makeGeminiRequest(
    provider: GeminiProvider,
    revision: UUID,
    text: String,
    rate: Int
) async throws -> SpeechRequest {
    let selection = ProviderSelection(
        providerID: .gemini,
        modelID: GeminiWireContractV1.modelID,
        voiceID: VoiceID(rawValue: "gemini.Kore"),
        rate: NormalizedRate(version: GeminiRateMappingV1.version, value: rate)!
    )
    let chunks = try await provider.split(text, selection: selection)
    return try SpeechRequest.make(
        id: SpeechRequestID(rawValue: UUID()),
        selection: selection,
        chunk: try XCTUnwrap(chunks.first),
        controls: GeminiRateMappingV1.controls(for: selection.rate),
        credentialScopeRevision: revision,
        capabilities: provider.capabilities,
        outputFormatID: GeminiWireContractV1.outputFormatID,
        canonicalizerVersion: "canonical-wav-v1"
    )
}

private func synthesizeGemini(
    provider: GeminiProvider,
    request: SpeechRequest,
    revision: UUID
) async throws -> OwnedNativeAudioArtifact {
    try await ProviderSynthesisGate(provider: provider).synthesize(
        request,
        credential: .apiKey(
            providerID: .gemini,
            envelope: CredentialEnvelope(providerID: .gemini, revision: revision, secret: Data("fixture".utf8))
        )
    )
}

private func geminiAudioResponse(
    _ data: Data,
    mimeType: String = "audio/L16;codec=pcm;rate=24000"
) -> Data {
    geminiRawAudioResponse(data: data.base64EncodedString(), mimeType: mimeType)
}

private func geminiRawAudioResponse(data: String, mimeType: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "candidates": [["content": ["parts": [["inlineData": ["mimeType": mimeType, "data": data]]]]]]
    ], options: [.sortedKeys])
}

private func geminiErrorResponse(status: String, reason: String?, message: String) -> Data {
    var error: [String: Any] = ["code": 400, "message": message, "status": status]
    if let reason { error["details"] = [["reason": reason]] }
    return try! JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys])
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}

private final class GeminiTestDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-gemini-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

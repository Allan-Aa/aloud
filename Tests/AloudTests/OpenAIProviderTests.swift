import XCTest
@testable import Aloud

final class OpenAIProviderTests: XCTestCase {
    func testTTS1UsesOnlyOfficialEndpointCharacterLimitWhileDeprecatedGPTAddsItsOwnTokenLimit() throws {
        let tts1 = try OpenAIWireContractV1.capabilities(for: ModelID(rawValue: "tts-1"))
        XCTAssertEqual(tts1.inputLimits.count, 3)
        XCTAssertEqual(Set(tts1.inputLimits.map(\.unit)), [.graphemes, .unicodeScalars, .utf8Bytes])
        XCTAssertTrue(tts1.inputLimits.allSatisfy { $0.endpoint.hasPrefix("/v1/audio/speech:input:") })
        XCTAssertTrue(tts1.inputLimits.allSatisfy { $0.maximum == 4_096 })

        let hd = try OpenAIWireContractV1.capabilities(for: ModelID(rawValue: "tts-1-hd"))
        XCTAssertEqual(hd.inputLimits, tts1.inputLimits)

        let gpt = try OpenAIWireContractV1.capabilities(for: ModelID(rawValue: "gpt-4o-mini-tts"))
        XCTAssertEqual(gpt.inputLimits.count, 4)
        let modelLimit = try XCTUnwrap(gpt.inputLimits.first { $0.unit == .conservativeTokens })
        XCTAssertEqual(modelLimit.endpoint, "/v1/audio/speech:gpt-4o-mini-tts-input")
        XCTAssertEqual(modelLimit.maximum, 2_000)
        XCTAssertGreaterThan(modelLimit.safetyMargin, 0)

        let catalog = try ProviderContractCatalog.bundled()
        XCTAssertEqual(catalog.modelAvailability(providerID: .openAI, modelID: ModelID(rawValue: "gpt-4o-mini-tts")).kind, .deprecated)
        XCTAssertEqual(catalog.modelAvailability(providerID: .openAI, modelID: ModelID(rawValue: "tts-1")).kind, .available)
        XCTAssertEqual(catalog.modelAvailability(providerID: .openAI, modelID: ModelID(rawValue: "tts-1-hd")).kind, .available)
    }

    func testTTS1SplitsAtEndpointLimitWithoutInventingModelTokenLimit() async throws {
        let provider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"),
            httpClient: RecordingOpenAIHTTPClient(results: []),
            nativeDirectory: try OpenAITestDirectory().url
        )
        let selection = openAISelection(model: "tts-1", voice: "openai.alloy", rate: 0)
        let text = String(repeating: "x", count: 4_097)
        let chunks = try await provider.split(text, selection: selection)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].text.count, 4_096)
        XCTAssertTrue(chunks.allSatisfy { $0.measurements.values.keys.allSatisfy { $0.unit != .conservativeTokens } })
    }

    func testCharacterAmbiguitySplitsCJKCombiningAndEmojiUnderEveryConservativeLimit() async throws {
        let provider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"),
            httpClient: RecordingOpenAIHTTPClient(results: []),
            nativeDirectory: try OpenAITestDirectory().url
        )
        let selection = openAISelection(model: "tts-1", voice: "openai.alloy", rate: 0)
        for unit in ["界", "e\u{301}", "👨‍👩‍👧‍👦"] {
            let text = String(repeating: unit, count: 1_500)
            let chunks = try await provider.split(text, selection: selection)
            XCTAssertEqual(chunks.map(\.text).joined(), text)
            XCTAssertGreaterThan(chunks.count, 1)
            for chunk in chunks {
                XCTAssertTrue(chunk.measurements.values.allSatisfy { limit, value in
                    value <= limit.maximum
                })
            }
        }
    }

    func testAllCurrentOfficialBuiltInVoicesAreAcceptedLocally() async throws {
        let client = RecordingOpenAIHTTPClient(results: [])
        let provider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"), httpClient: client,
            nativeDirectory: try OpenAITestDirectory().url
        )
        let official = [
            "alloy", "ash", "ballad", "cedar", "coral", "echo", "fable",
            "marin", "nova", "onyx", "sage", "shimmer", "verse",
        ]
        for voice in official {
            let chunks = try await provider.split(
                "x",
                selection: openAISelection(model: "tts-1", voice: "openai.\(voice)", rate: 0)
            )
            XCTAssertEqual(chunks.map(\.text), ["x"])
        }
        XCTAssertEqual(OpenAIVoiceCatalogV1.voices.count, 13)
        let requestCount = await client.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testSynthesizeSendsExactSpeechRequestAndReturnsOwnedWAVTemp() async throws {
        let directory = try OpenAITestDirectory()
        let wav = WAVTestFixture.wav(samples: 480)
        let client = RecordingOpenAIHTTPClient(results: [.success(.init(statusCode: 200, body: wav))])
        let provider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"), httpClient: client, nativeDirectory: directory.url
        )
        let revision = UUID()
        let fixtureKey = "fixture-\(UUID().uuidString)"
        let request = try await makeOpenAIRequest(provider: provider, revision: revision, text: "公开测试句", rate: 0)
        let artifact = try await ProviderSynthesisGate(provider: provider).synthesize(
            request,
            credential: .apiKey(
                providerID: .openAI,
                envelope: CredentialEnvelope(providerID: .openAI, revision: revision, secret: Data(fixtureKey.utf8))
            )
        )
        defer { artifact.cleanupIfOwned() }

        let recorded = await client.requests
        let sent = try XCTUnwrap(recorded.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(fixtureKey)")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "tts-1")
        XCTAssertEqual(object["voice"] as? String, "alloy")
        XCTAssertEqual(object["input"] as? String, "公开测试句")
        XCTAssertEqual(object["response_format"] as? String, "wav")
        XCTAssertEqual(object["speed"] as? Double, 1.0)
        XCTAssertEqual(Set(object.keys), ["model", "voice", "input", "response_format", "speed"])
        XCTAssertEqual(artifact.format, .encoded(container: "wav", codec: "pcm"))
        XCTAssertEqual(artifact.url.pathExtension, "wav")
        XCTAssertEqual(try Data(contentsOf: artifact.url), wav)
    }

    func testProviderClassifiesAuthAndRateFailuresWithoutPublishingRawBodyOrTemp() async throws {
        let canary = "task17-provider-private-\(UUID().uuidString)"
        let fixtures: [(status: Int, code: String, expected: OpenAIErrorCategory, rejectsKey: Bool)] = [
            (401, "invalid_api_key", .credentialRejected, true),
            (403, canary, .authConfigurationFailure, false),
            (429, canary, .rateOrQuotaUnknown, false),
        ]
        for fixture in fixtures {
            let directory = try OpenAITestDirectory()
            let body = openAIProviderErrorBody(
                code: fixture.code,
                type: canary,
                message: canary
            )
            let client = RecordingOpenAIHTTPClient(results: [
                .success(.init(statusCode: fixture.status, body: body))
            ])
            let provider = try OpenAIProvider(
                modelID: ModelID(rawValue: "tts-1"),
                httpClient: client,
                nativeDirectory: directory.url
            )
            let revision = UUID()
            let request = try await makeOpenAIRequest(
                provider: provider, revision: revision, text: "x", rate: 0
            )
            let classified: OpenAIClassifiedError
            do {
                let artifact = try await ProviderSynthesisGate(provider: provider).synthesize(
                    request,
                    credential: .apiKey(
                        providerID: .openAI,
                        envelope: CredentialEnvelope(
                            providerID: .openAI,
                            revision: revision,
                            secret: Data("fixture".utf8)
                        )
                    )
                )
                artifact.cleanupIfOwned()
                XCTFail("HTTP failure must not return an owned artifact")
                continue
            } catch OpenAIProviderError.classified(let result) {
                classified = result
            } catch {
                XCTFail("unexpected provider error: \(error)")
                continue
            }

            XCTAssertEqual(classified.category, fixture.expected)
            XCTAssertEqual(classified.shouldRejectCredential, fixture.rejectsKey)
            XCTAssertFalse(classified.technicalCode.contains(canary))
            XCTAssertFalse(classified.callToAction.contains(canary))
            XCTAssertFalse(classified.localizedDescription.contains(canary))
            let recordedRequests = await client.requests
            XCTAssertEqual(recordedRequests.count, 1)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.url.path),
                [],
                "status=\(fixture.status) response body and native temp must stay off disk"
            )
        }
    }

    func testWrongModelOrVoiceFailsBeforeTransport() async throws {
        let client = RecordingOpenAIHTTPClient(results: [])
        let provider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"), httpClient: client,
            nativeDirectory: try OpenAITestDirectory().url
        )
        for selection in [
            openAISelection(model: "tts-1-hd", voice: "openai.alloy", rate: 0),
            openAISelection(model: "tts-1", voice: "openai.fixture-unknown", rate: 0),
        ] {
            do {
                _ = try await provider.split("x", selection: selection)
                XCTFail("selection must fail locally")
            } catch let error as OpenAIProviderError {
                XCTAssertEqual(error, .unsupportedSelection)
            }
        }
        let requestCount = await client.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testCredentialProviderOrRevisionMismatchFailsBeforeTransport() async throws {
        let client = RecordingOpenAIHTTPClient(results: [])
        let provider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"), httpClient: client,
            nativeDirectory: try OpenAITestDirectory().url
        )
        let revision = UUID()
        let request = try await makeOpenAIRequest(
            provider: provider, revision: revision, text: "x", rate: 0
        )
        for credential in [
            ProviderCredential.apiKey(
                providerID: .minimax,
                envelope: CredentialEnvelope(
                    providerID: .minimax, revision: revision, secret: Data("fixture".utf8)
                )
            ),
            ProviderCredential.apiKey(
                providerID: .openAI,
                envelope: CredentialEnvelope(
                    providerID: .openAI, revision: UUID(), secret: Data("fixture".utf8)
                )
            ),
        ] {
            do {
                _ = try await ProviderSynthesisGate(provider: provider).synthesize(
                    request, credential: credential
                )
                XCTFail("credential mismatch must fail")
            } catch let error as OpenAIProviderError {
                XCTAssertEqual(error, .credentialMismatch)
            }
        }
        let requestCount = await client.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testCancellationAfterHTTPReturnAndAfterNativeWriteRemovesEveryTemp() async throws {
        for window in OpenAITask17CancellationWindow.allCases {
            let directory = try OpenAITestDirectory()
            let barrier = OpenAIAsyncBarrier()
            let client = BarrierOpenAIHTTPClient(body: WAVTestFixture.wav(samples: 480))
            let provider: OpenAIProvider
            switch window {
            case .afterHTTPReturn:
                provider = try OpenAIProvider(
                    modelID: ModelID(rawValue: "tts-1"),
                    httpClient: client,
                    nativeDirectory: directory.url,
                    afterHTTPReturn: { await barrier.reach() }
                )
            case .afterNativeWrite:
                provider = try OpenAIProvider(
                    modelID: ModelID(rawValue: "tts-1"),
                    httpClient: client,
                    nativeDirectory: directory.url,
                    afterNativeWrite: { await barrier.reach() }
                )
            }
            let revision = UUID()
            let request = try await makeOpenAIRequest(
                provider: provider, revision: revision, text: "x", rate: 0
            )
            let task = Task {
                try await ProviderSynthesisGate(provider: provider).synthesize(
                    request,
                    credential: .apiKey(
                        providerID: .openAI,
                        envelope: CredentialEnvelope(
                            providerID: .openAI, revision: revision,
                            secret: Data("fixture".utf8)
                        )
                    )
                )
            }
            await barrier.waitUntilReached()
            task.cancel()
            await barrier.release()
            await XCTAssertThrowsErrorAsync(try await task.value)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [],
                "window=\(window)"
            )
        }
    }

    func testRateEndpointsAndFingerprintContractVersionAreExact() async throws {
        XCTAssertEqual(OpenAIRateMappingV1.speed(for: NormalizedRate(version: OpenAIRateMappingV1.version, value: -100)!), 0.25)
        XCTAssertEqual(OpenAIRateMappingV1.speed(for: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!), 1)
        XCTAssertEqual(OpenAIRateMappingV1.speed(for: NormalizedRate(version: OpenAIRateMappingV1.version, value: 100)!), 4)
        let provider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"),
            httpClient: RecordingOpenAIHTTPClient(results: []),
            nativeDirectory: try OpenAITestDirectory().url
        )
        let revision = UUID()
        let slow = try await makeOpenAIRequest(provider: provider, revision: revision, text: "x", rate: -100)
        let normal = try await makeOpenAIRequest(provider: provider, revision: revision, text: "x", rate: 0)
        let fast = try await makeOpenAIRequest(provider: provider, revision: revision, text: "x", rate: 100)
        XCTAssertEqual(slow.controls.mappingVersion, "openai-rate-v1")
        XCTAssertEqual(Set([slow.requestFingerprint, normal.requestFingerprint, fast.requestFingerprint]).count, 3)
    }

    func testCatalogIsCredentialScopedEmptyWhileBuiltInsRemainContractOwned() async throws {
        let provider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"),
            httpClient: RecordingOpenAIHTTPClient(results: []),
            nativeDirectory: try OpenAITestDirectory().url
        )
        let catalog = try await provider.loadCatalog(
            using: .apiKey(
                providerID: .openAI,
                envelope: CredentialEnvelope(
                    providerID: .openAI, revision: UUID(), secret: Data("fixture".utf8)
                )
            )
        )
        XCTAssertEqual(catalog, .empty)
        XCTAssertEqual(OpenAIVoiceCatalogV1.contractOwnedResources.builtInVoices.count, 13)
        XCTAssertEqual(
            OpenAIVoiceCatalogV1.contractOwnedResources.builtInControls,
            [CatalogControlsID(rawValue: OpenAIRateMappingV1.version)]
        )
    }
}

private enum OpenAITask17CancellationWindow: CaseIterable { case afterHTTPReturn, afterNativeWrite }

private actor OpenAIAsyncBarrier {
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

private actor BarrierOpenAIHTTPClient: OpenAIHTTPClient {
    let body: Data
    init(body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse {
        return OpenAIHTTPResponse(statusCode: 200, body: body)
    }
}

private func openAISelection(model: String, voice: String, rate: Int) -> ProviderSelection {
    ProviderSelection(
        providerID: .openAI, modelID: ModelID(rawValue: model), voiceID: VoiceID(rawValue: voice),
        rate: NormalizedRate(version: "openai-rate-v1", value: rate)!
    )
}

private func makeOpenAIRequest(
    provider: OpenAIProvider, revision: UUID, text: String, rate: Int
) async throws -> SpeechRequest {
    let selection = openAISelection(model: provider.modelID.rawValue, voice: "openai.alloy", rate: rate)
    let chunks = try await provider.split(text, selection: selection)
    let chunk = try XCTUnwrap(chunks.first)
    return try SpeechRequest.make(
        id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk,
        controls: OpenAIRateMappingV1.controls(for: selection.rate), credentialScopeRevision: revision,
        capabilities: provider.capabilities, outputFormatID: OpenAIWireContractV1.outputFormatID,
        canonicalizerVersion: "canonical-wav-v1"
    )
}

private func openAIProviderErrorBody(code: String, type: String, message: String) -> Data {
    try! JSONSerialization.data(
        withJSONObject: ["error": ["code": code, "type": type, "message": message]],
        options: [.sortedKeys]
    )
}

private actor RecordingOpenAIHTTPClient: OpenAIHTTPClient {
    private var results: [Result<OpenAIHTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []
    init(results: [Result<OpenAIHTTPResponse, Error>]) { self.results = results }
    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse {
        requests.append(request)
        guard !results.isEmpty else { throw OpenAIProviderError.transport }
        return try results.removeFirst().get()
    }
}

private final class OpenAITestDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("aloud-openai-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

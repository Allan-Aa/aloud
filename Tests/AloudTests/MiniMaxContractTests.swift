import XCTest
@testable import Aloud

final class MiniMaxContractTests: XCTestCase {
    func testStableVoiceIDsRemainMigrationRecognizableButOnlyDefaultVoicesAreAvailable() throws {
        let expected: [String: MiniMaxWireVoice] = [
            "minimax.radio-host.default": .init(voiceID: "Chinese (Mandarin)_Radio_Host", emotion: nil),
            "minimax.radio-host.fluent": .init(voiceID: "Chinese (Mandarin)_Radio_Host", emotion: "fluent"),
            "minimax.laid-back-girl.default": .init(voiceID: "Chinese (Mandarin)_Laid_BackGirl", emotion: nil),
            "minimax.laid-back-girl.fluent": .init(voiceID: "Chinese (Mandarin)_Laid_BackGirl", emotion: "fluent"),
        ]
        XCTAssertEqual(MiniMaxVoiceCatalogV1.migrationMapping, expected.mapKeys(VoiceID.init(rawValue:)))
        XCTAssertEqual(Set(MiniMaxVoiceCatalogV1.availableMapping.keys), [
            VoiceID(rawValue: "minimax.radio-host.default"),
            VoiceID(rawValue: "minimax.laid-back-girl.default"),
        ])
        XCTAssertEqual(MiniMaxVoiceCatalogV1.contractOwnedResources.builtInVoices, Set(MiniMaxVoiceCatalogV1.availableMapping.keys))
        XCTAssertEqual(Set(MiniMaxVoiceCatalogV1.disabledReasons.keys), [
            VoiceID(rawValue: "minimax.radio-host.fluent"),
            VoiceID(rawValue: "minimax.laid-back-girl.fluent"),
        ])
        XCTAssertEqual(Voices.all.map(\.value), [
            "minimax:Chinese (Mandarin)_Radio_Host|default",
            "minimax:Chinese (Mandarin)_Laid_BackGirl|default",
        ])
    }

    func testVersionedWireContractLocksEndpointModelNativeAudioAndEvidenceBackedLimit() throws {
        XCTAssertEqual(MiniMaxWireContractV1.endpoint.absoluteString, "https://api.minimax.io/v1/t2a_v2")
        XCTAssertEqual(MiniMaxWireContractV1.modelID, ModelID(rawValue: "speech-2.8-hd"))
        XCTAssertEqual(MiniMaxWireContractV1.capabilities.contractVersion, ContractVersion(rawValue: "minimax-t2a-http-v1"))
        XCTAssertEqual(MiniMaxWireContractV1.capabilities.outputFormat, .encoded(container: "mp3", codec: "mp3"))
        let limits = MiniMaxWireContractV1.capabilities.inputLimits
        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(Set(limits.map(\.unit)), [.unicodeScalars, .utf8Bytes])
        XCTAssertTrue(limits.allSatisfy { $0.maximum == 9_999 && $0.safetyMargin == 0 })
        XCTAssertEqual(MiniMaxWireContractV1.retryContract.idempotency, .notGuaranteed)
        XCTAssertEqual(MiniMaxWireContractV1.retryContract.maximumAttempts, 1)
        XCTAssertEqual(
            MiniMaxVoiceManagementContractV1.endpoint.absoluteString,
            "https://api.minimax.io/v1/get_voice"
        )
        XCTAssertEqual(MiniMaxVoiceManagementContractV1.maximumResponseBytes, 2_000_000)
    }

    func testRateMappingHasExactClampedWireValuesAndItsVersionChangesFingerprint() async throws {
        let provider = MiniMaxProvider(httpClient: NeverMiniMaxHTTPClient(), nativeDirectory: URL(fileURLWithPath: "/in-memory"))
        let minus = try MiniMaxRateMappingV1.controls(for: XCTUnwrap(NormalizedRate(version: "legacy-minimax-rate-v1", value: -100)))
        let zero = try MiniMaxRateMappingV1.controls(for: XCTUnwrap(NormalizedRate(version: "rate-v1", value: 0)))
        let plus = try MiniMaxRateMappingV1.controls(for: XCTUnwrap(NormalizedRate(version: "anything", value: 100)))
        XCTAssertEqual(minus.renderedFields, [.init(name: "speed", value: "0.5")])
        XCTAssertEqual(zero.renderedFields, [.init(name: "speed", value: "1")])
        XCTAssertEqual(plus.renderedFields, [.init(name: "speed", value: "2")])
        XCTAssertEqual(minus.mappingVersion, "minimax-rate-v1")

        let split = try await provider.split("rate fingerprint", selection: selection(rate: 0))
        let chunk = try XCTUnwrap(split.first)
        let request = try SpeechRequest.make(
            id: SpeechRequestID(rawValue: UUID()), selection: selection(rate: 0), chunk: chunk,
            controls: zero, credentialScopeRevision: UUID(), capabilities: provider.capabilities,
            outputFormatID: MiniMaxWireContractV1.outputFormatID, canonicalizerVersion: "canonical-wav-v1"
        )
        let alternate = try SynthesisControls(
            renderedFields: zero.renderedFields, mappingVersion: "minimax-rate-v2", templateVersion: nil
        )
        let changed = try SpeechRequest.make(
            id: request.id, selection: request.selection, chunk: chunk, controls: alternate,
            credentialScopeRevision: request.credentialScopeRevision, capabilities: provider.capabilities,
            outputFormatID: request.outputFormatID, canonicalizerVersion: request.canonicalizerVersion
        )
        XCTAssertNotEqual(request.requestFingerprint, changed.requestFingerprint)
    }

    func testProviderOwnedMeasurementAndSplitKeepEveryValidatedChunkWithinConcurrentLimit() async throws {
        let provider = MiniMaxProvider(httpClient: NeverMiniMaxHTTPClient(), nativeDirectory: URL(fileURLWithPath: "/in-memory"))
        _ = try await provider.measureInput("x", requestOverhead: provider.capabilities.requestOverhead)
        let samples = [
            String(repeating: "界", count: 10_050),
            String(repeating: "e\u{301}", count: 5_100),
            String(repeating: "👩🏽‍💻", count: 900),
            String(repeating: "a", count: 10_050),
        ]
        for text in samples {
            let chunks = try await provider.split(text, selection: selection(rate: 0))
            XCTAssertGreaterThan(chunks.count, 1)
            XCTAssertEqual(chunks.map(\.text).joined(), text)
            for chunk in chunks {
                XCTAssertNoThrow(try provider.capabilities.validate(chunk.measurements))
                XCTAssertTrue(chunk.measurements.values.allSatisfy { $0.value <= $0.key.maximum })
                XCTAssertLessThanOrEqual(chunk.text.unicodeScalars.count, 9_999)
                XCTAssertLessThanOrEqual(chunk.text.utf8.count, 9_999)
            }
        }
    }

    func testCatalogKeepsBuiltInsInContractLayerAndRejectsWrongProviderBeforeTransport() async throws {
        let provider = MiniMaxProvider(httpClient: NeverMiniMaxHTTPClient(), nativeDirectory: URL(fileURLWithPath: "/in-memory"))
        XCTAssertEqual(MiniMaxVoiceCatalogV1.contractOwnedResources.builtInVoices.count, 2)

        await XCTAssertThrowsErrorAsync(try await provider.loadCatalog(using: .apiKey(
            providerID: .openAI,
            envelope: CredentialEnvelope(providerID: .openAI, revision: UUID(), secret: Data("other".utf8))
        )))
    }
}

private func selection(rate: Int) -> ProviderSelection {
    ProviderSelection(
        providerID: .minimax, modelID: MiniMaxWireContractV1.modelID,
        voiceID: VoiceID(rawValue: "minimax.radio-host.default"),
        rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: rate)!
    )
}

private struct NeverMiniMaxHTTPClient: MiniMaxHTTPClient {
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        XCTFail("contract-only test must not start transport")
        throw MiniMaxProviderError.transport
    }
}

private extension Dictionary where Key == String, Value == MiniMaxWireVoice {
    func mapKeys(_ transform: (String) -> VoiceID) -> [VoiceID: MiniMaxWireVoice] {
        Dictionary<VoiceID, MiniMaxWireVoice>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

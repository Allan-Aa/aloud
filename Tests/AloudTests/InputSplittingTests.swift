import XCTest
@testable import Aloud

final class InputSplittingTests: XCTestCase {
    private let v1 = ContractVersion(rawValue: "v1")
    private func capability(_ limits: Set<InputLimit>, overhead: RequestOverhead = RequestOverhead()) throws -> ProviderCapabilities {
        try ProviderCapabilities(inputLimits: limits, outputFormat: .encoded(container: "wav", codec: "pcm"), contractVersion: v1, requestOverhead: overhead)
    }

    func testSplitterKeepsCJKEmojiCombiningAndZWJGraphemesWithEveryProof() async throws {
        let byte = try InputLimit(endpoint: "tts", unit: .utf8Bytes, maximum: 150, safetyMargin: 0, contractVersion: v1)
        let grapheme = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 80, safetyMargin: 0, contractVersion: v1)
        let caps = try capability([byte, grapheme], overhead: RequestOverhead(instruction: "i", style: "s", rate: "r"))
        let text = "你😀e\u{301}👨‍👩‍👧‍👦Z"
        let chunks = try await ProviderInputSplitter(capabilities: caps).split(text)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { Set($0.measurements.values.keys) == Set([byte, grapheme]) })
        XCTAssertTrue(chunks.allSatisfy { $0.measurements.contractVersion == self.v1 })
    }

    func testMultipleChunksProveEveryConcurrentLimitIncludingTypedOverhead() async throws {
        let bytes = try InputLimit(endpoint: "tts", unit: .utf8Bytes, maximum: 160, safetyMargin: 0, contractVersion: v1)
        let graphemes = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 65, safetyMargin: 0, contractVersion: v1)
        let tokens = try InputLimit(endpoint: "tts", unit: .conservativeTokens, maximum: 162, safetyMargin: 2, contractVersion: v1)
        let overhead = RequestOverhead(instruction: "你", style: "😀", rate: "e\u{301}👨‍👩‍👧‍👦")
        let caps = try capability([bytes, graphemes, tokens], overhead: overhead)
        let text = "你😀e\u{301}👨‍👩‍👧‍👦Z你😀e\u{301}👨‍👩‍👧‍👦Z"
        let chunks = try await ProviderInputSplitter(capabilities: caps).split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        for chunk in chunks {
            XCTAssertNoThrow(try caps.validate(chunk.measurements))
            XCTAssertEqual(Set(chunk.measurements.values.keys), caps.inputLimits)
            XCTAssertTrue(chunk.measurements.values.allSatisfy { $0.value <= $0.key.maximum })
        }
        let instructionChanged = try capability([bytes, graphemes, tokens], overhead: RequestOverhead(instruction: "你x", style: "😀", rate: "e\u{301}👨‍👩‍👧‍👦"))
        let styleChanged = try capability([bytes, graphemes, tokens], overhead: RequestOverhead(instruction: "你", style: "😀x", rate: "e\u{301}👨‍👩‍👧‍👦"))
        let rateChanged = try capability([bytes, graphemes, tokens], overhead: RequestOverhead(instruction: "你", style: "😀", rate: "e\u{301}👨‍👩‍👧‍👦x"))
        let sample = try XCTUnwrap(chunks.first)
        let instructionProof = try await InputMeasurement.measure(sample.text, limits: instructionChanged.inputLimits, requestOverhead: instructionChanged.requestOverhead)
        let styleProof = try await InputMeasurement.measure(sample.text, limits: styleChanged.inputLimits, requestOverhead: styleChanged.requestOverhead)
        let rateProof = try await InputMeasurement.measure(sample.text, limits: rateChanged.inputLimits, requestOverhead: rateChanged.requestOverhead)
        XCTAssertNotEqual(sample.measurements, instructionProof)
        XCTAssertNotEqual(sample.measurements, styleProof)
        XCTAssertNotEqual(sample.measurements, rateProof)
    }

    func testUnbrokenLongGraphemeIsRejectedInsteadOfSplit() async throws {
        let byte = try InputLimit(endpoint: "tts", unit: .utf8Bytes, maximum: 4, safetyMargin: 0, contractVersion: v1)
        await XCTAssertThrowsErrorAsync(try await ProviderInputSplitter(capabilities: try capability([byte])).split("👨‍👩‍👧‍👦"))
    }

    func testRequestFactoryAcceptsOnlyProviderProofAndRecomputesFingerprint() async throws {
        let validLimit = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 50, safetyMargin: 0, contractVersion: v1)
        let validCaps = try capability([validLimit])
        let pieces = try await ProviderInputSplitter(capabilities: validCaps).split("abc")
        let chunk = try XCTUnwrap(pieces.first)
        let selection = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "alloy"), rate: try XCTUnwrap(NormalizedRate(version: "rate-v1", value: 0)))
        let controls = try SynthesisControls(renderedFields: [], mappingVersion: "rate-v1", templateVersion: nil)
        let request = try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk, controls: controls, credentialScopeRevision: UUID(), capabilities: validCaps, outputFormatID: "wav-v1", canonicalizerVersion: "canonical-v1")
        XCTAssertEqual(request.chunk.text, "abc")
        let tooSmall = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 40, safetyMargin: 0, contractVersion: v1)
        XCTAssertThrowsError(try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk, controls: controls, credentialScopeRevision: UUID(), capabilities: try capability([tooSmall]), outputFormatID: "wav-v1", canonicalizerVersion: "canonical-v1"))
    }

    func testGateUsesProtocolMeasurePathAndOnlyCallsSynthesizeForMatchingProof() async throws {
        let limit = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 50, safetyMargin: 0, contractVersion: v1)
        let caps = try capability([limit])
        let provider = GateProvider(capabilities: caps)
        let chunks = try await ProviderInputSplitter(capabilities: caps).split("abc")
        let chunk = try XCTUnwrap(chunks.first)
        let selection = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: nil, rate: try XCTUnwrap(NormalizedRate(version: "rate-v1", value: 0)))
        let request = try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk, controls: try SynthesisControls(renderedFields: [], mappingVersion: "rate-v1", templateVersion: nil), credentialScopeRevision: UUID(), capabilities: caps, outputFormatID: "wav", canonicalizerVersion: "v1")
        _ = try await ProviderSynthesisGate(provider: provider).synthesize(request, credential: .none)
        let firstCalls = await provider.calls()
        XCTAssertEqual(firstCalls, 1)
        await provider.setBadProof(true)
        await XCTAssertThrowsErrorAsync(try await ProviderSynthesisGate(provider: provider).synthesize(request, credential: .none))
        let finalCalls = await provider.calls()
        XCTAssertEqual(finalCalls, 1)
    }

    func testGateRejectsUnsafeTextControlsAndFingerprintMismatchesBeforeSynthesis() async throws {
        let limit = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 50, safetyMargin: 0, contractVersion: v1)
        let caps = try capability([limit])
        let provider = GateProvider(capabilities: caps)
        let chunks = try await ProviderInputSplitter(capabilities: caps).split("abc")
        let alternateChunks = try await ProviderInputSplitter(capabilities: caps).split("xyz")
        let selection = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: nil, rate: try XCTUnwrap(NormalizedRate(version: "rate-v1", value: 0)))
        let request = try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: try XCTUnwrap(chunks.first), controls: try SynthesisControls(renderedFields: [], mappingVersion: "rate-v1", templateVersion: nil), credentialScopeRevision: UUID(), capabilities: caps, outputFormatID: "wav", canonicalizerVersion: "v1")
        let changedText = SpeechRequest.unsafeFixtureForTesting(copying: request, chunk: try XCTUnwrap(alternateChunks.first))
        let changedControls = SpeechRequest.unsafeFixtureForTesting(copying: request, controls: try SynthesisControls(renderedFields: [SynthesisControlField(name: "speed", value: "1")], mappingVersion: "rate-v1", templateVersion: nil))
        let changedFingerprint = SpeechRequest.unsafeFixtureForTesting(copying: request, fingerprint: try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 7, count: 32))))
        for corrupted in [changedText, changedControls, changedFingerprint] {
            await XCTAssertThrowsErrorAsync(try await ProviderSynthesisGate(provider: provider).synthesize(corrupted, credential: .none))
        }
        let calls = await provider.calls()
        XCTAssertEqual(calls, 0)
    }
}

private actor GateProvider: VoiceProvider {
    let id: ProviderID = .openAI
    let capabilities: ProviderCapabilities
    private var synthCalls = 0; private var badProof = false
    init(capabilities: ProviderCapabilities) { self.capabilities = capabilities }
    func measureInput(_ text: String, requestOverhead: RequestOverhead) async throws -> InputMeasurement {
        let proof = try await InputMeasurement.measure(text, limits: capabilities.inputLimits, requestOverhead: requestOverhead)
        if badProof { return try await InputMeasurement.measure(text + "x", limits: capabilities.inputLimits, requestOverhead: requestOverhead) }
        return proof
    }
    func split(_ text: String, selection: ProviderSelection) async throws -> [ValidatedSpeechChunk] { try await ProviderInputSplitter(capabilities: capabilities, measure: { text, overhead in try await self.measureInput(text, requestOverhead: overhead) }).split(text) }
    func loadCatalog(using credential: ProviderCredential) async throws -> AccountCatalogSnapshot { AccountCatalogSnapshot() }
    func synthesize(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact {
        synthCalls += 1
        return OwnedNativeAudioArtifact(
            artifact: NativeAudioArtifact(
                url: URL(fileURLWithPath: "/tmp/fake.wav"),
                format: capabilities.outputFormat,
                purpose: .preview
            ),
            cleanup: {}
        )
    }
    func calls() -> Int { synthCalls }
    func setBadProof(_ value: Bool) { badProof = value }
}

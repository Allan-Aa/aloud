import CryptoKit
import XCTest
@testable import Aloud

final class RequestFingerprintTests: XCTestCase {
    func testU32LengthFramingAt256258And9999DoesNotTrapAndUsesBigEndian() throws {
        for length in [256, 258, 9_999] {
            let value = String(repeating: "x", count: length)
            let encoded = try RequestOverhead(instruction: value).encoded()
            // ALOVHD01 + instruction tag length/value; the instruction value
            // length starts after 8 + 4 + 11 bytes.
            let offset = 8 + 4 + "instruction".utf8.count
            XCTAssertEqual(Array(encoded[offset..<(offset + 4)]), [
                UInt8(truncatingIfNeeded: UInt32(length) >> 24),
                UInt8(truncatingIfNeeded: UInt32(length) >> 16),
                UInt8(truncatingIfNeeded: UInt32(length) >> 8),
                UInt8(truncatingIfNeeded: UInt32(length)),
            ])
        }
    }

    func testLargeTextMeasurementFlowsThroughRequestFingerprintWithoutTrap() async throws {
        let version = ContractVersion(rawValue: "large-v1")
        let limit = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 9_999, safetyMargin: 0, contractVersion: version)
        let capabilities = try ProviderCapabilities(inputLimits: [limit], outputFormat: .encoded(container: "mp3", codec: "mp3"), contractVersion: version)
        let text = String(repeating: "界", count: 9_999)
        let chunks = try await ProviderInputSplitter(capabilities: capabilities).split(text)
        let chunk = try XCTUnwrap(chunks.first)
        let selection = ProviderSelection(providerID: .minimax, modelID: ModelID(rawValue: "m"), voiceID: VoiceID(rawValue: "v"), rate: NormalizedRate(version: "r", value: 0)!)
        let controls = try SynthesisControls(renderedFields: [SynthesisControlField(name: "speed", value: "1")], mappingVersion: "r", templateVersion: nil)
        XCTAssertNoThrow(try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk, controls: controls, credentialScopeRevision: UUID(), capabilities: capabilities, outputFormatID: "mp3", canonicalizerVersion: "v1"))
    }
    func testAppendixAProductionSpeechRequestVectorHasExactWireBytesAndDigest() async throws {
        let request = try await appendixRequest()
        let fields = try appendixFields(for: request)
        XCTAssertEqual(hex(try RequestFingerprintCodec.encode(fields: fields)), "414c5246503030310001000000066f70656e61690000001000112233445566778899aabbccddeeff0000000233310000000f6770742d346f2d6d696e692d74747300000005616c6c6f790000002074bda49cd968a2d7d9ad710e764502946c91f1afa7676e67417806063b7d018b00000016414c4354524c3031000000057370656564000000013000000007726174652d7631ffffffff000000067761762d7631000000186e66632d757466382d76317c63616e6f6e6963616c2d7631")
        XCTAssertEqual(hex(request.requestFingerprint.rawValue), "6c72df1e3b38cc62a2f62d42a5dfd300e7c9345e10db9ae6e01d707a6c02e150")
        XCTAssertEqual(hex(try request.controls.encoded()), "414c4354524c30310000000573706565640000000130")
        XCTAssertEqual(request.canonicalizerVersion, "canonical-v1")
    }

    func testEveryIdentityFieldMutationChangesFingerprintAndNilIsDistinctFromEmpty() throws {
        let base = try appendixFields()
        let original = try RequestFingerprintCodec.fingerprint(fields: base)
        let variants: [RequestFingerprintFields] = [
            try fields(base, providerID: Data("other".utf8)),
            try fields(base, scopeRevision: Data(repeating: 0x42, count: 16)),
            try fields(base, contractVersion: Data("32".utf8)),
            try fields(base, modelID: Data("tts-1".utf8)),
            try fields(base, voiceID: Data("nova".utf8)),
            try fields(base, normalizedTextDigest: Data(repeating: 0x2A, count: 32)),
            try fields(base, controls: Data("other-controls".utf8)),
            try fields(base, mappingVersion: Data("rate-v2".utf8)),
            try fields(base, templateVersion: Data("template-v2".utf8)),
            try fields(base, outputFormat: Data("wav-v2".utf8)),
            try fields(base, canonicalizerVersion: Data("nfc-utf8-v1|canonical-v2".utf8))
        ]
        XCTAssertEqual(variants.count, 11)
        for variant in variants { XCTAssertNotEqual(try RequestFingerprintCodec.fingerprint(fields: variant), original) }
        let nilVoice = try fields(base, voiceID: nil)
        let emptyVoice = try fields(base, voiceID: Data())
        XCTAssertNotEqual(try RequestFingerprintCodec.fingerprint(fields: nilVoice), try RequestFingerprintCodec.fingerprint(fields: emptyVoice))
        let nilTemplate = try fields(base, templateVersion: nil)
        let emptyTemplate = try fields(base, templateVersion: Data())
        XCTAssertNotEqual(try RequestFingerprintCodec.fingerprint(fields: nilTemplate), try RequestFingerprintCodec.fingerprint(fields: emptyTemplate))
    }

    func testControlsAreCanonicalAndDecodeCannotBypassValidation() throws {
        XCTAssertNoThrow(try SynthesisControls(renderedFields: [SynthesisControlField(name: "pitch", value: "1"), SynthesisControlField(name: "speed", value: "0")], mappingVersion: "rate-v1", templateVersion: nil))
        for fields in [
            [SynthesisControlField(name: "speed", value: "")],
            [SynthesisControlField(name: "speed=0", value: "1")],
            [SynthesisControlField(name: "speed", value: "1"), SynthesisControlField(name: "speed", value: "2")],
            [SynthesisControlField(name: "speed", value: "1"), SynthesisControlField(name: "pitch", value: "2")]
        ] { XCTAssertThrowsError(try SynthesisControls(renderedFields: fields, mappingVersion: "rate-v1", templateVersion: nil)) }
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(SynthesisControls.self, from: Data(#"{"renderedFields":[{"name":"speed=0","value":"1"}],"mappingVersion":"rate-v1"}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(SynthesisControls.self, from: Data(#"{"renderedFields":[{"name":"speed","value":"1"},{"name":"speed","value":"2"}],"mappingVersion":"rate-v1"}"#.utf8)))
        let left = try SynthesisControls(renderedFields: [SynthesisControlField(name: "a", value: "bc")], mappingVersion: "rate-v1", templateVersion: nil)
        let right = try SynthesisControls(renderedFields: [SynthesisControlField(name: "ab", value: "c")], mappingVersion: "rate-v1", templateVersion: nil)
        XCTAssertNotEqual(try left.encoded(), try right.encoded())
    }

    private func appendixRequest() async throws -> SpeechRequest {
        let limit = try InputLimit(endpoint: "tts", unit: .utf8Bytes, maximum: 512, safetyMargin: 0, contractVersion: ContractVersion(rawValue: "31"))
        let capabilities = try ProviderCapabilities(inputLimits: [limit], outputFormat: .encoded(container: "wav", codec: "pcm"), contractVersion: ContractVersion(rawValue: "31"))
        let chunks = try await ProviderInputSplitter(capabilities: capabilities).split("A\u{030A}!" )
        let chunk = try XCTUnwrap(chunks.first)
        let selection = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "gpt-4o-mini-tts"), voiceID: VoiceID(rawValue: "alloy"), rate: try XCTUnwrap(NormalizedRate(version: "rate-v1", value: 0)))
        let controls = try SynthesisControls(renderedFields: [SynthesisControlField(name: "speed", value: "0")], mappingVersion: "rate-v1", templateVersion: nil)
        return try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!), selection: selection, chunk: chunk, controls: controls, credentialScopeRevision: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!, capabilities: capabilities, outputFormatID: "wav-v1", canonicalizerVersion: "canonical-v1")
    }
    private func appendixFields(for request: SpeechRequest) throws -> RequestFingerprintFields {
        try RequestFingerprintFields(providerID: Data(request.selection.providerID.rawValue.utf8), scopeRevision: Data(hexString: "00112233445566778899aabbccddeeff")!, contractVersion: Data("31".utf8), modelID: Data("gpt-4o-mini-tts".utf8), voiceID: Data("alloy".utf8), normalizedTextDigest: Data(SHA256.hash(data: Data("A\u{030A}!".precomposedStringWithCanonicalMapping.utf8))), controls: try request.controls.encoded(), mappingVersion: Data("rate-v1".utf8), templateVersion: nil, outputFormat: Data("wav-v1".utf8), canonicalizerVersion: Data("nfc-utf8-v1|canonical-v1".utf8))
    }
    private func appendixFields() throws -> RequestFingerprintFields {
        // Mirrors SpeechRequest.make's production values without using its codec.
        try RequestFingerprintFields(providerID: Data("openai".utf8), scopeRevision: Data(hexString: "00112233445566778899aabbccddeeff")!, contractVersion: Data("31".utf8), modelID: Data("gpt-4o-mini-tts".utf8), voiceID: Data("alloy".utf8), normalizedTextDigest: Data(SHA256.hash(data: Data("A\u{030A}!".precomposedStringWithCanonicalMapping.utf8))), controls: try SynthesisControls(renderedFields: [SynthesisControlField(name: "speed", value: "0")], mappingVersion: "rate-v1", templateVersion: nil).encoded(), mappingVersion: Data("rate-v1".utf8), templateVersion: nil, outputFormat: Data("wav-v1".utf8), canonicalizerVersion: Data("nfc-utf8-v1|canonical-v1".utf8))
    }
    private func fields(_ base: RequestFingerprintFields, providerID: Data? = nil, scopeRevision: Data? = nil, contractVersion: Data? = nil, modelID: Data? = nil, voiceID: Data?? = nil, normalizedTextDigest: Data? = nil, controls: Data? = nil, mappingVersion: Data? = nil, templateVersion: Data?? = nil, outputFormat: Data? = nil, canonicalizerVersion: Data? = nil) throws -> RequestFingerprintFields {
        try RequestFingerprintFields(providerID: providerID ?? base.providerID, scopeRevision: scopeRevision ?? base.scopeRevision, contractVersion: contractVersion ?? base.contractVersion, modelID: modelID ?? base.modelID, voiceID: voiceID ?? base.voiceID, normalizedTextDigest: normalizedTextDigest ?? base.normalizedTextDigest, controls: controls ?? base.controls, mappingVersion: mappingVersion ?? base.mappingVersion, templateVersion: templateVersion ?? base.templateVersion, outputFormat: outputFormat ?? base.outputFormat, canonicalizerVersion: canonicalizerVersion ?? base.canonicalizerVersion)
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

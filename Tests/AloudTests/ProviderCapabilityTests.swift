import XCTest
@testable import Aloud

final class ProviderCapabilityTests: XCTestCase {
    private let v1 = ContractVersion(rawValue: "v1")
    func testConstructionRejectsEmptyBadAndMixedContracts() throws {
        XCTAssertThrowsError(try ProviderCapabilities(inputLimits: [], outputFormat: .encoded(container: "mp3", codec: "mp3"), contractVersion: v1))
        XCTAssertThrowsError(try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 0, safetyMargin: 0, contractVersion: v1))
        XCTAssertThrowsError(try InputLimit(endpoint: "tts", unit: .conservativeTokens, maximum: 8, safetyMargin: 0, contractVersion: v1))
        XCTAssertThrowsError(try JSONDecoder().decode(InputLimit.self, from: Data(#"{"endpoint":"tts","unit":"conservativeTokens","maximum":8,"safetyMargin":0,"contractVersion":{"rawValue":"v1"}}"#.utf8)))
        let v2 = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 8, safetyMargin: 0, contractVersion: ContractVersion(rawValue: "v2"))
        XCTAssertThrowsError(try ProviderCapabilities(inputLimits: [v2], outputFormat: .encoded(container: "mp3", codec: "mp3"), contractVersion: v1))
    }
    func testAggregateMeasurementProvesAllConcurrentLimitsAndOverhead() async throws {
        let bytes = try InputLimit(endpoint: "tts", unit: .utf8Bytes, maximum: 128, safetyMargin: 0, contractVersion: v1)
        let graphemes = try InputLimit(endpoint: "tts", unit: .graphemes, maximum: 80, safetyMargin: 0, contractVersion: v1)
        let tokens = try InputLimit(endpoint: "tts", unit: .conservativeTokens, maximum: 130, safetyMargin: 1, contractVersion: v1)
        let proof = try await InputMeasurement.measure("你😀e\u{301}", limits: [bytes, graphemes, tokens], requestOverhead: RequestOverhead(instruction: "i", style: "s", rate: "r"))
        XCTAssertEqual(proof.values.count, 3)
        XCTAssertGreaterThan(proof.values[tokens]!, "你😀e\u{301}isr".lengthOfBytes(using: .utf8))
        XCTAssertNoThrow(try ProviderCapabilities(inputLimits: [bytes, graphemes, tokens], outputFormat: .encoded(container: "mp3", codec: "mp3"), contractVersion: v1).validate(proof))
    }
    func testRateMappingProducesConcreteVersionedControls() throws {
        let mapping = RateMapping(mappingVersion: "rate-v1", templateVersion: "prompt-v2") { rate in try SynthesisControls(renderedFields: [SynthesisControlField(name: "speed", value: "\(rate.value)")], mappingVersion: "rate-v1", templateVersion: "prompt-v2") }
        XCTAssertEqual(try mapping.controls(for: XCTUnwrap(NormalizedRate(version: "rate-v1", value: 0))).renderedFields.count, 1)
    }
    func testLengthPrefixBoundaryAndOverageThrowWithoutAllocationOrTrap() throws {
        XCTAssertEqual(try LengthPrefix.checked(3, maximum: 3), 3)
        XCTAssertThrowsError(try LengthPrefix.checked(4, maximum: 3)) { XCTAssertEqual($0 as? InputValidationError, .lengthPrefixTooLarge) }
        let overhead = RequestOverhead(instruction: "i", style: "s", rate: "r")
        XCTAssertNoThrow(try overhead.encoded(maximumLength: 11))
        XCTAssertThrowsError(try overhead.encoded(maximumLength: 10)) { XCTAssertEqual($0 as? InputValidationError, .lengthPrefixTooLarge) }
        XCTAssertNoThrow(try overhead.measurementBytes(for: "abc", maximumTextLength: 3, maximumOverheadFieldLength: 11))
        XCTAssertThrowsError(try overhead.measurementBytes(for: "abcd", maximumTextLength: 3, maximumOverheadFieldLength: 11)) { XCTAssertEqual($0 as? InputValidationError, .lengthPrefixTooLarge) }
    }
}

import XCTest
@testable import Aloud

final class SelectionGateTests: XCTestCase {
    func testCredentialRejectedAndMissingRequiredOutrankEveryOtherState() {
        XCTAssertEqual(gate(.configured(health: .explicitRejected), .available, .available, .valid), .blocked(.credentialRejected))
        XCTAssertEqual(gate(.missing, .unknown, .deprecated, .invalid), .blocked(.credentialMissing))
        XCTAssertEqual(gate(.noneRequired, .available, .available, .unknown), .allowed)
    }

    func testProviderAndModelFiveStateMatrixFailsClosedExceptQualifiedAvailability() {
        XCTAssertEqual(gate(.configured(health: .unknown), .available, .available, .unknown), .allowed)
        XCTAssertEqual(gate(.configured(health: .unknown), .disabled, .available, .valid), .blocked(.providerDisabled))
        XCTAssertEqual(gate(.configured(health: .unknown), .deprecated, .available, .valid), .blocked(.providerDeprecated))
        XCTAssertEqual(gate(.configured(health: .unknown), .unknown, .available, .valid), .blocked(.contractUnknown))
        XCTAssertEqual(gate(.configured(health: .unknown), .available, .disabled, .valid), .blocked(.modelDisabled))
        XCTAssertEqual(gate(.configured(health: .unknown), .available, .deprecated, .valid), .blocked(.modelDeprecated))
        XCTAssertEqual(gate(.configured(health: .unknown), .available, .unknown, .valid), .blocked(.modelUnknown))
    }

    func testExperimentalRequiresFlagReleaseAndEvidenceBeforeAccountGate() {
        XCTAssertEqual(gate(.configured(health: .unknown), .experimental, .experimental, .valid, featureFlag: false, releaseApproved: true, evidence: true), .blocked(.experimentalFeatureDisabled))
        XCTAssertEqual(gate(.configured(health: .unknown), .experimental, .experimental, .valid, featureFlag: true, releaseApproved: false, evidence: true), .blocked(.experimentalReleaseApprovalRequired))
        XCTAssertEqual(gate(.configured(health: .unknown), .experimental, .experimental, .valid, featureFlag: true, releaseApproved: true, evidence: false), .blocked(.experimentalEvidenceMissing))
        XCTAssertEqual(gate(.configured(health: .unknown), .experimental, .experimental, .unknown, featureFlag: true, releaseApproved: true, evidence: true), .allowed)
    }

    func testExperimentalProviderOrModelAloneStillRequiresAllExperimentalGates() {
        XCTAssertEqual(gate(.configured(health: .unknown), .experimental, .available, .unknown, featureFlag: false), .blocked(.experimentalFeatureDisabled))
        let provider = ProviderAvailability(kind: .available, reason: nil, maturity: .stable, featureFlagName: "geminiExperimentalEnabled", featureFlagEnabled: false, providerContractVersion: ContractVersion(rawValue: "test-v1"), evidenceID: "evidence")
        let model = ModelAvailability(kind: .experimental, reason: nil, contractVersion: ContractVersion(rawValue: "test-v1"), evidenceID: "evidence")
        XCTAssertEqual(SelectionGate.evaluate(credential: .configured(health: .unknown), provider: provider, model: model, account: .unknown, featureFlag: false, releaseApproved: true), .blocked(.experimentalFeatureDisabled))
    }

    func testExperimentalContractDoesNotUseStaticFlagAsRuntimeTruth() {
        let provider = ProviderAvailability(kind: .experimental, reason: nil, maturity: .experimental, featureFlagName: "geminiExperimentalEnabled", featureFlagEnabled: false, providerContractVersion: ContractVersion(rawValue: "test-v1"), evidenceID: "evidence")
        let model = ModelAvailability(kind: .experimental, reason: nil, contractVersion: ContractVersion(rawValue: "test-v1"), evidenceID: "evidence")
        XCTAssertEqual(SelectionGate.evaluate(credential: .configured(health: .unknown), provider: provider, model: model, account: .unknown, featureFlag: true, releaseApproved: true), .allowed)
    }

    func testBundledGeminiUsesRuntimeFlagAsTheOnlyEnablementTruth() throws {
        let catalog = try ProviderContractCatalog.bundled()
        let provider = catalog.providerAvailability(for: .gemini)
        let model = catalog.modelAvailability(providerID: .gemini, modelID: ModelID(rawValue: "gemini-2.5-pro-preview-tts"))
        XCTAssertNil(provider.featureFlagEnabled)
        XCTAssertEqual(SelectionGate.evaluate(credential: .configured(health: .unknown), provider: provider, model: model, account: .unknown, featureFlag: false, releaseApproved: true), .blocked(.experimentalFeatureDisabled))
        XCTAssertEqual(SelectionGate.evaluate(credential: .configured(health: .unknown), provider: provider, model: model, account: .unknown, featureFlag: true, releaseApproved: true), .allowed)
    }

    func testAccountInvalidBlocksOnlyAfterContractAndExperimentalChecks() {
        XCTAssertEqual(gate(.configured(health: .unknown), .available, .available, .invalid), .blocked(.accountInvalid))
        XCTAssertEqual(gate(.configured(health: .unknown), .unknown, .available, .invalid), .blocked(.contractUnknown))
    }

    func testNoEvidenceAndNoQualifiedModelBlockProvider() {
        XCTAssertEqual(gate(.configured(health: .unknown), .available, .available, .valid, evidence: false), .blocked(.contractEvidenceMissing))
        XCTAssertEqual(gate(.configured(health: .unknown), .disabled, .available, .valid, providerReason: .noQualifiedModel), .blocked(.noQualifiedModel))
    }

    private func gate(
        _ credential: CredentialGateState,
        _ provider: ProviderAvailabilityKind,
        _ model: ProviderAvailabilityKind,
        _ account: SelectionValidation,
        featureFlag: Bool = true,
        releaseApproved: Bool = true,
        evidence: Bool = true,
        providerReason: ProviderAvailabilityReason? = nil
    ) -> SynthesisGate {
        SelectionGate.evaluate(
            credential: credential,
            provider: ProviderAvailability(kind: provider, reason: providerReason, maturity: provider == .experimental ? .experimental : .stable, featureFlagName: provider == .experimental ? "geminiExperimentalEnabled" : nil, featureFlagEnabled: featureFlag, providerContractVersion: ContractVersion(rawValue: "test-v1"), evidenceID: evidence ? "evidence" : nil),
            model: ModelAvailability(kind: model, reason: nil, contractVersion: ContractVersion(rawValue: "test-v1"), evidenceID: evidence ? "evidence" : nil),
            account: account,
            featureFlag: featureFlag,
            releaseApproved: releaseApproved
        )
    }
}

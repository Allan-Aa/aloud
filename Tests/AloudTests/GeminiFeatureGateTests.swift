import CryptoKit
import XCTest
@testable import Aloud

final class GeminiFeatureGateTests: XCTestCase {
    func testAllFourIndependentReleaseGatesAreRequiredAcrossEveryBooleanCombination() {
        var combinations = 0
        for featureFlag in [false, true] {
            for releaseApproved in [false, true] {
                for contractLocked in [false, true] {
                    for realE2EPassed in [false, true] {
                        combinations += 1
                        let gate = GeminiReleaseGate(
                            featureFlag: featureFlag,
                            releaseApproved: releaseApproved,
                            catalogEvidence: contractLocked ? geminiCatalogEvidence() : nil,
                            realE2EEvidenceID: realE2EPassed ? "gemini-e2e-fixture-v1" : nil
                        )
                        let evaluation = gate.evaluate()
                        let allTrue = featureFlag && releaseApproved && contractLocked && realE2EPassed
                        XCTAssertEqual(evaluation.permitsSynthesis, allTrue)
                        XCTAssertEqual(evaluation.availability, .experimental)
                        XCTAssertTrue(evaluation.isDisplayed)
                        if !featureFlag {
                            XCTAssertFalse(evaluation.includedInProviderTotals)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(combinations, 16)
    }

    func testDefaultFlagIsOffAndGeminiCardIsManualAPIKeyOnly() {
        XCTAssertFalse(FeatureFlags.defaults.geminiExperimentalEnabled)
        let gate = GeminiReleaseGate(
            featureFlag: FeatureFlags.defaults.geminiExperimentalEnabled,
            releaseApproved: false,
            catalogEvidence: nil,
            realE2EEvidenceID: nil
        )
        XCTAssertEqual(gate.authRoute, .manualAPIKey)
        XCTAssertEqual(gate.cardActions, [.saveManualAPIKey, .preview])
        XCTAssertEqual(gate.billingText, "费用计入 API Key 关联的 Google Cloud 项目，不是 Gemini 网页订阅。")
        XCTAssertFalse(gate.evaluate().permitsSynthesis)
        XCTAssertFalse(gate.evaluate().includedInProviderTotals)
    }

    func testProductionConfigurationCannotOpenReleaseOrRealE2EGates() throws {
        let gate = GeminiReleaseGate.production(
            featureFlags: .defaults,
            catalog: try ProviderContractCatalog.bundled()
        )
        XCTAssertFalse(gate.featureFlag)
        XCTAssertFalse(gate.releaseApproved)
        XCTAssertNotNil(gate.catalogEvidence)
        XCTAssertNil(gate.realE2EEvidenceID)
        XCTAssertEqual(gate.evaluate().blockReason, .featureFlagDisabled)
        XCTAssertFalse(gate.evaluate().permitsSynthesis)
    }

    func testContractGateRejectsPresentButWrongSourceDigestOrVersionAndEmptyE2EID() {
        let catalog = try! ProviderContractCatalog.bundled()
        let providerRecord = try! XCTUnwrap(catalog.validatedEvidence(providerID: .gemini, modelID: nil))
        let wrongModelRecord = try! XCTUnwrap(
            catalog.validatedEvidence(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"))
        )
        let invalidEvidence = [providerRecord, wrongModelRecord]
        for evidence in invalidEvidence {
            let result = GeminiReleaseGate(
                featureFlag: true,
                releaseApproved: true,
                catalogEvidence: evidence,
                realE2EEvidenceID: "gemini-e2e-fixture-v1"
            ).evaluate()
            XCTAssertFalse(result.permitsSynthesis)
            XCTAssertEqual(result.blockReason, .contractEvidenceMissing)
        }
        let emptyE2E = GeminiReleaseGate(
            featureFlag: true,
            releaseApproved: true,
            catalogEvidence: geminiCatalogEvidence(),
            realE2EEvidenceID: ""
        ).evaluate()
        XCTAssertFalse(emptyE2E.permitsSynthesis)
        XCTAssertEqual(emptyE2E.blockReason, .realE2EEvidenceMissing)
    }

    func testBundledModelEvidenceIsTheControlledSnapshotDigestAndRouteSpecificSource() throws {
        let evidence = geminiCatalogEvidence()
        let digest = Data(SHA256.hash(data: Data(evidence.snapshot.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(evidence.snapshot, GeminiWireContractV1.controlledEvidenceSnapshot)
        XCTAssertEqual(digest, GeminiWireContractV1.requiredEvidenceDigest)
        XCTAssertEqual(evidence.evidence.evidenceDigest, digest)
        XCTAssertEqual(evidence.evidence.sourceURL, GeminiWireContractV1.evidenceSourceURL)
        XCTAssertEqual(
            GeminiWireContractV1.evidenceSourceURL.absoluteString,
            "https://ai.google.dev/gemini-api/docs/generate-content/speech-generation"
        )
        XCTAssertEqual(
            GeminiWireContractV1.currentCanonicalDocsURL.absoluteString,
            "https://ai.google.dev/gemini-api/docs/speech-generation"
        )

        let providerEvidence = try XCTUnwrap(
            try ProviderContractCatalog.bundled().validatedEvidence(providerID: .gemini, modelID: nil)
        )
        XCTAssertEqual(
            providerEvidence.snapshot,
            "provider|gemini||availability=experimental;maturity=preview;auth=x-goog-api-key"
        )
        XCTAssertEqual(providerEvidence.evidence.sourceURL, GeminiWireContractV1.evidenceSourceURL)
    }
}

private func geminiCatalogEvidence() -> CatalogValidatedEvidence {
    try! XCTUnwrap(
        try! ProviderContractCatalog.bundled().validatedEvidence(
            providerID: .gemini,
            modelID: GeminiWireContractV1.modelID
        )
    )
}

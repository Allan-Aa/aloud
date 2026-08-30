import XCTest
@testable import Aloud

final class OpenAIErrorClassifierTests: XCTestCase {
    func test401And403AreSeparatedWithoutTreatingEveryAuthStatusAsBadKey() throws {
        let fixtures: [(Int, String?, String?, String, OpenAIErrorCategory)] = [
            (401, "invalid_api_key", "authentication_error", "Incorrect API key provided", .credentialRejected),
            (401, nil, "authentication_error", "You must be a member of an organization to use the API", .organizationAccessRequired),
            (401, nil, "authentication_error", "IP not authorized", .ipNotAuthorized),
            (403, nil, "permission_error", "Country, region, or territory not supported", .regionUnsupported),
            (403, "model_not_found", "invalid_request_error", "Model is not available", .unsupportedSelection),
            (403, "insufficient_permissions", "permission_error", "Permission denied", .permissionDenied),
            (401, "unrecognized_auth", "authentication_error", "Fixture unknown", .authConfigurationFailure),
            (403, "unrecognized_permission", "permission_error", "Fixture unknown", .authConfigurationFailure),
        ]
        for (status, code, type, message, expected) in fixtures {
            let result = OpenAIErrorClassifier.classify(
                status: status, body: errorBody(code: code, type: type, message: message),
                retryAfter: nil, contract: .production
            )
            XCTAssertEqual(result.category, expected, "status=\(status) code=\(code ?? "nil")")
            XCTAssertEqual(result.health, expected == .credentialRejected ? .explicitRejected : .recoverableFailure)
            XCTAssertEqual(result.shouldRejectCredential, expected == .credentialRejected)
        }
    }

    func testProduction429ContractStaysEmptyWithoutDirectOfficialErrorCodeEvidence() {
        XCTAssertEqual(OpenAIRateLimitContract.production.billingOrQuotaCodes, [])
        XCTAssertEqual(OpenAIRateLimitContract.production.requestRateCodes, [])
    }

    func testSyntheticBillingAndRequestCodesExerciseClosedBranchesButUnknown429Stops() throws {
        let contract = try OpenAIRateLimitContract.synthetic(
            billingOrQuotaCodes: ["fixture.billing"], requestRateCodes: ["fixture.requests"]
        )
        let billing = OpenAIErrorClassifier.classify(
            status: 429,
            body: errorBody(code: "fixture.billing", type: "rate_limit_error", message: "fixture message"),
            retryAfter: .seconds(3), contract: contract
        )
        XCTAssertEqual(billing.category, .actionRequiredBillingOrQuota)
        XCTAssertEqual(billing.retryDecision, .stop)

        let request = OpenAIErrorClassifier.classify(
            status: 429,
            body: errorBody(code: "fixture.requests", type: "rate_limit_error", message: "fixture message"),
            retryAfter: .seconds(3), contract: contract
        )
        XCTAssertEqual(request.category, .requestsRateLimited(retryAfter: .seconds(3)))
        XCTAssertEqual(request.retryDecision, .retry(afterMilliseconds: 3_000))

        let unknown = OpenAIErrorClassifier.classify(
            status: 429,
            body: errorBody(code: "fixture.unknown", type: "rate_limit_error", message: "billing canary"),
            retryAfter: .seconds(3), contract: .production
        )
        XCTAssertEqual(unknown.category, .rateOrQuotaUnknown)
        XCTAssertEqual(unknown.retryDecision, .stop)
        XCTAssertEqual(unknown.callToAction, "稍后重试或检查 API 用量")
        XCTAssertFalse(unknown.callToAction.contains("账单"))
    }

    func testRawCodeMessageAndMalformedBodyNeverEscapeClosedTechnicalResult() {
        let canary = "fixture-private-message-and-code"
        for body in [errorBody(code: canary, type: canary, message: canary), Data("not-json-\(canary)".utf8)] {
            let result = OpenAIErrorClassifier.classify(
                status: 401, body: body, retryAfter: nil, contract: .production
            )
            XCTAssertEqual(result.category, .authConfigurationFailure)
            XCTAssertFalse(result.technicalCode.contains(canary))
            XCTAssertFalse(result.callToAction.contains(canary))
            XCTAssertFalse(result.localizedDescription.contains(canary))
        }
    }

    func testUnknown429CannotRejectCredentialFromAuthLikeRawContent() {
        let result = OpenAIErrorClassifier.classify(
            status: 429,
            body: errorBody(
                code: "invalid_api_key",
                type: "rate_limit_error",
                message: "Incorrect API key provided"
            ),
            retryAfter: .seconds(1),
            contract: .production
        )
        XCTAssertEqual(result.category, .rateOrQuotaUnknown)
        XCTAssertFalse(result.shouldRejectCredential)
        XCTAssertEqual(result.health, .recoverableFailure)
        XCTAssertEqual(result.retryDecision, .stop)
    }
}

private func errorBody(code: String?, type: String?, message: String) -> Data {
    let fields: [String: Any?] = ["code": code, "type": type, "message": message]
    let error = fields.compactMapValues { $0 }
    return try! JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys])
}

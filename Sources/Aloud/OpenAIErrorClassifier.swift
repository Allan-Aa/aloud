import Foundation

enum OpenAIErrorCategory: Equatable, Sendable {
    case credentialRejected
    case organizationAccessRequired
    case ipNotAuthorized
    case regionUnsupported
    case unsupportedSelection
    case permissionDenied
    case authConfigurationFailure
    case actionRequiredBillingOrQuota
    case requestsRateLimited(retryAfter: Duration?)
    case rateOrQuotaUnknown
}

/// Exact `error.code` values may enter the production classifier only after a
/// current official page states that exact code. The current official error
/// guide distinguishes rate, quota, and billing conditions by prose/status,
/// but does not publish stable `error.code` values for those branches.
struct OpenAIRateLimitContract: Equatable, Sendable {
    let billingOrQuotaCodes: Set<String>
    let requestRateCodes: Set<String>

    static let production = OpenAIRateLimitContract(
        billingOrQuotaCodes: [],
        requestRateCodes: []
    )

    static func synthetic(
        billingOrQuotaCodes: Set<String>,
        requestRateCodes: Set<String>
    ) throws -> OpenAIRateLimitContract {
        let all = billingOrQuotaCodes.union(requestRateCodes)
        guard !all.contains(where: { $0.isEmpty }),
              billingOrQuotaCodes.isDisjoint(with: requestRateCodes) else {
            throw OpenAIRateLimitContractError.invalidCodeSet
        }
        return OpenAIRateLimitContract(
            billingOrQuotaCodes: billingOrQuotaCodes,
            requestRateCodes: requestRateCodes
        )
    }
}

enum OpenAIRateLimitContractError: Error, Equatable, Sendable {
    case invalidCodeSet
}

struct OpenAIClassifiedError: Error, Equatable, Sendable {
    let category: OpenAIErrorCategory
    let technicalCode: String
    let callToAction: String
    let health: ProviderHealth
    let shouldRejectCredential: Bool
    let retryDecision: RetryDecision
}

extension OpenAIClassifiedError: LocalizedError {
    var errorDescription: String? { callToAction }
}

enum OpenAIErrorClassifier {
    private struct Envelope: Decodable {
        struct Body: Decodable {
            let code: String?
            let type: String?
            let message: String?
        }
        let error: Body
    }

    static func classify(
        status: Int,
        body: Data,
        retryAfter: Duration?,
        contract: OpenAIRateLimitContract = .production
    ) -> OpenAIClassifiedError {
        let decoded = try? JSONDecoder().decode(Envelope.self, from: body).error
        let code = decoded?.code?.lowercased()
        let message = decoded?.message?.lowercased() ?? ""

        if status == 429 {
            if let code, contract.billingOrQuotaCodes.contains(code) {
                return result(
                    .actionRequiredBillingOrQuota,
                    technicalCode: "openai.billing-or-quota-action-required",
                    callToAction: "请检查 OpenAI API 用量与计费状态。"
                )
            }
            if let code, contract.requestRateCodes.contains(code) {
                return result(
                    .requestsRateLimited(retryAfter: retryAfter),
                    technicalCode: "openai.requests-rate-limited",
                    callToAction: "请求过于频繁，请稍后重试。",
                    retryDecision: retryAfter.map { .retry(afterMilliseconds: milliseconds($0)) } ?? .stop
                )
            }
            return result(
                .rateOrQuotaUnknown,
                technicalCode: "openai.rate-or-quota-unknown",
                callToAction: "稍后重试或检查 API 用量"
            )
        }

        guard status == 401 || status == 403 else {
            return result(
                .authConfigurationFailure,
                technicalCode: "openai.auth-configuration-failure",
                callToAction: "OpenAI 鉴权或权限配置失败，请检查账户设置。"
            )
        }

        if isExplicitInvalidKey(code: code, message: message) {
            return result(
                .credentialRejected,
                technicalCode: "openai.credential-rejected",
                callToAction: "API Key 无效，请检查后重新输入。",
                health: .explicitRejected,
                rejectCredential: true
            )
        }
        if containsAny(message, ["member of an organization", "organization member", "organization membership"]) {
            return result(
                .organizationAccessRequired,
                technicalCode: "openai.organization-access-required",
                callToAction: "请检查 OpenAI 组织成员资格。"
            )
        }
        if containsAny(message, ["ip not authorized", "ip allowlist", "ip address is not authorized"]) {
            return result(
                .ipNotAuthorized,
                technicalCode: "openai.ip-not-authorized",
                callToAction: "当前网络地址未获授权，请检查 OpenAI IP 白名单。"
            )
        }
        if containsAny(message, ["country, region, or territory", "unsupported country", "region not supported"]) {
            return result(
                .regionUnsupported,
                technicalCode: "openai.region-unsupported",
                callToAction: "OpenAI API 当前不支持所在地区。"
            )
        }
        if code == "model_not_found" {
            return result(
                .unsupportedSelection,
                technicalCode: "openai.selection-unsupported",
                callToAction: "当前 OpenAI 模型不可用，请选择受支持的模型。"
            )
        }
        if code == "insufficient_permissions" || code == "permission_denied" {
            return result(
                .permissionDenied,
                technicalCode: "openai.permission-denied",
                callToAction: "当前 API Key 没有语音合成权限。"
            )
        }

        return result(
            .authConfigurationFailure,
            technicalCode: "openai.auth-configuration-failure",
            callToAction: "OpenAI 鉴权或权限配置失败，请检查账户设置。"
        )
    }

    private static func isExplicitInvalidKey(code: String?, message: String) -> Bool {
        code == "invalid_api_key" || code == "incorrect_api_key" ||
            containsAny(message, ["incorrect api key", "invalid api key"])
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }

    private static func result(
        _ category: OpenAIErrorCategory,
        technicalCode: String,
        callToAction: String,
        health: ProviderHealth = .recoverableFailure,
        rejectCredential: Bool = false,
        retryDecision: RetryDecision = .stop
    ) -> OpenAIClassifiedError {
        OpenAIClassifiedError(
            category: category,
            technicalCode: technicalCode,
            callToAction: callToAction,
            health: health,
            shouldRejectCredential: rejectCredential,
            retryDecision: retryDecision
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let seconds = components.seconds > Int64(Int.max / 1_000)
            ? Int.max
            : Int(components.seconds) * 1_000
        let fractional = Int(components.attoseconds / 1_000_000_000_000_000)
        return seconds > Int.max - fractional ? Int.max : seconds + fractional
    }
}

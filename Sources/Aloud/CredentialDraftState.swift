import Foundation
import SwiftUI

enum ProviderCredentialOperation: Equatable, Sendable {
    case manualSave
    case onePasswordImport
}

struct ProviderCredentialOperationToken: Sendable {
    fileprivate let providerID: ProviderID
    fileprivate let operation: ProviderCredentialOperation
    fileprivate let generation: UInt64
}

enum ProviderCredentialSuccessSource: Equatable, Sendable {
    case manual
    case onePassword

    func message(_ lang: Lang) -> String {
        switch (self, lang) {
        case (.onePassword, .zh): "已从 1Password 更新 · 密钥已安全隐藏"
        case (.onePassword, .en): "Updated from 1Password · key safely hidden"
        case (.manual, .zh): "已更新 · 密钥已安全隐藏"
        case (.manual, .en): "Updated · key safely hidden"
        }
    }
}

enum ProviderCredentialUIFailure: Error, Equatable, Sendable {
    case keychainUnavailable
    case rejectedInput
    case onePasswordUnavailable
    case onePasswordImportFailed
    case onePasswordOutputInvalid
    case onePasswordTimedOut
}

extension ProviderCredentialUIFailure {
    static func classify(_ error: Error) -> Self {
        if case CredentialEnvelopeError.empty = error { return .rejectedInput }
        if let onePasswordError = error as? OnePasswordPipeError {
            return classify(onePasswordError, viewIsDisappearing: false) ?? .onePasswordImportFailed
        }
        return .keychainUnavailable
    }

    static func classify(_ error: OnePasswordPipeError, viewIsDisappearing: Bool = false) -> Self? {
        switch error {
        case .launchFailed: return .onePasswordUnavailable
        case .malformedOutput: return .onePasswordOutputInvalid
        case .timedOut: return .onePasswordTimedOut
        case .nonZeroExit: return .onePasswordImportFailed
        case .cancelled: return viewIsDisappearing ? nil : .onePasswordImportFailed
        }
    }
}

enum ProviderCredentialUIStatus: Equatable, Sendable {
    case missing
    case configured
    case blocked(CredentialBlockReason)
    case working(ProviderCredentialOperation)
    case saveFailed(ProviderCredentialUIFailure)

    static var saving: Self { .working(.manualSave) }

    func message(_ lang: Lang) -> String {
        switch self {
        case .missing: return lang == .zh ? "尚未配置" : "Not configured"
        case .configured: return lang == .zh ? "已配置" : "Configured"
        case .working(.manualSave): return lang == .zh ? "正在保存…" : "Saving…"
        case .working(.onePasswordImport): return lang == .zh ? "正在从 1Password 读取…" : "Reading from 1Password…"
        case .saveFailed(.keychainUnavailable): return lang == .zh ? "钥匙串暂不可用，请重试" : "Keychain is unavailable. Try again."
        case .saveFailed(.rejectedInput): return lang == .zh ? "请输入有效的 API Key" : "Enter a valid API key."
        case .saveFailed(.onePasswordUnavailable): return lang == .zh ? "未找到 1Password CLI，请安装后重试" : "1Password CLI is unavailable. Try again after installing it."
        case .saveFailed(.onePasswordImportFailed): return lang == .zh ? "无法从 1Password 导入，请重试" : "Unable to import from 1Password. Try again."
        case .saveFailed(.onePasswordOutputInvalid): return lang == .zh ? "1Password 中的 API Key 无效" : "The API key in 1Password is invalid."
        case .saveFailed(.onePasswordTimedOut): return lang == .zh ? "从 1Password 读取超时，请重试" : "Reading from 1Password timed out. Try again."
        case .blocked(.nonV1Item), .blocked(.corruptEnvelope), .blocked(.providerMismatch): return lang == .zh ? "需要重新输入 API Key" : "Enter this provider’s API key again."
        case .blocked(.keychainReadFailed), .blocked(.keychainWriteFailed), .blocked(.needsReconcile): return lang == .zh ? "钥匙串暂不可用，请重试" : "Keychain is unavailable. Try again."
        }
    }
}

@MainActor
final class CredentialDraftState: ObservableObject {
    @Published private(set) var drafts: [ProviderID: String] = [:]
    @Published private(set) var status: [ProviderID: ProviderCredentialUIStatus] = [:]
    @Published private(set) var recentSuccessSource: [ProviderID: ProviderCredentialSuccessSource] = [:]
    private var loadedStatus: [ProviderID: ProviderCredentialUIStatus] = [:]
    private var mutationGeneration: [ProviderID: UInt64] = [:]

    init(initialStatus: [ProviderID: ProviderCredentialUIStatus] = [:]) {
        status = initialStatus
        loadedStatus = initialStatus
    }

    func draft(for providerID: ProviderID) -> String { drafts[providerID, default: ""] }
    func setDraft(_ value: String, for providerID: ProviderID) { drafts[providerID] = value }
    @discardableResult
    func begin(_ operation: ProviderCredentialOperation, for providerID: ProviderID) -> Bool {
        beginOperation(operation, for: providerID) != nil
    }

    func beginOperation(
        _ operation: ProviderCredentialOperation,
        for providerID: ProviderID
    ) -> ProviderCredentialOperationToken? {
        if case .working = status[providerID] { return nil }
        let generation = advanceMutationGeneration(for: providerID)
        recentSuccessSource[providerID] = nil
        status[providerID] = .working(operation)
        return .init(providerID: providerID, operation: operation, generation: generation)
    }

    func beginSave(for providerID: ProviderID) { _ = begin(.manualSave, for: providerID) }

    func restoreLoadedStatus(for providerID: ProviderID) {
        guard case .working = status[providerID] else { return }
        advanceMutationGeneration(for: providerID)
        recentSuccessSource[providerID] = nil
        status[providerID] = loadedStatus[providerID] ?? .missing
    }

    func restoreLoadedStatus(for providerID: ProviderID, operationToken: ProviderCredentialOperationToken) {
        guard isCurrent(operationToken, for: providerID) else { return }
        restoreLoadedStatus(for: providerID)
    }

    func load(read: @escaping @Sendable (ProviderID) async throws -> CredentialReadResult) async {
        let providers = [ProviderID.minimax, .openAI, .gemini]
        let loadGenerations = Dictionary(uniqueKeysWithValues: providers.map {
            ($0, advanceMutationGeneration(for: $0))
        })
        await withTaskGroup(of: (ProviderID, CredentialReadResult).self) { group in
            for providerID in providers {
                group.addTask { (providerID, (try? await read(providerID)) ?? .blocked(.keychainReadFailed)) }
            }
            for await (providerID, result) in group {
                guard mutationGeneration[providerID] == loadGenerations[providerID] else { continue }
                let loaded: ProviderCredentialUIStatus = {
                    if case .available = result { return .configured }
                    if case let .blocked(reason) = result { return .blocked(reason) }
                    return .missing
                }()
                loadedStatus[providerID] = loaded
                if case .working = status[providerID] { continue }
                status[providerID] = loaded
            }
        }
    }
    func completeSave(
        for providerID: ProviderID,
        result: Result<Void, ProviderCredentialUIFailure>,
        successSource: ProviderCredentialSuccessSource? = nil
    ) {
        advanceMutationGeneration(for: providerID)
        switch result {
        case .success:
            drafts[providerID] = ""
            loadedStatus[providerID] = .configured
            if let successSource { recentSuccessSource[providerID] = successSource }
            status[providerID] = .configured
        case let .failure(reason):
            recentSuccessSource[providerID] = nil
            status[providerID] = .saveFailed(reason)
        }
    }

    func completeSave(
        for providerID: ProviderID,
        result: Result<Void, ProviderCredentialUIFailure>,
        successSource: ProviderCredentialSuccessSource? = nil,
        operationToken: ProviderCredentialOperationToken
    ) {
        guard isCurrent(operationToken, for: providerID) else { return }
        completeSave(for: providerID, result: result, successSource: successSource)
    }

    private func isCurrent(_ token: ProviderCredentialOperationToken, for providerID: ProviderID) -> Bool {
        token.providerID == providerID &&
            token.generation == mutationGeneration[providerID] &&
            status[providerID] == .working(token.operation)
    }

    @discardableResult
    private func advanceMutationGeneration(for providerID: ProviderID) -> UInt64 {
        let next = mutationGeneration[providerID, default: 0] + 1
        mutationGeneration[providerID] = next
        return next
    }
}

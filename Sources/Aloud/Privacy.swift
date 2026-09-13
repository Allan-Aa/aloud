import Foundation

enum DiagnosticStatus: String, Sendable { case started, success, failed, cancelled }
enum DiagnosticTechnicalCode: String, Sendable {
    case credentialRejected, recoverableFailure, unavailable, invalidSelection
    case transport, service, audioInvalid, canonicalization, playback
}
enum DiagnosticSpeechStage: String, Sendable {
    case selectionValidated, chunksPrepared, canonicalAudioReady, sessionAudioReady
    case playbackLaunched, playbackVerified, historyWritten, lastAudioPromoted
}

enum DiagnosticEvent: Sendable {
    case selectionRead(status: DiagnosticStatus, characterCount: Int?)
    case currentAIReplyFailure(CurrentAIReplyFailure)
    case providerFailure(providerID: ProviderID, code: DiagnosticTechnicalCode)
    case speechStage(providerID: ProviderID, stage: DiagnosticSpeechStage)
    case cacheEviction(fileCount: Int, remainingMegabytes: Int)
    case hotkeyRegistration(failureCount: Int, accessibilityEnabled: Bool)
}

final class PrivacySafeDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) { lock.withLock { events.append(event) } }

    func renderedForTesting() -> String {
        lock.withLock { events.map(Self.render).joined(separator: "\n") }
    }

    static func render(_ event: DiagnosticEvent) -> String {
        switch event {
        case .selectionRead(let status, let count):
            return "selection status=\(status.rawValue)" + (count.map { " count=\($0)" } ?? "")
        case .currentAIReplyFailure(let failure):
            return "ai-reply status=failed code=\(failure.rawValue)"
        case .providerFailure(let providerID, let code):
            return "provider id=\(providerID.rawValue) code=\(code.rawValue)"
        case .speechStage(let providerID, let stage):
            return "speech id=\(providerID.rawValue) stage=\(stage.rawValue)"
        case .cacheEviction(let count, let megabytes):
            return "cache evicted=\(count) remainingMB=\(megabytes)"
        case .hotkeyRegistration(let count, let enabled):
            return "hotkeys failures=\(count) accessibility=\(enabled)"
        }
    }
}

struct SensitiveSinkCategory: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let diagnostics = Self(rawValue: "diagnostics")
    var description: String { rawValue }
}

struct SensitiveSinkFinding: Equatable, Sendable, CustomStringConvertible {
    let sink: SensitiveSinkCategory
    let matchCount: Int
    var description: String { "sink=\(sink.rawValue) matched=\(matchCount > 0) count=\(matchCount)" }
}

enum SensitiveSinkScanner {
    static func fragments(for value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        let characters = Array(value)
        var values = Set([value])
        for length in [4, 8, 12, 16, 20] where characters.count >= length {
            values.insert(String(characters.prefix(length)))
            values.insert(String(characters.suffix(length)))
            let start = max(0, (characters.count - length) / 2)
            values.insert(String(characters[start..<(start + length)]))
        }
        return values.sorted()
    }

    static func scan(canary: String, sinks: [SensitiveSinkCategory: Data]) -> [SensitiveSinkFinding] {
        let needles = fragments(for: canary).compactMap { $0.data(using: .utf8) }
        return sinks.compactMap { sink, bytes in
            let count = needles.reduce(into: 0) { total, needle in
                if bytes.range(of: needle) != nil { total += 1 }
            }
            return count == 0 ? nil : SensitiveSinkFinding(sink: sink, matchCount: count)
        }.sorted { $0.sink.rawValue < $1.sink.rawValue }
    }
}

enum PrivacySafeMessage {
    static func settingsLoadFailed(_ error: Error) -> String { _ = error; return "设置加载失败，请检查设置文件或进入恢复模式。" }
    static func settingsSaveFailed(_ error: Error) -> String { _ = error; return "设置保存失败，请重试。" }
    static func speechFailed(_ error: Error) -> String {
        if error is CancellationError { return "朗读已取消" }
        if let classified = error as? OpenAIClassifiedError { return classified.callToAction }
        if let classified = error as? GeminiClassifiedError { return classified.callToAction }
        return "朗读失败，请重新检查服务商配置或稍后重试。"
    }
    static func selectionFailed(_ error: Error) -> String {
        switch error {
        case CurrentAIReplyFailure.invalidClaudeLocalID:
            return "未能识别 Claude 当前会话，请切回对话面板后重试。"
        case CurrentAIReplyFailure.invalidClaudeTranscript:
            return "Claude 会话记录格式无法读取，请先复制回复并用剪贴板朗读。"
        case CurrentAIReplyFailure.oversizedClaudeTranscript:
            return "Claude 会话记录或回复超过读取上限，请复制需要朗读的文字，再用剪贴板朗读。"
        case CurrentAIReplyFailure.incompleteClaudeReply, CurrentAIReplyFailure.incompleteCodexReply:
            return "当前 AI 回复尚未完成，请等回复结束后再按快捷键。"
        case CurrentAIReplyFailure.frontmostApplicationDrift, CurrentAIReplyFailure.claudeLocalIDDrift,
             CurrentAIReplyFailure.claudeTranscriptDrift, CurrentAIReplyFailure.codexWindowDrift:
            return "读取期间会话发生变化，请停留在目标会话后重试。"
        case is CurrentAIReplyFailure:
            return "未能读取当前 AI 会话，请确认目标会话已打开且回复已完成，或使用剪贴板朗读。"
        case Selection.Failure.noAccessibility: return "需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，勾上「念」"
        case Selection.Failure.selfIsFrontmost: return "请切到有选中文字的 app 再按热键"
        default: return "没有读取到选中文字，请重新选择后再试。"
        }
    }
    static func exportFailed(_ error: Error) -> String { _ = error; return "保存失败，请检查目标文件夹后重试。" }
}

enum SpeechFailureDiagnostic {
    static func code(for error: Error) -> DiagnosticTechnicalCode {
        if let error = error as? MiniMaxProviderError {
            switch error {
            case .credentialRejected, .credentialMissing, .credentialMismatch, .credentialBlocked:
                return .credentialRejected
            case .unsupportedSelection, .disabledSelection, .invalidRequest:
                return .invalidSelection
            case .transport, .httpStatus:
                return .transport
            case .service:
                return .service
            case .invalidResponse, .audioMissing:
                return .audioInvalid
            case .nativeWriteFailed:
                return .canonicalization
            }
        }
        if error is WAVAudioError { return .canonicalization }
        if error is PlaybackVerificationError || error is MPVIPCFailure || error is MPVSocketError {
            return .playback
        }
        if error is ReplayBlockReason { return .invalidSelection }
        return .recoverableFailure
    }
}

/// Closed crash-boundary serialization. Raw errors never cross into crash
/// reports; only a stable category is retained for post-mortem triage.
enum PrivacySafeCrashCapture {
    static func capture(_ error: Error) -> Data {
        _ = error
        return Data("aloud-crash category=unexpected\n".utf8)
    }
}

enum PrivacySourceCategory: String, CaseIterable, Sendable {
    case secret, authorizedText, fixedPreview, rawErrorHeader, nativeAudio, canonicalAudio
}

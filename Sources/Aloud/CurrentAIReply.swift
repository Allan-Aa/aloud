import Foundation
import SQLite3

#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif

protocol CurrentAIReplyReading: Sendable {
    func readIfSupported() async throws -> String?
}

enum CurrentAIReplyFailure: String, Error, Equatable, Sendable {
    case unsupportedAIApplication
    case invalidClaudeLocalID
    case ambiguousClaudeMetadata
    case invalidClaudeMetadata
    case oversizedClaudeMetadata
    case ambiguousClaudeTranscript
    case oversizedClaudeTranscript
    case claudeTranscriptSessionMismatch
    case invalidClaudeTranscript
    case incompleteClaudeReply
    case noCompletedClaudeReply
    case frontmostApplicationDrift
    case claudeLocalIDDrift
    case claudeTranscriptDrift
    case invalidCodexDatabase
    case noMatchingCodexThread
    case ambiguousCodexThread
    case incompleteCodexReply
    case codexWindowDrift
    case codexCopyUnavailable
    case codexCopyTemporarilyUnavailable
    case oversizedCodexData
    case codexTraversalLimitExceeded
}

struct CurrentAIReplyReader: CurrentAIReplyReading {
    typealias FrontmostBundleIdentifier = @Sendable () async throws -> String?
    typealias ClaudeLocalID = @Sendable () async throws -> String
    typealias ClaudeMetadataFiles = @Sendable (String) async throws -> [URL]
    typealias ClaudeTranscriptFiles = @Sendable (String) async throws -> [URL]
    typealias CodexMessageCopier = @Sendable () async throws -> CodexCopiedMessage
    typealias CodexDatabaseURL = @Sendable () async throws -> URL
    typealias CodexWindowRevalidator = @Sendable (CodexWindowProof) async throws -> Void

    private static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let codexBundleID = "com.openai.codex"
    private let frontmostBundleIdentifier: FrontmostBundleIdentifier
    private let claudeLocalID: ClaudeLocalID
    private let claudeMetadataFiles: ClaudeMetadataFiles
    private let claudeTranscriptFiles: ClaudeTranscriptFiles
    private let codexMessageCopier: CodexMessageCopier
    private let codexDatabaseURL: CodexDatabaseURL
    private let codexWindowRevalidator: CodexWindowRevalidator

    init(
        frontmostBundleIdentifier: @escaping FrontmostBundleIdentifier,
        claudeLocalID: @escaping ClaudeLocalID,
        claudeMetadataFiles: @escaping ClaudeMetadataFiles,
        claudeTranscriptFiles: @escaping ClaudeTranscriptFiles,
        codexMessageCopier: @escaping CodexMessageCopier = {
            try await CodexLiveAssistantMessageCopier().copy()
        },
        codexDatabaseURL: @escaping CodexDatabaseURL = {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/thread_history_1.sqlite")
        },
        codexWindowRevalidator: @escaping CodexWindowRevalidator = { proof in
            try CodexLiveAssistantMessageCopier.revalidate(proof)
        }
    ) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.claudeLocalID = claudeLocalID
        self.claudeMetadataFiles = claudeMetadataFiles
        self.claudeTranscriptFiles = claudeTranscriptFiles
        self.codexMessageCopier = codexMessageCopier
        self.codexDatabaseURL = codexDatabaseURL
        self.codexWindowRevalidator = codexWindowRevalidator
    }

    func readIfSupported() async throws -> String? {
        switch try await frontmostBundleIdentifier() {
        case Self.claudeBundleID:
            return try await readClaude()
        case Self.codexBundleID:
            return try await readCodex()
        default:
            return nil
        }
    }

    private func readCodex() async throws -> String {
        let copiedMessage = try await codexMessageCopier()
        let reply = try CodexSQLiteReplyResolver(databaseURL: await codexDatabaseURL())
            .latestReply(matchingCopiedText: copiedMessage.text)
        let confirmation = try await codexMessageCopier()
        guard confirmation.proof == copiedMessage.proof,
              trailingWhitespaceNormalized(confirmation.text)
                == trailingWhitespaceNormalized(copiedMessage.text) else {
            throw CurrentAIReplyFailure.codexWindowDrift
        }
        try await codexWindowRevalidator(confirmation.proof)
        return reply
    }

    private func trailingWhitespaceNormalized(_ text: String) -> String {
        var normalized = text
        while normalized.last?.isWhitespace == true { normalized.removeLast() }
        return normalized
    }

    private func readClaude() async throws -> String {
        let initialLocalID = try await claudeLocalID()
        guard ClaudeAXLocalIDParser.isLocalID(initialLocalID) else {
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        }

        let metadata = try await claudeMetadataFiles(initialLocalID).compactMap { url -> ClaudeMetadata? in
            let data = try BoundedFileReader.read(
                url,
                maximumBytes: 256 * 1_024,
                oversizedFailure: .oversizedClaudeMetadata,
                invalidFailure: .invalidClaudeMetadata
            )
            let metadata = try ClaudeMetadata.decode(data)
            return metadata.sessionID == initialLocalID ? metadata : nil
        }
        guard metadata.count == 1, let cliSessionID = metadata.first?.cliSessionID else {
            throw CurrentAIReplyFailure.ambiguousClaudeMetadata
        }

        let transcriptURLs = try await claudeTranscriptFiles(cliSessionID)
        guard transcriptURLs.count == 1, let transcriptURL = transcriptURLs.first else {
            throw CurrentAIReplyFailure.ambiguousClaudeTranscript
        }
        let transcript = try BoundedFileReader.read(
            transcriptURL,
            maximumBytes: 64 * 1_024 * 1_024,
            oversizedFailure: .oversizedClaudeTranscript,
            invalidFailure: .invalidClaudeTranscript
        )
        let reply = try ClaudeTranscriptReader.lastCompletedAssistantText(
            transcript,
            expectedSessionID: cliSessionID
        )
        try await verifyClaudeStillCurrent(initialLocalID: initialLocalID)
        let confirmation = try BoundedFileReader.read(
            transcriptURL,
            maximumBytes: 64 * 1_024 * 1_024,
            oversizedFailure: .oversizedClaudeTranscript,
            invalidFailure: .invalidClaudeTranscript
        )
        guard confirmation == transcript else {
            throw CurrentAIReplyFailure.claudeTranscriptDrift
        }
        try await verifyClaudeStillCurrent(initialLocalID: initialLocalID)
        return reply
    }

    private func verifyClaudeStillCurrent(initialLocalID: String) async throws {
        guard try await frontmostBundleIdentifier() == Self.claudeBundleID else {
            throw CurrentAIReplyFailure.frontmostApplicationDrift
        }
        guard try await claudeLocalID() == initialLocalID else {
            throw CurrentAIReplyFailure.claudeLocalIDDrift
        }
    }
}

enum ClaudeAXLocalIDParser {
    static func parse(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              components.host == "claude.ai",
              components.port == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil,
              components.percentEncodedPath == components.path,
              components.path.hasPrefix("/epitaxy/") else {
            return nil
        }
        // Opening an Artifact changes panel state, not the conversation identity.
        if components.query != nil {
            guard let items = components.queryItems, items.count == 1,
                  items[0].name == "artifact", let artifactID = items[0].value,
                  let uuid = UUID(uuidString: artifactID),
                  uuid.uuidString.lowercased() == artifactID,
                  components.percentEncodedQuery == "artifact=\(artifactID)" else { return nil }
        }
        let localID = String(components.path.dropFirst("/epitaxy/".count))
        return isLocalID(localID) ? localID : nil
    }

    static func isLocalID(_ value: String) -> Bool {
        guard value.hasPrefix("local_") else { return false }
        let bytes = Array(value.dropFirst("local_".count).utf8)
        let hyphens: Set<Int> = [8, 13, 18, 23]
        return bytes.count == 36 && bytes.enumerated().allSatisfy { index, byte in
            hyphens.contains(index)
                ? byte == 0x2D
                : (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

enum ClaudeAXURLAnalyzer {
    static func uniqueLocalID(in values: [String], maximumCandidates: Int) throws -> String {
        guard maximumCandidates > 0, values.count <= maximumCandidates else {
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        }
        let matches = Set(values.compactMap(ClaudeAXLocalIDParser.parse))
        guard matches.count == 1, let localID = matches.first else {
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        }
        return localID
    }
}

enum ClaudeCLISessionID {
    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let hyphens: Set<Int> = [8, 13, 18, 23]
        return bytes.count == 36 && bytes.enumerated().allSatisfy { index, byte in
            hyphens.contains(index)
                ? byte == 0x2D
                : (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

struct ClaudeMetadataLocator: Sendable {
    let root: URL
    let maximumDirectoryEntries: Int

    init(root: URL, maximumDirectoryEntries: Int = 256) {
        self.root = root
        self.maximumDirectoryEntries = maximumDirectoryEntries
    }

    func files(localID: String) throws -> [URL] {
        guard ClaudeAXLocalIDParser.isLocalID(localID) else {
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        }
        var remaining = maximumDirectoryEntries
        var matches: [URL] = []
        for device in try ClaudeFileLocator.directories(
            in: root, remaining: &remaining,
            invalid: .invalidClaudeMetadata, oversized: .oversizedClaudeMetadata
        ) {
            for organization in try ClaudeFileLocator.directories(
                in: device, remaining: &remaining,
                invalid: .invalidClaudeMetadata, oversized: .oversizedClaudeMetadata
            ) {
                let candidate = organization.appendingPathComponent("\(localID).json")
                if try ClaudeFileLocator.isRegularFileIfPresent(candidate, invalid: .invalidClaudeMetadata) {
                    matches.append(candidate)
                }
            }
        }
        return matches.sorted { $0.path < $1.path }
    }
}

struct ClaudeTranscriptLocator: Sendable {
    let root: URL
    let maximumDirectoryEntries: Int

    init(root: URL, maximumDirectoryEntries: Int = 256) {
        self.root = root
        self.maximumDirectoryEntries = maximumDirectoryEntries
    }

    func files(cliSessionID: String) throws -> [URL] {
        guard ClaudeCLISessionID.isValid(cliSessionID) else {
            throw CurrentAIReplyFailure.invalidClaudeMetadata
        }
        var remaining = maximumDirectoryEntries
        var matches: [URL] = []
        for project in try ClaudeFileLocator.directories(
            in: root, remaining: &remaining,
            invalid: .invalidClaudeTranscript, oversized: .oversizedClaudeTranscript
        ) {
            let candidate = project.appendingPathComponent("\(cliSessionID).jsonl")
            if try ClaudeFileLocator.isRegularFileIfPresent(candidate, invalid: .invalidClaudeTranscript) {
                matches.append(candidate)
            }
        }
        return matches.sorted { $0.path < $1.path }
    }
}

private enum ClaudeFileLocator {
    static func directories(
        in root: URL,
        remaining: inout Int,
        invalid: CurrentAIReplyFailure,
        oversized: CurrentAIReplyFailure
    ) throws -> [URL] {
        guard remaining >= 0 else { throw oversized }
        do {
            let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw invalid }
            let entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            guard entries.count <= remaining else { throw oversized }
            remaining -= entries.count
            return try entries.map { entry in
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalid }
                return entry
            }.sorted { $0.path < $1.path }
        } catch let error as CurrentAIReplyFailure {
            throw error
        } catch {
            throw invalid
        }
    }

    static func isRegularFileIfPresent(
        _ url: URL,
        invalid: CurrentAIReplyFailure
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw invalid }
            return true
        } catch let error as CurrentAIReplyFailure {
            throw error
        } catch {
            throw invalid
        }
    }
}

private enum BoundedFileReader {
    static func read(
        _ url: URL,
        maximumBytes: Int,
        oversizedFailure: CurrentAIReplyFailure,
        invalidFailure: CurrentAIReplyFailure
    ) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                throw invalidFailure
            }
            guard fileSize <= maximumBytes else { throw oversizedFailure }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw oversizedFailure }
            return data
        } catch let error as CurrentAIReplyFailure {
            throw error
        } catch {
            throw invalidFailure
        }
    }
}

private struct ClaudeMetadata: Decodable {
    let sessionID: String
    let cliSessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cliSessionID = "cliSessionId"
    }

    static func decode(_ data: Data) throws -> ClaudeMetadata {
        do {
            let metadata = try JSONDecoder().decode(Self.self, from: data)
            guard ClaudeAXLocalIDParser.isLocalID(metadata.sessionID),
                  ClaudeCLISessionID.isValid(metadata.cliSessionID) else {
                throw CurrentAIReplyFailure.invalidClaudeMetadata
            }
            return metadata
        } catch let error as CurrentAIReplyFailure {
            throw error
        } catch {
            throw CurrentAIReplyFailure.invalidClaudeMetadata
        }
    }
}

private enum ClaudeTranscriptReader {
    private enum LatestAssistantReply {
        case completed(String)
        case incomplete
    }

    static func lastCompletedAssistantText(_ data: Data, expectedSessionID: String) throws -> String {
        let lines = data.split(separator: 0x0A, maxSplits: 16_384, omittingEmptySubsequences: true)
        guard lines.count <= 16_384 else {
            throw CurrentAIReplyFailure.oversizedClaudeTranscript
        }

        var sawExpectedSession = false
        var latestAssistantReply: LatestAssistantReply?
        for line in lines {
            let lineData = Data(line)
            // Tool results can exceed the reply limit. Decode only their envelope;
            // the file-wide bound still limits memory, and user turns invalidate old replies.
            if line.count > 1 * 1_024 * 1_024 {
                guard let type = try? JSONDecoder().decode(ClaudeTranscriptType.self, from: lineData),
                      type.type == "user",
                      let user = try? JSONDecoder().decode(ClaudeUserRecord.self, from: lineData),
                      user.message.role == "user" else {
                    throw CurrentAIReplyFailure.oversizedClaudeTranscript
                }
            }
            let type: ClaudeTranscriptType
            do {
                type = try JSONDecoder().decode(ClaudeTranscriptType.self, from: lineData)
            } catch {
                throw CurrentAIReplyFailure.invalidClaudeTranscript
            }
            // File history is not a conversation turn and has no sessionId.
            if type.type == "file-history-snapshot" || type.type == "file-history-delta" { continue }
            let header: ClaudeTranscriptHeader
            do {
                header = try JSONDecoder().decode(ClaudeTranscriptHeader.self, from: lineData)
            } catch {
                throw CurrentAIReplyFailure.invalidClaudeTranscript
            }
            guard let sessionID = header.sessionID else {
                throw CurrentAIReplyFailure.invalidClaudeTranscript
            }
            guard sessionID == expectedSessionID else { continue }
            sawExpectedSession = true

            if type.type == "user" {
                let user: ClaudeUserRecord
                do {
                    user = try JSONDecoder().decode(ClaudeUserRecord.self, from: lineData)
                } catch {
                    throw CurrentAIReplyFailure.invalidClaudeTranscript
                }
                guard user.message.role == "user" else {
                    throw CurrentAIReplyFailure.invalidClaudeTranscript
                }
                if user.isSidechain == false { latestAssistantReply = .incomplete }
                continue
            }
            guard type.type == "assistant" else { continue }

            let assistant: ClaudeAssistantRecord
            do {
                assistant = try JSONDecoder().decode(ClaudeAssistantRecord.self, from: lineData)
            } catch {
                throw CurrentAIReplyFailure.invalidClaudeTranscript
            }
            guard assistant.isSidechain == false else { continue }
            guard assistant.message.role == "assistant",
                  let stopReason = assistant.message.stopReason else {
                throw CurrentAIReplyFailure.invalidClaudeTranscript
            }
            guard stopReason == "end_turn" else {
                latestAssistantReply = .incomplete
                continue
            }

            var text = ""
            for content in assistant.message.content {
                switch content.type {
                case "thinking":
                    continue
                case "text":
                    guard let value = content.text else {
                        throw CurrentAIReplyFailure.invalidClaudeTranscript
                    }
                    text += value
                default:
                    throw CurrentAIReplyFailure.invalidClaudeTranscript
                }
            }
            latestAssistantReply = !text.isEmpty ? .completed(text) : .incomplete
        }

        guard sawExpectedSession else {
            throw CurrentAIReplyFailure.claudeTranscriptSessionMismatch
        }
        guard let latestAssistantReply else {
            throw CurrentAIReplyFailure.noCompletedClaudeReply
        }
        switch latestAssistantReply {
        case .completed(let text): return text
        case .incomplete: throw CurrentAIReplyFailure.incompleteClaudeReply
        }
    }
}

private struct ClaudeTranscriptHeader: Decodable {
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
    }
}

private struct ClaudeTranscriptType: Decodable {
    let type: String
}

private struct ClaudeAssistantRecord: Decodable {
    let isSidechain: Bool
    let message: ClaudeTranscriptMessage
}

private struct ClaudeUserRecord: Decodable {
    let isSidechain: Bool
    let message: ClaudeTranscriptRole
}

private struct ClaudeTranscriptRole: Decodable {
    let role: String
}

private struct ClaudeTranscriptMessage: Decodable {
    let role: String
    let stopReason: String?
    let content: [ClaudeTranscriptContent]

    enum CodingKeys: String, CodingKey {
        case role, content
        case stopReason = "stop_reason"
    }
}

private struct ClaudeTranscriptContent: Decodable {
    let type: String
    let text: String?
}

#if canImport(AppKit)
enum ClaudeAXURLAttributeDecoder {
    static func decode(result: AXError, value: AnyObject?) throws -> String? {
        switch result {
        case .noValue, .attributeUnsupported:
            return nil
        case .success:
            if let string = value as? String { return string }
            if let url = value as? URL { return url.absoluteString }
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        default:
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        }
    }
}

extension CurrentAIReplyReader {
    static var live: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let metadataLocator = ClaudeMetadataLocator(
            root: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        )
        let transcriptLocator = ClaudeTranscriptLocator(
            root: home.appendingPathComponent(".claude/projects")
        )
        return Self(
            frontmostBundleIdentifier: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            },
            claudeLocalID: {
                try ClaudeLiveAXLocalIDReader.read()
            },
            claudeMetadataFiles: { localID in
                try metadataLocator.files(localID: localID)
            },
            claudeTranscriptFiles: { cliSessionID in
                try transcriptLocator.files(cliSessionID: cliSessionID)
            }
        )
    }
}

private enum ClaudeLiveAXLocalIDReader {
    private static let bundleIdentifier = "com.anthropic.claudefordesktop"
    private static let maximumNodes = 6_000
    private static let maximumDepth = 40
    private static let timeout: TimeInterval = 4

    static func read() throws -> String {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == bundleIdentifier else {
            throw CurrentAIReplyFailure.frontmostApplicationDrift
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard AXUIElementSetMessagingTimeout(applicationElement, 1) == .success,
              let window = elementAttribute(kAXFocusedWindowAttribute as String, of: applicationElement) else {
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        }

        let deadline = Date().addingTimeInterval(timeout)
        var pending: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var urls: [String] = []
        while let (element, depth) = pending.popLast() {
            guard Date() < deadline, visited < maximumNodes, depth <= maximumDepth else {
                throw CurrentAIReplyFailure.invalidClaudeLocalID
            }
            visited += 1
            if let url = try urlAttribute(of: element) { urls.append(url) }
            let children = try boundedChildren(
                of: element,
                remaining: maximumNodes - visited - pending.count
            )
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return try ClaudeAXURLAnalyzer.uniqueLocalID(in: urls, maximumCandidates: maximumNodes)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func urlAttribute(of element: AXUIElement) throws -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXURLAttribute as CFString,
            &value
        )
        return try ClaudeAXURLAttributeDecoder.decode(result: result, value: value)
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func boundedChildren(of element: AXUIElement, remaining: Int) throws -> [AXUIElement] {
        guard remaining >= 0 else { throw CurrentAIReplyFailure.invalidClaudeLocalID }
        var count = 0
        let result = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        if result == .noValue || result == .attributeUnsupported { return [] }
        guard result == .success, count >= 0, count <= remaining else {
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        }
        guard count > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(
            element, kAXChildrenAttribute as CFString, 0, count, &values
        ) == .success, let children = values as? [AXUIElement] else {
            throw CurrentAIReplyFailure.invalidClaudeLocalID
        }
        return children
    }
}
#endif

struct CodexAXCopyCandidate: Equatable, Sendable {
    enum MessageRole: Sendable { case user, assistant }

    let id: Int
    let role: MessageRole
    let order: Int
}

struct CodexAXWindowSnapshot: Equatable, Sendable {
    let processIdentifier: Int32
    let focusedWindowIdentifier: String
}

struct CodexWindowProof: Equatable, Sendable {
    let snapshot: CodexAXWindowSnapshot
    var copyElement: CodexAXElementBox? = nil
}

struct CodexWindowObservation: Equatable, Sendable {
    let snapshot: CodexAXWindowSnapshot
    let isGenerating: Bool
    var elements: [CodexAXElementBox] = []
}

struct CodexCopiedMessage: Equatable, Sendable {
    let text: String
    let proof: CodexWindowProof
}

enum CodexWindowProofValidator {
    static func validate(
        expected: CodexWindowProof,
        observed: CodexWindowObservation
    ) throws {
        guard !observed.isGenerating else { throw CurrentAIReplyFailure.incompleteCodexReply }
        guard expected.snapshot == observed.snapshot else { throw CurrentAIReplyFailure.codexWindowDrift }
        if let copyElement = expected.copyElement, !observed.elements.contains(copyElement) {
            throw CurrentAIReplyFailure.codexWindowDrift
        }
    }
}

struct CodexAXFlatNode: Equatable, Sendable {
    let id: Int
    let parentID: Int?
    let role: String
    let labels: [String]
    let canPress: Bool
    let order: Int
}

struct CodexAXAnalysisLimits: Sendable {
    let maximumNodes: Int
    let maximumDepth: Int
    let maximumAncestorSteps: Int
    let maximumCandidates: Int

    init(
        maximumNodes: Int = 12_000,
        maximumDepth: Int = 40,
        maximumAncestorSteps: Int = 1_100_000,
        maximumCandidates: Int = 512
    ) {
        self.maximumNodes = maximumNodes
        self.maximumDepth = maximumDepth
        self.maximumAncestorSteps = maximumAncestorSteps
        self.maximumCandidates = maximumCandidates
    }
}

enum CodexAXTreeAnalyzer {
    private enum AssistantActionState {
        case ready
        case transient
    }

    static func copyCandidate(
        in nodes: [CodexAXFlatNode],
        limits: CodexAXAnalysisLimits = .init()
    ) throws -> CodexAXCopyCandidate {
        guard limits.maximumNodes > 0, limits.maximumDepth > 0,
              limits.maximumAncestorSteps > 0, limits.maximumCandidates > 0,
              nodes.count <= limits.maximumNodes else {
            throw CurrentAIReplyFailure.codexTraversalLimitExceeded
        }
        let grouped = Dictionary(grouping: nodes, by: \.id)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw CurrentAIReplyFailure.codexTraversalLimitExceeded
        }
        let byID = grouped.mapValues { $0[0] }
        guard byID.count == nodes.count,
              nodes.allSatisfy({ $0.parentID == nil || byID[$0.parentID!] != nil }) else {
            throw CurrentAIReplyFailure.codexTraversalLimitExceeded
        }
        guard !containsStop(in: nodes) else { throw CurrentAIReplyFailure.incompleteCodexReply }

        let actionNodes = nodes.filter { assistantActionState($0) != nil }
        guard actionNodes.count <= limits.maximumCandidates else {
            throw CurrentAIReplyFailure.codexTraversalLimitExceeded
        }

        var work = 0
        func spend() throws {
            work += 1
            guard work <= limits.maximumAncestorSteps else {
                throw CurrentAIReplyFailure.codexTraversalLimitExceeded
            }
        }

        var ancestorsByID: [Int: [Int]] = [:]
        for node in nodes {
            var ancestors: [Int] = []
            var parentID = node.parentID
            var visited: Set<Int> = [node.id]
            while let currentID = parentID {
                try spend()
                guard visited.insert(currentID).inserted,
                      ancestors.count < limits.maximumDepth,
                      let parent = byID[currentID] else {
                    throw CurrentAIReplyFailure.codexTraversalLimitExceeded
                }
                ancestors.append(currentID)
                parentID = parent.parentID
            }
            ancestorsByID[node.id] = ancestors
        }

        var headingRolesByAncestor: [Int: [CodexAXCopyCandidate.MessageRole]] = [:]
        for heading in nodes where heading.role == "AXHeading" {
            guard let role = headingRole(heading) else { continue }
            for ancestorID in ancestorsByID[heading.id] ?? [] {
                try spend()
                headingRolesByAncestor[ancestorID, default: []].append(role)
            }
        }
        let codeNodeIDs = Set(nodes.lazy.filter(isCodeNode).map(\.id))
        var childrenByParent: [Int: [CodexAXFlatNode]] = [:]
        for node in nodes {
            if let parentID = node.parentID { childrenByParent[parentID, default: []].append(node) }
        }
        let ambiguousSiblingParents = Set(childrenByParent.compactMap { entry -> Int? in
            Set(entry.value.map(\.order)).count == entry.value.count ? nil : entry.key
        })
        let siblingHeadingParents = Set(childrenByParent.compactMap { entry -> Int? in
            entry.value.contains(where: { $0.role == "AXHeading" }) ? entry.key : nil
        })

        var containerCandidates: [Int: [(node: CodexAXFlatNode, depth: Int)]] = [:]
        for node in actionNodes {
            if let parentID = node.parentID,
               ambiguousSiblingParents.contains(parentID) || siblingHeadingParents.contains(parentID) {
                continue
            }
            var hasCodeAncestor = false
            for (index, ancestorID) in (ancestorsByID[node.id] ?? []).enumerated() {
                try spend()
                if codeNodeIDs.contains(ancestorID) { hasCodeAncestor = true }
                let roles = headingRolesByAncestor[ancestorID] ?? []
                if roles.count > 1 { break }
                if roles.count == 1 {
                    if roles[0] == .assistant, !hasCodeAncestor {
                        containerCandidates[ancestorID, default: []].append((node, index + 1))
                    }
                    break
                }
            }
        }

        var siblingCandidates: [CodexAXFlatNode] = []
        for (parentID, children) in childrenByParent where !ambiguousSiblingParents.contains(parentID) {
            var activeRole: CodexAXCopyCandidate.MessageRole?
            for child in children.sorted(by: { $0.order < $1.order }) {
                try spend()
                if child.role == "AXHeading" {
                    activeRole = headingRole(child)
                    continue
                }
                guard activeRole == .assistant, assistantActionState(child) != nil else { continue }
                var hasCodeAncestor = false
                for ancestorID in ancestorsByID[child.id] ?? [] {
                    try spend()
                    if codeNodeIDs.contains(ancestorID) {
                        hasCodeAncestor = true
                        break
                    }
                }
                if !hasCodeAncestor { siblingCandidates.append(child) }
            }
        }

        let selectedPerContainer = containerCandidates.compactMap { _, values -> CodexAXFlatNode? in
            guard let minimumDepth = values.map(\.depth).min() else { return nil }
            let shallowest = values.filter { $0.depth == minimumDepth }
            guard shallowest.count == 1 else { return nil }
            return shallowest[0].node
        }
        guard let selected = (selectedPerContainer + siblingCandidates).max(by: { $0.order < $1.order }) else {
            throw CurrentAIReplyFailure.codexCopyUnavailable
        }
        guard assistantActionState(selected) == .ready else {
            throw CurrentAIReplyFailure.codexCopyTemporarilyUnavailable
        }
        return CodexAXCopyCandidate(id: selected.id, role: .assistant, order: selected.order)
    }

    static func containsStop(in nodes: [CodexAXFlatNode]) -> Bool {
        nodes.contains { node in
            node.role == "AXButton" && normalizedLabels(node).contains {
                ["stop", "stop generating", "停止", "停止生成"].contains($0)
            }
        }
    }

    private static func assistantActionState(_ node: CodexAXFlatNode) -> AssistantActionState? {
        guard node.role == "AXButton" else { return nil }
        let labels = normalizedLabels(node)
        if node.canPress, labels.contains(where: { label in
            ["copy", "copy message", "copy response", "复制", "拷贝", "复制消息", "复制回答"].contains(label)
                || label.contains("copy-message") || label.contains("message-copy")
        }) {
            return .ready
        }
        if labels.contains(where: { label in
            ["copied", "copied message", "response copied", "已复制", "已拷贝", "复制成功", "拷贝成功"].contains(label)
                || label.contains("copied-message") || label.contains("message-copied")
        }) {
            return .transient
        }
        return nil
    }

    private static func isCodeNode(_ node: CodexAXFlatNode) -> Bool {
        normalizedLabels(node).contains {
            $0.contains("code block") || $0.contains("code-block") || $0.contains("codeblock")
        }
    }

    private static func headingRole(_ node: CodexAXFlatNode) -> CodexAXCopyCandidate.MessageRole? {
        for value in normalizedLabels(node) {
            if value.hasPrefix("you said") || value.hasPrefix("你说") { return .user }
            if [
                "chatgpt said", "codex said", "assistant said", "chatgpt responded",
                "codex responded", "assistant responded", "chatgpt 回答", "codex 回答",
            ].contains(where: value.hasPrefix) {
                return .assistant
            }
        }
        return nil
    }

    private static func normalizedLabels(_ node: CodexAXFlatNode) -> [String] {
        node.labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}

enum CodexTemporaryAvailabilityPoller {
    static func wait<Value>(
        scan: () async throws -> Value,
        retryAfterTemporaryUnavailable: () async throws -> Bool
    ) async throws -> Value {
        while true {
            do {
                return try await scan()
            } catch CurrentAIReplyFailure.codexCopyTemporarilyUnavailable {
                guard try await retryAfterTemporaryUnavailable() else {
                    throw CurrentAIReplyFailure.codexCopyTemporarilyUnavailable
                }
            }
        }
    }
}

enum CodexAXPasteboardCopy {
    static func read(
        using transport: PasteboardTransport,
        press: @escaping @Sendable (PasteboardOperationOwnership) async throws -> Void
    ) async throws -> String {
        try await transport.readSelection(using: press)
    }
}

struct CodexResolverLimits: Sendable {
    let maxCopiedTextBytes: Int
    let maxRows: Int
    let maxItemJSONBytes: Int
    let maxTextBytes: Int
    let maxTotalItemJSONBytes: Int

    init(
        maxCopiedTextBytes: Int = 1 * 1_024 * 1_024,
        maxRows: Int = 65_536,
        maxItemJSONBytes: Int = 1 * 1_024 * 1_024,
        maxTextBytes: Int = 1 * 1_024 * 1_024,
        maxTotalItemJSONBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.maxCopiedTextBytes = maxCopiedTextBytes
        self.maxRows = maxRows
        self.maxItemJSONBytes = maxItemJSONBytes
        self.maxTextBytes = maxTextBytes
        self.maxTotalItemJSONBytes = maxTotalItemJSONBytes
    }
}

struct CodexSQLiteReplyResolver {
    private static let threadItemColumns: [SQLiteColumn] = [
        .init("thread_id", "TEXT", true, nil, 1), .init("turn_id", "TEXT", true, nil, 2),
        .init("item_id", "TEXT", true, nil, 3), .init("rollout_ordinal", "INTEGER", true),
        .init("created_at_ms", "INTEGER", true), .init("item_json", "TEXT", true),
        .init("item_type", "TEXT", true, "''"), .init("updated_at_ordinal", "INTEGER", true, "0"),
    ]
    private static let threadTurnColumns: [SQLiteColumn] = [
        .init("thread_id", "TEXT", true, nil, 1), .init("turn_id", "TEXT", true, nil, 2),
        .init("rollout_ordinal", "INTEGER", true), .init("status", "TEXT", true),
        .init("error_json", "TEXT", false), .init("started_at", "INTEGER", false),
        .init("completed_at", "INTEGER", false), .init("duration_ms", "INTEGER", false),
        .init("first_user_item_id", "TEXT", false), .init("final_agent_item_id", "TEXT", false),
        .init("rollout_byte_offset", "INTEGER", false), .init("rollout_end_ordinal", "INTEGER", false),
        .init("rollout_end_byte_offset", "INTEGER", false),
    ]

    let databaseURL: URL
    let limits: CodexResolverLimits

    init(databaseURL: URL, limits: CodexResolverLimits = .init()) {
        self.databaseURL = databaseURL
        self.limits = limits
    }

    func latestReply(matchingCopiedText copiedText: String) throws -> String {
        guard limits.maxCopiedTextBytes > 0, limits.maxRows > 0,
              limits.maxItemJSONBytes > 0, limits.maxTextBytes > 0,
              copiedText.utf8.count <= limits.maxCopiedTextBytes else {
            throw CurrentAIReplyFailure.oversizedCodexData
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        defer { sqlite3_close(database) }

        try validateSchema(database)
        let threadID = try uniqueThreadID(database, copiedText: copiedText)
        return try latestFinal(database, threadID: threadID)
    }

    private func validateSchema(_ database: OpaquePointer) throws {
        guard try columns(in: "thread_items", database: database) == Self.threadItemColumns,
              try columns(in: "thread_turns", database: database) == Self.threadTurnColumns else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
    }

    private func columns(in table: String, database: OpaquePointer) throws -> [SQLiteColumn] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        defer { sqlite3_finalize(statement) }
        var result: [SQLiteColumn] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(.init(
                    try text(statement, column: 1),
                    try text(statement, column: 2),
                    sqlite3_column_int(statement, 3) == 1,
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                        ? nil
                        : try text(statement, column: 4),
                    sqlite3_column_int(statement, 5)
                ))
            case SQLITE_DONE:
                return result
            default:
                throw CurrentAIReplyFailure.invalidCodexDatabase
            }
        }
    }

    private func uniqueThreadID(_ database: OpaquePointer, copiedText: String) throws -> String {
        guard limits.maxRows > 0, limits.maxRows < Int.max else {
            throw CurrentAIReplyFailure.oversizedCodexData
        }
        let sql = """
        SELECT i.thread_id, i.item_json
        FROM thread_items i
        JOIN thread_turns t ON t.thread_id = i.thread_id AND t.turn_id = i.turn_id
            AND t.final_agent_item_id = i.item_id
        WHERE t.status = 'completed' AND i.item_type = 'agentMessage'
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_int64(statement, 1, Int64(limits.maxRows + 1)) == SQLITE_OK else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        let normalizedCopy = normalize(copiedText)
        var scannedBytes = 0
        var matches = Set<String>()
        var rowCount = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rowCount += 1
                guard rowCount <= limits.maxRows else {
                    throw CurrentAIReplyFailure.oversizedCodexData
                }
                let itemBytes = Int(sqlite3_column_bytes(statement, 1))
                guard itemBytes <= limits.maxTotalItemJSONBytes - scannedBytes else {
                    throw CurrentAIReplyFailure.oversizedCodexData
                }
                scannedBytes += itemBytes
                let threadID = try text(statement, column: 0)
                let item = try CodexAgentMessage.decode(
                    text(statement, column: 1, maximumBytes: limits.maxItemJSONBytes),
                    maximumTextBytes: limits.maxTextBytes
                )
                if item.isFinalForCompletedTurn, normalize(item.text) == normalizedCopy {
                    matches.insert(threadID)
                }
            case SQLITE_DONE:
                guard matches.count == 1, let threadID = matches.first else {
                    throw matches.isEmpty
                        ? CurrentAIReplyFailure.noMatchingCodexThread
                        : CurrentAIReplyFailure.ambiguousCodexThread
                }
                return threadID
            default:
                throw CurrentAIReplyFailure.invalidCodexDatabase
            }
        }
    }

    private func latestFinal(_ database: OpaquePointer, threadID: String) throws -> String {
        let turnSQL = """
        SELECT turn_id, status, final_agent_item_id
        FROM thread_turns
        WHERE thread_id = ?
        ORDER BY rollout_ordinal DESC
        LIMIT 1
        """
        var turnStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, turnSQL, -1, &turnStatement, nil) == SQLITE_OK,
              let turnStatement else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        defer { sqlite3_finalize(turnStatement) }
        try bind(threadID, to: turnStatement, column: 1)
        guard sqlite3_step(turnStatement) == SQLITE_ROW,
              try text(turnStatement, column: 1) == "completed",
              sqlite3_column_type(turnStatement, 2) == SQLITE_TEXT else {
            throw CurrentAIReplyFailure.incompleteCodexReply
        }
        let turnID = try text(turnStatement, column: 0)
        let finalItemID = try text(turnStatement, column: 2)
        guard !finalItemID.isEmpty else { throw CurrentAIReplyFailure.incompleteCodexReply }

        let itemSQL = """
        SELECT item_json
        FROM thread_items
        WHERE thread_id = ? AND turn_id = ? AND item_id = ? AND item_type = 'agentMessage'
        """
        var itemStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, itemSQL, -1, &itemStatement, nil) == SQLITE_OK,
              let itemStatement else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        defer { sqlite3_finalize(itemStatement) }
        try bind(threadID, to: itemStatement, column: 1)
        try bind(turnID, to: itemStatement, column: 2)
        try bind(finalItemID, to: itemStatement, column: 3)
        guard sqlite3_step(itemStatement) == SQLITE_ROW else {
            throw CurrentAIReplyFailure.incompleteCodexReply
        }
        let item = try CodexAgentMessage.decode(
            text(itemStatement, column: 0, maximumBytes: limits.maxItemJSONBytes),
            maximumTextBytes: limits.maxTextBytes
        )
        guard item.isFinalForCompletedTurn, !item.text.isEmpty,
              sqlite3_step(itemStatement) == SQLITE_DONE else {
            throw CurrentAIReplyFailure.incompleteCodexReply
        }
        return item.text
    }

    private func text(
        _ statement: OpaquePointer,
        column: Int32,
        maximumBytes: Int? = nil
    ) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        if let maximumBytes, count > maximumBytes {
            throw CurrentAIReplyFailure.oversizedCodexData
        }
        guard let value = String(data: Data(bytes: bytes, count: count), encoding: .utf8) else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        return value
    }

    private func bind(_ value: String, to statement: OpaquePointer, column: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, column, value, -1, transient) == SQLITE_OK else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
    }

    private func normalize(_ value: String) -> String {
        var value = value
        while value.last?.isWhitespace == true { value.removeLast() }
        return value
    }
}

private struct SQLiteColumn: Equatable {
    let name: String
    let type: String
    let notNull: Bool
    let defaultValue: String?
    let primaryKeyPosition: Int32

    init(
        _ name: String,
        _ type: String,
        _ notNull: Bool,
        _ defaultValue: String? = nil,
        _ primaryKeyPosition: Int32 = 0
    ) {
        self.name = name
        self.type = type
        self.notNull = notNull
        self.defaultValue = defaultValue
        self.primaryKeyPosition = primaryKeyPosition
    }
}

private struct CodexAgentMessage {
    let phase: String?
    let text: String

    // Both callers resolve completed turns through final_agent_item_id.
    // Older records omit phase or store null; explicit nonfinal phases remain invalid.
    var isFinalForCompletedTurn: Bool { phase == nil || phase == "final_answer" }

    static func decode(_ json: String, maximumTextBytes: Int) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let dictionary = object as? [String: Any],
              dictionary["type"] as? String == "agentMessage",
              let text = dictionary["text"] as? String else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        let rawPhase = dictionary["phase"]
        guard rawPhase == nil || rawPhase is NSNull || rawPhase is String else {
            throw CurrentAIReplyFailure.invalidCodexDatabase
        }
        guard text.utf8.count <= maximumTextBytes else {
            throw CurrentAIReplyFailure.oversizedCodexData
        }
        return Self(phase: rawPhase as? String, text: text)
    }
}

#if canImport(AppKit)
final class CodexAXElementBox: @unchecked Sendable, Equatable {
    static func == (lhs: CodexAXElementBox, rhs: CodexAXElementBox) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

private struct CodexLiveAXSnapshot {
    let observation: CodexWindowObservation
    let window: AXUIElement
    let nodes: [CodexAXFlatNode]
    let elements: [Int: CodexAXElementBox]
}

struct CodexLiveAssistantMessageCopier: Sendable {
    private static let bundleIdentifier = "com.openai.codex"
    private let transport: PasteboardTransport

    init(
        transport: PasteboardTransport = PasteboardTransport(
            client: SystemPasteboardClient(),
            interference: SystemCopyInterferenceMonitor()
        )
    ) {
        self.transport = transport
    }

    func copy() async throws -> CodexCopiedMessage {
        let (before, selected) = try await Self.waitForReadyCopyAction()
        guard let element = before.elements[selected.id] else {
            throw CurrentAIReplyFailure.codexCopyUnavailable
        }
        let copied = try await CodexAXPasteboardCopy.read(using: transport) { ownership in
            guard AXUIElementPerformAction(element.element, kAXPressAction as CFString) == .success else {
                throw CurrentAIReplyFailure.codexCopyUnavailable
            }
            ownership.copyCommandDispatched()
        }
        let after = try Self.scanFocusedWindow()
        let proof = CodexWindowProof(snapshot: before.observation.snapshot, copyElement: element)
        guard CFEqual(before.window, after.window) else { throw CurrentAIReplyFailure.codexWindowDrift }
        try CodexWindowProofValidator.validate(expected: proof, observed: after.observation)
        return CodexCopiedMessage(text: copied, proof: proof)
    }

    private static func waitForReadyCopyAction() async throws -> (CodexLiveAXSnapshot, CodexAXCopyCandidate) {
        let deadline = Date().addingTimeInterval(3)
        return try await CodexTemporaryAvailabilityPoller.wait(
            scan: {
                guard Date() < deadline else {
                    throw CurrentAIReplyFailure.codexCopyTemporarilyUnavailable
                }
                let snapshot = try scanFocusedWindow(deadline: deadline)
                let selected = try CodexAXTreeAnalyzer.copyCandidate(in: snapshot.nodes)
                return (snapshot, selected)
            },
            retryAfterTemporaryUnavailable: {
                guard Date() < deadline else { return false }
                try await Task.sleep(for: .milliseconds(30))
                return Date() < deadline
            }
        )
    }

    static func revalidate(_ proof: CodexWindowProof) throws {
        try CodexWindowProofValidator.validate(
            expected: proof,
            observed: scanFocusedWindow().observation
        )
    }

    private static func scanFocusedWindow(deadline: Date? = nil) throws -> CodexLiveAXSnapshot {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == bundleIdentifier else {
            throw CurrentAIReplyFailure.frontmostApplicationDrift
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard AXUIElementSetMessagingTimeout(applicationElement, 1) == .success,
              let window = elementAttribute(kAXFocusedWindowAttribute as String, of: applicationElement) else {
            throw CurrentAIReplyFailure.codexCopyUnavailable
        }

        let maximumNodes = 12_000
        let maximumDepth = 40
        let traversalDeadline = deadline ?? Date().addingTimeInterval(6)
        var pending: [(element: AXUIElement, depth: Int, parentID: Int?)] = [(window, 0, nil)]
        var visited = 0
        var nodes: [CodexAXFlatNode] = []
        var elements: [Int: CodexAXElementBox] = [:]

        while let current = pending.popLast() {
            guard Date() < traversalDeadline else {
                throw deadline == nil
                    ? CurrentAIReplyFailure.codexCopyUnavailable
                    : CurrentAIReplyFailure.codexCopyTemporarilyUnavailable
            }
            guard visited < maximumNodes, current.depth <= maximumDepth else {
                throw CurrentAIReplyFailure.codexCopyUnavailable
            }
            let order = visited
            visited += 1
            let role = stringAttribute(kAXRoleAttribute as String, of: current.element) ?? ""
            nodes.append(CodexAXFlatNode(
                id: order,
                parentID: current.parentID,
                role: role,
                labels: labels(current.element),
                canPress: isPressableButton(current.element),
                order: order
            ))
            elements[order] = CodexAXElementBox(current.element)
            let lookup = boundedChildren(
                of: current.element,
                remaining: maximumNodes - visited - pending.count
            )
            guard !lookup.exceeded else { throw CurrentAIReplyFailure.codexCopyUnavailable }
            pending.append(contentsOf: lookup.children.reversed().map {
                ($0, current.depth + 1, order)
            })
        }

        let windowID = "\(stringAttribute(kAXIdentifierAttribute as String, of: window) ?? "")#\(CFHash(window))"
        let snapshot = CodexAXWindowSnapshot(
            processIdentifier: application.processIdentifier,
            focusedWindowIdentifier: windowID
        )
        return CodexLiveAXSnapshot(
            observation: CodexWindowObservation(
                snapshot: snapshot,
                isGenerating: CodexAXTreeAnalyzer.containsStop(in: nodes),
                elements: Array(elements.values)
            ),
            window: window,
            nodes: nodes,
            elements: elements
        )
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func boundedChildren(
        of element: AXUIElement,
        remaining: Int
    ) -> (children: [AXUIElement], exceeded: Bool) {
        guard remaining >= 0 else { return ([], true) }
        var count = 0
        let result = AXUIElementGetAttributeValueCount(
            element,
            kAXChildrenAttribute as CFString,
            &count
        )
        if result == .noValue || result == .attributeUnsupported { return ([], false) }
        guard result == .success, count >= 0, count <= remaining else { return ([], true) }
        guard count > 0 else { return ([], false) }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            0,
            count,
            &values
        ) == .success else {
            return ([], true)
        }
        return (values as? [AXUIElement] ?? [], false)
    }

    private static func labels(_ element: AXUIElement) -> [String] {
        [
            stringAttribute(kAXTitleAttribute as String, of: element),
            stringAttribute(kAXDescriptionAttribute as String, of: element),
            stringAttribute(kAXHelpAttribute as String, of: element),
            stringAttribute(kAXIdentifierAttribute as String, of: element),
            stringAttribute(kAXValueAttribute as String, of: element),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    private static func isPressableButton(_ element: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute as String, of: element) == kAXButtonRole as String else {
            return false
        }
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else {
            return false
        }
        return actions.contains(kAXPressAction as String)
    }

}
#endif

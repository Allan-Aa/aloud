import Foundation
import ApplicationServices
import XCTest
@testable import Aloud

final class CurrentAIReplyTests: XCTestCase {
    private let claudeBundleID = "com.anthropic.claudefordesktop"
    private let localA = "local_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let localB = "local_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let cliA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let cliB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    func testNonAIAppReturnsNilWithoutReadingClaude() async throws {
        let reader = CurrentAIReplyReader(
            frontmostBundleIdentifier: { "com.apple.TextEdit" },
            claudeLocalID: { XCTFail("Claude local ID must not be read"); return "local_unused" },
            claudeMetadataFiles: { _ in XCTFail("Claude metadata must not be read"); return [] },
            claudeTranscriptFiles: { _ in XCTFail("Claude transcripts must not be read"); return [] }
        )

        let reply = try await reader.readIfSupported()
        XCTAssertNil(reply)
    }

    func testClaudeDesktopBundleRoutesToClaudeReader() async throws {
        let metadataFiles = try fixtureFiles([metadata(sessionID: localA, cliSessionID: cliA)])
        let transcriptFiles = try fixtureFiles([transcript(sessionID: cliA, text: "reply")])
        let reader = makeReader(
            bundle: claudeBundleID,
            localID: localA,
            metadataFiles: metadataFiles,
            transcriptFiles: transcriptFiles
        )

        let reply = try await reader.readIfSupported()
        XCTAssertEqual(reply, "reply")
    }

    func testClaudeLocalIDsMapToTheirOwnCLISessions() async throws {
        let metadataFiles = try fixtureFiles([
            metadata(sessionID: localA, cliSessionID: cliA),
            metadata(sessionID: localB, cliSessionID: cliB),
        ])
        let transcriptAFiles = try fixtureFiles([transcript(sessionID: cliA, text: "reply A")])
        let transcriptBFiles = try fixtureFiles([transcript(sessionID: cliB, text: "reply B")])

        for (localID, expected, transcripts) in [
            (localA, "reply A", transcriptAFiles),
            (localB, "reply B", transcriptBFiles),
        ] {
            let reader = makeReader(
                bundle: claudeBundleID,
                localID: localID,
                metadataFiles: metadataFiles,
                transcriptFiles: transcripts
            )
            let reply = try await reader.readIfSupported()
            XCTAssertEqual(reply, expected)
        }
    }

    func testClaudeFailsClosedWhenMetadataMatchIsNotUnique() async throws {
        for metadataPayloads in [
            [Data](),
            [metadata(sessionID: localA, cliSessionID: cliA), metadata(sessionID: localA, cliSessionID: cliB)],
        ] {
            let reader = makeReader(
                bundle: claudeBundleID,
                localID: localA,
                metadataFiles: try fixtureFiles(metadataPayloads),
                transcriptFiles: []
            )

            await assertFailure(reader, equals: .ambiguousClaudeMetadata)
        }
    }

    func testClaudeFailsWhenTranscriptSessionIDDoesNotMatchMetadata() async throws {
        let reader = makeReader(
            bundle: claudeBundleID,
            localID: localA,
            metadataFiles: try fixtureFiles([metadata(sessionID: localA, cliSessionID: cliA)]),
            transcriptFiles: try fixtureFiles([transcript(sessionID: cliB, text: "wrong reply")])
        )

        await assertFailure(reader, equals: .claudeTranscriptSessionMismatch)
    }

    func testClaudeReturnsLastCompletedNonSidechainAssistantTextAndIgnoresThinking() async throws {
        let jsonl = [
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("first")]),
            transcriptLine(sessionID: cliA, sidechain: true, stopReason: "end_turn", content: [.text("sidechain")]),
            transcriptLine(sessionID: cliA, stopReason: "stop_sequence", content: [.text("older incomplete")]),
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.thinking("internal"), .text("last complete")]),
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        let reply = try await reader.readIfSupported()
        XCTAssertEqual(reply, "last complete")
    }

    func testClaudeFileHistoryRecordsWithoutSessionIDDoNotBlockFinalReply() async throws {
        let jsonl = [
            #"{"type":"file-history-snapshot","snapshot":{"trackedFileBackups":{}}}"#,
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("final reply")]),
            #"{"type":"file-history-delta","changes":[]}"#,
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        let reply = try await reader.readIfSupported()
        XCTAssertEqual(reply, "final reply")
    }

    func testClaudeFileHistoryDoesNotMakePendingUserTurnComplete() async throws {
        let jsonl = [
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old reply")]),
            userTranscriptLine(sessionID: cliA),
            #"{"type":"file-history-snapshot","snapshot":{}}"#,
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        await assertFailure(reader, equals: .incompleteClaudeReply)
    }

    func testClaudeStillRejectsConversationOrUnknownRecordsWithoutSessionID() async throws {
        for type in ["user", "assistant", "unknown"] {
            let jsonl = transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old reply")])
                + "\n{\"type\":\"\(type)\",\"isSidechain\":false,\"message\":{\"role\":\"\(type)\"}}"
            let reader = try claudeReader(transcript: Data(jsonl.utf8))
            await assertFailure(reader, equals: .invalidClaudeTranscript)
        }
    }

    func testClaudeRejectsOldCompletedReplyFollowedByIncompleteAssistant() async throws {
        let jsonl = [
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old complete")]),
            transcriptLine(sessionID: cliA, stopReason: "stop_sequence", content: [.text("in progress")]),
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        await assertFailure(reader, equals: .incompleteClaudeReply)
    }

    func testClaudeRejectsOldCompletedReplyFollowedByTargetSessionUser() async throws {
        let jsonl = [
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old complete")]),
            userTranscriptLine(sessionID: cliA),
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        await assertFailure(reader, equals: .incompleteClaudeReply)
    }

    func testClaudeCompletedAssistantAfterTargetUserReplacesIncompleteState() async throws {
        let jsonl = [
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old complete")]),
            userTranscriptLine(sessionID: cliA),
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("final reply")]),
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        let reply = try await reader.readIfSupported()
        XCTAssertEqual(reply, "final reply")
    }

    func testClaudeAllowsIntermediateToolUseBeforeFinalCompletedReply() async throws {
        let jsonl = [
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old complete")]),
            transcriptLine(sessionID: cliA, stopReason: "tool_use", content: [.toolUse]),
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("final reply")]),
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        let reply = try await reader.readIfSupported()
        XCTAssertEqual(reply, "final reply")
    }

    func testClaudeTreatsLastToolUseAssistantAsIncomplete() async throws {
        let jsonl = [
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old complete")]),
            transcriptLine(
                sessionID: cliA,
                stopReason: "tool_use",
                content: [.toolUse, .thinking("internal"), .text("intermediate")]
            ),
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        await assertFailure(reader, equals: .incompleteClaudeReply)
    }

    func testClaudeRejectsOldCompletedReplyFollowedByMalformedAssistant() async throws {
        let complete = transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old complete")])
        let malformed = "{\"sessionId\":\"\(cliA)\",\"type\":\"assistant\",\"isSidechain\":false,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"missing stop\"}]}}"
        let reader = try claudeReader(transcript: Data("\(complete)\n\(malformed)".utf8))

        await assertFailure(reader, equals: .invalidClaudeTranscript)
    }

    func testClaudeRejectsUnknownTargetAssistantContentType() async throws {
        let reader = try claudeReader(
            transcript: Data(transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.unknown]).utf8)
        )

        await assertFailure(reader, equals: .invalidClaudeTranscript)
    }

    func testClaudeFailsWhenFrontmostAppDriftsToNonAI() async throws {
        let bundles = SequentialSampler([claudeBundleID, "com.apple.TextEdit"])
        let localIDs = SequentialSampler([localA])
        let reader = try claudeReader(
            frontmostBundleIdentifier: { await bundles.next() },
            claudeLocalID: { await localIDs.next() }
        )

        await assertFailure(reader, equals: .frontmostApplicationDrift)
    }

    func testClaudeFailsWhenLocalIDDriftsBetweenReadAndReturn() async throws {
        let bundles = SequentialSampler([claudeBundleID, claudeBundleID])
        let localIDs = SequentialSampler([localA, localB])
        let reader = try claudeReader(
            frontmostBundleIdentifier: { await bundles.next() },
            claudeLocalID: { await localIDs.next() }
        )

        await assertFailure(reader, equals: .claudeLocalIDDrift)
    }

    func testClaudeRejectsTranscriptThatDriftsDuringCurrentSessionVerification() async throws {
        let original = transcript(sessionID: cliA, text: "old reply")
        let changed = transcript(sessionID: cliA, text: "new reply")
        let transcriptURL = try XCTUnwrap(fixtureFiles([original]).first)
        let localIDReads = SequentialSampler([false, true])
        let reader = try claudeReader(
            transcriptFiles: [transcriptURL],
            claudeLocalID: {
                if await localIDReads.next() {
                    try changed.write(to: transcriptURL, options: .atomic)
                }
                return self.localA
            }
        )

        await assertFailure(reader, equals: .claudeTranscriptDrift)
    }

    func testClaudeRejectsTranscriptOverByteLimitBeforeFullRead() async throws {
        let tooLarge = try sparseFile(byteCount: 64 * 1_024 * 1_024 + 1)
        let reader = try claudeReader(transcriptFiles: [tooLarge])

        await assertFailure(reader, equals: .oversizedClaudeTranscript)
    }

    func testClaudeRejectsTranscriptOverLineCountLimit() async throws {
        let record = transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("reply")])
        let data = Data((Array(repeating: record, count: 16_385).joined(separator: "\n")).utf8)
        let reader = try claudeReader(transcript: data)

        await assertFailure(reader, equals: .oversizedClaudeTranscript)
    }

    func testClaudeLargeToolResultDoesNotBlockFinalReply() async throws {
        let toolResult = "{\"type\":\"user\",\"sessionId\":\"\(cliA)\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"\(String(repeating: "x", count: 1_300_000))\"}]}}"
        let reader = try claudeReader(transcript: Data((toolResult + "\n" + transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("final reply")])).utf8))
        let reply = try await reader.readIfSupported()
        XCTAssertEqual(reply, "final reply")
    }

    func testClaudeLargeUserRecordStillInvalidatesOldReply() async throws {
        let user = "{\"type\":\"user\",\"sessionId\":\"\(cliA)\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"\(String(repeating: "x", count: 1_300_000))\"}}"
        let reader = try claudeReader(transcript: Data((transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("old reply")]) + "\n" + user).utf8))
        await assertFailure(reader, equals: .incompleteClaudeReply)
    }

    func testClaudeStillRejectsOversizedAssistantReply() async throws {
        let reader = try claudeReader(transcript: transcript(sessionID: cliA, text: String(repeating: "x", count: 1_300_000)))
        await assertFailure(reader, equals: .oversizedClaudeTranscript)
    }

    func testClaudeRejectsTranscriptOverSingleLineLimit() async throws {
        let reader = try claudeReader(transcript: Data(repeating: 0x61, count: 1 * 1_024 * 1_024 + 1))

        await assertFailure(reader, equals: .oversizedClaudeTranscript)
    }

    func testClaudeRejectsOversizedMetadataBeforeDecode() async throws {
        let metadataFile = try sparseFile(byteCount: 256 * 1_024 + 1)
        let reader = makeReader(
            bundle: claudeBundleID,
            localID: localA,
            metadataFiles: [metadataFile],
            transcriptFiles: []
        )

        await assertFailure(reader, equals: .oversizedClaudeMetadata)
    }

    func testClaudeForkTranscriptIgnoresForeignSessionRecords() async throws {
        let jsonl = [
            transcriptLine(sessionID: "foreign", stopReason: "end_turn", content: [.unknown]),
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("target old")]),
            transcriptLine(sessionID: "foreign", stopReason: "stop_sequence", content: [.text("foreign newer")]),
            transcriptLine(sessionID: cliA, stopReason: "end_turn", content: [.text("target latest")]),
        ].joined(separator: "\n")
        let reader = try claudeReader(transcript: Data(jsonl.utf8))

        let reply = try await reader.readIfSupported()
        XCTAssertEqual(reply, "target latest")
    }

    func testClaudeAXLocalIDParserAcceptsOnlyExactLocalClaudeURL() {
        XCTAssertEqual(
            ClaudeAXLocalIDParser.parse("https://claude.ai/epitaxy/\(localA)"),
            localA
        )
        XCTAssertNil(ClaudeAXLocalIDParser.parse("https://claude.ai/epitaxy/LOCAL_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        XCTAssertNil(ClaudeAXLocalIDParser.parse("https://claude.ai/epitaxy/\(localA)?query=1"))
    }

    func testClaudeMetadataRejectsCLIIDsThatAreNotLowercaseUUIDs() async throws {
        for invalidID in [
            "../escape",
            "cli-A",
            "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        ] {
            let reader = makeReader(
                bundle: claudeBundleID,
                localID: localA,
                metadataFiles: try fixtureFiles([metadata(sessionID: localA, cliSessionID: invalidID)]),
                transcriptFiles: try fixtureFiles([transcript(sessionID: invalidID, text: "must not escape")])
            )

            await assertFailure(reader, equals: .invalidClaudeMetadata)
        }
    }

    func testClaudeArtifactPanelKeepsConversationIdentity() throws {
        let artifact = "a691a00b-fa8d-49ec-b1db-9987c4d11610"
        let plain = "https://claude.ai/epitaxy/\(localA)"
        let opened = "\(plain)?artifact=\(artifact)"
        XCTAssertEqual(ClaudeAXLocalIDParser.parse(opened), localA)
        XCTAssertEqual(try ClaudeAXURLAnalyzer.uniqueLocalID(in: [opened,
            "https://claude.ai/code/artifact/\(artifact)?m=dark",
            "https://\(artifact).frame.claudeusercontent.com/_f/example/",
            "http://localhost:4175/example.html",
        ], maximumCandidates: 8), localA)
        XCTAssertEqual(try ClaudeAXURLAnalyzer.uniqueLocalID(in: [plain, opened], maximumCandidates: 8), localA)
        XCTAssertThrowsError(try ClaudeAXURLAnalyzer.uniqueLocalID(in: [opened,
            "https://claude.ai/epitaxy/\(localB)?artifact=\(artifact)",
        ], maximumCandidates: 8))
    }

    func testCurrentReplyDiagnosticDoesNotEmitReplyOrRawErrors() async throws {
        let canary = "private reply \(UUID().uuidString)"
        let reader = try claudeReader(transcript: transcript(sessionID: cliA, text: canary))
        let success = await CurrentAIReplyDiagnosticCLI.run(reader: reader)
        XCTAssertEqual(success.status, 0)
        XCTAssertEqual(String(decoding: success.output, as: UTF8.self), "ai-reply status=success count=\(canary.count)\n")

        let failingReader = try claudeReader(claudeLocalID: { throw CurrentAIReplyFailure.invalidClaudeLocalID })
        let failure = await CurrentAIReplyDiagnosticCLI.run(reader: failingReader)
        XCTAssertEqual(failure.status, 69)
        XCTAssertEqual(String(decoding: failure.output, as: UTF8.self), "ai-reply status=failed code=invalidClaudeLocalID\n")
        XCTAssertEqual(PrivacySafeDiagnostics.render(.currentAIReplyFailure(.invalidClaudeLocalID)),
                       "ai-reply status=failed code=invalidClaudeLocalID")
        let rawFailureReader = try claudeReader(claudeLocalID: {
            throw NSError(domain: canary, code: 1, userInfo: [NSLocalizedDescriptionKey: canary])
        })
        let rawFailure = await CurrentAIReplyDiagnosticCLI.run(reader: rawFailureReader)
        XCTAssertEqual(String(decoding: rawFailure.output, as: UTF8.self), "ai-reply status=failed code=unavailable\n")
    }

    func testClaudeArtifactURLStillRejectsInvalidOrAmbiguousRoutes() {
        let artifact = "a691a00b-fa8d-49ec-b1db-9987c4d11610"
        let base = "https://claude.ai/epitaxy/\(localA)"
        for url in [
            "\(base)?artifact=", "\(base)?artifact=not-a-uuid",
            "\(base)?artifact=\(artifact)&artifact=\(artifact)",
            "\(base)?artifact=\(artifact)&query=1", "\(base)?query=1",
            "\(base)?artifact=\(artifact)#other", "\(base)/extra?artifact=\(artifact)",
            "https://evil.example/epitaxy/\(localA)?artifact=\(artifact)",
        ] { XCTAssertNil(ClaudeAXLocalIDParser.parse(url), url) }
    }

    func testClaudeMetadataLocatorSearchesOnlyExactDeviceOrgLocalIDPaths() throws {
        let root = try temporaryDirectory()
        let pathA = "device-a/org-a/\(localA).json"
        let pathB = "device-b/org-b/\(localB).json"
        try writeFixture(Data(), relativePath: pathA, under: root)
        try writeFixture(Data(), relativePath: pathB, under: root)
        try writeFixture(Data(), relativePath: "device-a/org-a/not-\(localA).json", under: root)
        let locator = ClaudeMetadataLocator(root: root)

        XCTAssertEqual(try locator.files(localID: localA).map(\.lastPathComponent), ["\(localA).json"])
        XCTAssertEqual(try locator.files(localID: localB).map(\.lastPathComponent), ["\(localB).json"])
        XCTAssertTrue(try locator.files(localID: "local_cccccccc-cccc-cccc-cccc-cccccccccccc").isEmpty)

        try writeFixture(Data(), relativePath: "device-c/org-c/\(localA).json", under: root)
        XCTAssertEqual(try locator.files(localID: localA).count, 2)
    }

    func testClaudeTranscriptLocatorSearchesOnlyExactProjectUUIDPaths() throws {
        let root = try temporaryDirectory()
        try writeFixture(Data(), relativePath: "project-a/\(cliA).jsonl", under: root)
        try writeFixture(Data(), relativePath: "project-b/\(cliB).jsonl", under: root)
        try writeFixture(Data(), relativePath: "project-a/not-\(cliA).jsonl", under: root)
        let locator = ClaudeTranscriptLocator(root: root)

        XCTAssertEqual(try locator.files(cliSessionID: cliA).map(\.lastPathComponent), ["\(cliA).jsonl"])
        XCTAssertEqual(try locator.files(cliSessionID: cliB).map(\.lastPathComponent), ["\(cliB).jsonl"])
        XCTAssertTrue(try locator.files(cliSessionID: "cccccccc-cccc-cccc-cccc-cccccccccccc").isEmpty)

        try writeFixture(Data(), relativePath: "project-c/\(cliA).jsonl", under: root)
        XCTAssertEqual(try locator.files(cliSessionID: cliA).count, 2)
    }

    func testClaudeFileLocatorsRejectDirectoryLimitNonDirectoryAndSymlink() throws {
        let metadataRoot = try temporaryDirectory()
        for name in ["device-a", "device-b", "device-c"] {
            try FileManager.default.createDirectory(
                at: metadataRoot.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        XCTAssertThrowsError(
            try ClaudeMetadataLocator(root: metadataRoot, maximumDirectoryEntries: 2).files(localID: localA)
        ) { XCTAssertEqual($0 as? CurrentAIReplyFailure, .oversizedClaudeMetadata) }

        let nonDirectoryRoot = try temporaryDirectory()
        try writeFixture(Data(), relativePath: "not-a-directory", under: nonDirectoryRoot)
        XCTAssertThrowsError(
            try ClaudeTranscriptLocator(root: nonDirectoryRoot).files(cliSessionID: cliA)
        ) { XCTAssertEqual($0 as? CurrentAIReplyFailure, .invalidClaudeTranscript) }

        let transcriptRoot = try temporaryDirectory()
        let realProject = try temporaryDirectory()
        let linkedProject = transcriptRoot.appendingPathComponent("linked-project")
        try FileManager.default.createSymbolicLink(at: linkedProject, withDestinationURL: realProject)
        XCTAssertThrowsError(
            try ClaudeTranscriptLocator(root: transcriptRoot).files(cliSessionID: cliA)
        ) { XCTAssertEqual($0 as? CurrentAIReplyFailure, .invalidClaudeTranscript) }
    }

    func testClaudeAXURLAnalyzerRequiresOneBoundedLocalID() throws {
        XCTAssertEqual(
            try ClaudeAXURLAnalyzer.uniqueLocalID(
                in: ["not a URL", "https://claude.ai/epitaxy/\(localA)"],
                maximumCandidates: 8
            ),
            localA
        )
        for values in [
            [String](),
            ["https://claude.ai/epitaxy/\(localA)", "https://claude.ai/epitaxy/\(localB)"],
            Array(repeating: "not a URL", count: 9),
        ] {
            XCTAssertThrowsError(try ClaudeAXURLAnalyzer.uniqueLocalID(in: values, maximumCandidates: 8)) {
                XCTAssertEqual($0 as? CurrentAIReplyFailure, .invalidClaudeLocalID)
            }
        }
    }

    func testClaudeAXURLAttributeDecoderFailsClosedExceptForExplicitMissingValues() throws {
        XCTAssertNil(try ClaudeAXURLAttributeDecoder.decode(result: .noValue, value: nil))
        XCTAssertNil(try ClaudeAXURLAttributeDecoder.decode(result: .attributeUnsupported, value: nil))
        XCTAssertEqual(
            try ClaudeAXURLAttributeDecoder.decode(
                result: .success,
                value: "https://claude.ai/epitaxy/\(localA)" as CFString
            ),
            "https://claude.ai/epitaxy/\(localA)"
        )
        XCTAssertEqual(
            try ClaudeAXURLAttributeDecoder.decode(
                result: .success,
                value: NSURL(string: "https://claude.ai/epitaxy/\(localB)")
            ),
            "https://claude.ai/epitaxy/\(localB)"
        )

        for result in [AXError.cannotComplete, .apiDisabled, .failure] {
            XCTAssertThrowsError(try ClaudeAXURLAttributeDecoder.decode(result: result, value: nil)) {
                XCTAssertEqual($0 as? CurrentAIReplyFailure, .invalidClaudeLocalID)
            }
        }
        for invalidValue in [nil, NSNumber(value: 1)] as [AnyObject?] {
            XCTAssertThrowsError(
                try ClaudeAXURLAttributeDecoder.decode(result: .success, value: invalidValue)
            ) { XCTAssertEqual($0 as? CurrentAIReplyFailure, .invalidClaudeLocalID) }
        }
    }

    func testCodexCopiedFinalUniquelyMapsThreadAndPreservesOriginalText() throws {
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-A", ordinal: 1, status: "completed", finalItem: "item-A"),
            codexItem(thread: "thread-A", turn: "turn-A", item: "item-A", ordinal: 2, text: "reply\n\n"),
        ])

        let reply = try CodexSQLiteReplyResolver(databaseURL: database)
            .latestReply(matchingCopiedText: "reply \t\n")

        XCTAssertEqual(reply, "reply\n\n")
    }

    func testCodexRepeatedCopiedFinalInsideOneThreadRemainsUnique() throws {
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-1", ordinal: 1, status: "completed", finalItem: "item-1"),
            codexItem(thread: "thread-A", turn: "turn-1", item: "item-1", ordinal: 2, text: "same"),
            codexTurn(thread: "thread-A", turn: "turn-2", ordinal: 3, status: "completed", finalItem: "item-2"),
            codexItem(thread: "thread-A", turn: "turn-2", item: "item-2", ordinal: 4, text: "same"),
        ])

        let reply = try CodexSQLiteReplyResolver(databaseURL: database)
            .latestReply(matchingCopiedText: "same")

        XCTAssertEqual(reply, "same")
    }

    func testCodexLegacyNullPhaseDoesNotBlockUnrelatedCurrentReply() throws {
        let database = try codexDatabase([
            codexTurn(thread: "legacy", turn: "old", ordinal: 1, status: "completed", finalItem: "old-final"),
            codexItem(thread: "legacy", turn: "old", item: "old-final", ordinal: 2, text: "old reply", phase: NSNull()),
            codexTurn(thread: "current", turn: "new", ordinal: 1, status: "completed", finalItem: "new-final"),
            codexItem(thread: "current", turn: "new", item: "new-final", ordinal: 2, text: "current reply"),
        ])
        XCTAssertEqual(try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "current reply"), "current reply")
    }

    func testCodexLegacyFinalPointerAcceptsNullAndMissingPhase() throws {
        for removePhase in [false, true] {
            var statements = [
                codexTurn(thread: "legacy", turn: "old", ordinal: 1, status: "completed", finalItem: "old-final"),
                codexItem(thread: "legacy", turn: "old", item: "old-final", ordinal: 2, text: "old reply", phase: NSNull()),
            ]
            if removePhase { statements.append("UPDATE thread_items SET item_json=json_remove(item_json, '$.phase');") }
            let database = try codexDatabase(statements)
            XCTAssertEqual(try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "old reply"), "old reply")
        }
    }

    func testCodexLegacyDuplicateStillMakesCurrentCopyAmbiguous() throws {
        let database = try codexDatabase([
            codexTurn(thread: "legacy", turn: "old", ordinal: 1, status: "completed", finalItem: "old-final"),
            codexItem(thread: "legacy", turn: "old", item: "old-final", ordinal: 2, text: "same", phase: NSNull()),
            codexTurn(thread: "current", turn: "new", ordinal: 1, status: "completed", finalItem: "new-final"),
            codexItem(thread: "current", turn: "new", item: "new-final", ordinal: 2, text: "same"),
        ])
        XCTAssertThrowsError(try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "same")) {
            XCTAssertEqual($0 as? CurrentAIReplyFailure, .ambiguousCodexThread)
        }
    }

    func testCodexOnlyFinalPointerMessagesParticipateInMatching() throws {
        let database = try codexDatabase([
            codexTurn(thread: "A", turn: "turn", ordinal: 1, status: "completed", finalItem: "final"),
            codexItem(thread: "A", turn: "turn", item: "progress", ordinal: 2, text: "unrelated", phase: 42),
            codexItem(thread: "A", turn: "turn", item: "final", ordinal: 3, text: "reply", phase: NSNull()),
        ])
        XCTAssertEqual(try CodexSQLiteReplyResolver(databaseURL: database, limits: .init(maxRows: 1)).latestReply(matchingCopiedText: "reply"), "reply")
        XCTAssertThrowsError(try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "unrelated")) {
            XCTAssertEqual($0 as? CurrentAIReplyFailure, .noMatchingCodexThread)
        }
    }

    func testCodexFinalPointerDoesNotOverrideExplicitNonfinalOrInvalidPhase() throws {
        for phase: Any in ["commentary", "unknown", 42] {
            let database = try codexDatabase([
                codexTurn(thread: "A", turn: "turn", ordinal: 1, status: "completed", finalItem: "final"),
                codexItem(thread: "A", turn: "turn", item: "final", ordinal: 2, text: "reply", phase: phase),
            ])
            XCTAssertThrowsError(try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "reply")) {
                XCTAssertEqual($0 as? CurrentAIReplyFailure, phase is String ? .noMatchingCodexThread : .invalidCodexDatabase)
            }
        }
    }

    func testCodexLatestLegacyFinalIsReturnedAfterMatchingOlderReply() throws {
        let database = try codexDatabase([
            codexTurn(thread: "A", turn: "old", ordinal: 1, status: "completed", finalItem: "old-final"),
            codexItem(thread: "A", turn: "old", item: "old-final", ordinal: 2, text: "old reply"),
            codexTurn(thread: "A", turn: "new", ordinal: 3, status: "completed", finalItem: "new-final"),
            codexItem(thread: "A", turn: "new", item: "new-final", ordinal: 4, text: "latest reply", phase: NSNull()),
        ])
        XCTAssertEqual(try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "old reply"), "latest reply")
    }

    func testCodexLatestExplicitCommentaryNeverFallsBackToOldFinal() throws {
        let database = try codexDatabase([
            codexTurn(thread: "A", turn: "old", ordinal: 1, status: "completed", finalItem: "old-final"),
            codexItem(thread: "A", turn: "old", item: "old-final", ordinal: 2, text: "old reply", phase: NSNull()),
            codexTurn(thread: "A", turn: "new", ordinal: 3, status: "completed", finalItem: "new-final"),
            codexItem(thread: "A", turn: "new", item: "new-final", ordinal: 4, text: "progress", phase: "commentary"),
        ])
        XCTAssertThrowsError(try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "old reply")) {
            XCTAssertEqual($0 as? CurrentAIReplyFailure, .incompleteCodexReply)
        }
    }

    func testCodexCopiedFinalAcrossTwoThreadsIsAmbiguous() throws {
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-A", ordinal: 1, status: "completed", finalItem: "item-A"),
            codexItem(thread: "thread-A", turn: "turn-A", item: "item-A", ordinal: 2, text: "same"),
            codexTurn(thread: "thread-B", turn: "turn-B", ordinal: 1, status: "completed", finalItem: "item-B"),
            codexItem(thread: "thread-B", turn: "turn-B", item: "item-B", ordinal: 2, text: "same"),
        ])

        XCTAssertThrowsError(
            try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "same")
        ) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .ambiguousCodexThread)
        }
    }

    func testCodexCopiedFinalWithNoMatchingThreadFailsClosed() throws {
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-A", ordinal: 1, status: "completed", finalItem: "item-A"),
            codexItem(thread: "thread-A", turn: "turn-A", item: "item-A", ordinal: 2, text: "other"),
        ])

        XCTAssertThrowsError(
            try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "missing")
        ) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .noMatchingCodexThread)
        }
    }

    func testCodexReturnsUniqueThreadLatestCompletedFinalInsteadOfMatchedOlderFinal() throws {
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-1", ordinal: 1, status: "completed", finalItem: "item-1"),
            codexItem(thread: "thread-A", turn: "turn-1", item: "item-1", ordinal: 2, text: "copied older"),
            codexTurn(thread: "thread-A", turn: "turn-2", ordinal: 3, status: "completed", finalItem: "item-2"),
            codexItem(thread: "thread-A", turn: "turn-2", item: "item-2", ordinal: 4, text: "latest raw\n"),
        ])

        let reply = try CodexSQLiteReplyResolver(databaseURL: database)
            .latestReply(matchingCopiedText: "copied older")

        XCTAssertEqual(reply, "latest raw\n")
    }

    func testCodexSchemaMismatchFailsClosed() throws {
        let database = try codexDatabase([], schema: "CREATE TABLE thread_items (thread_id TEXT);")

        XCTAssertThrowsError(
            try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "reply")
        ) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .invalidCodexDatabase)
        }
    }

    func testCodexSchemaWithCanonicalColumnsButNoPrimaryKeysFailsClosed() throws {
        let schema = codexSchema
            .replacingOccurrences(of: ",\n    PRIMARY KEY (thread_id, turn_id, item_id)", with: "")
            .replacingOccurrences(of: ",\n    PRIMARY KEY (thread_id, turn_id)", with: "")
        let database = try codexDatabase([], schema: schema)

        XCTAssertThrowsError(
            try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "reply")
        ) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .invalidCodexDatabase)
        }
    }

    func testCodexLatestGeneratingTurnRefusesOldCompletedFinal() throws {
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-1", ordinal: 1, status: "completed", finalItem: "item-1"),
            codexItem(thread: "thread-A", turn: "turn-1", item: "item-1", ordinal: 2, text: "copied older"),
            codexTurn(thread: "thread-A", turn: "turn-2", ordinal: 3, status: "inProgress", finalItem: nil),
        ])

        XCTAssertThrowsError(
            try CodexSQLiteReplyResolver(databaseURL: database).latestReply(matchingCopiedText: "copied older")
        ) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .incompleteCodexReply)
        }
    }

    func testCodexAXRawTreeBindsPlainCopyToAssistantContainerAcrossTraversalOrder() throws {
        let nodes = codexAXTree()

        for fixture in [nodes, Array(nodes.reversed())] {
            XCTAssertEqual(try CodexAXTreeAnalyzer.copyCandidate(in: fixture).id, 26)
        }
    }

    func testCodexAXRawTreeBindsLatestAssistantCopyWithinSharedSiblingContainer() throws {
        let nodes = [
            CodexAXFlatNode(id: 302, parentID: nil, role: "AXGroup", labels: [], canPress: false, order: 302),
            CodexAXFlatNode(id: 303, parentID: 302, role: "AXHeading", labels: ["you said:"], canPress: false, order: 303),
            CodexAXFlatNode(id: 309, parentID: 302, role: "AXButton", labels: ["copy message"], canPress: true, order: 309),
            CodexAXFlatNode(id: 315, parentID: 302, role: "AXHeading", labels: ["chatgpt said:"], canPress: false, order: 315),
            CodexAXFlatNode(id: 374, parentID: 302, role: "AXButton", labels: ["copy"], canPress: true, order: 374),
            CodexAXFlatNode(id: 383, parentID: 302, role: "AXHeading", labels: ["you said:"], canPress: false, order: 383),
            CodexAXFlatNode(id: 389, parentID: 302, role: "AXButton", labels: ["copy message"], canPress: true, order: 389),
            CodexAXFlatNode(id: 393, parentID: 302, role: "AXHeading", labels: ["chatgpt said:"], canPress: false, order: 393),
            CodexAXFlatNode(id: 412, parentID: 302, role: "AXButton", labels: ["copy"], canPress: true, order: 412),
        ]

        for fixture in [nodes, Array(nodes.reversed())] {
            XCTAssertEqual(try CodexAXTreeAnalyzer.copyCandidate(in: fixture).id, 412)
        }
    }

    func testCodexAXRawTreeDoesNotFallbackWhenLatestAssistantActionIsTransientCopied() {
        let nodes = [
            CodexAXFlatNode(id: 0, parentID: nil, role: "AXWindow", labels: [], canPress: false, order: 0),
            CodexAXFlatNode(id: 10, parentID: 0, role: "AXGroup", labels: [], canPress: false, order: 10),
            CodexAXFlatNode(id: 11, parentID: 10, role: "AXHeading", labels: ["ChatGPT said"], canPress: false, order: 11),
            CodexAXFlatNode(id: 12, parentID: 10, role: "AXButton", labels: ["copy"], canPress: true, order: 12),
            CodexAXFlatNode(id: 20, parentID: 0, role: "AXGroup", labels: [], canPress: false, order: 20),
            CodexAXFlatNode(id: 21, parentID: 20, role: "AXHeading", labels: ["ChatGPT said"], canPress: false, order: 21),
            CodexAXFlatNode(id: 22, parentID: 20, role: "AXButton", labels: ["Copied"], canPress: false, order: 22),
        ]

        XCTAssertThrowsError(try CodexAXTreeAnalyzer.copyCandidate(in: nodes)) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .codexCopyTemporarilyUnavailable)
        }
    }

    func testCodexTemporaryAvailabilityPollerRetriesTransientThenReturnsLatestReadyAction() async throws {
        let scans = SequentialSampler([
            codexAssistantActionTree(latestLabel: "Copied", latestCanPress: false),
            codexAssistantActionTree(latestLabel: "copy", latestCanPress: true),
        ])
        let retries = SequentialSampler([true])

        let selected = try await CodexTemporaryAvailabilityPoller.wait(
            scan: {
                try CodexAXTreeAnalyzer.copyCandidate(in: await scans.next())
            },
            retryAfterTemporaryUnavailable: {
                await retries.next()
            }
        )

        XCTAssertEqual(selected.id, 22)
        let remainingScans = await scans.remainingCount
        let remainingRetries = await retries.remainingCount
        XCTAssertEqual(remainingScans, 0)
        XCTAssertEqual(remainingRetries, 0)
    }

    func testCodexTemporaryAvailabilityPollerFailsClosedAtInjectedRetryLimit() async {
        let transient = codexAssistantActionTree(latestLabel: "Copied", latestCanPress: false)
        let scans = SequentialSampler([transient, transient])
        let retries = SequentialSampler([true, false])

        do {
            _ = try await CodexTemporaryAvailabilityPoller.wait(
                scan: {
                    try CodexAXTreeAnalyzer.copyCandidate(in: await scans.next())
                },
                retryAfterTemporaryUnavailable: {
                    await retries.next()
                }
            )
            XCTFail("Expected temporary availability timeout")
        } catch {
            XCTAssertEqual(error as? CurrentAIReplyFailure, .codexCopyTemporarilyUnavailable)
        }
        let remainingScans = await scans.remainingCount
        let remainingRetries = await retries.remainingCount
        XCTAssertEqual(remainingScans, 0)
        XCTAssertEqual(remainingRetries, 0)
    }

    func testCodexAXSiblingSegmentsRejectUnknownHeadingAmbiguousOrderAndCodeAncestor() {
        let parent = CodexAXFlatNode(
            id: 100, parentID: nil, role: "AXGroup", labels: [], canPress: false, order: 100
        )
        let unknownHeading = [
            parent,
            CodexAXFlatNode(id: 101, parentID: 100, role: "AXHeading", labels: ["chatgpt said:"], canPress: false, order: 101),
            CodexAXFlatNode(id: 102, parentID: 100, role: "AXHeading", labels: ["notice"], canPress: false, order: 102),
            CodexAXFlatNode(id: 106, parentID: 100, role: "AXButton", labels: ["copy"], canPress: true, order: 103),
        ]
        let ambiguousOrder = [
            parent,
            CodexAXFlatNode(id: 103, parentID: 100, role: "AXHeading", labels: ["chatgpt said:"], canPress: false, order: 101),
            CodexAXFlatNode(id: 104, parentID: 100, role: "AXGroup", labels: [], canPress: false, order: 101),
            CodexAXFlatNode(id: 105, parentID: 100, role: "AXButton", labels: ["copy"], canPress: true, order: 102),
        ]
        let codeParent = CodexAXFlatNode(
            id: 200, parentID: nil, role: "AXGroup", labels: ["code block"], canPress: false, order: 200
        )
        let codeAncestor = [
            codeParent,
            CodexAXFlatNode(id: 201, parentID: 200, role: "AXHeading", labels: ["chatgpt said:"], canPress: false, order: 201),
            CodexAXFlatNode(id: 202, parentID: 200, role: "AXButton", labels: ["copy"], canPress: true, order: 202),
        ]

        for fixture in [unknownHeading, ambiguousOrder, codeAncestor] {
            XCTAssertThrowsError(try CodexAXTreeAnalyzer.copyCandidate(in: fixture)) { error in
                XCTAssertEqual(error as? CurrentAIReplyFailure, .codexCopyUnavailable)
            }
        }
    }

    func testCodexAXRawTreeRejectsCodeCopyStopAndMissingOrAmbiguousContainerRole() throws {
        let onlyCodeCopy = codexAXTree().filter { $0.id != 26 }
        XCTAssertThrowsError(try CodexAXTreeAnalyzer.copyCandidate(in: onlyCodeCopy)) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .codexCopyUnavailable)
        }

        let stop = CodexAXFlatNode(
            id: 30,
            parentID: 0,
            role: "AXButton",
            labels: ["stop generating"],
            canPress: true,
            order: 30
        )
        XCTAssertThrowsError(try CodexAXTreeAnalyzer.copyCandidate(in: codexAXTree() + [stop])) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .incompleteCodexReply)
        }

        let missingRole = [
            CodexAXFlatNode(id: 0, parentID: nil, role: "AXWindow", labels: [], canPress: false, order: 0),
            CodexAXFlatNode(id: 10, parentID: 0, role: "AXGroup", labels: [], canPress: false, order: 10),
            CodexAXFlatNode(id: 11, parentID: 10, role: "AXButton", labels: ["copy"], canPress: true, order: 11),
        ]
        XCTAssertThrowsError(try CodexAXTreeAnalyzer.copyCandidate(in: missingRole)) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .codexCopyUnavailable)
        }

        let ambiguousRole = codexAXTree() + [
            CodexAXFlatNode(id: 27, parentID: 20, role: "AXHeading", labels: ["ChatGPT said"], canPress: false, order: 27),
        ]
        XCTAssertThrowsError(try CodexAXTreeAnalyzer.copyCandidate(in: ambiguousRole)) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .codexCopyUnavailable)
        }
    }

    func testCodexAXAnalyzerFailsClosedForCycleCandidateCapAndWorkBudget() throws {
        let cycle = [
            CodexAXFlatNode(id: 0, parentID: 1, role: "AXGroup", labels: [], canPress: false, order: 0),
            CodexAXFlatNode(id: 1, parentID: 0, role: "AXGroup", labels: [], canPress: false, order: 1),
        ]
        assertCodexTraversalFailure(try CodexAXTreeAnalyzer.copyCandidate(in: cycle))

        let manyCopies = [
            CodexAXFlatNode(id: 0, parentID: nil, role: "AXWindow", labels: [], canPress: false, order: 0),
            CodexAXFlatNode(id: 1, parentID: 0, role: "AXGroup", labels: [], canPress: false, order: 1),
            CodexAXFlatNode(id: 2, parentID: 1, role: "AXHeading", labels: ["ChatGPT said"], canPress: false, order: 2),
        ] + (0...512).map {
            CodexAXFlatNode(id: 1_000 + $0, parentID: 1, role: "AXButton", labels: ["copy"], canPress: true, order: 1_000 + $0)
        }
        assertCodexTraversalFailure(try CodexAXTreeAnalyzer.copyCandidate(in: manyCopies))

        assertCodexTraversalFailure(
            try CodexAXTreeAnalyzer.copyCandidate(
                in: codexAXTree(),
                limits: .init(
                    maximumNodes: 12_000,
                    maximumDepth: 40,
                    maximumAncestorSteps: 2,
                    maximumCandidates: 512
                )
            )
        )
    }

    func testCodexReaderRejectsFocusedWindowChangeDuringSQLiteResolution() async throws {
        let proof = CodexWindowProof(
            snapshot: CodexAXWindowSnapshot(processIdentifier: 42, focusedWindowIdentifier: "window-A")
        )
        let reader = try codexReader(
            copied: CodexCopiedMessage(text: "reply", proof: proof),
            observedAfterResolve: CodexWindowObservation(
                snapshot: CodexAXWindowSnapshot(processIdentifier: 42, focusedWindowIdentifier: "window-B"),
                isGenerating: false
            )
        )

        await assertFailure(reader, equals: .codexWindowDrift)
    }

    func testCodexReaderRejectsStopAppearingAfterSQLiteResolution() async throws {
        let snapshot = CodexAXWindowSnapshot(processIdentifier: 42, focusedWindowIdentifier: "window-A")
        let reader = try codexReader(
            copied: CodexCopiedMessage(text: "reply", proof: CodexWindowProof(snapshot: snapshot)),
            observedAfterResolve: CodexWindowObservation(snapshot: snapshot, isGenerating: true)
        )

        await assertFailure(reader, equals: .incompleteCodexReply)
    }

    func testCodexReaderRejectsSameWindowWhenSecondProtectedCopyChangesFingerprint() async throws {
        let snapshot = CodexAXWindowSnapshot(processIdentifier: 42, focusedWindowIdentifier: "window-A")
        let proof = CodexWindowProof(snapshot: snapshot)
        let copies = SequentialSampler([
            CodexCopiedMessage(text: "fingerprint A", proof: proof),
            CodexCopiedMessage(text: "fingerprint B", proof: proof),
        ])
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-A", ordinal: 1, status: "completed", finalItem: "item-A"),
            codexItem(thread: "thread-A", turn: "turn-A", item: "item-A", ordinal: 2, text: "fingerprint A"),
        ])
        let reader = CurrentAIReplyReader(
            frontmostBundleIdentifier: { "com.openai.codex" },
            claudeLocalID: { XCTFail("Claude must not be read"); return "" },
            claudeMetadataFiles: { _ in XCTFail("Claude must not be read"); return [] },
            claudeTranscriptFiles: { _ in XCTFail("Claude must not be read"); return [] },
            codexMessageCopier: { await copies.next() },
            codexDatabaseURL: { database },
            codexWindowRevalidator: { observedProof in
                XCTAssertEqual(observedProof, proof)
            }
        )

        await assertFailure(reader, equals: .codexWindowDrift)
    }

    func testCodexReaderSameProofAndFingerprintReturnsOriginallyResolvedLatestFinal() async throws {
        let snapshot = CodexAXWindowSnapshot(processIdentifier: 42, focusedWindowIdentifier: "window-A")
        let proof = CodexWindowProof(snapshot: snapshot)
        let copies = SequentialSampler([
            CodexCopiedMessage(text: "fingerprint A\n", proof: proof),
            CodexCopiedMessage(text: "fingerprint A\t\n", proof: proof),
        ])
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-1", ordinal: 1, status: "completed", finalItem: "item-1"),
            codexItem(thread: "thread-A", turn: "turn-1", item: "item-1", ordinal: 2, text: "fingerprint A"),
            codexTurn(thread: "thread-A", turn: "turn-2", ordinal: 3, status: "completed", finalItem: "item-2"),
            codexItem(thread: "thread-A", turn: "turn-2", item: "item-2", ordinal: 4, text: "original latest final"),
        ])
        let reader = CurrentAIReplyReader(
            frontmostBundleIdentifier: { "com.openai.codex" },
            claudeLocalID: { XCTFail("Claude must not be read"); return "" },
            claudeMetadataFiles: { _ in XCTFail("Claude must not be read"); return [] },
            claudeTranscriptFiles: { _ in XCTFail("Claude must not be read"); return [] },
            codexMessageCopier: { await copies.next() },
            codexDatabaseURL: { database },
            codexWindowRevalidator: { observedProof in
                XCTAssertEqual(observedProof, proof)
            }
        )

        let reply = try await reader.readIfSupported()
        XCTAssertEqual(reply, "original latest final")
    }

    func testCodexRevalidationRejectsReplacementCopyControlInSameWindow() throws {
        let snapshot = CodexAXWindowSnapshot(processIdentifier: 42, focusedWindowIdentifier: "window-A")
        let original = CodexAXElementBox(AXUIElementCreateApplication(101))
        let replacement = CodexAXElementBox(AXUIElementCreateApplication(102))
        let proof = CodexWindowProof(snapshot: snapshot, copyElement: original)
        XCTAssertThrowsError(try CodexWindowProofValidator.validate(
            expected: proof,
            observed: CodexWindowObservation(snapshot: snapshot, isGenerating: false, elements: [replacement])
        )) { error in XCTAssertEqual(error as? CurrentAIReplyFailure, .codexWindowDrift) }
        XCTAssertNoThrow(try CodexWindowProofValidator.validate(
            expected: proof,
            observed: CodexWindowObservation(snapshot: snapshot, isGenerating: false, elements: [original])
        ))
    }

    func testCodexResolverEnforcesCumulativeJSONBudget() throws {
        let first = String(repeating: "a", count: 64)
        let rows = [
            codexTurn(thread: "thread-A", turn: "turn-1", ordinal: 1, status: "completed", finalItem: "item-1"),
            codexItem(thread: "thread-A", turn: "turn-1", item: "item-1", ordinal: 2, text: first),
            codexTurn(thread: "thread-A", turn: "turn-2", ordinal: 3, status: "completed", finalItem: "item-2"),
            codexItem(thread: "thread-A", turn: "turn-2", item: "item-2", ordinal: 4, text: String(repeating: "b", count: 64)),
        ]
        let limits = CodexResolverLimits(maxItemJSONBytes: 1_024, maxTotalItemJSONBytes: 200)
        let single = try CodexSQLiteReplyResolver(databaseURL: codexDatabase(Array(rows.prefix(2))), limits: limits)
        XCTAssertEqual(try single.latestReply(matchingCopiedText: first), first)
        let multiple = try CodexSQLiteReplyResolver(databaseURL: codexDatabase(rows), limits: limits)
        assertCodexOversized(try multiple.latestReply(matchingCopiedText: first))
    }

    func testCodexResolverRejectsCopiedRowJSONAndTextLimits() throws {
        let oneReply = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-A", ordinal: 1, status: "completed", finalItem: "item-A"),
            codexItem(thread: "thread-A", turn: "turn-A", item: "item-A", ordinal: 2, text: "reply"),
        ])
        assertCodexOversized(
            try CodexSQLiteReplyResolver(
                databaseURL: oneReply,
                limits: .init(maxCopiedTextBytes: 4, maxRows: 10, maxItemJSONBytes: 1_024, maxTextBytes: 1_024)
            ).latestReply(matchingCopiedText: "reply")
        )

        let twoRows = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-1", ordinal: 1, status: "completed", finalItem: "item-1"),
            codexItem(thread: "thread-A", turn: "turn-1", item: "item-1", ordinal: 2, text: "reply"),
            codexTurn(thread: "thread-A", turn: "turn-2", ordinal: 3, status: "completed", finalItem: "item-2"),
            codexItem(thread: "thread-A", turn: "turn-2", item: "item-2", ordinal: 4, text: "latest"),
        ])
        assertCodexOversized(
            try CodexSQLiteReplyResolver(
                databaseURL: twoRows,
                limits: .init(maxCopiedTextBytes: 100, maxRows: 1, maxItemJSONBytes: 1_024, maxTextBytes: 1_024)
            ).latestReply(matchingCopiedText: "reply")
        )
        assertCodexOversized(
            try CodexSQLiteReplyResolver(
                databaseURL: oneReply,
                limits: .init(maxCopiedTextBytes: 100, maxRows: 10, maxItemJSONBytes: 20, maxTextBytes: 1_024)
            ).latestReply(matchingCopiedText: "reply")
        )
        assertCodexOversized(
            try CodexSQLiteReplyResolver(
                databaseURL: oneReply,
                limits: .init(maxCopiedTextBytes: 100, maxRows: 10, maxItemJSONBytes: 1_024, maxTextBytes: 4)
            ).latestReply(matchingCopiedText: "reply")
        )
    }

    func testCodexAXCopyUsesPasteboardTransportAndRestoresSnapshot() async throws {
        let original = [
            PasteboardItem(types: ["public.utf8-plain-text": Data("old".utf8), "custom": Data([1, 2])]),
            PasteboardItem(types: ["public.rtf": Data([3, 4])]),
        ]
        let client = CurrentReplyPasteboardClient(items: original)
        let transport = PasteboardTransport(client: client, timeout: .milliseconds(30))

        let copied = try await CodexAXPasteboardCopy.read(using: transport) { ownership in
            client.replaceWithCopiedText("assistant reply")
            ownership.copyCommandDispatched()
        }

        XCTAssertEqual(copied, "assistant reply")
        XCTAssertEqual(client.items, original)
    }

    private func claudeReader(
        transcript: Data? = nil,
        transcriptFiles: [URL]? = nil,
        frontmostBundleIdentifier: @escaping CurrentAIReplyReader.FrontmostBundleIdentifier = { "com.anthropic.claudefordesktop" },
        claudeLocalID: @escaping CurrentAIReplyReader.ClaudeLocalID = { "local_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }
    ) throws -> CurrentAIReplyReader {
        makeReader(
            bundleReader: frontmostBundleIdentifier,
            localIDReader: claudeLocalID,
            metadataFiles: try fixtureFiles([metadata(sessionID: localA, cliSessionID: cliA)]),
            transcriptFiles: try transcriptFiles ?? fixtureFiles([
                transcript ?? self.transcript(sessionID: cliA, text: "reply")
            ])
        )
    }

    private func makeReader(
        bundle: String,
        localID: String,
        metadataFiles: [URL],
        transcriptFiles: [URL]
    ) -> CurrentAIReplyReader {
        makeReader(
            bundleReader: { bundle },
            localIDReader: { localID },
            metadataFiles: metadataFiles,
            transcriptFiles: transcriptFiles
        )
    }

    private func makeReader(
        bundleReader: @escaping CurrentAIReplyReader.FrontmostBundleIdentifier,
        localIDReader: @escaping CurrentAIReplyReader.ClaudeLocalID,
        metadataFiles: [URL],
        transcriptFiles: [URL]
    ) -> CurrentAIReplyReader {
        CurrentAIReplyReader(
            frontmostBundleIdentifier: bundleReader,
            claudeLocalID: localIDReader,
            claudeMetadataFiles: { _ in metadataFiles },
            claudeTranscriptFiles: { _ in transcriptFiles }
        )
    }

    private func assertFailure(_ reader: CurrentAIReplyReader, equals expected: CurrentAIReplyFailure) async {
        await XCTAssertThrowsErrorAsync(try await reader.readIfSupported()) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, expected)
        }
    }

    private func fixtureFiles(_ payloads: [Data]) throws -> [URL] {
        let directory = try temporaryDirectory()
        return try payloads.enumerated().map { index, payload in
            let url = directory.appendingPathComponent("fixture-\(index).json")
            try payload.write(to: url, options: .atomic)
            return url
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeFixture(_ data: Data, relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func sparseFile(byteCount: Int) throws -> URL {
        let url = try fixtureFiles([Data()]).first!
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
        return url
    }

    private func metadata(sessionID: String, cliSessionID: String) -> Data {
        Data("{\"sessionId\":\"\(sessionID)\",\"cliSessionId\":\"\(cliSessionID)\"}".utf8)
    }

    private func transcript(sessionID: String, text: String) -> Data {
        Data(transcriptLine(sessionID: sessionID, stopReason: "end_turn", content: [.text(text)]).utf8)
    }

    private func transcriptLine(
        sessionID: String,
        sidechain: Bool = false,
        stopReason: String,
        content: [TranscriptContent]
    ) -> String {
        "{\"sessionId\":\"\(sessionID)\",\"type\":\"assistant\",\"isSidechain\":\(sidechain),\"message\":{\"role\":\"assistant\",\"stop_reason\":\"\(stopReason)\",\"content\":[\(content.map(\.json).joined(separator: ","))]}}"
    }

    private func userTranscriptLine(sessionID: String) -> String {
        "{\"sessionId\":\"\(sessionID)\",\"type\":\"user\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"next prompt\"}]}}"
    }

    private func codexReader(
        copied: CodexCopiedMessage,
        observedAfterResolve: CodexWindowObservation
    ) throws -> CurrentAIReplyReader {
        let database = try codexDatabase([
            codexTurn(thread: "thread-A", turn: "turn-A", ordinal: 1, status: "completed", finalItem: "item-A"),
            codexItem(thread: "thread-A", turn: "turn-A", item: "item-A", ordinal: 2, text: "reply"),
        ])
        return CurrentAIReplyReader(
            frontmostBundleIdentifier: { "com.openai.codex" },
            claudeLocalID: { XCTFail("Claude must not be read"); return "" },
            claudeMetadataFiles: { _ in XCTFail("Claude must not be read"); return [] },
            claudeTranscriptFiles: { _ in XCTFail("Claude must not be read"); return [] },
            codexMessageCopier: { copied },
            codexDatabaseURL: { database },
            codexWindowRevalidator: { proof in
                try CodexWindowProofValidator.validate(expected: proof, observed: observedAfterResolve)
            }
        )
    }

    private func assertCodexOversized(_ expression: @autoclosure () throws -> String) {
        XCTAssertThrowsError(try expression()) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .oversizedCodexData)
        }
    }

    private func assertCodexTraversalFailure(
        _ expression: @autoclosure () throws -> CodexAXCopyCandidate
    ) {
        XCTAssertThrowsError(try expression()) { error in
            XCTAssertEqual(error as? CurrentAIReplyFailure, .codexTraversalLimitExceeded)
        }
    }

    private func codexAXTree() -> [CodexAXFlatNode] {
        [
            .init(id: 0, parentID: nil, role: "AXWindow", labels: [], canPress: false, order: 0),
            .init(id: 10, parentID: 0, role: "AXGroup", labels: ["user message"], canPress: false, order: 10),
            .init(id: 11, parentID: 10, role: "AXHeading", labels: ["You said"], canPress: false, order: 11),
            .init(id: 12, parentID: 10, role: "AXGroup", labels: ["message actions"], canPress: false, order: 12),
            .init(id: 13, parentID: 12, role: "AXButton", labels: ["copy"], canPress: true, order: 13),
            .init(id: 20, parentID: 0, role: "AXGroup", labels: ["assistant message"], canPress: false, order: 20),
            .init(id: 21, parentID: 20, role: "AXHeading", labels: ["ChatGPT said"], canPress: false, order: 21),
            .init(id: 22, parentID: 20, role: "AXGroup", labels: ["message body"], canPress: false, order: 22),
            .init(id: 23, parentID: 22, role: "AXGroup", labels: ["code block"], canPress: false, order: 23),
            .init(id: 24, parentID: 23, role: "AXButton", labels: ["copy"], canPress: true, order: 24),
            .init(id: 25, parentID: 20, role: "AXGroup", labels: ["message actions"], canPress: false, order: 25),
            .init(id: 26, parentID: 25, role: "AXButton", labels: ["copy"], canPress: true, order: 26),
        ]
    }

    private func codexAssistantActionTree(
        latestLabel: String,
        latestCanPress: Bool
    ) -> [CodexAXFlatNode] {
        [
            CodexAXFlatNode(id: 0, parentID: nil, role: "AXWindow", labels: [], canPress: false, order: 0),
            CodexAXFlatNode(id: 10, parentID: 0, role: "AXGroup", labels: [], canPress: false, order: 10),
            CodexAXFlatNode(id: 11, parentID: 10, role: "AXHeading", labels: ["ChatGPT said"], canPress: false, order: 11),
            CodexAXFlatNode(id: 12, parentID: 10, role: "AXButton", labels: ["copy"], canPress: true, order: 12),
            CodexAXFlatNode(id: 20, parentID: 0, role: "AXGroup", labels: [], canPress: false, order: 20),
            CodexAXFlatNode(id: 21, parentID: 20, role: "AXHeading", labels: ["ChatGPT said"], canPress: false, order: 21),
            CodexAXFlatNode(id: 22, parentID: 20, role: "AXButton", labels: [latestLabel], canPress: latestCanPress, order: 22),
        ]
    }

    private func codexDatabase(
        _ statements: [String],
        schema: String? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("thread-history.sqlite")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(([schema ?? codexSchema] + statements).joined(separator: "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return database
    }

    private func codexTurn(
        thread: String,
        turn: String,
        ordinal: Int,
        status: String,
        finalItem: String?
    ) -> String {
        "INSERT INTO thread_turns "
            + "(thread_id, turn_id, rollout_ordinal, status, final_agent_item_id) VALUES "
            + "('\(sql(thread))', '\(sql(turn))', \(ordinal), '\(sql(status))', \(finalItem.map { "'\(sql($0))'" } ?? "NULL"));"
    }

    private func codexItem(
        thread: String,
        turn: String,
        item: String,
        ordinal: Int,
        text: String,
        phase: Any = "final_answer"
    ) -> String {
        let json = try! String(
            data: JSONSerialization.data(
                withJSONObject: ["type": "agentMessage", "phase": phase, "text": text],
                options: [.sortedKeys]
            ),
            encoding: .utf8
        )!
        return "INSERT INTO thread_items "
            + "(thread_id, turn_id, item_id, rollout_ordinal, created_at_ms, item_json, item_type, updated_at_ordinal) VALUES "
            + "('\(sql(thread))', '\(sql(turn))', '\(sql(item))', \(ordinal), \(ordinal), '\(sql(json))', 'agentMessage', \(ordinal));"
    }

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private var codexSchema: String {
        """
        CREATE TABLE thread_items (
            thread_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            rollout_ordinal INTEGER NOT NULL,
            created_at_ms INTEGER NOT NULL,
            item_json TEXT NOT NULL,
            item_type TEXT NOT NULL DEFAULT '',
            updated_at_ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (thread_id, turn_id, item_id)
        );
        CREATE TABLE thread_turns (
            thread_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            rollout_ordinal INTEGER NOT NULL,
            status TEXT NOT NULL,
            error_json TEXT,
            started_at INTEGER,
            completed_at INTEGER,
            duration_ms INTEGER,
            first_user_item_id TEXT,
            final_agent_item_id TEXT,
            rollout_byte_offset INTEGER,
            rollout_end_ordinal INTEGER,
            rollout_end_byte_offset INTEGER,
            PRIMARY KEY (thread_id, turn_id)
        );
        """
    }
}

private enum TranscriptContent {
    case text(String)
    case thinking(String)
    case toolUse
    case unknown

    var json: String {
        switch self {
        case .text(let value): return "{\"type\":\"text\",\"text\":\"\(value)\"}"
        case .thinking(let value): return "{\"type\":\"thinking\",\"thinking\":\"\(value)\"}"
        case .toolUse: return "{\"type\":\"tool_use\",\"id\":\"tool-1\",\"name\":\"Read\",\"input\":{}}"
        case .unknown: return "{\"type\":\"image\",\"url\":\"ignored\"}"
        }
    }
}

private actor SequentialSampler<Value: Sendable> {
    private var values: [Value]

    init(_ values: [Value]) {
        self.values = values
    }

    func next() -> Value {
        precondition(!values.isEmpty, "Unexpected extra sample")
        return values.removeFirst()
    }

    var remainingCount: Int { values.count }
}

private final class CurrentReplyPasteboardClient: @unchecked Sendable, PasteboardClient {
    private let lock = NSLock()
    private var storedItems: [PasteboardItem]
    private var count = 0

    init(items: [PasteboardItem]) { storedItems = items }
    var items: [PasteboardItem] { lock.withLock { storedItems } }
    var changeCount: Int { lock.withLock { count } }
    func snapshotAllItems() throws -> PasteboardSnapshot { PasteboardSnapshot(items: items) }
    func restore(_ snapshot: PasteboardSnapshot) throws { replace(snapshot.items) }
    func installOperationMarker(_ marker: PasteboardOperationMarker) throws {
        var current = items
        var types = current.first?.types ?? [:]
        types["app.aloud.pasteboard-operation"] = Data(marker.rawValue.uuidString.utf8)
        if current.isEmpty { current = [PasteboardItem(types: types)] }
        else { current[0] = PasteboardItem(types: types) }
        replace(current)
    }
    func containsOperationMarker(_ marker: PasteboardOperationMarker) -> Bool {
        items.contains { $0.types["app.aloud.pasteboard-operation"] == Data(marker.rawValue.uuidString.utf8) }
    }
    func nonEmptyString() throws -> String {
        guard let data = items.lazy.compactMap({ $0.types["public.utf8-plain-text"] }).first,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw PasteboardTransportError.noText
        }
        return value
    }
    func replaceWithCopiedText(_ value: String) {
        replace([PasteboardItem(types: ["public.utf8-plain-text": Data(value.utf8)])])
    }
    private func replace(_ items: [PasteboardItem]) {
        lock.withLock { storedItems = items; count += 1 }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        errorHandler(error)
    }
}

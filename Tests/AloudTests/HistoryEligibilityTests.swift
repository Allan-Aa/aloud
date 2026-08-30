import XCTest
@testable import Aloud

final class HistoryEligibilityTests: XCTestCase {
    func testHistoryPanelPolicyIsTheCentralizedActionPolicy() throws {
        let entry = HistoryEntry(id: UUID(), version: 1, text: "valid", contentResolution: .valid, seconds: 1, providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"), voiceID: VoiceID(rawValue: "minimax.radio-host.default"), rate: NormalizedRate(version: MiniMaxRateMappingV1.version, value: 0)!, displayLabelSnapshot: "voice", selectionResolution: .resolved, date: nil, legacyAgoSnapshot: nil)
        XCTAssertEqual(HistoryPanel.actionPolicy(for: entry), HistoryActionPolicy(entry: entry))
    }
    private func entry(text: String?, content: HistoryContentResolution, selection: HistorySelectionResolution = .resolved) -> HistoryEntry {
        HistoryEntry(id: UUID(), version: 1, text: text, contentResolution: content, seconds: 1,
                     providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"),
                     voiceID: selection == .resolved ? VoiceID(rawValue: "minimax.radio-host.default") : nil,
                     rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 1)!,
                     displayLabelSnapshot: "电台主持", selectionResolution: selection,
                     date: nil, legacyAgoSnapshot: nil)
    }

    func testOnlyValidContentIsSearchableCopyableAndLoadable() {
        XCTAssertEqual(HistoryEligibility(for: entry(text: "safe", content: .valid)).actions, [.search, .copy, .load, .replay])
        XCTAssertEqual(HistoryEligibility(for: entry(text: nil, content: .missing)).actions, [])
        XCTAssertEqual(HistoryEligibility(for: entry(text: nil, content: .skipped)).actions, [])
    }

    func testUnresolvedLegacyVoiceAllowsLoadButBlocksReplay() {
        let eligibility = HistoryEligibility(for: entry(text: "safe", content: .valid, selection: .unresolvedLegacyVoice))
        XCTAssertTrue(eligibility.allows(.load))
        XCTAssertFalse(eligibility.allows(.replay))
        XCTAssertEqual(eligibility.selectionMessage, "选择音色/配置")
    }

    func testVisibleContentMessagesAreClosedAndDoNotPretendMissingContentIsSearchable() {
        XCTAssertEqual(HistoryEligibility(for: entry(text: nil, content: .skipped)).contentMessage, "内容不可用（已跳过）")
        XCTAssertEqual(HistoryEligibility(for: entry(text: nil, content: .missing)).contentMessage, "无保存正文")
    }
}

import Foundation

struct DictRule: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var find: String
    var replace: String
    var enabled: Bool
}

/// 视觉阶段的假数据。接真功能时整块替换成 store。
enum Mock {
    static let history: [HistoryEntry] = [
        history("为什么用合成语速而不是倍速：合成语速是让模型按那个节奏去说，换气和停顿都跟着重新分配，听感自然；倍速是把已经生成好的音频机械拉伸。", 11, "电台主持", 50, "1 小时前"),
        history("念念不忘，必有回响。这段字用来看合成和播放的动效。", 3, "电台主持", 50, "2 小时前"),
        history("13x6 直发价格带调研：主推 30 寸，落在 $85-99 这一档，竞品在这个区间的评论增速最快。", 8, "松弛女孩", 15, "昨天"),
        history("亚马逊标题新规 75 字符已生效，超限会被 AI 改写丢词，14 天窗口只对品牌备案开放。", 7, "电台主持", 50, "昨天"),
        history("发包滚动备货模版用水位线补货法，ASIN 级修正后建议 5970 件，草稿里的 12200 超备了一倍。", 9, "电台主持", 30, "2 天前"),
    ]

    private static func history(_ text: String, _ seconds: Int, _ label: String, _ rate: Int, _ ago: String) -> HistoryEntry {
        let voice = LegacyVoiceMapV1.voices[label]
        return HistoryEntry(id: UUID(), version: 1, text: text, contentResolution: .valid, seconds: seconds,
                            providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"), voiceID: voice,
                            rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: rate)!,
                            displayLabelSnapshot: label,
                            selectionResolution: voice == nil ? .unresolvedLegacyVoice : .resolved,
                            date: nil, legacyAgoSnapshot: ago)
    }

    static let rules: [DictRule] = [
        .init(find: "THE FOX", replace: "the fox", enabled: true),
        .init(find: "wigfam", replace: "wig fam", enabled: true),
        .init(find: "ASIN", replace: "A-sin", enabled: true),
        .init(find: "D2C", replace: "D-to-C", enabled: false),
    ]

    static let voices = ["电台主持", "电台主持 · fluent", "松弛女孩", "松弛女孩 · fluent"]
}

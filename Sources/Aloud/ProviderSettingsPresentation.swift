import Foundation

struct ProviderModelOption: Identifiable, Equatable, Sendable {
    let id: ModelID
    let title: String
}

enum ProviderVoiceGroup: CaseIterable, Equatable, Hashable, Sendable {
    case recommended
    case system
    case cloned
    case generated

    var title: String {
        switch self {
        case .recommended: return "推荐"
        case .system: return "系统音色"
        case .cloned: return "我的克隆"
        case .generated: return "我的生成"
        }
    }

    var sectionOrder: Int {
        switch self {
        case .recommended: return 0
        case .system: return 500
        case .cloned: return 900
        case .generated: return 1_000
        }
    }
}

struct ProviderVoiceSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let options: [ProviderVoiceOption]
}

enum ProviderVoicePickerCatalog {
    static func sections(
        voices: [ProviderVoiceOption], query: String
    ) -> [ProviderVoiceSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = voices.filter { option in
            needle.isEmpty || option.title.localizedCaseInsensitiveContains(needle)
        }
        let grouped = Dictionary(grouping: filtered) { option in
            VoiceSectionKey(order: option.sectionOrder, title: option.sectionTitle)
        }
        return grouped.keys.sorted().compactMap { key in
            guard let options = grouped[key]?.sorted(by: precedes) else { return nil }
            return ProviderVoiceSection(
                id: "\(key.order):\(key.title)", title: key.title, options: options
            )
        }
    }

    private struct VoiceSectionKey: Hashable, Comparable {
        let order: Int
        let title: String

        static func < (lhs: VoiceSectionKey, rhs: VoiceSectionKey) -> Bool {
            lhs.order == rhs.order
                ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                : lhs.order < rhs.order
        }
    }

    private static func precedes(
        _ lhs: ProviderVoiceOption, _ rhs: ProviderVoiceOption
    ) -> Bool {
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

struct ProviderVoiceOption: Identifiable, Equatable, Sendable {
    let id: VoiceID
    let title: String
    let wireID: String
    let languageTag: String
    let group: ProviderVoiceGroup
    let sectionTitle: String
    let sectionOrder: Int

    init(
        id: VoiceID,
        title: String,
        wireID: String? = nil,
        languageTag: String = "zh-CN",
        group: ProviderVoiceGroup = .system,
        sectionTitle: String? = nil,
        sectionOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.wireID = wireID ?? id.rawValue
        self.languageTag = languageTag
        self.group = group
        self.sectionTitle = sectionTitle ?? group.title
        self.sectionOrder = sectionOrder ?? group.sectionOrder
    }
}

struct ProviderVoiceControlState: Equatable, Sendable {
    let providerID: ProviderID
    let modelID: ModelID
    let voices: [ProviderVoiceOption]
    let selectedVoiceID: VoiceID
    let rate: NormalizedRate
    let canMutate: Bool
}

struct ProviderSidebarPresentation: Identifiable, Equatable, Sendable {
    let id: ProviderID
    let title: String
    let status: String
    let isDefault: Bool
    let isEnabled: Bool
}

struct ProviderDetailPresentation: Equatable, Sendable {
    let id: ProviderID
    let title: String
    let status: String
    let models: [ProviderModelOption]
    let voices: [ProviderVoiceOption]
    let credentialMessage: String
    let technicalDetails: String
}

struct ProviderSettingsPresentation: Equatable, Sendable {
    let sidebar: [ProviderSidebarPresentation]
    let detail: ProviderDetailPresentation
    let primaryText: String
}

enum ProviderSettingsPresenter {
    static func voiceControl(
        state: ProviderSettingsState,
        providerID: ProviderID,
        systemVoices: [SystemVoiceDescriptor],
        language: Lang
    ) -> ProviderVoiceControlState? {
        let card = state.cards.first { $0.id == providerID }
        guard let card, let selection = card.selection, let voiceID = selection.voiceID else { return nil }
        let presentation = make(
            state: state,
            selectedProviderID: providerID,
            credentialStatuses: [:],
            systemVoices: systemVoices,
            language: language
        )
        return ProviderVoiceControlState(
            providerID: providerID,
            modelID: selection.modelID,
            voices: presentation.detail.voices,
            selectedVoiceID: voiceID,
            rate: selection.rate,
            canMutate: ProviderSettingsPersistenceGate.canMutateSelection(card)
        )
    }

    static func make(
        state: ProviderSettingsState,
        selectedProviderID: ProviderID,
        credentialStatuses: [ProviderID: ProviderCredentialUIStatus],
        systemVoices: [SystemVoiceDescriptor],
        language: Lang
    ) -> ProviderSettingsPresentation {
        let selected = state.cards.first(where: { $0.id == selectedProviderID }) ?? state.cards[0]
        let sidebar = state.cards.map { card in
            ProviderSidebarPresentation(
                id: card.id,
                title: providerTitle(card.id),
                status: status(for: card, credentialStatus: credentialStatuses[card.id], language: language),
                isDefault: card.isDefault,
                isEnabled: ProviderSettingsPersistenceGate.canMutateSelection(card)
            )
        }
        let knownModels = models(for: selected.id)
        let selectedModelIsKnown = selected.selection.map { selection in knownModels.contains { $0.id == selection.modelID } } ?? true
        let modelOptions = selectedModelIsKnown ? knownModels : [ProviderModelOption(id: selected.selection!.modelID, title: unavailable(language))]
        let knownVoices = voices(
            for: selected.id,
            selectedVoiceID: selected.selection?.voiceID,
            availableVoices: selected.availableVoices,
            systemVoices: systemVoices
        )
        let selectedVoiceIsKnown = selected.selection?.voiceID.map { voice in knownVoices.contains { $0.id == voice } } ?? true
        let voiceOptions = voiceOptions(
            knownVoices,
            selectedVoiceID: selected.selection?.voiceID,
            language: language
        )
        let technicalDetails = technicalDetails(for: selected)
        let detail = ProviderDetailPresentation(
            id: selected.id,
            title: providerTitle(selected.id),
            status: status(for: selected, credentialStatus: credentialStatuses[selected.id], language: language),
            models: modelOptions,
            voices: voiceOptions,
            credentialMessage: credentialStatuses[selected.id]?.message(language) ?? selected.statusText,
            technicalDetails: technicalDetails
        )
        return ProviderSettingsPresentation(sidebar: sidebar, detail: detail, primaryText: primaryText(for: detail, selectedModelIsKnown: selectedModelIsKnown, selectedVoiceIsKnown: selectedVoiceIsKnown, language: language))
    }

    private static func providerTitle(_ id: ProviderID) -> String {
        switch id {
        case .minimax: return "MiniMax"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .macOS: return "macOS"
        default: return "语音服务"
        }
    }

    private static func status(for card: ProviderCardState, credentialStatus: ProviderCredentialUIStatus?, language: Lang) -> String {
        if let availability = availabilityMessage(for: card.availability, language: language) { return availability }
        if let credentialStatus, credentialStatus != .configured { return credentialStatus.message(language) }
        guard card.configuration == .configured else { return card.statusText }
        if let health = healthMessage(for: card.health, language: language) { return health }
        return credentialStatus?.message(language) ?? card.statusText
    }

    private static func healthMessage(for health: ProviderHealth, language: Lang) -> String? {
        switch health {
        case .unknown: return nil
        case .verifying: return language == .zh ? "正在试听…" : "Previewing…"
        case .recentSuccess: return language == .zh ? "试听成功" : "Preview succeeded"
        case .recoverableFailure: return language == .zh ? "试听失败，请重试" : "Preview failed. Try again."
        case .explicitRejected: return language == .zh ? "API Key 被服务商拒绝" : "The provider rejected this API key"
        }
    }

    private static func availabilityMessage(for availability: ProviderAvailability, language: Lang) -> String? {
        switch availability.kind {
        case .disabled: return language == .zh ? "当前服务已禁用" : "This provider is disabled"
        case .deprecated: return language == .zh ? "当前服务已弃用" : "This provider is deprecated"
        case .unknown: return language == .zh ? "当前服务暂不可用" : "This provider is unavailable"
        case .experimental where availability.featureFlagEnabled != true:
            return language == .zh ? "当前服务尚未启用" : "This provider is not enabled"
        case .available, .experimental: return nil
        }
    }

    private static func models(for id: ProviderID) -> [ProviderModelOption] {
        switch id {
        case .minimax: return [.init(id: MiniMaxWireContractV1.modelID, title: "高品质语音 2.8")]
        case .openAI: return [
            .init(id: OpenAIWireContractV1.tts1, title: "标准语音"),
            .init(id: OpenAIWireContractV1.tts1HD, title: "高品质语音")
        ]
        case .gemini: return [.init(id: GeminiWireContractV1.modelID, title: "Gemini 2.5 Pro Preview TTS")]
        case .macOS: return [.init(id: SystemVoiceContractV1.modelID, title: "系统语音")]
        default: return []
        }
    }

    private static func voices(
        for id: ProviderID,
        selectedVoiceID: VoiceID?,
        availableVoices: [MiniMaxVoiceDescriptor],
        systemVoices: [SystemVoiceDescriptor]
    ) -> [ProviderVoiceOption] {
        switch id {
        case .minimax:
            var options = availableVoices.map {
                let placement = miniMaxVoicePlacement(for: $0)
                return ProviderVoiceOption(
                    id: $0.stableID,
                    title: miniMaxVoiceTitle(for: $0),
                    wireID: $0.wireID,
                    languageTag: miniMaxLanguageTag(for: $0.wireID),
                    group: placement.group,
                    sectionTitle: placement.title,
                    sectionOrder: placement.order
                )
            }
            if let legacy = selectedVoiceID, let replacement = legacyMiniMaxOption(for: legacy),
               let index = options.firstIndex(where: { $0.id == replacement.id }) {
                let current = options[index]
                options[index] = .init(
                    id: legacy, title: replacement.title, wireID: current.wireID,
                    languageTag: current.languageTag, group: replacement.group,
                    sectionTitle: current.sectionTitle, sectionOrder: current.sectionOrder
                )
            }
            return options
        case .openAI:
            return OpenAIVoiceCatalogV1.voices.sorted { $0.rawValue < $1.rawValue }.map {
                .init(id: $0, title: String($0.rawValue.dropFirst("openai.".count)).capitalized, wireID: String($0.rawValue.dropFirst("openai.".count)), languageTag: "en-US")
            }
        case .gemini:
            return GeminiVoiceCatalogV1.voices.sorted { $0.rawValue < $1.rawValue }.map {
                .init(id: $0, title: String($0.rawValue.dropFirst("gemini.".count)), wireID: String($0.rawValue.dropFirst("gemini.".count)), languageTag: "en-US")
            }
        case .macOS:
            return systemVoices.map { .init(id: VoiceID(rawValue: "macos.\($0.identifier)"), title: "\($0.name) · \($0.language)", wireID: $0.identifier, languageTag: $0.language) }
        default: return []
        }
    }

    private static func voiceOptions(
        _ knownVoices: [ProviderVoiceOption],
        selectedVoiceID: VoiceID?,
        language: Lang
    ) -> [ProviderVoiceOption] {
        guard let selectedVoiceID, !knownVoices.contains(where: { $0.id == selectedVoiceID }) else {
            return knownVoices
        }
        var options = knownVoices
        let insertionIndex = options.lastIndex(where: { $0.group == .system }).map { $0 + 1 } ?? 0
        options.insert(
            ProviderVoiceOption(id: selectedVoiceID, title: unavailable(language), group: .system),
            at: insertionIndex
        )
        return options
    }

    private static func miniMaxVoiceTitle(for descriptor: MiniMaxVoiceDescriptor) -> String {
        let displayName = descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isReadableMiniMaxVoiceTitle(displayName, stableID: descriptor.stableID) { return displayName }
        let wireID = descriptor.wireID.trimmingCharacters(in: .whitespacesAndNewlines)
        if isReadableMiniMaxVoiceTitle(wireID, stableID: descriptor.stableID) { return wireID }
        return "未命名音色"
    }

    private static func miniMaxLanguageTag(for wireID: String) -> String {
        if wireID.hasPrefix("English_") { return "en-US" }
        if wireID.hasPrefix("Japanese_") { return "ja-JP" }
        if wireID.hasPrefix("Korean_") { return "ko-KR" }
        if wireID.hasPrefix("Spanish_") { return "es-ES" }
        if wireID.hasPrefix("French_") { return "fr-FR" }
        if wireID.hasPrefix("German_") { return "de-DE" }
        if wireID.hasPrefix("Portuguese_") { return "pt-PT" }
        if wireID.hasPrefix("Italian_") { return "it-IT" }
        if wireID.hasPrefix("Russian_") { return "ru-RU" }
        if wireID.hasPrefix("Arabic_") { return "ar-SA" }
        if wireID.hasPrefix("Turkish_") { return "tr-TR" }
        if wireID.hasPrefix("Vietnamese_") { return "vi-VN" }
        if wireID.hasPrefix("Indonesian_") { return "id-ID" }
        if wireID.hasPrefix("Thai_") { return "th-TH" }
        if wireID.hasPrefix("Dutch_") { return "nl-NL" }
        if wireID.hasPrefix("Ukrainian_") { return "uk-UA" }
        if wireID.hasPrefix("Polish_") { return "pl-PL" }
        if wireID.hasPrefix("Romanian_") { return "ro-RO" }
        if wireID.lowercased().hasPrefix("greek_") { return "el-GR" }
        if wireID.lowercased().hasPrefix("czech_") { return "cs-CZ" }
        if wireID.lowercased().hasPrefix("finnish_") { return "fi-FI" }
        if wireID.lowercased().hasPrefix("hindi_") { return "hi-IN" }
        if wireID.hasPrefix("Cantonese_") { return "yue-HK" }
        return "zh-CN"
    }

    private static func isReadableMiniMaxVoiceTitle(_ value: String, stableID: VoiceID) -> Bool {
        !value.isEmpty && value != stableID.rawValue && !value.hasPrefix("minimax.dynamic.")
    }

    private static func voiceGroup(for kind: MiniMaxVoiceKind) -> ProviderVoiceGroup {
        switch kind {
        case .system: return .system
        case .cloned: return .cloned
        case .generated: return .generated
        }
    }

    private static func miniMaxVoicePlacement(
        for descriptor: MiniMaxVoiceDescriptor
    ) -> (group: ProviderVoiceGroup, title: String, order: Int) {
        if MiniMaxVoiceCatalogV1.contractOwnedResources.builtInVoices.contains(descriptor.stableID) {
            return (.recommended, ProviderVoiceGroup.recommended.title, 0)
        }
        guard descriptor.kind == .system else {
            let group = voiceGroup(for: descriptor.kind)
            return (group, group.title, group.sectionOrder)
        }
        let languages: [(prefix: String, title: String, order: Int)] = [
            ("Chinese (Mandarin)_", "中文（普通话）", 100),
            ("Cantonese_", "中文（粤语）", 110),
            ("English_", "英语", 120),
            ("Japanese_", "日语", 130),
            ("Korean_", "韩语", 140),
            ("Spanish_", "西班牙语", 150),
            ("French_", "法语", 160),
            ("German_", "德语", 170),
            ("Portuguese_", "葡萄牙语", 180),
            ("Italian_", "意大利语", 190),
            ("Russian_", "俄语", 200),
            ("Arabic_", "阿拉伯语", 210),
            ("Turkish_", "土耳其语", 220),
            ("Vietnamese_", "越南语", 230),
            ("Indonesian_", "印尼语", 240),
            ("Thai_", "泰语", 250),
        ]
        if let language = languages.first(where: { descriptor.wireID.hasPrefix($0.prefix) }) {
            return (.system, language.title, language.order)
        }
        return (.system, "其他系统音色", 800)
    }

    private static func technicalDetails(for card: ProviderCardState) -> String {
        let model = card.selection?.modelID.rawValue ?? "none"
        let voice = card.selection?.voiceID?.rawValue ?? "none"
        return "provider=\(card.id.rawValue); model=\(model); voice=\(voice)"
    }

    private static func legacyMiniMaxOption(for voice: VoiceID) -> ProviderVoiceOption? {
        switch voice.rawValue {
        case "Chinese (Mandarin)_Radio_Host|default":
            return .init(
                id: VoiceID(rawValue: "minimax.radio-host.default"),
                title: "中文 · 电台主播",
                group: .recommended
            )
        case "Chinese (Mandarin)_Laid_BackGirl|default":
            return .init(
                id: VoiceID(rawValue: "minimax.laid-back-girl.default"),
                title: "中文 · 慵懒少女",
                group: .recommended
            )
        default:
            return nil
        }
    }

    private static func primaryText(for detail: ProviderDetailPresentation, selectedModelIsKnown: Bool, selectedVoiceIsKnown: Bool, language: Lang) -> String {
        guard selectedModelIsKnown && selectedVoiceIsKnown else { return unavailable(language) }
        return "\(detail.title) · \(detail.status)"
    }

    private static func unavailable(_ language: Lang) -> String {
        language == .zh ? "当前选择不可用" : "Current selection is unavailable"
    }
}

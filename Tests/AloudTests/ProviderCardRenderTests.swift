import XCTest
@testable import Aloud

@MainActor
final class ProviderCardRenderTests: XCTestCase {
    func testVoicePickerAccessibilityLabelIncludesPersistedSelectionTitle() {
        let selected = VoiceID(rawValue: "minimax.dynamic.sweet-lady")
        let voices = [ProviderVoiceOption(id: selected, title: "Sweet Lady")]

        XCTAssertEqual(
            ProviderVoicePicker.accessibilityLabel(voices: voices, selection: selected),
            "音色，Sweet Lady"
        )
    }

    func testSettingsScrollerUsesNativeOverlayAutohideWithoutHorizontalBar() {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true

        SettingsOverlayScrollerConfiguration.apply(to: scrollView)

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
    }

    func testPresentationShowsFourSidebarItemsAndOnlySelectedDetail() throws {
        let state = try groupedMiniMaxVoiceState(
            selectedVoiceID: VoiceID(rawValue: "Chinese (Mandarin)_Radio_Host|default"),
            voices: [MiniMaxVoiceDescriptor(
                stableID: VoiceID(rawValue: "minimax.radio-host.default"),
                wireID: "Chinese (Mandarin)_Radio_Host",
                displayName: "中文 · 电台主播",
                kind: .system
            )]
        )
        let rendered = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .minimax,
            credentialStatuses: [.minimax: .configured], systemVoices: [], language: .zh
        )

        XCTAssertEqual(rendered.sidebar.map(\.id), [.minimax, .openAI, .gemini, .macOS])
        XCTAssertEqual(rendered.detail.id, .minimax)
        XCTAssertEqual(rendered.detail.models.map(\.title), ["高品质语音 2.8"])
        XCTAssertTrue(rendered.detail.voices.map(\.title).contains("中文 · 电台主播"))
        XCTAssertFalse(rendered.primaryText.contains("speech-2.8-hd"))
        XCTAssertFalse(rendered.primaryText.contains("Chinese (Mandarin)_Radio_Host"))
        XCTAssertTrue(rendered.detail.technicalDetails.contains("speech-2.8-hd"))
        XCTAssertTrue(rendered.detail.voices.contains(.init(
            id: VoiceID(rawValue: "Chinese (Mandarin)_Radio_Host|default"),
            title: "中文 · 电台主播",
            wireID: "Chinese (Mandarin)_Radio_Host",
            languageTag: "zh-CN",
            group: .recommended,
            sectionTitle: "推荐",
            sectionOrder: 0
        )))
        XCTAssertEqual(rendered.detail.voices.filter { $0.title == "中文 · 电台主播" }.count, 1)
    }

    func testVoicePickerSectionsPinRecommendedVoicesAndFilterSortedVisibleTitles() {
        let voices: [ProviderVoiceOption] = [
            .init(id: VoiceID(rawValue: "system.z"), title: "Zulu", group: .system),
            .init(id: VoiceID(rawValue: "recommended.radio"), title: "中文 · 电台主播", group: .recommended),
            .init(id: VoiceID(rawValue: "system.a"), title: "Alpha", group: .system),
            .init(id: VoiceID(rawValue: "clone.mine"), title: "我的声音", group: .cloned),
            .init(id: VoiceID(rawValue: "generated.mine"), title: "生成音色", group: .generated),
        ]

        let sections = ProviderVoicePickerCatalog.sections(voices: voices, query: "")
        XCTAssertEqual(sections.map(\.title), ["推荐", "系统音色", "我的克隆", "我的生成"])
        XCTAssertEqual(sections.map { $0.options.map(\.title) }, [
            ["中文 · 电台主播"], ["Alpha", "Zulu"], ["我的声音"], ["生成音色"],
        ])
        XCTAssertEqual(
            ProviderVoicePickerCatalog.sections(voices: voices, query: "alp").flatMap(\.options).map(\.id),
            [VoiceID(rawValue: "system.a")]
        )
    }

    func testMiniMaxSystemVoicesAreSeparatedByLanguageInsteadOfOneHugeSection() throws {
        let voices = [
            MiniMaxVoiceDescriptor(
                stableID: VoiceID(rawValue: "minimax.dynamic.mandarin"),
                wireID: "Chinese (Mandarin)_News_Anchor",
                displayName: "News Anchor",
                kind: .system
            ),
            MiniMaxVoiceDescriptor(
                stableID: VoiceID(rawValue: "minimax.dynamic.cantonese"),
                wireID: "Cantonese_ProfessionalHost (F)",
                displayName: "Professional Female Host",
                kind: .system
            ),
            MiniMaxVoiceDescriptor(
                stableID: VoiceID(rawValue: "minimax.dynamic.english"),
                wireID: "English_expressive_narrator",
                displayName: "Expressive Narrator",
                kind: .system
            ),
        ]
        let state = try groupedMiniMaxVoiceState(
            selectedVoiceID: VoiceID(rawValue: "minimax.dynamic.mandarin"),
            voices: voices
        )
        let rendered = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .minimax,
            credentialStatuses: [.minimax: .configured], systemVoices: [], language: .zh
        )

        XCTAssertEqual(
            ProviderVoicePickerCatalog.sections(voices: rendered.detail.voices, query: "").map(\.title),
            ["中文（普通话）", "中文（粤语）", "英语"]
        )
    }

    func testMiniMaxVoiceOptionsAreGroupedAndUseDisplayNamesWithoutRawIDs() throws {
        let selectedVoiceID = VoiceID(rawValue: "minimax.dynamic.cloned")
        let state = try groupedMiniMaxVoiceState(selectedVoiceID: selectedVoiceID)

        let rendered = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .minimax,
            credentialStatuses: [.minimax: .configured], systemVoices: [], language: .zh
        )

        XCTAssertEqual(rendered.detail.voices.map(\.id), [
            VoiceID(rawValue: "minimax.dynamic.system"),
            selectedVoiceID,
            VoiceID(rawValue: "minimax.dynamic.generated"),
        ])
        XCTAssertEqual(rendered.detail.voices.map(\.title), ["新闻主播", "我的声音", "generated-1"])
        XCTAssertEqual(rendered.detail.voices.map(\.group), [.system, .cloned, .generated])
        XCTAssertFalse(rendered.detail.voices.map(\.title).contains { $0.contains("minimax.dynamic") })
    }

    func testUnknownMiniMaxSelectionKeepsRecoveryOptionsAndAddsOneUnavailablePlaceholder() throws {
        let missingVoiceID = VoiceID(rawValue: "minimax.dynamic.missing")
        let state = try groupedMiniMaxVoiceState(selectedVoiceID: missingVoiceID)

        let rendered = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .minimax,
            credentialStatuses: [.minimax: .configured], systemVoices: [], language: .zh
        )

        XCTAssertEqual(rendered.detail.voices.map(\.id), [
            VoiceID(rawValue: "minimax.dynamic.system"),
            missingVoiceID,
            VoiceID(rawValue: "minimax.dynamic.cloned"),
            VoiceID(rawValue: "minimax.dynamic.generated"),
        ])
        XCTAssertEqual(rendered.detail.voices.map(\.title), ["新闻主播", "当前选择不可用", "我的声音", "generated-1"])
        XCTAssertEqual(rendered.detail.voices.map(\.group), [.system, .system, .cloned, .generated])
        XCTAssertEqual(rendered.detail.voices.filter { $0.id == missingVoiceID }.count, 1)
        XCTAssertEqual(rendered.primaryText, "当前选择不可用")
    }

    func testMiniMaxVoiceTitlesTrimNamesAndSafelyFallBackFromEmptyOrTechnicalValues() throws {
        let technicalID = VoiceID(rawValue: "minimax.dynamic.technical")
        let state = try groupedMiniMaxVoiceState(
            selectedVoiceID: technicalID,
            voices: [
                MiniMaxVoiceDescriptor(
                    stableID: VoiceID(rawValue: "minimax.dynamic.named"),
                    wireID: "named-wire",
                    displayName: "  我的声音  ",
                    kind: .system
                ),
                MiniMaxVoiceDescriptor(
                    stableID: technicalID,
                    wireID: "  clone-1  ",
                    displayName: "minimax.dynamic.technical",
                    kind: .cloned
                ),
                MiniMaxVoiceDescriptor(
                    stableID: VoiceID(rawValue: "minimax.dynamic.blank-name"),
                    wireID: "  generated-1  ",
                    displayName: " \n ",
                    kind: .generated
                ),
                MiniMaxVoiceDescriptor(
                    stableID: VoiceID(rawValue: "minimax.dynamic.unnamed"),
                    wireID: " \t ",
                    displayName: "minimax.dynamic.unnamed",
                    kind: .generated
                ),
            ]
        )

        let rendered = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .minimax,
            credentialStatuses: [.minimax: .configured], systemVoices: [], language: .zh
        )

        XCTAssertEqual(rendered.detail.voices.map(\.title), ["我的声音", "clone-1", "generated-1", "未命名音色"])
        XCTAssertFalse(rendered.detail.voices.map(\.title).contains(where: { $0.isEmpty || $0.contains("minimax.dynamic") }))
    }

    func testOtherProviderVoiceOptionsKeepTheirExistingTitlesInTheSystemGroup() throws {
        let state = try ProviderSettingsState.fixture()
        let openAI = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .openAI,
            credentialStatuses: [:], systemVoices: [], language: .zh
        ).detail.voices
        let gemini = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .gemini,
            credentialStatuses: [:], systemVoices: [], language: .zh
        ).detail.voices
        let macOS = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .macOS,
            credentialStatuses: [:],
            systemVoices: [SystemVoiceDescriptor(identifier: "fixture", name: "云希", language: "zh-CN")],
            language: .zh
        ).detail.voices

        XCTAssertEqual(openAI.count, 13)
        XCTAssertTrue(openAI.contains { $0.id == VoiceID(rawValue: "openai.alloy") && $0.title == "Alloy" })
        XCTAssertEqual(gemini.count, 30)
        XCTAssertTrue(gemini.contains { $0.id == VoiceID(rawValue: "gemini.Kore") && $0.title == "Kore" })
        XCTAssertEqual(macOS, [.init(id: VoiceID(rawValue: "macos.fixture"), title: "云希 · zh-CN", wireID: "fixture", languageTag: "zh-CN")])
        XCTAssertEqual((openAI + gemini + macOS).map(\.group), Array(repeating: .system, count: 44))
    }

    func testPresentationKeepsUnknownSelectionOutOfPrimaryText() throws {
        var state = try ProviderSettingsState.fixture()
        let index = try XCTUnwrap(state.cards.firstIndex { $0.id == .minimax })
        state.cards[index].selection = ProviderSelection(
            providerID: .minimax, modelID: ModelID(rawValue: "deprecated-model"),
            voiceID: VoiceID(rawValue: "deprecated-voice"),
            rate: NormalizedRate(version: MiniMaxRateMappingV1.version, value: 0)!
        )

        let rendered = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .minimax,
            credentialStatuses: [:], systemVoices: [], language: .zh
        )

        XCTAssertEqual(rendered.primaryText, "当前选择不可用")
        XCTAssertFalse(rendered.primaryText.contains("deprecated-model"))
        XCTAssertTrue(rendered.detail.technicalDetails.contains("deprecated-model"))
        XCTAssertTrue(rendered.detail.technicalDetails.contains("deprecated-voice"))
    }

    func testValueRendererContainsFourCardsSecureDraftRulesAndNoSecretActions() throws {
        let state = try ProviderSettingsState.fixture()
        let rendered = ProviderCardRenderer.render(state)
        XCTAssertEqual(rendered.cards.count, 4)
        XCTAssertTrue(rendered.cards[0].controls.contains(.onePasswordImport))
        XCTAssertTrue(rendered.cards[1].controls.contains(.secureField))
        XCTAssertTrue(rendered.cards.allSatisfy { $0.controls.isSuperset(of: [.model, .voice, .rate, .preview]) })
        XCTAssertFalse(rendered.cards[3].controls.contains(.secureField))
        XCTAssertFalse(rendered.cards.flatMap(\.controls).contains(.revealSecret))
        XCTAssertFalse(rendered.cards.flatMap(\.controls).contains(.copySecret))
    }

    func testPreviewButtonUsesCompleteSynthesisGate() throws {
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "/Tests/AloudTests/ProviderCardRenderTests.swift", with: "/Sources/Aloud/ProviderSettingsView.swift"))
        XCTAssertTrue(source.contains(".disabled(providerWorking || !ProviderSettingsPersistenceGate.canSynthesize(card))"))

        var state = try ProviderSettingsState.fixture(defaultProviderID: .macOS)
        let index = try XCTUnwrap(state.cards.firstIndex { $0.id == .macOS })
        state.cards[index].selection = nil
        XCTAssertFalse(ProviderSettingsPersistenceGate.canSynthesize(state.cards[index]))
    }

    func testCredentialDraftNeverRefillsAndSuccessClearsWhileFailurePreservesItsSource() async {
        let draft = CredentialDraftState()
        draft.setDraft("typed", for: .openAI)
        await draft.load { _ in .available(.init(providerID: .openAI, revision: UUID(), secret: Data("existing".utf8))) }
        XCTAssertEqual(draft.draft(for: .openAI), "typed")
        draft.completeSave(for: .openAI, result: .failure(.keychainUnavailable))
        XCTAssertEqual(draft.draft(for: .openAI), "typed")
        draft.completeSave(for: .openAI, result: .success(()), successSource: .manual)
        XCTAssertEqual(draft.draft(for: .openAI), "")
        XCTAssertEqual(draft.recentSuccessSource[.openAI], .manual)
    }

    func testDeterministicPreviewCredentialStatusOnlyChangesTheSelectedProviderPresentation() throws {
        let state = try ProviderSettingsState.fixture()
        let rendered = ProviderSettingsPresenter.make(
            state: state,
            selectedProviderID: .openAI,
            credentialStatuses: [.minimax: .working(.onePasswordImport), .openAI: .saveFailed(.onePasswordOutputInvalid)],
            systemVoices: [],
            language: .zh
        )

        XCTAssertEqual(rendered.detail.id, .openAI)
        XCTAssertEqual(rendered.detail.status, "1Password 中的 API Key 无效")
        XCTAssertEqual(rendered.sidebar.first { $0.id == .minimax }?.status, "正在从 1Password 读取…")
    }

    func testPresentationShowsPreviewProgressSuccessAndFailureInsteadOfConfiguredPlaceholder() throws {
        for (health, expected) in [
            (ProviderHealth.verifying, "正在试听…"),
            (.recentSuccess, "试听成功"),
            (.recoverableFailure, "试听失败，请重试"),
        ] {
            var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
            let index = try XCTUnwrap(state.cards.firstIndex { $0.id == .minimax })
            state.cards[index].health = health

            let rendered = ProviderSettingsPresenter.make(
                state: state, selectedProviderID: .minimax,
                credentialStatuses: [.minimax: .configured], systemVoices: [], language: .zh
            )

            XCTAssertEqual(rendered.detail.status, expected)
        }

        var unconfigured = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        let index = try XCTUnwrap(unconfigured.cards.firstIndex { $0.id == .minimax })
        unconfigured.cards[index].configuration = .unconfigured
        unconfigured.cards[index].health = .recentSuccess
        let rendered = ProviderSettingsPresenter.make(
            state: unconfigured, selectedProviderID: .minimax,
            credentialStatuses: [:], systemVoices: [], language: .zh
        )
        XCTAssertEqual(rendered.detail.status, "默认 · 未配置")
    }

    func testSidebarUsesCompleteProviderNamesAndDisabledAvailabilityOverridesMissingCredential() throws {
        var state = try ProviderSettingsState.fixture(defaultProviderID: .openAI)
        let index = try XCTUnwrap(state.cards.firstIndex { $0.id == .gemini })
        let availability = state.cards[index].availability
        state.cards[index].availability = ProviderAvailability(
            kind: .disabled, reason: .explicitlyDisabled, maturity: availability.maturity,
            featureFlagName: availability.featureFlagName, featureFlagEnabled: availability.featureFlagEnabled,
            providerContractVersion: availability.providerContractVersion, evidenceID: availability.evidenceID
        )

        let rendered = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .gemini, credentialStatuses: [.gemini: .missing], systemVoices: [], language: .zh
        )

        XCTAssertEqual(rendered.sidebar.map(\.title), ["MiniMax", "OpenAI", "Gemini", "macOS"])
        XCTAssertEqual(rendered.detail.status, "当前服务已禁用")
    }

    func testSettingsBodyInitialSelectionUsesLiveStateUnlessPreviewOverridesIt() throws {
        let providerSettings = try ProviderSettingsState.fixture(defaultProviderID: .openAI)
        let state = SettingsViewState(
            initialTab: 0,
            hasKey: false,
            voice: "",
            rate: 0,
            stripMarkdown: false,
            skipCode: false,
            hotkeyReadSelection: "",
            hotkeyReadClipboard: "",
            hotkeyTogglePause: "",
            recordingHotkey: nil,
            hotkeyChime: false,
            launchAtLogin: false,
            menuBarOnly: false,
            rules: [],
            cacheLimitMB: 0,
            binaryStatuses: [],
            providerSettings: providerSettings,
            selectedProviderID: SettingsView.initialSelectedProviderID(in: providerSettings),
            credentialStatuses: [:],
            systemVoices: []
        )

        let liveBody = SettingsViewBody(
            state: state,
            exporting: false,
            credentialActions: .unavailable,
            systemVoices: .init(load: { [] }),
            actions: .none
        )
        let previewBody = SettingsViewBody(
            state: state,
            exporting: true,
            credentialActions: .unavailable,
            systemVoices: .init(load: { [] }),
            actions: .none,
            initialSelectedProviderID: .minimax
        )

        XCTAssertEqual(liveBody.resolvedInitialProviderID, .openAI)
        XCTAssertEqual(previewBody.resolvedInitialProviderID, .minimax)
    }
}

let groupedMiniMaxVoices = [
    MiniMaxVoiceDescriptor(
        stableID: VoiceID(rawValue: "minimax.dynamic.system"),
        wireID: "system-1",
        displayName: "新闻主播",
        kind: .system
    ),
    MiniMaxVoiceDescriptor(
        stableID: VoiceID(rawValue: "minimax.dynamic.cloned"),
        wireID: "clone-1",
        displayName: "我的声音",
        kind: .cloned
    ),
    MiniMaxVoiceDescriptor(
        stableID: VoiceID(rawValue: "minimax.dynamic.generated"),
        wireID: "generated-1",
        displayName: "generated-1",
        kind: .generated
    ),
]

func groupedMiniMaxVoiceState(
    selectedVoiceID: VoiceID,
    voices: [MiniMaxVoiceDescriptor] = groupedMiniMaxVoices
) throws -> ProviderSettingsState {
    var prefs = PrefsV1.defaults
    let selection = prefs.selections[.minimax]!
    prefs.selections[.minimax] = ProviderSelection(
        providerID: .minimax,
        modelID: selection.modelID,
        voiceID: selectedVoiceID,
        rate: selection.rate
    )
    return try ProviderSettingsState.build(
        prefs: prefs,
        credentialConfigurations: [.minimax: .configured],
        health: [:],
        recoveryMode: false,
        availableVoices: [.minimax: voices]
    )
}

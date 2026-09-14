import Foundation
import SwiftUI
import AppKit

enum SettingsOverlayScrollerConfiguration {
    static func apply(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
    }
}

private final class SettingsOverlayScrollerHost: NSView {
    override func layout() {
        super.layout()
        applyConfiguration()
    }

    func applyConfiguration() {
        guard let scrollView = enclosingScrollView else { return }
        SettingsOverlayScrollerConfiguration.apply(to: scrollView)
    }
}

private struct SettingsOverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsOverlayScrollerHost {
        SettingsOverlayScrollerHost()
    }

    func updateNSView(_ view: SettingsOverlayScrollerHost, context: Context) {
        view.applyConfiguration()
    }
}

extension View {
    func settingsOverlayScroller() -> some View {
        background(SettingsOverlayScroller())
    }
}

struct SettingsButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.palette) private var p

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(prominent ? p.bg : p.ink)
            .background(prominent ? p.seal : p.ink.opacity(configuration.isPressed ? 0.08 : 0.035),
                        in: RoundedRectangle(cornerRadius: 4))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct InkToggle: View {
    @Binding var on: Bool
    @Environment(\.palette) private var p
    @Environment(\.lang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { on.toggle() } label: {
            Capsule().fill(on ? p.seal : p.ink.opacity(0.15))
                .frame(width: 29, height: 17)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(p.bg).frame(width: 13, height: 13).padding(.horizontal, 2)
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? (lang == .zh ? "开启" : "On") : (lang == .zh ? "关闭" : "Off"))
        .animation(reduceMotion ? nil : Motion.fade, value: on)
    }
}

struct SettingRow<Control: View>: View {
    var title: String
    var note: String? = nil
    @ViewBuilder var control: () -> Control

    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundStyle(p.ink)
                if let note {
                    Text(note).font(.system(size: 10)).foregroundStyle(p.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control().accessibilityLabel(title)
        }
        .padding(.vertical, 15)
    }
}

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @StateObject private var recorder = KeyRecorder()
    @State private var hasKey: Bool
    @State private var binaryStatuses: [BinaryStatus]
    private let initialTab: Int
    private let embedded: Bool
    private let onClose: () -> Void
    private let credentialIngress: CredentialIngress
    private let systemVoices: ProviderSettingsSystemVoices
    @TaskLocal private static var binaryProbeOverride: (@Sendable (String) -> Bool)?

    static func withBinaryProbe<Value>(
        _ probe: @escaping @Sendable (String) -> Bool,
        operation: () throws -> Value
    ) rethrows -> Value {
        try $binaryProbeOverride.withValue(probe, operation: operation)
    }

    static func initialSelectedProviderID(in state: ProviderSettingsState) -> ProviderID {
        state.cards.first(where: \.isDefault)?.id ?? .minimax
    }

    static func probeBinary(atPath path: String) -> Bool {
        withBinaryProbePreviewAccessAudit(auditedValue: false) {
            binaryProbeOverride?(path) ?? FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func withBinaryProbePreviewAccessAudit<Value>(
        auditedValue: @autoclosure () -> Value,
        perform: () -> Value
    ) -> Value {
        PreviewAccessAudit.access(
            .fileManagerPathSelection,
            auditedValue: auditedValue(),
            perform: perform
        )
    }

    init(engine: Engine, credentialIngress: CredentialIngress, systemVoices: ProviderSettingsSystemVoices, initialTab: Int = 0, embedded: Bool = false, onClose: @escaping () -> Void = {}) {
        self.engine = engine
        self.credentialIngress = credentialIngress
        self.systemVoices = systemVoices
        self.initialTab = initialTab
        self.embedded = embedded
        self.onClose = onClose
        _hasKey = State(initialValue: false)
        let paths = [
            ("mpv", engine.prefs.mpvBin),
            ("ffmpeg", engine.prefs.ffmpegBin),
            ("ffprobe", "/opt/homebrew/bin/ffprobe"),
            ("edge-tts", "/opt/homebrew/bin/edge-tts"),
        ]
        _binaryStatuses = State(initialValue: paths.map { name, path in
            BinaryStatus(
                name: name,
                path: path,
                isExecutable: Self.probeBinary(atPath: path)
            )
        })
    }

    var body: some View {
        SettingsViewBody(
            state: SettingsViewState(
                initialTab: initialTab,
                hasKey: hasKey,
                voice: engine.prefs.voice,
                rate: engine.prefs.rate,
                stripMarkdown: engine.prefs.stripMarkdown,
                skipCode: engine.prefs.skipCode,
                hotkeyReadSelection: engine.prefs.hotkey(.readSelection).display,
                hotkeyReadClipboard: engine.prefs.hotkey(.readClipboard).display,
                hotkeyTogglePause: engine.prefs.hotkey(.togglePause).display,
                recordingHotkey: recorder.recording,
                hotkeyChime: engine.prefs.hotkeyChime,
                launchAtLogin: engine.prefs.launchAtLogin,
                menuBarOnly: engine.prefs.menuBarOnly,
                rules: engine.rules,
                cacheLimitMB: engine.prefs.cacheLimitMB,
                binaryStatuses: binaryStatuses,
                providerSettings: engine.providerSettingsState,
                selectedProviderID: Self.initialSelectedProviderID(in: engine.providerSettingsState),
                credentialStatuses: [:],
                systemVoices: []
            ),
            exporting: false,
            credentialActions: SettingsCredentialActions(ingress: credentialIngress, providerCredentialDidSave: { providerID in
                await engine.providerCredentialDidSaveAndWait(providerID)
            }),
            systemVoices: systemVoices,
            actions: SettingsViewActions(
                setVoice: { engine.setVoice($0) },
                setRate: { engine.setRate($0) },
                setStripMarkdown: { engine.setStripMarkdown($0) },
                setSkipCode: { engine.setSkipCode($0) },
                startRecording: { action in
                    recorder.start(action) { spec in
                        if let spec { engine.rebindHotkey(action, spec) }
                        else { engine.restoreHotkeys() }
                    }
                },
                setHotkeyChime: { engine.setHotkeyChime($0) },
                setLaunchAtLogin: { engine.applyLaunchAtLogin($0) },
                setMenuBarOnly: { engine.applyMenuBarOnly($0) },
                addRule: { engine.rules.append(DictRule(find: "", replace: "", enabled: true)) },
                setRule: { updated in
                    guard let index = engine.rules.firstIndex(where: { $0.id == updated.id }) else { return }
                    engine.rules[index] = updated
                },
                deleteRule: { id in engine.rules.removeAll { $0.id == id } },
                setDefaultProvider: { engine.setDefaultProvider($0) },
                previewProvider: { engine.previewProvider($0) },
                updateProviderSelection: { engine.updateProviderSelection($0) },
                toggleVoiceSample: { providerID, voiceID in engine.toggleVoiceSample(providerID: providerID, voiceID: voiceID) },
                installInitialSystemVoiceSelection: { voices in
                    _ = await engine.installInitialSystemVoiceSelectionIfNeeded(voices, preferredLanguages: Locale.preferredLanguages)
                },
                confirmOpenAIDisclosureAndPreview: { engine.confirmOpenAIDisclosureAndPreview() },
                cancelRecording: {
                    guard recorder.recording != nil else { return }
                    recorder.stop()
                    engine.restoreHotkeys()
                }
            ),
            voiceSampleState: engine.voiceSamplePlaybackState,
            embedded: embedded, onClose: onClose
        )
    }
}

struct SettingsPreviewView: View {
    let state: SettingsViewState
    var embedded = false

    var body: some View {
        SettingsViewBody(
            state: state,
            exporting: true,
            credentialActions: .unavailable,
            systemVoices: .init(load: { [] }),
            actions: .none,
            embedded: embedded,
            previewCredentialStatuses: state.credentialStatuses,
            initialSelectedProviderID: state.selectedProviderID,
            previewSystemVoices: state.systemVoices
        )
    }
}

enum SettingsCredentialCommitResult: Equatable, Sendable { case updated, persistedButRefreshFailed }

struct SettingsCredentialActions: Sendable {
    let ingress: CredentialIngress
    let providerCredentialDidSave: @MainActor @Sendable (ProviderID) async -> Bool
    func read(_ providerID: ProviderID) async -> CredentialReadResult { (try? await ingress.store.read(providerID: providerID)) ?? .blocked(.keychainReadFailed) }
    func importMiniMaxFromOnePassword() async throws -> SettingsCredentialCommitResult {
        _ = try await ingress.importMiniMaxFrom1Password()
        return await providerCredentialDidSave(.minimax) ? .updated : .persistedButRefreshFailed
    }
    func saveManual(providerID: ProviderID, draft: String) async throws -> SettingsCredentialCommitResult {
        _ = try await ingress.saveManual(providerID: providerID, draft: draft)
        return await providerCredentialDidSave(providerID) ? .updated : .persistedButRefreshFailed
    }
    static let unavailable = SettingsCredentialActions(ingress: CredentialIngress(store: CredentialStore(keychain: UnavailableSettingsKeychain())), providerCredentialDidSave: { _ in false })
}

@MainActor
final class SettingsCredentialBannerState: ObservableObject {
    @Published private(set) var message: String?
    private var currentToken = UUID()

    func show(_ message: String) -> UUID {
        let token = UUID()
        currentToken = token
        self.message = message
        return token
    }

    func clear(ifCurrent token: UUID) {
        guard currentToken == token else { return }
        message = nil
    }
}

private struct UnavailableSettingsKeychain: KeychainClient {
    func read(service: String, account: String) -> CredentialKeychainRead { .failure(errSecInteractionNotAllowed) }
    func update(data: Data, service: String, account: String) -> OSStatus { errSecInteractionNotAllowed }
    func add(data: Data, service: String, account: String) -> OSStatus { errSecInteractionNotAllowed }
    func delete(service: String, account: String) -> OSStatus { errSecInteractionNotAllowed }
}

struct SettingsViewActions {
    let setVoice: (String) -> Void
    let setRate: (Int) -> Void
    let setStripMarkdown: (Bool) -> Void
    let setSkipCode: (Bool) -> Void
    let startRecording: (HotkeyAction) -> Void
    let setHotkeyChime: (Bool) -> Void
    let setLaunchAtLogin: (Bool) -> Void
    let setMenuBarOnly: (Bool) -> Void
    let addRule: () -> Void
    let setRule: (DictRule) -> Void
    let deleteRule: (DictRule.ID) -> Void
    let setDefaultProvider: (ProviderID) -> Void
    let previewProvider: (ProviderID) -> Void
    let updateProviderSelection: (ProviderSelection) -> Void
    let toggleVoiceSample: (ProviderID, VoiceID) -> Void
    let installInitialSystemVoiceSelection: ([SystemVoiceDescriptor]) async -> Void
    let confirmOpenAIDisclosureAndPreview: () -> Void
    var cancelRecording: () -> Void = {}

    static let none = SettingsViewActions(
        setVoice: { _ in }, setRate: { _ in }, setStripMarkdown: { _ in }, setSkipCode: { _ in },
        startRecording: { _ in }, setHotkeyChime: { _ in }, setLaunchAtLogin: { _ in },
        setMenuBarOnly: { _ in }, addRule: {}, setRule: { _ in }, deleteRule: { _ in },
        setDefaultProvider: { _ in }, previewProvider: { _ in }, updateProviderSelection: { _ in }, toggleVoiceSample: { _, _ in },
        installInitialSystemVoiceSelection: { _ in }, confirmOpenAIDisclosureAndPreview: {}
    )
}

struct SettingsViewBody: View {
    let state: SettingsViewState
    let exporting: Bool
    let credentialActions: SettingsCredentialActions
    let systemVoices: ProviderSettingsSystemVoices
    let actions: SettingsViewActions
    let voiceSampleState: VoiceSamplePlaybackState
    let resolvedInitialProviderID: ProviderID
    let embedded: Bool
    let onClose: () -> Void

    @Environment(\.lang) private var lang
    @State private var tab: Int
    @State private var diagnosticsExpanded = false
    @FocusState private var focusedRule: DictRule.ID?
    // Each cloud provider owns an independent, ephemeral draft. Switching cards
    // never moves a typed key into another provider's save action.
    @StateObject private var credentialDraftState: CredentialDraftState
    @State private var selectedProviderID: ProviderID = .minimax
    @State private var systemVoiceDescriptors: [SystemVoiceDescriptor] = []
    @State private var credentialTasks: [ProviderID: Task<Void, Never>] = [:]
    @StateObject private var credentialBanner = SettingsCredentialBannerState()

    private var p: Palette { .reader }
    private var tabs: [String] { [T.tabVoice(lang), T.tabHotkeys(lang), T.tabDict(lang), lang == .zh ? "通用" : "General"] }

    init(
        state: SettingsViewState,
        exporting: Bool,
        credentialActions: SettingsCredentialActions,
        systemVoices: ProviderSettingsSystemVoices,
        actions: SettingsViewActions,
        voiceSampleState: VoiceSamplePlaybackState = .idle,
        embedded: Bool = false,
        onClose: @escaping () -> Void = {},
        previewCredentialStatuses: [ProviderID: ProviderCredentialUIStatus]? = nil,
        initialSelectedProviderID: ProviderID? = nil,
        previewSystemVoices: [SystemVoiceDescriptor]? = nil
    ) {
        self.state = state
        self.exporting = exporting
        self.credentialActions = credentialActions
        self.systemVoices = systemVoices
        self.actions = actions
        self.voiceSampleState = voiceSampleState
        self.embedded = embedded
        self.onClose = onClose
        let resolvedInitialProviderID = initialSelectedProviderID ?? state.selectedProviderID
        self.resolvedInitialProviderID = resolvedInitialProviderID
        _tab = State(initialValue: state.initialTab)
        _credentialDraftState = StateObject(wrappedValue: previewCredentialStatuses.map(CredentialDraftState.init(initialStatus:)) ?? CredentialDraftState())
        _selectedProviderID = State(initialValue: resolvedInitialProviderID)
        _systemVoiceDescriptors = State(initialValue: previewSystemVoices ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 17) {
                ForEach(tabs.indices, id: \.self) { index in
                    Button { tab = index } label: {
                        Text(tabs[index])
                            .font(.system(size: 11, weight: tab == index ? .medium : .regular))
                            .foregroundStyle(tab == index ? p.ink : p.inkDim)
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                if tab == index { p.ink.frame(height: 1) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == index ? .isSelected : [])
                }
                Spacer(minLength: 0)
                if embedded {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 10))
                            .foregroundStyle(p.inkDim).frame(width: 22, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(lang == .zh ? "收起设置" : "Close settings")
                    .accessibilityLabel(lang == .zh ? "收起设置" : "Close settings")
                    .accessibilityIdentifier("settings-close")
                }
            }.padding(.horizontal, 27).padding(.top, 14).padding(.bottom, 22)

            Group {
                if tab == 0 {
                    voice
                } else if exporting {
                    GeometryReader { _ in
                        VStack(alignment: .leading, spacing: 0) { body(for: tab) }
                            .padding(.horizontal, 27).padding(.bottom, 24)
                    }.clipped()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { body(for: tab) }
                            .padding(.horizontal, 27).padding(.bottom, 24)
                            .settingsOverlayScroller()
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 350)
        .frame(height: embedded ? nil : 666)
        .frame(maxHeight: embedded ? .infinity : nil, alignment: .top)
        .background(p.surface)
        .foregroundStyle(p.ink)
        .font(.system(size: 12))
        .tint(p.seal)
        .buttonStyle(SettingsButtonStyle())
        .environment(\.palette, p)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .task { await loadLiveProviderDependencies() }
        .onChange(of: tab) { old, _ in if old == 1 { actions.cancelRecording() } }
        .onChange(of: state.rules.map(\.id)) { old, new in
            if let added = new.first(where: { !old.contains($0) }) { focusedRule = added }
        }
        .onDisappear { actions.cancelRecording(); credentialTasks.values.forEach { $0.cancel() }; for providerID in credentialTasks.keys { credentialDraftState.restoreLoadedStatus(for: providerID) }; credentialTasks = [:] }
    }

    func loadLiveProviderDependencies() async {
        guard !exporting else { return }
        await credentialDraftState.load { providerID in await credentialActions.read(providerID) }
        let loadedSystemVoices = await systemVoices.load()
        systemVoiceDescriptors = loadedSystemVoices
        await actions.installInitialSystemVoiceSelection(loadedSystemVoices)
    }

    @ViewBuilder private func body(for tab: Int) -> some View {
        switch tab {
        case 0: voice
        case 1: hotkeys
        case 2: dictionary
        default: advanced
        }
    }

    @ViewBuilder private var voice: some View {
        ProviderSettingsView(
            state: state.providerSettings,
            presentation: ProviderSettingsPresenter.make(state: state.providerSettings, selectedProviderID: selectedProviderID, credentialStatuses: credentialDraftState.status, systemVoices: systemVoiceDescriptors, language: lang),
            exporting: exporting,
            selectedProviderID: $selectedProviderID,
            drafts: credentialDraftState,
            actions: ProviderSettingsViewActions(
                setDefault: actions.setDefaultProvider,
                preview: actions.previewProvider,
                updateSelection: actions.updateProviderSelection,
                toggleVoiceSample: actions.toggleVoiceSample,
                confirmDisclosureAndPreview: actions.confirmOpenAIDisclosureAndPreview
            ),
            voiceSampleState: voiceSampleState,
            beginCredentialAction: startCredentialAction
        ) {
            if let message = credentialBanner.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text(lang == .zh ? "文本处理" : "Text processing").font(.system(size: 10)).foregroundStyle(p.inkDim).padding(.top, 24)
            SettingRow(title: lang == .zh ? "略过排版标记" : "Skip formatting", note: T.stripMdNote(lang)) {
                InkToggle(on: Binding(get: { state.stripMarkdown }, set: actions.setStripMarkdown))
            }
            line
            SettingRow(title: T.skipCode(lang), note: lang == .zh ? "保留说明文字，略过整段代码。" : "Keep explanations, skip code blocks.") {
                InkToggle(on: Binding(get: { state.skipCode }, set: actions.setSkipCode))
            }
        }
    }

    @ViewBuilder private func keyField(_ action: HotkeyAction, display: String) -> some View {
        let live = state.recordingHotkey == action
        Button { actions.startRecording(action) } label: {
            Text(live ? T.pressKeys(lang) : display)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(live ? p.seal : p.ink)
                .frame(minWidth: 76)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 3).fill(live ? p.ink.opacity(0.06) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(live ? p.seal : .clear, lineWidth: 1))
        }
        .accessibilityValue(live ? T.pressKeys(lang) : display)
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(exporting)
    }

    private func startCredentialAction(_ providerID: ProviderID, _ operation: ProviderCredentialOperation) {
        guard let operationToken = credentialDraftState.beginOperation(operation, for: providerID) else { return }
        credentialTasks[providerID] = Task { @MainActor in
            do {
                switch operation {
                case .onePasswordImport:
                    _ = try await credentialActions.importMiniMaxFromOnePassword()
                case .manualSave:
                    _ = try await credentialActions.saveManual(providerID: providerID, draft: credentialDraftState.draft(for: providerID))
                }
                credentialDraftState.completeSave(
                    for: providerID,
                    result: .success(()),
                    successSource: operation == .onePasswordImport ? .onePassword : .manual,
                    operationToken: operationToken
                )
            } catch is CancellationError {
                credentialDraftState.restoreLoadedStatus(for: providerID, operationToken: operationToken)
            } catch let error as OnePasswordPipeError where error == .cancelled {
                credentialDraftState.restoreLoadedStatus(for: providerID, operationToken: operationToken)
            } catch {
                let failure = ProviderCredentialUIFailure.classify(error)
                credentialDraftState.completeSave(for: providerID, result: .failure(failure), operationToken: operationToken)
                showCredentialBanner(ProviderCredentialUIStatus.saveFailed(failure).message(lang))
            }
            credentialTasks[providerID] = nil
        }
    }

    private func showCredentialBanner(_ message: String) {
        let token = credentialBanner.show(message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            credentialBanner.clear(ifCurrent: token)
        }
    }

    @ViewBuilder private var hotkeys: some View {
        SettingRow(
            title: T.hkSelection(lang),
            note: state.recordingHotkey != nil ? T.recording(lang) : T.hkSelNote(lang)
        ) {
            keyField(.readSelection, display: state.hotkeyReadSelection)
        }
        line
        SettingRow(title: T.hkClipboard(lang)) {
            keyField(.readClipboard, display: state.hotkeyReadClipboard)
        }
        line
        SettingRow(title: T.hkPlayPause(lang)) {
            keyField(.togglePause, display: state.hotkeyTogglePause)
        }
        line
        SettingRow(title: T.hkSound(lang), note: T.hkSoundNote(lang)) {
            InkToggle(on: Binding(get: { state.hotkeyChime }, set: actions.setHotkeyChime))
        }

    }

    @ViewBuilder private var dictionary: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(T.dictNote(lang)).font(.system(size: 10)).foregroundStyle(p.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: actions.addRule) {
                Label(lang == .zh ? "添加" : "Add", systemImage: "plus")
                    .font(.system(size: 10)).fixedSize()
            }.buttonStyle(.plain).disabled(exporting)
                .accessibilityIdentifier("dictionary-add")
        }.padding(.bottom, 20)
        if state.rules.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.book.closed").font(.system(size: 24))
                Text(lang == .zh ? "还没有发音规则" : "No pronunciation rules yet")
                    .font(.system(size: 11))
            }.foregroundStyle(p.inkDim).frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            HStack {
                Text(T.dictFind(lang)).frame(maxWidth: .infinity, alignment: .leading)
                Text(T.dictReplace(lang)).frame(maxWidth: .infinity, alignment: .leading)
                Text(lang == .zh ? "启用" : "On").frame(width: 51)
            }.font(.system(size: 9)).foregroundStyle(p.inkDim).padding(.bottom, 12)
            line
            ForEach(state.rules) { rule in
                HStack(spacing: 7) {
                    if exporting {
                        Text(rule.find).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(p.inkDim)
                        Text(rule.replace).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField(T.dictFind(lang), text: ruleBinding(rule, keyPath: \.find))
                            .focused($focusedRule, equals: rule.id)
                            .accessibilityLabel(T.dictFind(lang))
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(p.inkDim)
                        TextField(T.dictReplace(lang), text: ruleBinding(rule, keyPath: \.replace))
                            .accessibilityLabel(T.dictReplace(lang))
                    }
                    InkToggle(on: Binding(get: { rule.enabled }, set: { value in
                        var updated = rule; updated.enabled = value; actions.setRule(updated)
                    })).accessibilityLabel("\(rule.find) \(lang == .zh ? "启用规则" : "Enable rule")")
                    Button { actions.deleteRule(rule.id) } label: {
                        Image(systemName: "trash").font(.system(size: 10))
                            .foregroundStyle(p.inkDim).frame(width: 15, height: 25)
                    }.buttonStyle(.plain).disabled(exporting)
                        .help(lang == .zh ? "删除规则" : "Delete rule")
                        .accessibilityLabel(lang == .zh ? "删除规则" : "Delete rule")
                }.font(.system(size: 11)).textFieldStyle(.plain).padding(.vertical, 12)
                line
            }
            Text(lang == .zh ? "修改自动保存，应用于之后的朗读。" : "Changes are saved automatically for future reading.")
                .font(.system(size: 10)).foregroundStyle(p.inkDim).padding(.top, 15)
        }
    }

    @ViewBuilder private var advanced: some View {
        Text(lang == .zh ? "启动与驻留" : "Startup and windows")
            .font(.system(size: 10)).foregroundStyle(p.inkDim)
        SettingRow(title: T.launchAtLogin(lang)) {
            InkToggle(on: Binding(get: { state.launchAtLogin }, set: actions.setLaunchAtLogin))
        }
        line
        SettingRow(title: T.menuBarOnly(lang), note: T.menuBarNote(lang)) {
            InkToggle(on: Binding(get: { state.menuBarOnly }, set: actions.setMenuBarOnly))
        }
        line
        Text(lang == .zh ? "音频缓存 · 只读" : "Audio cache · Read only")
            .font(.system(size: 10)).foregroundStyle(p.inkDim).padding(.top, 26)
        SettingRow(title: T.cacheLimit(lang), note: T.cacheLimitNote(lang)) {
            valueLabel("\(state.cacheLimitMB) MB")
        }
        line
        SettingRow(title: T.cacheDays(lang)) { valueLabel(T.daysValue(lang)) }
        line
        DisclosureGroup(lang == .zh ? "本地工具与诊断" : "Local tools and diagnostics", isExpanded: $diagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 15) {
                ForEach(state.binaryStatuses, id: \.name) { binary in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(binary.name)
                            Spacer()
                            Text(binary.isExecutable ? (lang == .zh ? "可用" : "Available") : (lang == .zh ? "未找到" : "Not found"))
                        }.font(.system(size: 11))
                        Text(binary.path).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(p.inkDim).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.top, 14)
        }.font(.system(size: 11)).foregroundStyle(p.inkDim).padding(.top, 22)
    }

    private var line: some View { Divider().overlay(p.line.opacity(0.7)) }

    private func ruleBinding(
        _ rule: DictRule,
        keyPath: WritableKeyPath<DictRule, String>
    ) -> Binding<String> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: { value in
                var updated = rule
                updated[keyPath: keyPath] = value
                actions.setRule(updated)
            }
        )
    }

    private func valueLabel(_ value: String) -> some View {
        Text(value).font(.system(size: 12)).foregroundStyle(p.ink).accessibilityValue(value)
    }

    private func pillLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundStyle(p.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(p.ink.opacity(0.06)))
            .overlay(Capsule().stroke(p.line, lineWidth: 1))
    }
}

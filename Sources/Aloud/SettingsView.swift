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

struct InkToggle: View {
    @Binding var on: Bool
    @Environment(\.palette) private var p

    var body: some View {
        Button { on.toggle() } label: {
            Capsule()
                .fill(on ? p.seal : p.ink.opacity(0.15))
                .frame(width: 34, height: 20)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .padding(.horizontal, 2)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .animation(Motion.snap, value: on)
    }
}

struct SettingRow<Control: View>: View {
    var title: String
    var note: String? = nil
    @ViewBuilder var control: () -> Control

    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(p.ink)
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(p.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 9)
    }
}

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @StateObject private var recorder = KeyRecorder()
    @State private var hasKey: Bool
    @State private var binaryStatuses: [BinaryStatus]
    private let initialTab: Int
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

    init(engine: Engine, credentialIngress: CredentialIngress, systemVoices: ProviderSettingsSystemVoices, initialTab: Int = 0) {
        self.engine = engine
        self.credentialIngress = credentialIngress
        self.systemVoices = systemVoices
        self.initialTab = initialTab
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
                confirmOpenAIDisclosureAndPreview: { engine.confirmOpenAIDisclosureAndPreview() }
            ),
            voiceSampleState: engine.voiceSamplePlaybackState
        )
    }
}

struct SettingsPreviewView: View {
    let state: SettingsViewState

    var body: some View {
        SettingsViewBody(
            state: state,
            exporting: true,
            credentialActions: .unavailable,
            systemVoices: .init(load: { [] }),
            actions: .none,
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

    @Environment(\.colorScheme) private var scheme
    @Environment(\.lang) private var lang
    @State private var tab: Int
    // Each cloud provider owns an independent, ephemeral draft. Switching cards
    // never moves a typed key into another provider's save action.
    @StateObject private var credentialDraftState: CredentialDraftState
    @State private var selectedProviderID: ProviderID = .minimax
    @State private var systemVoiceDescriptors: [SystemVoiceDescriptor] = []
    @State private var credentialTasks: [ProviderID: Task<Void, Never>] = [:]
    @StateObject private var credentialBanner = SettingsCredentialBannerState()

    private var p: Palette { Palette.of(scheme) }
    private var tabs: [String] { [T.tabVoice(lang), T.tabHotkeys(lang), T.tabDict(lang), T.tabAdvanced(lang)] }

    init(
        state: SettingsViewState,
        exporting: Bool,
        credentialActions: SettingsCredentialActions,
        systemVoices: ProviderSettingsSystemVoices,
        actions: SettingsViewActions,
        voiceSampleState: VoiceSamplePlaybackState = .idle,
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
        let resolvedInitialProviderID = initialSelectedProviderID ?? state.selectedProviderID
        self.resolvedInitialProviderID = resolvedInitialProviderID
        _tab = State(initialValue: state.initialTab)
        _credentialDraftState = StateObject(wrappedValue: previewCredentialStatuses.map(CredentialDraftState.init(initialStatus:)) ?? CredentialDraftState())
        _selectedProviderID = State(initialValue: resolvedInitialProviderID)
        _systemVoiceDescriptors = State(initialValue: previewSystemVoices ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs.indices, id: \.self) { index in
                    Button { tab = index } label: {
                        Text(tabs[index])
                            .font(.system(size: 12, weight: tab == index ? .semibold : .regular))
                            .foregroundStyle(tab == index ? p.ink : p.inkDim)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(tab == index ? p.ink.opacity(0.07) : .clear))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider().overlay(p.line)

            Group {
                if exporting {
                    VStack(alignment: .leading, spacing: 0) { body(for: tab) }
                        .padding(.horizontal, 20).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Spacer(minLength: 0)
                } else if tab == 0 {
                    voice
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { body(for: tab) }
                            .padding(.horizontal, 20).padding(.vertical, 6)
                            .settingsOverlayScroller()
                    }
                }
            }
        }
        .frame(width: 640, height: 480)
        .background(p.bg)
        .environment(\.palette, p)
        .task { await loadLiveProviderDependencies() }
        .onDisappear { credentialTasks.values.forEach { $0.cancel() }; for providerID in credentialTasks.keys { credentialDraftState.restoreLoadedStatus(for: providerID) }; credentialTasks = [:] }
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
            line
            Text("朗读处理").font(.system(size: 12, weight: .semibold)).padding(.top, 8)
            SettingRow(title: T.stripMarkdown(lang), note: T.stripMdNote(lang)) {
                InkToggle(on: Binding(get: { state.stripMarkdown }, set: actions.setStripMarkdown))
            }
            line
            SettingRow(title: T.skipCode(lang)) {
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
                .background(RoundedRectangle(cornerRadius: 5).fill(p.ink.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(live ? p.seal : p.line, lineWidth: live ? 1.5 : 1))
        }
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
        line
        SettingRow(title: T.launchAtLogin(lang)) {
            InkToggle(on: Binding(get: { state.launchAtLogin }, set: actions.setLaunchAtLogin))
        }
        line
        SettingRow(title: T.menuBarOnly(lang), note: T.menuBarNote(lang)) {
            InkToggle(on: Binding(get: { state.menuBarOnly }, set: actions.setMenuBarOnly))
        }
    }

    @ViewBuilder private var dictionary: some View {
        HStack {
            Text(T.dictNote(lang)).font(.system(size: 11)).foregroundStyle(p.inkFaint)
            Spacer()
            Button(action: actions.addRule) { pillLabel(T.newRule(lang)) }
                .buttonStyle(.plain).focusEffectDisabled().disabled(exporting)
        }
        .padding(.vertical, 10)
        line
        if exporting {
            ForEach(state.rules) { rule in
                HStack(spacing: 10) {
                    Text(rule.find).font(.system(size: 12, weight: .medium)).foregroundStyle(p.ink)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(p.inkFaint)
                    Text(rule.replace).font(.system(size: 12)).foregroundStyle(p.inkDim)
                    Spacer()
                    InkToggle(on: .constant(rule.enabled))
                }
                .padding(.vertical, 8)
                line
            }
        } else {
            ForEach(state.rules) { rule in
                HStack(spacing: 10) {
                    TextField(T.dictFind(lang), text: ruleBinding(rule, keyPath: \.find))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.ink)
                        .frame(width: 130)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(p.inkFaint)
                    TextField(T.dictReplace(lang), text: ruleBinding(rule, keyPath: \.replace))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(p.inkDim)
                    Spacer()
                    InkToggle(on: Binding(
                        get: { rule.enabled },
                        set: { enabled in
                            var updated = rule
                            updated.enabled = enabled
                            actions.setRule(updated)
                        }
                    ))
                    Button { actions.deleteRule(rule.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(p.inkFaint)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
                .padding(.vertical, 6)
                line
            }
        }
    }

    @ViewBuilder private var advanced: some View {
        SettingRow(title: T.cacheLimit(lang), note: T.cacheLimitNote(lang)) {
            valueLabel("\(state.cacheLimitMB) MB")
        }
        line
        SettingRow(title: T.cacheDays(lang)) { valueLabel(T.daysValue(lang)) }
        line
        ForEach(state.binaryStatuses, id: \.name) { binary in
            SettingRow(title: T.binPath(binary.name)(lang)) {
                HStack(spacing: 7) {
                    Circle().fill(binary.isExecutable ? Color(0x3FAE6A) : p.inkFaint)
                        .frame(width: 6, height: 6)
                    Text(binary.path).font(.system(size: 11)).foregroundStyle(p.inkDim)
                }
            }
            line
        }
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
        Text(value).font(.system(size: 12)).foregroundStyle(p.ink)
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

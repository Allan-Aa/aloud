import CryptoKit
import Foundation
import ServiceManagement
import SwiftUI

/// Injectable platform effects. The coordinator invokes these only after prefs persist.
@MainActor
final class PrefsSideEffects: @unchecked Sendable {
    static let live = PrefsSideEffects()

    func setPlaybackSpeed(_ speed: Double) { Player.shared.setSpeed(speed) }

    func setMenuBarOnly(_ enabled: Bool) {
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if !enabled { NSApp.activate(ignoringOtherApps: true) }
    }

    func registerHotkeys(_ prefs: Prefs) throws {
        let specs = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, prefs.hotkey($0)) })
        let results = Hotkeys.shared.registerAll(specs)
        guard results.values.allSatisfy({ $0 }) else { throw SideEffectError.hotkeyRegistrationFailed }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    enum SideEffectError: Swift.Error { case hotkeyRegistrationFailed }
}

/// 界面的唯一数据源。文本 → 缓存 → 合成 → 播放,状态全从这里发出去。
@MainActor
protocol EnginePlayback: AnyObject, Sendable {
    var alive: Bool { get }
    var paused: Bool { get }
    var position: Double { get }
    var duration: Double { get }
    func play(file: URL, prefs: Prefs, streaming: Bool) throws
    func playSample(file: URL, prefs: Prefs) throws
    func append(file: URL) throws
    func finishStream(prefs: Prefs)
    func stop()
    func stopAndWait() async
    func togglePause()
    func seek(relative: Double)
    func setSpeed(_ speed: Double)
}

extension EnginePlayback {
    func playSample(file: URL, prefs: Prefs) throws { try play(file: file, prefs: prefs, streaming: false) }
    func stopAndWait() async {}
}

extension Player: EnginePlayback {}

/// Speech may be submitted during launch, but credential capture cannot begin
/// until the registry hook is installed. Waiting happens inside the
/// coordinator-owned pending task, so Stop/replacement cancellation owns it.
private actor SpeechReadinessGate {
    private var ready = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        if ready { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if ready { continuation.resume() }
                else if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }

    func markReady() {
        ready = true
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor ProviderSuccessOnce {
    private var claimed = false
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

enum MiniMaxCredentialCapture {
    static func envelope(from result: CredentialReadResult, providerID: ProviderID) throws -> CredentialEnvelope {
        switch result {
        case .available(let envelope) where envelope.providerID == providerID:
            return envelope
        case .available:
            throw MiniMaxProviderError.credentialMismatch
        case .missing:
            throw MiniMaxProviderError.credentialMissing
        case .blocked(let reason):
            throw MiniMaxProviderError.credentialBlocked(reason)
        }
    }
}

@MainActor
struct EngineSpeechDependencies {
    let cachePath: (String, String, Int) -> URL
    let cacheHit: (URL) -> Bool
    let synthesize: (String, String, Int, URL) async throws -> Void
    let concat: ([URL], URL, String) throws -> Void
    let beforePlayback: () async -> Void
    let beforeHistoryWrite: () async -> Void
    let readSelection: @Sendable () async throws -> String
    let legacyMiniMaxDisabled: Bool
    let provider: (any VoiceProvider)?
    let providerForID: (ProviderID) -> (any VoiceProvider)?
    let accountSnapshot: @Sendable (ProviderID) async -> AccountCatalogSnapshot
    let canonicalizeNative: @Sendable (NativeAudioArtifact, SpeechPurpose, String) async throws -> OwnedAudioArtifact
    let captureCredential: @Sendable (ProviderID) async throws -> CredentialEnvelope?
    let advanceCanonicalScope: @Sendable (ProviderID, UUID, SessionGeneration) async -> Void
    /// Staged seam for Task 14 sessions and Task 16 adapters. New providers
    /// return unpublished chunks; this resolver is their only final-cache path.
    let canonicalChunkResolver: @Sendable (CacheFlightKey, SessionGeneration, SpeechPurpose, @escaping @Sendable () async throws -> UnpublishedArtifact) async throws -> AudioArtifact
    let verifyPlayback: @Sendable () async throws -> PlaybackEvidence
    let prepareSessionArtifact: ([URL], SpeechPurpose) throws -> AudioArtifact?
    let providerDidSucceed: @Sendable (SessionCurrentToken) async -> Void
    let afterNativeSynthesis: @Sendable () async -> Void
    let afterCanonicalization: @Sendable () async -> Void

    init(
        cachePath: @escaping (String, String, Int) -> URL,
        cacheHit: @escaping (URL) -> Bool,
        synthesize: @escaping (String, String, Int, URL) async throws -> Void,
        concat: @escaping ([URL], URL, String) throws -> Void,
        beforePlayback: @escaping () async -> Void = {},
        beforeHistoryWrite: @escaping () async -> Void = {},
        readSelection: @escaping @Sendable () async throws -> String = { try await Selection.read() },
        legacyMiniMaxDisabled: Bool = false,
        provider: (any VoiceProvider)? = nil,
        providerForID: ((ProviderID) -> (any VoiceProvider)?)? = nil,
        accountSnapshot: @escaping @Sendable (ProviderID) async -> AccountCatalogSnapshot = { _ in .empty },
        canonicalizeNative: @escaping @Sendable (NativeAudioArtifact, SpeechPurpose, String) async throws -> OwnedAudioArtifact = { _, _, _ in throw WAVAudioError.invalidContainer },
        captureCredential: @escaping @Sendable (ProviderID) async throws -> CredentialEnvelope? = { _ in nil },
        advanceCanonicalScope: @escaping @Sendable (ProviderID, UUID, SessionGeneration) async -> Void = { _, _, _ in },
        canonicalChunkResolver: @escaping @Sendable (CacheFlightKey, SessionGeneration, SpeechPurpose, @escaping @Sendable () async throws -> UnpublishedArtifact) async throws -> AudioArtifact = { _, _, _, _ in throw CacheFlightError.noReadyArtifact },
        verifyPlayback: @escaping @Sendable () async throws -> PlaybackEvidence = {
            PlaybackEvidence(firstTimePosition: 0, secondTimePosition: 0.001, observedAt: Date())
        },
        prepareSessionArtifact: @escaping ([URL], SpeechPurpose) throws -> AudioArtifact? = { _, _ in nil },
        providerDidSucceed: @escaping @Sendable (SessionCurrentToken) async -> Void = { _ in },
        afterNativeSynthesis: @escaping @Sendable () async -> Void = {},
        afterCanonicalization: @escaping @Sendable () async -> Void = {}
    ) {
        self.cachePath = cachePath; self.cacheHit = cacheHit; self.synthesize = synthesize
        self.concat = concat; self.beforePlayback = beforePlayback; self.beforeHistoryWrite = beforeHistoryWrite; self.readSelection = readSelection; self.legacyMiniMaxDisabled = legacyMiniMaxDisabled
        self.provider = provider; self.canonicalizeNative = canonicalizeNative
        self.providerForID = providerForID ?? { id in provider?.id == id ? provider : nil }
        self.accountSnapshot = accountSnapshot
        self.captureCredential = captureCredential; self.advanceCanonicalScope = advanceCanonicalScope; self.canonicalChunkResolver = canonicalChunkResolver
        self.verifyPlayback = verifyPlayback; self.prepareSessionArtifact = prepareSessionArtifact; self.providerDidSucceed = providerDidSucceed
        self.afterNativeSynthesis = afterNativeSynthesis; self.afterCanonicalization = afterCanonicalization
    }

    @MainActor static var live: EngineSpeechDependencies {
        let miniMax: any VoiceProvider = MiniMaxProvider(httpClient: URLSessionMiniMaxHTTPClient(), nativeDirectory: Store.runtimeDir)
        let openAI: (any VoiceProvider)? = try? OpenAIProvider(modelID: ModelID(rawValue: "tts-1"), httpClient: URLSessionOpenAIHTTPClient(), nativeDirectory: Store.runtimeDir)
        let macOS: (any VoiceProvider)? = try? SystemVoiceProvider(synthesizer: AVSpeechSynthesizerClient(), nativeDirectory: Store.runtimeDir)
        return EngineSpeechDependencies(
        cachePath: AudioCache.path,
        cacheHit: AudioCache.hit,
        synthesize: { _, _, _, _ in throw MiniMaxProviderError.invalidRequest },
        concat: AudioJoin.concat,
        beforePlayback: {}, beforeHistoryWrite: {}, legacyMiniMaxDisabled: false,
        provider: miniMax,
        providerForID: { providerID in
            switch providerID {
            case .minimax: return miniMax
            case .openAI: return openAI
            case .macOS: return macOS
            default: return nil
            }
        },
        accountSnapshot: { providerID in await ProviderAccountEvidenceStore.shared.snapshot(for: providerID) },
        canonicalizeNative: { native, purpose, ffmpeg in
            let scoped = NativeAudioArtifact(url: native.url, format: native.format, purpose: purpose)
            let artifact = try await WAVCanonicalizer(
                runner: WAVProcessRunner(executableURL: URL(fileURLWithPath: ffmpeg))
            ).canonicalize(scoped, destinationDirectory: Store.runtimeDir)
            return OwnedAudioArtifact(artifact: artifact)
        },
        captureCredential: { providerID in
            let result = try await CredentialStore.live.read(providerID: providerID)
            return try MiniMaxCredentialCapture.envelope(from: result, providerID: providerID)
        },
        advanceCanonicalScope: { providerID, revision, generation in
            await CanonicalChunkCacheCoordinator.live.advance(providerID: providerID, revision: revision, generation: generation)
        },
        canonicalChunkResolver: { key, generation, purpose, producer in
            try await CanonicalChunkCacheCoordinator.live.resolve(key: key, generation: generation, purpose: purpose, produce: producer)
        },
        verifyPlayback: {
            try await PlaybackVerifier.verify(client: Player.shared, timeout: .seconds(8), cleanup: {})
        },
        prepareSessionArtifact: { urls, purpose in
            try WAVConcatenator.concatenate(
                urls,
                to: Store.runtimeDir.appendingPathComponent("aloud-last-audio-\(UUID().uuidString).wav"),
                purpose: purpose
            )
        }
        )
    }
}

@MainActor
final class Engine: ObservableObject {
    static var shared: Engine { AppCompositionRoot.live.engine }

    @Published var text = ""
    @Published var phase: Phase = .idle
    @Published private var storedPrefs: Prefs
    var prefs: Prefs { storedPrefs }
    @Published var history: [HistoryEntry] = []
    @Published var rules: [DictRule] = [] { didSet { if rules != oldValue { Store.save("dictionary.json", rules) } } }
    @Published var toast: String?
    @Published var voiceSamplePlaybackState: VoiceSamplePlaybackState = .idle
    @Published private var systemVoiceDescriptors: [SystemVoiceDescriptor] = []
    @Published var providerSettingsState: ProviderSettingsState = try! ProviderSettingsState.build(
        prefs: .defaults,
        credentialConfigurations: [.macOS: .configured],
        health: [:],
        recoveryMode: false
    )

    private let player: any EnginePlayback
    private let speech: EngineSpeechDependencies
    private let credentialRegistry: CredentialScopeRegistry
    private var syncTask: Task<Void, Never>?
    private var initialHydrationTask: Task<Void, Never>?
    private let providerSettingsStore: ProviderSettingsStore
    private let openAIDisclosureCoordinator: OpenAIDisclosureCoordinator
    private let providerSettingsRuntimeLoader: ProviderSettingsRuntimeLoader
    private let prefsMutations: PrefsMutationController
    private let prefsEffects: PrefsSideEffects
    private let prefsEffectCoordinator: PrefsSideEffectCoordinator
    private let hotkeys: any HotkeyRegistering
    private let historyMutations: HistoryMutationController
    private var prefsMutationGeneration = 0
    private var credentialCancellationHookIDs: [ProviderID: UUID] = [:]
    private let speechCoordinator: SpeechCoordinator
    private let speechReadiness = SpeechReadinessGate()
    private let lastAudioStore: LastAudioArtifactStore
    private let voiceSampleCoordinator: VoiceSampleCoordinator
    private var voiceSamplePreparationTask: Task<Void, Never>?
    func persistedProviderPrefsForTesting() async -> PrefsV1 { await providerSettingsStore.prefsSnapshot() }

    convenience init() { self.init(player: Player.shared, speech: .live, credentialRegistry: .shared) }

    init(player: any EnginePlayback, speech: EngineSpeechDependencies, credentialRegistry: CredentialScopeRegistry, historyController: HistoryMutationController? = nil, installCredentialHook: Bool = true, speechCoordinator: SpeechCoordinator = SpeechCoordinator(), lastAudioStore: LastAudioArtifactStore = .shared, hotkeys: any HotkeyRegistering = Hotkeys.shared, providerSettingsRuntimeLoader: ProviderSettingsRuntimeLoader? = nil, openAIDisclosureCoordinator: OpenAIDisclosureCoordinator? = nil, voiceSampleStore: VoiceSampleStore = VoiceSampleStore()) {
        self.player = player
        self.speech = speech
        self.credentialRegistry = credentialRegistry
        self.speechCoordinator = speechCoordinator
        self.lastAudioStore = lastAudioStore
        self.voiceSampleCoordinator = VoiceSampleCoordinator(store: voiceSampleStore)
        self.hotkeys = hotkeys
        self.providerSettingsRuntimeLoader = providerSettingsRuntimeLoader ?? ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                (try? await CredentialStore.live.read(providerID: providerID)) ?? .blocked(.keychainReadFailed)
            },
            accountSnapshot: speech.accountSnapshot
        )
        let settings = ProviderSettingsStore.open(url: Store.dir.appendingPathComponent("prefs.json"))
        self.providerSettingsStore = settings
        self.openAIDisclosureCoordinator = openAIDisclosureCoordinator ?? OpenAIDisclosureCoordinator(store: settings)
        self.prefsMutations = PrefsMutationController(store: settings)
        self.prefsEffects = PrefsSideEffects.live
        self.prefsEffectCoordinator = PrefsSideEffectCoordinator(controller: self.prefsMutations)
        self.storedPrefs = Prefs()
        let historyURL = Store.dir.appendingPathComponent("history.json")
        self.historyMutations = historyController ?? HistoryMutationController(url: historyURL)
        self.history = historyController == nil ? HistoryRepository.open(url: historyURL).entries : []
        self.rules = Store.load("dictionary.json", default: Mock.rules)
        self.voiceSampleCoordinator.stateDidChange = { [weak self] state in
            self?.voiceSamplePlaybackState = state
        }
        initialHydrationTask = Task { @MainActor [weak self] in
            do {
                let loaded = try await self?.prefsMutations.hydrate()
                guard let self, self.prefsMutationGeneration == 0, let loaded else { return }
                self.storedPrefs = loaded
                await self.reloadProviderSettingsState(resetHealthFor: [.minimax, .openAI, .gemini, .macOS])
            } catch {
                self?.toast = PrivacySafeMessage.settingsLoadFailed(error)
            }
        }
        observePlayer()
        if installCredentialHook { Task { @MainActor [weak self] in await self?.installCredentialCancellationHook() } }
        Task { self.evictCache() }
    }

    /// Deterministic launch boundary used by the assembled fake graph. UI use
    /// remains asynchronous, but tests and restart flows need not guess a delay.
    func waitForInitialHydration() async { await initialHydrationTask?.value }

    @discardableResult
    func reloadProviderSettingsState(resetHealthFor: Set<ProviderID> = []) async -> Bool {
        let prefs = await providerSettingsStore.prefsSnapshot()
        let recovery = await providerSettingsStore.currentMode() == .readOnlyRecovery
        let health = Dictionary(uniqueKeysWithValues: providerSettingsState.cards.map { ($0.id, $0.health) })
        if (try? await providerSettingsRuntimeLoader.load(
            prefs: prefs,
            recoveryMode: recovery,
            health: health,
            resetHealthFor: resetHealthFor,
            install: { providerSettingsState = $0 }
        )) != nil {
            return true
        }
        return false
    }

    func setDefaultProvider(_ providerID: ProviderID) {
        guard ProviderSettingsPersistenceGate.canSetDefault(providerSettingsState.card(providerID)) else {
            toast = "当前语音服务不可设为默认"
            return
        }
        let store = providerSettingsStore
        let coordinator = speechCoordinator
        let stopPlayer = stopPlayerCommand()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await store.currentMode() == .ready else {
                self.toast = self.providerSettingsState.recoveryMessage
                return
            }
            do {
                try await store.updateInMemory { $0.defaultProviderID = providerID }
                await coordinator.defaultProviderDidChange(stopPlayer: stopPlayer)
                self.providerSettingsState = ProviderSettingsReducer.reduce(self.providerSettingsState, .setDefault(providerID))
            } catch {
                self.toast = "默认语音服务保存失败"
            }
        }
    }

    func providerCredentialDidSave(_ providerID: ProviderID) {
        Task { @MainActor [weak self] in _ = await self?.providerCredentialDidSaveAndWait(providerID) }
    }

    func providerCredentialDidSaveAndWait(_ providerID: ProviderID) async -> Bool {
        await reloadProviderSettingsState(resetHealthFor: [providerID])
    }

    static func preferredInitialSystemVoice(
        from voices: [SystemVoiceDescriptor],
        preferredLanguages: [String]
    ) -> SystemVoiceDescriptor? {
        let sorted = voices.enumerated().sorted { lhs, rhs in
            let leftLanguage = normalizedSystemVoiceLanguage(lhs.element.language)
            let rightLanguage = normalizedSystemVoiceLanguage(rhs.element.language)
            if leftLanguage != rightLanguage { return leftLanguage < rightLanguage }
            let leftName = lhs.element.name.lowercased()
            let rightName = rhs.element.name.lowercased()
            if leftName != rightName { return leftName < rightName }
            let leftIdentifier = lhs.element.identifier.lowercased()
            let rightIdentifier = rhs.element.identifier.lowercased()
            if leftIdentifier != rightIdentifier { return leftIdentifier < rightIdentifier }
            return lhs.offset < rhs.offset
        }.map(\.element)
        for preferred in preferredLanguages.map(normalizedSystemVoiceLanguage) {
            if let exact = sorted.first(where: { normalizedSystemVoiceLanguage($0.language) == preferred }) { return exact }
        }
        for preferred in preferredLanguages.map(normalizedSystemVoiceLanguage) {
            let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if let baseMatch = sorted.first(where: {
                normalizedSystemVoiceLanguage($0.language).split(separator: "-").first.map(String.init) == base
            }) { return baseMatch }
        }
        return sorted.first
    }

    @discardableResult
    func installInitialSystemVoiceSelectionIfNeeded(
        _ voices: [SystemVoiceDescriptor],
        preferredLanguages: [String]
    ) async -> Bool {
        systemVoiceDescriptors = voices
        guard let voice = Self.preferredInitialSystemVoice(from: voices, preferredLanguages: preferredLanguages) else { return false }
        let selection = ProviderSelection(
            providerID: .macOS,
            modelID: SystemVoiceContractV1.modelID,
            voiceID: VoiceID(rawValue: "macos.\(voice.identifier)"),
            rate: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: 0)!
        )
        let store = providerSettingsStore
        guard await store.currentMode() == .ready,
              await store.prefsSnapshot().selections[.macOS] == nil else { return false }
        do {
            try await store.updateInMemory { prefs in
                guard prefs.selections[.macOS] == nil else { return }
                prefs.selections[.macOS] = selection
            }
            guard await store.prefsSnapshot().selections[.macOS] == selection else { return false }
            _ = await reloadProviderSettingsState(resetHealthFor: [.macOS])
            return true
        } catch {
            toast = "系统语音选择保存失败"
            return false
        }
    }

    private static func normalizedSystemVoiceLanguage(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    func updateProviderSelection(_ selection: ProviderSelection) {
        Task { @MainActor [weak self] in
            _ = await self?.updateProviderSelectionAndWait(selection)
        }
    }

    @discardableResult
    func updateProviderSelectionAndWait(_ selection: ProviderSelection) async -> Bool {
        guard ProviderSettingsPersistenceGate.canMutateSelection(providerSettingsState.card(selection.providerID)) else {
            toast = "当前语音服务不可修改"
            return false
        }
        let store = providerSettingsStore
        let coordinator = speechCoordinator
        let stopPlayer = stopPlayerCommand()
        guard await store.currentMode() == .ready else {
            toast = providerSettingsState.recoveryMessage
            return false
        }
        do {
            try await store.updateInMemory { $0.selections[selection.providerID] = selection }
            storedPrefs = await prefsMutations.syncFromStore()
            coordinator.requestSelectionChange(providerID: selection.providerID, stopPlayer: stopPlayer)
            return await reloadProviderSettingsState(resetHealthFor: [selection.providerID])
        } catch {
            toast = "语音选择保存失败"
            return false
        }
    }

    var currentVoiceDisplayLabel: String {
        guard let card = providerSettingsState.cards.first(where: \.isDefault),
              let voiceID = card.selection?.voiceID else {
            return Voices.label(prefs.voice, .zh)
        }
        if card.id == .minimax,
           let descriptor = card.availableVoices.first(where: { $0.stableID == voiceID }) {
            let displayName = descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty, displayName != voiceID.rawValue { return displayName }
        }
        switch card.id {
        case .openAI:
            return String(voiceID.rawValue.dropFirst("openai.".count)).capitalized
        case .gemini:
            return String(voiceID.rawValue.dropFirst("gemini.".count))
        case .macOS:
            return "macOS"
        case .minimax:
            return Voices.label(prefs.voice, .zh)
        default:
            return Voices.label(prefs.voice, .zh)
        }
    }

    var currentDefaultVoiceControlState: ProviderVoiceControlState? {
        guard let card = providerSettingsState.cards.first(where: \.isDefault) else { return nil }
        return ProviderSettingsPresenter.voiceControl(
            state: providerSettingsState,
            providerID: card.id,
            systemVoices: systemVoiceDescriptors,
            language: .zh
        )
    }

    @discardableResult
    func updateCurrentDefaultVoice(_ voiceID: VoiceID) async -> Bool {
        guard let card = providerSettingsState.cards.first(where: \.isDefault),
              let selection = card.selection,
              currentDefaultVoiceControlState?.voices.contains(where: { $0.id == voiceID }) == true else {
            return false
        }
        return await updateProviderSelectionAndWait(ProviderSelection(
            providerID: selection.providerID,
            modelID: selection.modelID,
            voiceID: voiceID,
            rate: selection.rate
        ))
    }

    @discardableResult
    func updateCurrentDefaultRate(_ value: Int) async -> Bool {
        guard let card = providerSettingsState.cards.first(where: \.isDefault),
              let selection = card.selection,
              let rate = NormalizedRate(version: selection.rate.version, value: value) else {
            return false
        }
        return await updateProviderSelectionAndWait(ProviderSelection(
            providerID: selection.providerID,
            modelID: selection.modelID,
            voiceID: selection.voiceID,
            rate: rate
        ))
    }

    func toggleVoiceSample(providerID: ProviderID, voiceID: VoiceID) {
        if let active = voiceSamplePlaybackState.activeIdentity,
           active.providerID == providerID, active.stableVoiceID == voiceID {
            voiceSamplePreparationTask?.cancel()
            voiceSampleCoordinator.stop(player: player)
            return
        }
        voiceSamplePreparationTask?.cancel()
        guard let provider = speech.providerForID(providerID),
              let card = providerSettingsState.cards.first(where: { $0.id == providerID }),
              ProviderSettingsPersistenceGate.canSynthesize(card),
              let baseSelection = card.selection,
              let control = ProviderSettingsPresenter.voiceControl(
                state: providerSettingsState, providerID: providerID,
                systemVoices: systemVoiceDescriptors, language: .zh
              ),
              let option = control.voices.first(where: { $0.id == voiceID }) else {
            toast = "当前音色暂时无法试听"
            return
        }
        let selection = ProviderSelection(
            providerID: providerID, modelID: baseSelection.modelID,
            voiceID: voiceID,
            rate: NormalizedRate(version: baseSelection.rate.version, value: 0) ?? baseSelection.rate
        )
        let isPrivate = option.group == .cloned || option.group == .generated
        if isPrivate { toast = "首次生成样音，可能产生少量费用；以后将永久复用" }
        let speech = self.speech
        let prefs = self.prefs
        let player = self.player
        let coordinator = voiceSampleCoordinator
        voiceSamplePreparationTask = Task { @MainActor [weak self] in
            do {
                let preparedEnvelope = isPrivate && providerID != .macOS
                    ? try await speech.captureCredential(providerID)
                    : nil
                try Task.checkCancellation()
                let identity = VoiceSampleIdentity(
                    providerID: providerID, modelID: selection.modelID,
                    stableVoiceID: option.id, wireVoiceID: option.wireID,
                    credentialScopeRevision: preparedEnvelope?.revision,
                    rateContractVersion: selection.rate.version,
                    phraseVersion: VoiceSamplePhraseCatalog.version,
                    outputFormatVersion: "voice-sample-audio-v1"
                )
                let outputFormatID = Self.previewOutputFormatID(providerID)
                coordinator.toggle(identity: identity, player: player, prefs: prefs) {
                    let envelope: CredentialEnvelope?
                    if let preparedEnvelope { envelope = preparedEnvelope }
                    else if providerID == .macOS { envelope = nil }
                    else { envelope = try await speech.captureCredential(providerID) }
                    let scope = envelope?.revision ?? SystemVoiceContractV1.scopeRevision
                    let phrase = VoiceSamplePhraseCatalog.phrase(languageTag: option.languageTag)
                    let chunks = try await provider.split(phrase, selection: selection)
                    guard chunks.count == 1, let chunk = chunks.first else { throw ProviderPreviewError.failed }
                    let controls: SynthesisControls
                    switch providerID {
                    case .minimax: controls = try MiniMaxRateMappingV1.controls(for: selection.rate)
                    case .openAI: controls = try OpenAIRateMappingV1.controls(for: selection.rate)
                    case .gemini: controls = try GeminiRateMappingV1.controls(for: selection.rate)
                    case .macOS: controls = try SystemVoiceRateMappingV1.controls(for: selection.rate)
                    default: throw ProviderPreviewError.failed
                    }
                    let request = try SpeechRequest.make(
                        id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk,
                        controls: controls, credentialScopeRevision: scope,
                        capabilities: provider.capabilities,
                        outputFormatID: outputFormatID,
                        canonicalizerVersion: "canonical-wav-v1"
                    )
                    let native = try await ProviderSynthesisGate(provider: provider).synthesize(
                        request,
                        credential: envelope.map { .apiKey(providerID: providerID, envelope: $0) } ?? .none
                    )
                    let canonical: OwnedAudioArtifact
                    do {
                        canonical = try await speech.canonicalizeNative(
                            .init(url: native.url, format: native.format, purpose: .preview),
                            .preview,
                            prefs.ffmpegBin
                        )
                        native.cleanupIfOwned()
                    } catch {
                        native.cleanupIfOwned()
                        throw error
                    }
                    return VoiceSampleCandidate(url: canonical.url, fileExtension: "wav") {
                        canonical.cleanupIfOwned()
                    }
                }
            } catch is CancellationError {
                self?.voiceSamplePlaybackState = .idle
            } catch {
                self?.toast = "音色样音生成失败，请稍后重试"
            }
        }
    }

    func previewProvider(_ providerID: ProviderID, phraseID: String = "zh-CN") {
        let card = providerSettingsState.card(providerID)
        guard ProviderSettingsPersistenceGate.canSynthesize(card),
              let provider = speech.providerForID(providerID), provider.id == providerID,
              let persistedSelection = card.selection else {
            toast = "当前服务商尚不可试听"
            return
        }
        let selection = normalizedCurrentSelection(persistedSelection)
        submitPreviewPreparation(providerID: providerID, phraseID: phraseID, provider: provider, selection: selection) { [openAIDisclosureCoordinator] in
            guard providerID == .openAI, let voice = selection.voiceID else { return }
            try await openAIDisclosureCoordinator.performIfAuthorized(modelID: selection.modelID, voiceID: voice, purpose: .preview) {}
        }
    }

    func confirmOpenAIDisclosureAndPreview(phraseID: String = "zh-CN") {
        let card = providerSettingsState.card(.openAI)
        guard ProviderSettingsPersistenceGate.canSynthesize(card), let selection = card.selection, let voice = selection.voiceID else {
            toast = "当前服务商尚不可试听"
            return
        }
        guard let provider = speech.providerForID(.openAI), provider.id == .openAI else { return }
        submitPreviewPreparation(providerID: .openAI, phraseID: phraseID, provider: provider, selection: selection) { [openAIDisclosureCoordinator] in
            guard try await openAIDisclosureCoordinator.confirm(modelID: selection.modelID, voiceID: voice, explicitlyAccepted: true) != nil else {
                throw OpenAIDisclosureAuthorizationError.acknowledgementRequired(OpenAIDisclosureGate.evaluate(modelID: selection.modelID, voiceID: voice, ack: nil, purpose: .preview))
            }
        }
    }

    private func submitPreviewPreparation(
        providerID: ProviderID,
        phraseID: String,
        provider: any VoiceProvider,
        selection: ProviderSelection,
        authorize: @escaping @Sendable () async throws -> Void
    ) {
        let coordinator = speechCoordinator
        coordinator.submitInput(
            providerID: providerID,
            stopPlayer: { _ in },
            prepare: { @MainActor [weak self] control in
                guard let self else { throw CancellationError() }
                try await authorize()
                return try await control.performCurrent {
                    let current = self.providerSettingsState.card(providerID)
                    let currentSelection = current.selection.map(self.normalizedCurrentSelection)
                    guard ProviderSettingsPersistenceGate.canSynthesize(current), currentSelection == selection,
                          self.speech.providerForID(providerID)?.id == provider.id else { throw CancellationError() }
                    self.providerSettingsState = ProviderSettingsReducer.reduce(self.providerSettingsState, .synthesisStarted(providerID))
                    if providerID == .openAI, let voice = selection.voiceID {
                        self.providerSettingsState.cards[self.providerSettingsState.cards.firstIndex(where: { $0.id == .openAI })!].actions.remove(.confirmDisclosure)
                        guard selection.modelID == currentSelection?.modelID, voice == currentSelection?.voiceID else { throw CancellationError() }
                    }
                    return self.previewSubmission(providerID, phraseID: phraseID, provider: provider, selection: selection)
                }
            },
            onPreparationFailure: { @MainActor [weak self] control, error in
                guard let self else { return }
                _ = try? await control.performCurrent {
                    if error is OpenAIDisclosureAuthorizationError {
                        if let index = self.providerSettingsState.cards.firstIndex(where: { $0.id == .openAI }) {
                            self.providerSettingsState.cards[index].health = .unknown
                            self.providerSettingsState.cards[index].actions.insert(.confirmDisclosure)
                        }
                        self.toast = OpenAIDisclosurePolicy.text
                    } else {
                        self.toast = "试听准备失败"
                    }
                }
            }
        )
    }

    private func previewSubmission(_ providerID: ProviderID, phraseID: String, provider: any VoiceProvider, selection: ProviderSelection) -> SpeechCoordinator.PreparedSubmission {
        let speech = self.speech
        let player = self.player
        let outputFormatID = Self.previewOutputFormatID(providerID)
        let transaction = ProviderPreviewTransaction(
            phraseCatalog: .builtIn,
            synthesize: { phrase, policy in
                guard policy == PreviewIsolationPolicy(cache: .bypass, history: .forbidden, lastAudio: .forbidden) else {
                    throw ProviderPreviewError.failed
                }
                let envelope = providerID == .macOS ? nil : try await speech.captureCredential(providerID)
                let scopeRevision = envelope?.revision ?? SystemVoiceContractV1.scopeRevision
                let chunks = try await provider.split(phrase, selection: selection)
                guard chunks.count == 1, let chunk = chunks.first else { throw ProviderPreviewError.failed }
                let controls: SynthesisControls
                switch providerID {
                case .minimax: controls = try MiniMaxRateMappingV1.controls(for: selection.rate)
                case .openAI: controls = try OpenAIRateMappingV1.controls(for: selection.rate)
                case .gemini: controls = try GeminiRateMappingV1.controls(for: selection.rate)
                case .macOS: controls = try SystemVoiceRateMappingV1.controls(for: selection.rate)
                default: throw ProviderPreviewError.failed
                }
                let request = try SpeechRequest.make(
                    id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk,
                    controls: controls, credentialScopeRevision: scopeRevision,
                    capabilities: provider.capabilities,
                    outputFormatID: outputFormatID, canonicalizerVersion: "canonical-wav-v1"
                )
                let owned = try await ProviderSynthesisGate(provider: provider).synthesize(
                    request,
                    credential: envelope.map { .apiKey(providerID: providerID, envelope: $0) } ?? .none
                )
                let canonical: OwnedAudioArtifact
                do {
                    canonical = try await speech.canonicalizeNative(
                        .init(url: owned.url, format: owned.format, purpose: .preview),
                        .preview,
                        self.prefs.ffmpegBin
                    )
                    owned.cleanupIfOwned()
                } catch {
                    owned.cleanupIfOwned()
                    throw error
                }
                return OwnedNativeAudioArtifact(
                    artifact: NativeAudioArtifact(
                        url: canonical.url,
                        format: .encoded(container: "wav", codec: "pcm-s16le"),
                        purpose: .preview
                    ),
                    cleanup: { canonical.cleanupIfOwned() }
                )
            },
            startPlayback: { artifact in
                try player.play(file: artifact.url, prefs: self.prefs, streaming: false)
                self.phase = .playing
            },
            verifyPlayback: { try await speech.verifyPlayback() }
        )
        let stopAndDrain: SpeechCoordinator.StopPlayer = { @MainActor [weak self] _ in
                guard let self else { return }
                self.player.stop()
                self.phase = .idle
                await self.player.stopAndWait()
        }
        return SpeechCoordinator.PreparedSubmission(
            command: .preview(providerID: providerID, phraseID: phraseID),
            captureEnvelope: speech.captureCredential,
            stopPlayer: stopAndDrain,
            work: { @MainActor [weak self] token in
                guard let self else { return }
                do {
                    _ = try await transaction.run(token: token, providerID: providerID, phraseID: phraseID, editorText: "", historyText: "")
                    try await token.performCurrent {
                        self.providerSettingsState = ProviderSettingsReducer.reduce(self.providerSettingsState, .synthesisSucceeded(providerID))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try await token.performCurrent {
                        self.providerSettingsState = ProviderSettingsReducer.reduce(self.providerSettingsState, .synthesisFailed(providerID, .recoverableFailure))
                    }
                    throw error
                }
            },
            onFailure: { _, _ in }
        )
    }

    private static func previewOutputFormatID(_ providerID: ProviderID) -> String {
        switch providerID {
        case .minimax: return MiniMaxWireContractV1.outputFormatID
        case .openAI: return OpenAIWireContractV1.outputFormatID
        case .gemini: return GeminiWireContractV1.outputFormatID
        case .macOS: return SystemVoiceContractV1.outputFormatID
        default: return "unsupported"
        }
    }

    func mutatePrefs(_ mutation: @escaping @Sendable (inout Prefs) -> Void) {
        prefsMutationGeneration += 1
        let generation = prefsMutationGeneration
        let controller = prefsMutations
        Task { @MainActor [weak self] in
            do {
                let updated = try await controller.mutate(mutation)
                guard let self, self.prefsMutationGeneration == generation else { return }
                self.storedPrefs = updated
            } catch {
                guard let self, self.prefsMutationGeneration == generation else { return }
                self.toast = PrivacySafeMessage.settingsSaveFailed(error)
            }
        }
    }

    private func mutatePrefsThenEffect(
        _ mutation: @escaping @Sendable (inout Prefs) -> Void,
        apply: @escaping @Sendable (Prefs) async throws -> Void,
        compensate: @escaping @Sendable (Prefs) async throws -> Void
    ) {
        prefsMutationGeneration += 1
        let generation = prefsMutationGeneration
        let coordinator = prefsEffectCoordinator
        Task { @MainActor [weak self] in
            do {
                let updated = try await coordinator.commit(mutation, apply: apply, compensate: compensate)
                guard let self, self.prefsMutationGeneration == generation else { return }
                self.storedPrefs = updated
            } catch let error as PrefsSideEffectCoordinator.Error {
                guard let self, self.prefsMutationGeneration == generation else { return }
                self.storedPrefs = PrefsConsistencyReducer.visiblePrefs(after: error)
                self.toast = PrefsConsistencyReducer.message(after: error)
            } catch {
                guard let self, self.prefsMutationGeneration == generation else { return }
                self.toast = "设置应用失败，已恢复原设置"
            }
        }
    }

    func setVoice(_ voice: String) {
        speechCoordinator.requestSelectionChange(providerID: .minimax, stopPlayer: stopPlayerCommand())
        mutatePrefs { $0.voice = voice }
    }
    func setRate(_ rate: Int) {
        speechCoordinator.requestSelectionChange(providerID: .minimax, stopPlayer: stopPlayerCommand())
        mutatePrefs { $0.rate = rate }
    }
    func setStripMarkdown(_ value: Bool) { mutatePrefs { $0.stripMarkdown = value } }
    func setSkipCode(_ value: Bool) { mutatePrefs { $0.skipCode = value } }
    func setHotkeyChime(_ value: Bool) { mutatePrefs { $0.hotkeyChime = value } }

    /// 设置里的「缓存上限/保留天数」在这儿真正执行。先删过期的,还超限再从最旧删起。
    private func evictCache() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: Store.cacheDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var files: [(url: URL, date: Date, size: Int)] = urls.compactMap { u in
            guard let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let d = rv.contentModificationDate, let s = rv.fileSize else { return nil }
            return (u, d, s)
        }
        var removed = 0
        let cutoff = Date().addingTimeInterval(-Double(prefs.cacheDays) * 86400)
        for f in files where f.date < cutoff {
            try? fm.removeItem(at: f.url); removed += 1
        }
        files.removeAll { $0.date < cutoff }
        var total = files.reduce(0) { $0 + $1.size }
        let limit = prefs.cacheLimitMB * 1_000_000
        for f in files.sorted(by: { $0.date < $1.date }) where total > limit {
            try? fm.removeItem(at: f.url)
            total -= f.size
            removed += 1
        }
        if removed > 0 { Diag.record(.cacheEviction(fileCount: removed, remainingMegabytes: total / 1_000_000)) }
    }

    // MARK: 播放位置
    var position: Double { player.position }
    var duration: Double { max(player.duration, 0.001) }

    private func observePlayer() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                // mpv 自己播完会退出,界面要跟着回到空闲
                if self.phase == .playing || self.phase == .paused {
                    if !self.player.alive {
                        self.phase = .idle
                    } else {
                        self.phase = self.player.paused ? .paused : .playing
                    }
                }
                self.objectWillChange.send()
            }
        }
    }

    // MARK: 朗读
    func speak() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let identity = currentDefaultReadingIdentity() else {
            phase = .idle
            let defaultProvider = providerSettingsState.cards.first(where: \.isDefault)?.id
            toast = speech.legacyMiniMaxDisabled && defaultProvider == .minimax
                ? "旧音频格式升级中，请使用系统语音或等待新的语音提供商。"
                : "当前默认语音服务尚不可用，请先完成配置。"
            return
        }
        if identity.providerID == .openAI {
            submitOpenAIReading(raw: raw, identity: identity)
            return
        }
        startReading(raw: raw, origin: .speak, historyIdentity: identity)
    }

    /// OpenAI disclosure authorization is part of the same coordinator-owned
    /// pending session as the subsequent Speak. Stop/replacement/selection or
    /// credential changes therefore cannot leave an authorized orphan request.
    private func submitOpenAIReading(raw: String, identity: ReadingIdentity) {
        guard let voiceID = identity.voiceID else { return }
        let disclosure = openAIDisclosureCoordinator
        let speech = self.speech
        speechCoordinator.submitInput(
            providerID: .openAI,
            stopPlayer: stopPlayerCommand(),
            advanceCacheScope: speech.advanceCanonicalScope,
            prepare: { @MainActor [weak self] control in
                guard let self else { throw CancellationError() }
                try await disclosure.performIfAuthorized(
                    modelID: identity.modelID, voiceID: voiceID,
                    purpose: .reading(.speak)
                ) {}
                return try await control.performCurrent {
                    guard let current = self.currentDefaultReadingIdentity(),
                          current.providerID == .openAI,
                          current.modelID == identity.modelID,
                          current.voiceID == identity.voiceID,
                          current.normalizedRate == identity.normalizedRate else {
                        throw CancellationError()
                    }
                    return self.readingSubmission(raw: raw, origin: .speak, historyIdentity: identity)
                }
            },
            onPreparationFailure: { @MainActor [weak self] control, error in
                guard let self else { return }
                _ = try? await control.performCurrent {
                    self.phase = .idle
                    if error is OpenAIDisclosureAuthorizationError {
                        if let index = self.providerSettingsState.cards.firstIndex(where: { $0.id == .openAI }) {
                            self.providerSettingsState.cards[index].actions.insert(.confirmDisclosure)
                        }
                        self.toast = OpenAIDisclosurePolicy.text
                    } else if !(error is CancellationError) {
                        self.toast = "朗读准备失败"
                    }
                }
            }
        )
    }

    private struct ReadingIdentity: Sendable {
        let providerID: ProviderID
        let modelID: ModelID
        let voiceID: VoiceID?
        let normalizedRate: NormalizedRate
        let displayLabel: String
        let legacyVoice: String
        let rate: Int
        let billingNotice: String?
    }

    private struct ReadingSnapshot: Sendable {
        let raw: String
        let clean: String
        let origin: ReadingOrigin
        let identity: ReadingIdentity
        let prefs: Prefs
    }

    private func readingSubmission(raw: String, origin: ReadingOrigin, historyIdentity: ReadingIdentity?, capturedEnvelope: CredentialEnvelope? = nil) -> SpeechCoordinator.PreparedSubmission? {
        let currentPrefs = prefs
        let clean = Dictionary_.apply(raw, prefs: currentPrefs, rules: rules)
        guard !clean.isEmpty else { return nil }
        let label = Voices.label(currentPrefs.voice, .zh)
        let stableVoice = LegacyVoiceMapV1.voices[label]
        let identity = historyIdentity ?? ReadingIdentity(
            providerID: .minimax,
            modelID: ModelID(rawValue: "speech-2.8-hd"),
            voiceID: stableVoice,
            normalizedRate: NormalizedRate(version: "legacy-minimax-rate-v1", value: currentPrefs.rate)!,
            displayLabel: label,
            legacyVoice: currentPrefs.voice,
            rate: currentPrefs.rate,
            billingNotice: nil
        )
        let snapshot = ReadingSnapshot(raw: raw, clean: clean, origin: origin, identity: identity, prefs: currentPrefs)
        let command = SpeechCommand.reading(
            text: clean, origin: origin, providerID: identity.providerID,
            credentiallessScopeRevision: identity.providerID == .macOS ? SystemVoiceContractV1.scopeRevision : nil
        )
        let speech = self.speech
        let readiness = speechReadiness
        let captureEnvelope: SpeechCoordinator.CaptureEnvelope
        if let capturedEnvelope {
            captureEnvelope = { _ in capturedEnvelope }
        } else {
            captureEnvelope = { providerID in
                try await readiness.wait()
                try Task.checkCancellation()
                return try await speech.captureCredential(providerID)
            }
        }
        let work: SpeechCoordinator.Work = { [weak self] token in
            guard let self else { throw CancellationError() }
            try await self.runReading(snapshot, token: token)
        }
        let failure: SpeechCoordinator.Failure = { [weak self] token, error in
            guard let self else { return }
            _ = try? await token.performCurrent {
                if !(error is CancellationError) {
                    Diag.record(.providerFailure(
                        providerID: snapshot.identity.providerID,
                        code: SpeechFailureDiagnostic.code(for: error)
                    ))
                }
                self.player.stop()
                self.phase = .idle
                self.toast = PrivacySafeMessage.speechFailed(error)
                NSSound(named: "Basso")?.play()
            }
        }
        let startFailure: SpeechCoordinator.StartFailure = { [weak self] control, error in
            guard let self else { return }
            _ = try? await control.performCurrent {
                if !(error is CancellationError) {
                    Diag.record(.providerFailure(
                        providerID: snapshot.identity.providerID,
                        code: SpeechFailureDiagnostic.code(for: error)
                    ))
                }
                self.player.stop()
                self.phase = .idle
                self.toast = PrivacySafeMessage.speechFailed(error)
            }
        }

        return SpeechCoordinator.PreparedSubmission(
            command: command, captureEnvelope: captureEnvelope,
            stopPlayer: stopPlayerCommand(), advanceCacheScope: speech.advanceCanonicalScope,
            work: work, onFailure: failure, onStartFailure: startFailure
        )
    }

    private func startReading(raw: String, origin: ReadingOrigin, historyIdentity: ReadingIdentity?) {
        guard let submission = readingSubmission(raw: raw, origin: origin, historyIdentity: historyIdentity) else { return }
        speechCoordinator.submit(submission)
    }

    private func runReading(_ snapshot: ReadingSnapshot, token: SessionCurrentToken) async throws {
        try await token.performCurrent {
            self.phase = .synthesizing
            self.toast = snapshot.identity.billingNotice
        }
        if let provider = speech.providerForID(snapshot.identity.providerID) {
            try await runProviderReading(snapshot, provider: provider, token: token)
            return
        }
        let clean = snapshot.clean
        let voice = snapshot.identity.legacyVoice
        let rate = snapshot.identity.rate
        let cached = speech.cachePath(clean, voice, rate)
        let wasCached = speech.cacheHit(cached)
        if wasCached { try LegacyAudioIsolation.requireCanonical(cached) }
        let chunks = Chunker.split(clean)
        let legacyRate = NormalizedRate(version: "legacy-minimax-rate-v1", value: rate)!
        _ = legacyRate
        try await requireEngineCurrent(token)

        var partURLs: [URL] = []
        var synthesized = false
        if wasCached {
            partURLs = [cached]
        } else {
            for chunk in chunks {
                let part = chunks.count == 1 ? cached : speech.cachePath(chunk, voice, rate)
                if !speech.cacheHit(part) {
                    try await speech.synthesize(chunk, voice, rate, part)
                    synthesized = true
                    try await requireEngineCurrent(token)
                } else {
                    try LegacyAudioIsolation.requireCanonical(part)
                }
                partURLs.append(part)
            }
        }

        try await requireEngineCurrent(token)
        let purpose = SpeechPurpose.reading(snapshot.origin)
        let sessionArtifact = try speech.prepareSessionArtifact(partURLs, purpose)
        let cleanupID: UUID?
        if let sessionArtifact {
            do {
                cleanupID = try token.registerUnpublishedCleanup {
                    try? FileManager.default.removeItem(at: sessionArtifact.url)
                }
            } catch {
                try? FileManager.default.removeItem(at: sessionArtifact.url)
                throw error
            }
        } else {
            cleanupID = nil
        }

        if synthesized {
            await speech.providerDidSucceed(token)
            try await requireEngineCurrent(token)
        }
        await speech.beforePlayback()
        try await requireEngineCurrent(token)
        // Player retains a terminating-process handle until TERM/SIGKILL exit
        // acknowledgement. A replacement session must drain it before any new
        // mpv launch, while the current-token check below prevents an obsolete
        // waiter from launching after cancellation.
        await player.stopAndWait()
        try await requireEngineCurrent(token)
        for (index, part) in partURLs.enumerated() {
            if index == 0 {
                try await token.performCurrent {
                    try self.player.play(file: part, prefs: snapshot.prefs, streaming: partURLs.count > 1)
                }
                try await token.performCurrent { self.phase = .playing }
            } else {
                try await token.performCurrent { try self.player.append(file: part) }
            }
        }
        if partURLs.count > 1 {
            try await token.performCurrent { self.player.finishStream(prefs: snapshot.prefs) }
        }

        let evidence = try await speech.verifyPlayback()
        try await requireEngineCurrent(token)
        let seconds = sessionArtifact?.duration ?? player.duration
        try await record(snapshot: snapshot, seconds: seconds, token: token)
        if let sessionArtifact {
            try await lastAudioStore.promote(
                sessionArtifact, generation: token.generation, purpose: purpose,
                evidence: evidence, token: token, disarmingCleanup: cleanupID
            )
        }
    }

    private func currentDefaultReadingIdentity() -> ReadingIdentity? {
        guard let card = providerSettingsState.cards.first(where: \.isDefault), let selection = card.selection else { return nil }
        guard speech.providerForID(selection.providerID) != nil ||
              (selection.providerID == .minimax && !speech.legacyMiniMaxDisabled) else { return nil }
        let effectiveSelection = normalizedCurrentSelection(selection)
        return ReadingIdentity(
            providerID: effectiveSelection.providerID, modelID: effectiveSelection.modelID, voiceID: effectiveSelection.voiceID,
            normalizedRate: effectiveSelection.rate, displayLabel: effectiveSelection.voiceID?.rawValue ?? effectiveSelection.providerID.rawValue,
            legacyVoice: effectiveSelection.voiceID?.rawValue ?? prefs.voice, rate: effectiveSelection.rate.value,
            billingNotice: nil
        )
    }

    private func normalizedCurrentSelection(_ selection: ProviderSelection) -> ProviderSelection {
        guard selection.providerID == .minimax else { return selection }
        let voice = selection.voiceID.flatMap { current in
            MiniMaxVoiceCatalogV1.migrationMapping.first(where: { stable, wire in
                stable == current || "\(wire.voiceID)|\(wire.emotion ?? "default")" == current.rawValue
            })?.key
        } ?? selection.voiceID
        let rate = ["rate-v1", "legacy-minimax-rate-v1"].contains(selection.rate.version)
            ? NormalizedRate(version: MiniMaxRateMappingV1.version, value: selection.rate.value) ?? selection.rate
            : selection.rate
        return ProviderSelection(providerID: selection.providerID, modelID: selection.modelID, voiceID: voice, rate: rate)
    }

    private func runProviderReading(
        _ snapshot: ReadingSnapshot,
        provider: any VoiceProvider,
        token: SessionCurrentToken
    ) async throws {
        guard provider.id == snapshot.identity.providerID,
              let scopeRevision = token.scopeRevision else {
            throw MiniMaxProviderError.credentialMismatch
        }
        let envelope = token.envelope
        guard provider.id == .macOS || envelope?.providerID == provider.id else { throw MiniMaxProviderError.credentialMismatch }
        let selection = ProviderSelection(
            providerID: snapshot.identity.providerID,
            modelID: snapshot.identity.modelID,
            voiceID: snapshot.identity.voiceID,
            rate: snapshot.identity.normalizedRate
        )
        try await validateSelectionGate(selection, envelope: envelope)
        Diag.record(.speechStage(providerID: provider.id, stage: .selectionValidated))
        let chunks = try await provider.split(snapshot.clean, selection: selection)
        Diag.record(.speechStage(providerID: provider.id, stage: .chunksPrepared))
        try await requireEngineCurrent(token)
        let controls = try synthesisControls(for: selection)
        let purpose = SpeechPurpose.reading(snapshot.origin)
        let gate = ProviderSynthesisGate(provider: provider)
        let credential = envelope.map { ProviderCredential.apiKey(providerID: provider.id, envelope: $0) } ?? .none
        var partURLs: [URL] = []
        let providerSuccess = ProviderSuccessOnce()

        for chunk in chunks {
            try await requireEngineCurrent(token)
            let request = try SpeechRequest.make(
                id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk,
                controls: controls, credentialScopeRevision: scopeRevision,
                capabilities: provider.capabilities,
                outputFormatID: Self.providerOutputFormatID(provider.id),
                canonicalizerVersion: "canonical-wav-v1"
            )
            let key = CacheFlightKey(
                providerID: provider.id, fingerprint: request.requestFingerprint,
                scopeRevision: scopeRevision
            )
            let speech = self.speech
            let artifact = try await speech.canonicalChunkResolver(
                key, token.generation, purpose
            ) {
                try await token.requireCurrent()
                let native = try await self.speechCoordinator.synthesizeWithRetry(
                    token: token, contract: try self.providerRetryContract(provider.id)
                ) { _ in
                    .success(try await gate.synthesize(request, credential: credential))
                }
                let nativeCleanupID: UUID
                do {
                    nativeCleanupID = try token.registerUnpublishedCleanup {
                        native.cleanupIfOwned()
                    }
                } catch {
                    native.cleanupIfOwned()
                    throw error
                }
                defer {
                    native.cleanupIfOwned()
                    try? token.disarmUnpublishedCleanup(nativeCleanupID)
                }
                await speech.afterNativeSynthesis()
                try await token.requireCurrent()
                if await providerSuccess.claim() {
                    await speech.providerDidSucceed(token)
                    try await token.requireCurrent()
                }
                let canonical = try await speech.canonicalizeNative(native.artifact, purpose, snapshot.prefs.ffmpegBin)
                native.cleanupIfOwned()
                try? token.disarmUnpublishedCleanup(nativeCleanupID)
                let canonicalCleanupID: UUID
                do {
                    canonicalCleanupID = try token.registerUnpublishedCleanup {
                        canonical.cleanupIfOwned()
                    }
                } catch {
                    canonical.cleanupIfOwned()
                    throw error
                }
                defer {
                    canonical.cleanupIfOwned()
                    try? token.disarmUnpublishedCleanup(canonicalCleanupID)
                }
                await speech.afterCanonicalization()
                try await token.requireCurrent()
                return try token.transferUnpublishedArtifact(
                    canonical, cleanupID: canonicalCleanupID
                )
            }
            try await requireEngineCurrent(token)
            partURLs.append(artifact.url)
            Diag.record(.speechStage(providerID: provider.id, stage: .canonicalAudioReady))
        }

        let sessionArtifact = try speech.prepareSessionArtifact(partURLs, purpose)
        Diag.record(.speechStage(providerID: provider.id, stage: .sessionAudioReady))
        let cleanupID: UUID?
        if let sessionArtifact {
            do {
                cleanupID = try token.registerUnpublishedCleanup {
                    try? FileManager.default.removeItem(at: sessionArtifact.url)
                }
            } catch {
                try? FileManager.default.removeItem(at: sessionArtifact.url)
                throw error
            }
        } else {
            cleanupID = nil
        }

        await speech.beforePlayback()
        try await requireEngineCurrent(token)
        await player.stopAndWait()
        try await requireEngineCurrent(token)
        for (index, part) in partURLs.enumerated() {
            if index == 0 {
                try await token.performCurrent {
                    try self.player.play(file: part, prefs: snapshot.prefs, streaming: partURLs.count > 1)
                }
                try await token.performCurrent { self.phase = .playing }
                Diag.record(.speechStage(providerID: provider.id, stage: .playbackLaunched))
            } else {
                try await token.performCurrent { try self.player.append(file: part) }
            }
        }
        if partURLs.count > 1 {
            try await token.performCurrent { self.player.finishStream(prefs: snapshot.prefs) }
        }

        let evidence = try await speech.verifyPlayback()
        Diag.record(.speechStage(providerID: provider.id, stage: .playbackVerified))
        try await requireEngineCurrent(token)
        let seconds = sessionArtifact?.duration ?? player.duration
        try await record(snapshot: snapshot, seconds: seconds, token: token)
        Diag.record(.speechStage(providerID: provider.id, stage: .historyWritten))
        if let sessionArtifact {
            try await lastAudioStore.promote(
                sessionArtifact, generation: token.generation, purpose: purpose,
                evidence: evidence, token: token, disarmingCleanup: cleanupID
            )
            Diag.record(.speechStage(providerID: provider.id, stage: .lastAudioPromoted))
        }
    }

    private func synthesisControls(for selection: ProviderSelection) throws -> SynthesisControls {
        switch selection.providerID {
        case .minimax: return try MiniMaxRateMappingV1.controls(for: selection.rate)
        case .openAI: return try OpenAIRateMappingV1.controls(for: selection.rate)
        case .gemini: return try GeminiRateMappingV1.controls(for: selection.rate)
        case .macOS: return try SystemVoiceRateMappingV1.controls(for: selection.rate)
        default: throw MiniMaxProviderError.invalidRequest
        }
    }

    private static func providerOutputFormatID(_ providerID: ProviderID) -> String { previewOutputFormatID(providerID) }

    private func providerRetryContract(_ providerID: ProviderID) throws -> RetryContract {
        guard let contract = try ProviderContractCatalog.bundled().contract(for: providerID) else { throw MiniMaxProviderError.invalidRequest }
        return contract.retryContract
    }

    private func validateAccountSelection(_ selection: ProviderSelection, scopeRevision: UUID) async throws {
        guard await accountSelectionValidation(selection, scopeRevision: scopeRevision) != .invalid else {
            throw MiniMaxProviderError.invalidRequest
        }
    }

    private func accountSelectionValidation(_ selection: ProviderSelection, scopeRevision: UUID) async -> SelectionValidation {
        guard let voice = selection.voiceID else { return .invalid }
        let snapshot = await speech.accountSnapshot(selection.providerID)
        guard let relationship = snapshot.relationshipEvidence.first(where: {
            $0.key.providerID == selection.providerID && $0.key.credentialRevision == scopeRevision &&
            $0.key.parentModelID == selection.modelID
        }) else { return .unknown }
        let resources: ContractOwnedResources
        switch selection.providerID {
        case .minimax: resources = MiniMaxVoiceCatalogV1.contractOwnedResources
        case .openAI: resources = OpenAIVoiceCatalogV1.contractOwnedResources
        case .gemini: resources = GeminiVoiceCatalogV1.contractOwnedResources
        default: resources = .none
        }
        return AccountSelectionValidator.validate(
            model: selection.modelID, voice: voice, in: snapshot, scope: relationship.key,
            currentRevision: scopeRevision, currentRefreshID: relationship.value.refreshID,
            contractOwned: resources
        )
    }

    private func requireEngineCurrent(_ token: SessionCurrentToken) async throws {
        try await token.requireCurrent()
        guard !(await credentialRegistry.isBlocked(token.session.providerID)) else { throw CancellationError() }
    }

    func togglePause() {
        player.togglePause()
        phase = player.paused ? .paused : .playing
    }

    func stop() {
        let control = speechCoordinator.requestStop(reason: .userStopped, stopPlayer: stopPlayerCommand())
        try? control.performCurrentSync {
            phase = .idle
        }
    }

    private func stopPlayerCommand() -> SpeechCoordinator.StopPlayer {
        { [weak self] control in
            guard let self else { return }
            let stopped = try? await control.performCurrent {
                self.player.stop()
                self.phase = .idle
                return true
            }
            guard stopped == true else { return }
            await self.player.stopAndWait()
        }
    }

    func installCredentialCancellationHook() async {
        guard credentialCancellationHookIDs.isEmpty else {
            await speechReadiness.markReady()
            return
        }
        for providerID in [ProviderID.minimax, .openAI, .gemini] {
            credentialCancellationHookIDs[providerID] = await credentialRegistry.registerCancellation(providerID: providerID) { [weak self] in
                guard let self else { return }
                let (coordinator, stopPlayer) = await MainActor.run { (self.speechCoordinator, self.stopPlayerCommand()) }
                await coordinator.credentialWillChange(providerID: providerID, stopPlayer: stopPlayer)
                await MainActor.run { [weak self] in
                    guard let self, let index = self.providerSettingsState.cards.firstIndex(where: { $0.id == providerID }) else { return }
                    self.providerSettingsState.cards[index].health = .unknown
                }
            }
        }
        await speechReadiness.markReady()
    }

    func shutdownSpeech() async {
        await speechCoordinator.shutdown(stopPlayer: stopPlayerCommand())
    }

    func seek(_ delta: Double) { player.seek(relative: delta) }

    func setSpeed(_ s: Double) {
        let effects = prefsEffects
        mutatePrefsThenEffect({ $0.playbackSpeed = s }, apply: { prefs in
            await effects.setPlaybackSpeed(prefs.playbackSpeed)
        }, compensate: { prefs in
            await effects.setPlaybackSpeed(prefs.playbackSpeed)
        })
    }

    func readClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            toast = "剪贴板是空的"
            return
        }
        text = s
        speak()
    }

    /// 热键路径:读别的 app 里选中的文字。失败原因要说人话,别让人对着"失败"猜。
    func readSelection() {
        Diag.record(.selectionRead(status: .started, characterCount: nil))
        guard let identity = currentDefaultReadingIdentity() else {
            Diag.record(.selectionRead(status: .failed, characterCount: nil))
            toast = "当前默认语音服务尚不可用，请先完成配置。"
            return
        }
        let read = speech.readSelection
        let disclosure = openAIDisclosureCoordinator
        speechCoordinator.submitInput(
            providerID: identity.providerID,
            stopPlayer: stopPlayerCommand(),
            advanceCacheScope: speech.advanceCanonicalScope,
            prepare: { [weak self] control in
                guard let self else { throw CancellationError() }
                let s = try await read()
                try Task.checkCancellation()
                if identity.providerID == .openAI, let voiceID = identity.voiceID {
                    try await disclosure.performIfAuthorized(
                        modelID: identity.modelID, voiceID: voiceID,
                        purpose: .reading(.speak)
                    ) {}
                }
                return try await control.performCurrent {
                    guard let current = self.currentDefaultReadingIdentity(),
                          current.providerID == identity.providerID,
                          current.modelID == identity.modelID,
                          current.voiceID == identity.voiceID,
                          current.normalizedRate == identity.normalizedRate else {
                        throw CancellationError()
                    }
                    self.text = s
                    Diag.record(.selectionRead(status: .success, characterCount: s.count))
                    return self.readingSubmission(raw: s, origin: .speak, historyIdentity: identity)
                }
            },
            onPreparationFailure: { [weak self] control, error in
                guard let self else { return }
                Diag.record(.selectionRead(status: error is CancellationError ? .cancelled : .failed, characterCount: nil))
                _ = try? await control.performCurrent {
                    self.toast = error is OpenAIDisclosureAuthorizationError
                        ? OpenAIDisclosurePolicy.text
                        : PrivacySafeMessage.selectionFailed(error)
                    NSSound(named: "Basso")?.play()
                }
            }
        )
    }

    /// 开机自启走 SMAppService,不用往 LaunchAgents 里塞 plist。
    func applyLaunchAtLogin(_ on: Bool) {
        let effects = prefsEffects
        mutatePrefsThenEffect({ $0.launchAtLogin = on }, apply: { prefs in
            try await effects.setLaunchAtLogin(prefs.launchAtLogin)
        }, compensate: { prefs in
            try await effects.setLaunchAtLogin(prefs.launchAtLogin)
        })
    }

    /// 只留菜单栏 = 从 Dock 和 ⌘Tab 里消失。切换是即时的,不用重启。
    func applyMenuBarOnly(_ on: Bool) {
        let effects = prefsEffects
        mutatePrefsThenEffect({ $0.menuBarOnly = on }, apply: { prefs in
            await effects.setMenuBarOnly(prefs.menuBarOnly)
        }, compensate: { prefs in
            await effects.setMenuBarOnly(prefs.menuBarOnly)
        })
    }

    /// 改完热键立刻重注册,不用重启 app。
    func rebindHotkey(_ action: HotkeyAction, _ spec: HotkeySpec) {
        let effects = prefsEffects
        mutatePrefsThenEffect({ $0.setHotkey(action, spec) }, apply: { prefs in
            try await effects.registerHotkeys(prefs)
        }, compensate: { prefs in
            try await effects.registerHotkeys(prefs)
        })
    }

    /// 录制取消时:把三个热键原样装回去
    func restoreHotkeys() {
        for a in HotkeyAction.allCases {
            let s = prefs.hotkey(a)
            if !s.isEmpty { hotkeys.register(a, s) }
        }
    }

    func installHotkeysAfterInitialHydration() async {
        await waitForInitialHydration()
        installHotkeys()
    }

    /// 启动时装热键。注册失败通常是别的实例先抢注了(开发实例 vs 正式 app)。
    func installHotkeys() {
        hotkeys.install { [weak self] action in
            guard let self else { return }
            switch action {
            case .readSelection:
                if self.prefs.hotkeyChime { NSSound(named: "Pop")?.play() }
                self.readSelection()
            case .readClipboard:
                if self.prefs.hotkeyChime { NSSound(named: "Pop")?.play() }
                self.readClipboard()
            case .togglePause:
                if self.phase.isLive { self.togglePause() }
            }
        }
        let result = hotkeys.registerAll([
            .readSelection: prefs.hkReadSelection,
            .readClipboard: prefs.hkReadClipboard,
            .togglePause: prefs.hkTogglePause,
        ])
        let failed = result.filter { !$0.value }.keys
        if !failed.isEmpty {
            toast = "有 \(failed.count) 个热键没注册上，可能被别的 app 占了"
        }
        // 读选中要辅助功能权限。没有就弹系统授权框——这个框只有 app 自己能唤起。
        if !Selection.hasAccessibility {
            Selection.requestAccessibility()
        }
        Diag.record(.hotkeyRegistration(failureCount: failed.count, accessibilityEnabled: Selection.hasAccessibility))
    }

    func saveAudio() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stem = Self.exportFilenameStem()
        var dest = downloads.appendingPathComponent("\(stem).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("\(stem)-\(n).wav")
            n += 1
        }
        let lastAudioStore = self.lastAudioStore
        Task { @MainActor [weak self] in
            do {
                _ = try await AudioExporter.saveAudio(from: lastAudioStore, to: dest)
                self?.toast = "已保存 → \(dest.lastPathComponent)"
            } catch LastAudioError.noRetainedAudio {
                self?.toast = "还没有可保存的音频，先念一次"
            } catch {
                self?.toast = PrivacySafeMessage.exportFailed(error)
            }
        }
    }

    static func exportFilenameStem(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "念-音频-\(formatter.string(from: date))"
    }

    func loadHistory(_ entry: HistoryEntry) {
        guard HistoryActionPolicy(entry: entry).allows(.load), let text = entry.text else { return }
        self.text = text
    }

    func replay(_ e: HistoryEntry) {
        guard HistoryActionPolicy(entry: e).allows(.replay), let text = e.text, let voiceID = e.voiceID else { return }
        let selection = ProviderSelection(providerID: e.providerID, modelID: e.modelID, voiceID: voiceID, rate: e.rate)
        let speech = self.speech
        let readiness = speechReadiness
        let disclosure = openAIDisclosureCoordinator
        speechCoordinator.submitInput(
            providerID: e.providerID, stopPlayer: stopPlayerCommand(), advanceCacheScope: speech.advanceCanonicalScope,
            prepare: { @MainActor [weak self] control in
                guard let self else { throw CancellationError() }
                try await readiness.wait()
                let envelope = e.providerID == .macOS ? nil : try await speech.captureCredential(e.providerID)
                try await self.validateReplaySelection(selection, envelope: envelope)
                if e.providerID == .openAI {
                    try await disclosure.performIfAuthorized(modelID: e.modelID, voiceID: voiceID, purpose: .reading(.replay)) {}
                }
                return try await control.performCurrent {
                    let identity = ReadingIdentity(
                        providerID: e.providerID, modelID: e.modelID, voiceID: voiceID, normalizedRate: e.rate,
                        displayLabel: e.displayLabelSnapshot, legacyVoice: voiceID.rawValue, rate: e.rate.value,
                        billingNotice: self.replayBillingNotice(e.providerID)
                    )
                    self.text = text
                    return self.readingSubmission(raw: text, origin: .replay, historyIdentity: identity, capturedEnvelope: envelope)
                }
            },
            onPreparationFailure: { @MainActor [weak self] control, error in
                guard let self else { return }
                _ = try? await control.performCurrent {
                    self.phase = .idle
                    self.toast = error is OpenAIDisclosureAuthorizationError
                        ? "OpenAI AI 生成语音：确认披露后才能重播；费用计入原 OpenAI API 账户。"
                        : "无法按历史语音重播，请检查原服务商、凭据和音色配置。"
                }
            }
        )
    }

    private func validateReplaySelection(_ selection: ProviderSelection, envelope: CredentialEnvelope?) async throws {
        guard speech.providerForID(selection.providerID) != nil || (selection.providerID == .minimax && !speech.legacyMiniMaxDisabled) else { throw ReplayBlockReason.providerUnavailable }
        try await validateSelectionGate(selection, envelope: envelope)
    }

    /// Single synthesis authorization contract used by ordinary Speak and
    /// exact Replay. UI card state is never sufficient authorization.
    private func validateSelectionGate(_ selection: ProviderSelection, envelope: CredentialEnvelope?) async throws {
        guard selection.providerID == .macOS || envelope?.providerID == selection.providerID else { throw ReplayBlockReason.credentialMissing }
        let catalog = try ProviderContractCatalog.bundled()
        let provider = catalog.providerAvailability(for: selection.providerID)
        let model = catalog.modelAvailability(providerID: selection.providerID, modelID: selection.modelID)
        guard validRateVersion(selection.rate.version, providerID: selection.providerID) else { throw ReplayBlockReason.selectionInvalid }
        let health = providerSettingsState.cards.first(where: { $0.id == selection.providerID })?.health ?? .unknown
        let credential: CredentialGateState = selection.providerID == .macOS ? .noneRequired : .configured(health: health)
        let account = if let revision = envelope?.revision {
            await accountSelectionValidation(selection, scopeRevision: revision)
        } else { SelectionValidation.unknown }
        let feature = await providerSettingsStore.prefsSnapshot().featureFlags.geminiExperimentalEnabled
        // Phase-one production has no approved Gemini release/E2E evidence.
        let releaseApproved = selection.providerID != .gemini
        guard SelectionGate.evaluate(
            credential: credential, provider: provider, model: model, account: account,
            featureFlag: feature, releaseApproved: releaseApproved
        ) == .allowed else { throw ReplayBlockReason.selectionInvalid }
    }

    private func validRateVersion(_ version: String, providerID: ProviderID) -> Bool {
        switch providerID {
        case .minimax: return version == MiniMaxRateMappingV1.version || version == "legacy-minimax-rate-v1"
        case .openAI: return version == OpenAIRateMappingV1.version
        case .gemini: return version == GeminiRateMappingV1.version
        case .macOS: return version == SystemVoiceRateMappingV1.version
        default: return false
        }
    }

    private func replayBillingNotice(_ providerID: ProviderID) -> String {
        let name = providerID == .openAI ? "OpenAI" : providerID == .minimax ? "MiniMax" : providerID == .gemini ? "Gemini / Google Cloud" : "macOS"
        return "正在按历史配置重播；使用原 \(name) 服务" + (providerID == .macOS ? "。" : "并计入该 API 账户。") + (providerID == .openAI ? " 此声音由 AI 生成。" : "")
    }

    private func record(snapshot: ReadingSnapshot, seconds: TimeInterval, token: SessionCurrentToken) async throws {
        let identity = snapshot.identity
        let entry = HistoryEntry(id: UUID(), version: 1, text: snapshot.raw, contentResolution: .valid,
                                 seconds: Int(seconds.rounded()), providerID: identity.providerID,
                                 modelID: identity.modelID, voiceID: identity.voiceID,
                                 rate: identity.normalizedRate,
                                 displayLabelSnapshot: identity.displayLabel,
                                 selectionResolution: identity.voiceID == nil ? .unresolvedLegacyVoice : .resolved,
                                 date: Date(), legacyAgoSnapshot: nil)
        await speech.beforeHistoryWrite()
        try await requireEngineCurrent(token)
        let registry = credentialRegistry
        let updated = try await historyMutations.append(entry, preflight: {
            try await token.requireCurrent()
            guard !(await registry.isBlocked(token.session.providerID)) else { throw CancellationError() }
        })
        try await requireEngineCurrent(token)
        try await token.performCurrent { self.history = updated }
    }
}

/// 词典替换。朗读前生效,缓存 key 用的是替换之后的文本。
enum Dictionary_ {
    static func apply(_ text: String, prefs: Prefs, rules: [DictRule]) -> String {
        var out = text
        // 空的 find 会把整篇文本替换烂,必须跳过(新建规则还没填完时就是空的)
        for r in rules where r.enabled && !r.find.isEmpty {
            out = out.replacingOccurrences(of: r.find, with: r.replace)
        }
        if prefs.stripMarkdown {
            out = out.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
        }
        if prefs.skipCode {
            out = out.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Legacy cache facade kept only for the pre-provider test seam. Provider work
/// publishes through CanonicalAudioCache with RequestFingerprint identity.
enum AudioCache {
    static func path(text: String, voice: String, rate: Int) -> URL {
        let digest = SHA256.hash(data: Data("\(text)|\(voice)|\(rate)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Store.cacheDir.appendingPathComponent("\(hex).wav")
    }

    static func hit(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "wav" else { return false }
        return (try? WAVValidator.validate(url, purpose: .reading(.speak))) != nil
    }
}

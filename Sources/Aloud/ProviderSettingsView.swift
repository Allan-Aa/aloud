import Foundation
import SwiftUI

enum CredentialAuthRoute: Equatable, Hashable, Sendable { case onePasswordImport, manualAPIKey }
enum ProviderSaveCapability: Equatable, Sendable { case available, notApplicable }
enum ProviderCardAction: Equatable, Hashable, Sendable {
    case importFromOnePassword, saveManual, preview, setDefault, configure, repair, backupAndReset, confirmDisclosure, login, logout
}
enum ProviderCardControl: Equatable, Hashable, Sendable { case onePasswordImport, secureField, preview, model, voice, rate, revealSecret, copySecret }

struct ProviderCardState: Identifiable, Equatable, Sendable {
    let id: ProviderID
    let authRoutes: [CredentialAuthRoute]
    var availability: ProviderAvailability
    var configuration: ProviderConfiguration
    var health: ProviderHealth
    var isDefault: Bool
    var selection: ProviderSelection?
    let availableVoices: [MiniMaxVoiceDescriptor]
    let accountCoverage: [CatalogDimension: EvidenceCoverage]
    let accountCatalogPresentation: [AccountCatalogPresentationDimension: AccountCatalogPresentation]
    let catalogSource: String
    let catalogFetchedAt: Date?
    let disclosure: String?
    let billingNotice: String?
    let previewBillingNotice: String?
    var actions: Set<ProviderCardAction>
    let saveCapability: ProviderSaveCapability
    var persistenceActionsEnabled: Bool

    var statusText: String {
        if isDefault && configuration == .unconfigured { return "默认 · 未配置" }
        if isDefault { return "默认" }
        switch configuration {
        case .configured: return "已配置"
        case .unconfigured: return "未配置"
        case .invalidSelection: return "选择不可用"
        }
    }

    var synthesisBlockedReason: SynthesisBlockReason? {
        switch availability.kind {
        case .disabled: return .providerDisabled
        case .deprecated: return .providerDeprecated
        case .unknown: return .contractUnknown
        case .experimental where availability.featureFlagEnabled != true: return .experimentalFeatureDisabled
        case .available, .experimental: return nil
        }
    }
}

struct ProviderSettingsState: Equatable, Sendable {
    var cards: [ProviderCardState]
    var recoveryMode: Bool
    var recoveryMessage: String

    func card(_ id: ProviderID) -> ProviderCardState { cards.first { $0.id == id }! }

    static func build(
        prefs: PrefsV1,
        credentialConfigurations: [ProviderID: ProviderConfiguration],
        health: [ProviderID: ProviderHealth],
        recoveryMode: Bool,
        accountCoverage: [ProviderID: [CatalogDimension: EvidenceCoverage]] = [:],
        accountPresentation: [ProviderID: [AccountCatalogPresentationDimension: AccountCatalogPresentation]] = [:],
        availableVoices: [ProviderID: [MiniMaxVoiceDescriptor]] = [:],
        catalog: ProviderContractCatalog = try! ProviderContractCatalog.bundled()
    ) throws -> ProviderSettingsState {
        let cloudNotice = "将请求一次短句合成，可能产生少量可计费用量"
        let defaultSelections: [ProviderID: ProviderSelection] = [
            .openAI: .init(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"), rate: NormalizedRate(version: "openai-rate-v1", value: 0)!),
            .gemini: .init(providerID: .gemini, modelID: GeminiWireContractV1.modelID, voiceID: VoiceID(rawValue: "gemini.Kore"), rate: NormalizedRate(version: GeminiRateMappingV1.version, value: 0)!),
        ]
        let routes: [ProviderID: [CredentialAuthRoute]] = [.minimax: [.onePasswordImport, .manualAPIKey], .openAI: [.manualAPIKey], .gemini: [.manualAPIKey], .macOS: []]
        var state = ProviderSettingsState(
            cards: [ProviderID.minimax, .openAI, .gemini, .macOS].map { id in
                let evidence = catalog.evidenceRecords.first { $0.providerID == id && $0.kind == .provider }
                let selection = prefs.selections[id] ?? defaultSelections[id]
                let catalogAvailability = catalog.providerAvailability(for: id)
                let availability = id == .gemini && catalogAvailability.kind == .experimental
                    ? ProviderAvailability(
                        kind: catalogAvailability.kind, reason: catalogAvailability.reason,
                        maturity: catalogAvailability.maturity,
                        featureFlagName: catalogAvailability.featureFlagName,
                        featureFlagEnabled: prefs.featureFlags.geminiExperimentalEnabled,
                        providerContractVersion: catalogAvailability.providerContractVersion,
                        evidenceID: catalogAvailability.evidenceID
                    )
                    : catalogAvailability
                var actions: Set<ProviderCardAction> = id == .minimax ? [.importFromOnePassword, .saveManual, .preview, .setDefault] : id == .macOS ? [.preview, .setDefault] : [.saveManual, .preview, .setDefault]
                if id == .openAI, let model = selection?.modelID, let voice = selection?.voiceID,
                   prefs.openAIDisclosureAck?.matches(policyVersion: OpenAIDisclosurePolicy.version, modelID: model, voiceID: voice) != true {
                    actions.insert(.confirmDisclosure)
                }
                return ProviderCardState(
                    id: id,
                    authRoutes: routes[id]!,
                    availability: availability,
                    configuration: credentialConfigurations[id] ?? (id == .macOS ? .configured : .unconfigured),
                    health: health[id] ?? .unknown,
                    isDefault: id == prefs.defaultProviderID,
                    selection: selection,
                    availableVoices: availableVoices[id] ?? [],
                    accountCoverage: accountCoverage[id] ?? [.model: .unknown, .voice: .unknown, .controls: .unknown],
                    accountCatalogPresentation: accountPresentation[id] ?? [:],
                    catalogSource: evidence?.evidence.sourceURL.absoluteString ?? "unverified",
                    catalogFetchedAt: evidence?.evidence.retrievedAt,
                    disclosure: id == .openAI ? "AI 生成语音" : nil,
                    billingNotice: id == .gemini ? "费用计入 API Key 关联的 Google Cloud 项目，不是 Gemini 网页订阅。" : nil,
                    previewBillingNotice: id == .macOS ? nil : cloudNotice,
                    actions: actions,
                    saveCapability: id == .macOS ? .notApplicable : .available,
                    persistenceActionsEnabled: true
                )
            },
            recoveryMode: false,
            recoveryMessage: ""
        )
        if recoveryMode { state = ProviderSettingsReducer.reduce(state, .recoveryModeChanged(true)) }
        return state
    }

    static func fixture(defaultProviderID: ProviderID = .minimax) throws -> ProviderSettingsState {
        var prefs = PrefsV1.defaults
        prefs.defaultProviderID = defaultProviderID
        prefs.selections[.openAI] = .init(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"), rate: NormalizedRate(version: "openai-rate-v1", value: 0)!)
        prefs.selections[.gemini] = .init(providerID: .gemini, modelID: GeminiWireContractV1.modelID, voiceID: VoiceID(rawValue: "gemini.Kore"), rate: NormalizedRate(version: GeminiRateMappingV1.version, value: 0)!)
        prefs.selections[.macOS] = .init(providerID: .macOS, modelID: SystemVoiceContractV1.modelID, voiceID: VoiceID(rawValue: "macos.fixture"), rate: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: 0)!)
        return try build(
            prefs: prefs,
            credentialConfigurations: [.minimax: .configured, .openAI: .configured, .gemini: .configured, .macOS: .configured],
            health: [:], recoveryMode: false,
            accountCoverage: Dictionary(uniqueKeysWithValues: [ProviderID.minimax, .openAI, .gemini, .macOS].map { ($0, [.voice: .authoritativeComplete]) })
        )
    }
}

enum ProviderSettingsPersistenceError: Error, Equatable, Sendable { case unavailable }

enum ProviderSettingsPersistenceGate {
    static func canMutateSelection(_ card: ProviderCardState) -> Bool {
        card.persistenceActionsEnabled && card.synthesisBlockedReason == nil
    }
    static func canSetDefault(_ card: ProviderCardState) -> Bool {
        canMutateSelection(card) && card.configuration == .configured && card.selection != nil
    }
    static func canSynthesize(_ card: ProviderCardState) -> Bool {
        card.health != .explicitRejected && card.synthesisBlockedReason == nil &&
            card.configuration == .configured && card.selection != nil
    }
}

struct ProviderCatalogRefresh: Sendable {
    let snapshot: AccountCatalogSnapshot
    let voices: [MiniMaxVoiceDescriptor]
    let publicationRevision: UUID?
    let healthOverride: ProviderHealth?

    init(
        snapshot: AccountCatalogSnapshot,
        voices: [MiniMaxVoiceDescriptor],
        publicationRevision: UUID? = nil,
        healthOverride: ProviderHealth? = nil
    ) {
        self.snapshot = snapshot
        self.voices = voices
        self.publicationRevision = publicationRevision
        self.healthOverride = healthOverride
    }
}

struct ProviderSettingsRuntimeLoader: Sendable {
    typealias ReadCredential = @Sendable (ProviderID) async -> CredentialReadResult
    typealias AccountSnapshot = @Sendable (ProviderID) async -> AccountCatalogSnapshot
    typealias RefreshCatalog = @Sendable (
        ProviderID,
        CredentialEnvelope,
        ProviderAccountEvidenceStore.PublicationToken
    ) async throws -> ProviderCatalogRefresh?
    let readCredential: ReadCredential
    let accountSnapshot: AccountSnapshot
    let refreshCatalog: RefreshCatalog
    private let publication: ProviderAccountEvidenceStore
    private let beforeFinalPublicationValidation: @Sendable () async -> Void

    init(
        readCredential: @escaping ReadCredential,
        accountSnapshot: @escaping AccountSnapshot,
        refreshCatalog: @escaping RefreshCatalog = { _, _, _ in nil },
        publication: ProviderAccountEvidenceStore = ProviderAccountEvidenceStore(),
        beforeFinalPublicationValidation: @escaping @Sendable () async -> Void = {}
    ) {
        self.readCredential = readCredential
        self.accountSnapshot = accountSnapshot
        self.refreshCatalog = refreshCatalog
        self.publication = publication
        self.beforeFinalPublicationValidation = beforeFinalPublicationValidation
    }

    @MainActor
    func load(
        prefs: PrefsV1,
        recoveryMode: Bool,
        health: [ProviderID: ProviderHealth] = [:],
        resetHealthFor: Set<ProviderID> = [],
        install: (ProviderSettingsState) -> Void = { _ in }
    ) async throws -> ProviderSettingsState {
        let publicationToken = publication.beginPublication()
        var configurations: [ProviderID: ProviderConfiguration] = [.macOS: .configured]
        var envelopes: [ProviderID: CredentialEnvelope] = [:]
        for providerID in [ProviderID.minimax, .openAI, .gemini] {
            switch await readCredential(providerID) {
            case .available(let envelope) where envelope.providerID == providerID:
                configurations[providerID] = .configured
                envelopes[providerID] = envelope
            case .available, .missing, .blocked:
                configurations[providerID] = .unconfigured
            }
        }
        var coverage: [ProviderID: [CatalogDimension: EvidenceCoverage]] = [:]
        var presentations: [ProviderID: [AccountCatalogPresentationDimension: AccountCatalogPresentation]] = [:]
        var snapshots: [ProviderID: AccountCatalogSnapshot] = [:]
        var availableVoices: [ProviderID: [MiniMaxVoiceDescriptor]] = [:]
        var miniMaxRefresh: ProviderCatalogRefresh?
        for providerID in [ProviderID.minimax, .openAI, .gemini, .macOS] {
            let refreshed = providerID == .minimax && envelopes[providerID] != nil
                ? try await refreshCatalog(providerID, envelopes[providerID]!, publicationToken)
                : nil
            try Task.checkCancellation()
            let snapshot: AccountCatalogSnapshot
            if let refreshed {
                snapshot = refreshed.snapshot
            } else {
                snapshot = await accountSnapshot(providerID)
            }
            snapshots[providerID] = snapshot
            availableVoices[providerID] = refreshed?.voices ?? []
            if providerID == .minimax { miniMaxRefresh = refreshed }
            coverage[providerID] = Self.coverage(from: snapshot, providerID: providerID)
            presentations[providerID] = Self.presentation(from: snapshot, providerID: providerID)
        }
        let catalog = try ProviderContractCatalog.bundled()
        for providerID in [ProviderID.minimax, .openAI, .gemini, .macOS] {
            guard configurations[providerID] == .configured, let selection = prefs.selections[providerID] else { continue }
            let model = catalog.modelAvailability(providerID: providerID, modelID: selection.modelID)
            if [.disabled, .deprecated, .unknown].contains(model.kind) {
                configurations[providerID] = .invalidSelection
                continue
            }
            guard let revision = envelopes[providerID]?.revision, let voice = selection.voiceID,
                  let snapshot = snapshots[providerID],
                  let relationship = snapshot.relationshipEvidence.first(where: {
                      $0.key.providerID == providerID && $0.key.credentialRevision == revision &&
                      $0.key.contractVersion == model.contractVersion && $0.key.parentModelID == selection.modelID
                  }) else { continue }
            let validation = AccountSelectionValidator.validate(
                model: selection.modelID, voice: voice, in: snapshot, scope: relationship.key,
                currentRevision: revision, currentRefreshID: relationship.value.refreshID,
                contractOwned: Self.contractOwnedResources(providerID)
            )
            if validation == .invalid { configurations[providerID] = .invalidSelection }
        }
        var resolvedHealth = health.merging(
            Dictionary(uniqueKeysWithValues: resetHealthFor.map { ($0, ProviderHealth.unknown) }),
            uniquingKeysWith: { _, reset in reset }
        )
        if let healthOverride = miniMaxRefresh?.healthOverride {
            resolvedHealth[.minimax] = healthOverride
        }
        let candidate = try ProviderSettingsState.build(
            prefs: prefs, credentialConfigurations: configurations,
            health: resolvedHealth,
            recoveryMode: recoveryMode, accountCoverage: coverage, accountPresentation: presentations,
            availableVoices: availableVoices,
            catalog: catalog
        )
        try Task.checkCancellation()
        let receipt = try await publication.publish(
            candidate, miniMaxRefresh: miniMaxRefresh, using: publicationToken
        )
        await beforeFinalPublicationValidation()
        try receipt.install(apply: install)
        return receipt.candidate
    }

    private static func coverage(from snapshot: AccountCatalogSnapshot, providerID: ProviderID) -> [CatalogDimension: EvidenceCoverage] {
        func strongest(_ values: [EvidenceCoverage]) -> EvidenceCoverage {
            values.contains(.authoritativeComplete) ? .authoritativeComplete : values.contains(.partial) ? .partial : .unknown
        }
        let models = snapshot.modelEvidence.filter { $0.key.providerID == providerID }.flatMap { $0.value.values.map(\.coverage) }
        let voices = snapshot.voiceEvidence.filter { $0.key.providerID == providerID }.flatMap { $0.value.values.map(\.coverage) }
        let controls = snapshot.controlsEvidence.filter { $0.key.providerID == providerID }.flatMap { $0.value.values.map(\.coverage) }
        return [.model: strongest(models), .voice: strongest(voices), .controls: strongest(controls)]
    }

    private static func contractOwnedResources(_ providerID: ProviderID) -> ContractOwnedResources {
        switch providerID {
        case .minimax: return MiniMaxVoiceCatalogV1.contractOwnedResources
        case .openAI: return OpenAIVoiceCatalogV1.contractOwnedResources
        case .gemini: return GeminiVoiceCatalogV1.contractOwnedResources
        default: return .none
        }
    }

    private static func presentation(from snapshot: AccountCatalogSnapshot, providerID: ProviderID) -> [AccountCatalogPresentationDimension: AccountCatalogPresentation] {
        var result: [AccountCatalogPresentationDimension: AccountCatalogPresentation] = [:]
        func assign(_ dimension: AccountCatalogPresentationDimension, _ entries: [(String, Date, EvidenceCoverage, ContractVersion)]) {
            guard let latest = entries.max(by: { $0.1 < $1.1 }) else { return }
            result[dimension] = AccountCatalogPresentation(authoritySource: latest.0, fetchedAt: latest.1, coverage: latest.2, contractVersion: latest.3)
        }
        assign(.model, snapshot.modelEvidence.filter { $0.key.providerID == providerID }.flatMap { $0.value.values.map { ($0.authoritySource, $0.fetchedAt, $0.coverage, $0.contractVersion) } })
        assign(.voice, snapshot.voiceEvidence.filter { $0.key.providerID == providerID }.flatMap { $0.value.values.map { ($0.authoritySource, $0.fetchedAt, $0.coverage, $0.contractVersion) } })
        assign(.controls, snapshot.controlsEvidence.filter { $0.key.providerID == providerID }.flatMap { $0.value.values.map { ($0.authoritySource, $0.fetchedAt, $0.coverage, $0.contractVersion) } })
        assign(.relationship, snapshot.relationshipEvidence.filter { $0.key.providerID == providerID }.map { ($0.value.authoritySource, $0.value.fetchedAt, $0.value.coverage, $0.value.contractVersion) })
        return result
    }
}

enum AccountCatalogPresentationDimension: String, CaseIterable, Hashable, Sendable { case model, voice, controls, relationship }
struct AccountCatalogPresentation: Equatable, Sendable {
    let authoritySource: String?
    let fetchedAt: Date?
    let coverage: EvidenceCoverage
    let contractVersion: ContractVersion
}

actor ProviderAccountEvidenceStore {
    static let shared = ProviderAccountEvidenceStore()
    struct PublicationToken: Equatable, Sendable {
        let generation: UInt64
        fileprivate let source: ProviderSettingsPublicationGeneration

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.generation == rhs.generation && lhs.source === rhs.source
        }

        fileprivate func validateCurrent() throws {
            try Task.checkCancellation()
            guard source.isCurrent(generation) else { throw CancellationError() }
        }

        fileprivate var isCurrent: Bool { source.isCurrent(generation) }
    }

    struct PublicationReceipt: Sendable {
        let candidate: ProviderSettingsState
        fileprivate let generation: UInt64
        fileprivate let miniMaxBaseline: MiniMaxPublicationBaseline
        fileprivate let source: ProviderSettingsPublicationGeneration

        @MainActor
        fileprivate func install(apply: (ProviderSettingsState) -> Void) throws {
            try source.install(
                generation: generation,
                baseline: InstalledPublicationBaseline(
                    state: candidate,
                    miniMax: miniMaxBaseline
                )
            ) {
                apply(candidate)
            }
        }
    }

    fileprivate struct MiniMaxPublicationBaseline: Sendable {
        let snapshot: AccountCatalogSnapshot?
        let voicesByRevision: [UUID: [VoiceID: MiniMaxVoiceDescriptor]]
        let publishedRevision: UUID?

        static let empty = MiniMaxPublicationBaseline(
            snapshot: nil,
            voicesByRevision: [:],
            publishedRevision: nil
        )
    }

    fileprivate struct InstalledPublicationBaseline: Sendable {
        let state: ProviderSettingsState?
        let miniMax: MiniMaxPublicationBaseline
    }

    private nonisolated let publicationGeneration = ProviderSettingsPublicationGeneration()
    private let afterPublish: @Sendable () async -> Void

    init(afterPublish: @escaping @Sendable () async -> Void = {}) {
        self.afterPublish = afterPublish
    }

    func snapshot(for providerID: ProviderID) -> AccountCatalogSnapshot {
        guard providerID == .minimax else { return .empty }
        return publicationGeneration.installedBaseline().miniMax.snapshot ?? .empty
    }

    nonisolated func beginPublication() -> PublicationToken {
        PublicationToken(
            generation: publicationGeneration.advance(),
            source: publicationGeneration
        )
    }

    nonisolated func isCurrent(_ token: PublicationToken) -> Bool {
        token.source === publicationGeneration && token.isCurrent
    }

    func publish(
        _ candidate: ProviderSettingsState,
        miniMaxRefresh: ProviderCatalogRefresh?,
        using token: PublicationToken
    ) async throws -> PublicationReceipt {
        try validateCurrent(token)
        var miniMaxBaseline = publicationGeneration.installedBaseline().miniMax
        if let refresh = miniMaxRefresh, let revision = refresh.publicationRevision {
            var voicesByRevision = miniMaxBaseline.voicesByRevision
            voicesByRevision[revision] = Dictionary(
                uniqueKeysWithValues: refresh.voices.map { ($0.stableID, $0) }
            )
            miniMaxBaseline = MiniMaxPublicationBaseline(
                snapshot: refresh.snapshot,
                voicesByRevision: voicesByRevision,
                publishedRevision: revision
            )
            await afterPublish()
            try validateCurrent(token)
        }
        return PublicationReceipt(
            candidate: candidate,
            generation: token.generation,
            miniMaxBaseline: miniMaxBaseline,
            source: publicationGeneration
        )
    }

    func miniMaxVoiceDescriptors(revision: UUID) -> [MiniMaxVoiceDescriptor]? {
        publicationGeneration.installedBaseline().miniMax.voicesByRevision[revision]?
            .values.sorted(by: Self.precedes)
    }

    func miniMaxCurrentCatalogContains(_ stableID: VoiceID) -> Bool {
        let baseline = publicationGeneration.installedBaseline().miniMax
        guard let publishedRevision = baseline.publishedRevision else { return false }
        return baseline.voicesByRevision[publishedRevision]?[stableID] != nil
    }

    func miniMaxVoiceDescriptor(
        _ stableID: VoiceID, revision: UUID
    ) -> MiniMaxVoiceDescriptor? {
        publicationGeneration.installedBaseline().miniMax.voicesByRevision[revision]?[stableID]
    }

    private nonisolated func validateCurrent(_ token: PublicationToken) throws {
        try token.validateCurrent()
        guard token.source === publicationGeneration else { throw CancellationError() }
    }

    private static func precedes(
        _ lhs: MiniMaxVoiceDescriptor, _ rhs: MiniMaxVoiceDescriptor
    ) -> Bool {
        let priorities: [MiniMaxVoiceKind: Int] = [.system: 0, .cloned: 1, .generated: 2]
        let lhsKey = (priorities[lhs.kind]!, lhs.wireID, lhs.stableID.rawValue)
        let rhsKey = (priorities[rhs.kind]!, rhs.wireID, rhs.stableID.rawValue)
        return lhsKey < rhsKey
    }
}

fileprivate final class ProviderSettingsPublicationGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0
    private var installed = ProviderAccountEvidenceStore.InstalledPublicationBaseline(
        state: nil,
        miniMax: .empty
    )

    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        current &+= 1
        return current
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == candidate
    }

    @MainActor
    func install(
        generation: UInt64,
        baseline: ProviderAccountEvidenceStore.InstalledPublicationBaseline,
        apply: () -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        installed = baseline
        apply()
    }

    func installedBaseline() -> ProviderAccountEvidenceStore.InstalledPublicationBaseline {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }
}

enum ProviderSettingsAction: Equatable, Sendable {
    case setDefault(ProviderID), restart, synthesisStarted(ProviderID), synthesisSucceeded(ProviderID)
    case synthesisFailed(ProviderID, ProviderHealth), credentialDeleted(ProviderID), recoveryModeChanged(Bool)
}

enum ProviderSettingsReducer {
    static func reduce(_ state: ProviderSettingsState, _ action: ProviderSettingsAction) -> ProviderSettingsState {
        var next = state
        func mutate(_ id: ProviderID, _ body: (inout ProviderCardState) -> Void) {
            guard let index = next.cards.firstIndex(where: { $0.id == id }) else { return }
            body(&next.cards[index])
        }
        switch action {
        case .setDefault(let id):
            guard let target = next.cards.first(where: { $0.id == id }), ProviderSettingsPersistenceGate.canSetDefault(target) else { return state }
            for index in next.cards.indices { next.cards[index].isDefault = next.cards[index].id == id }
        case .restart:
            for index in next.cards.indices { next.cards[index].health = .unknown }
        case .synthesisStarted(let id): mutate(id) { $0.health = .verifying }
        case .synthesisSucceeded(let id): mutate(id) { $0.health = .recentSuccess }
        case .synthesisFailed(let id, let health): mutate(id) { $0.health = health }
        case .credentialDeleted(let id): mutate(id) { card in card.configuration = .unconfigured; card.health = .unknown; card.actions.insert(.configure) }
        case .recoveryModeChanged(let enabled):
            next.recoveryMode = enabled
            next.recoveryMessage = enabled ? "恢复模式：当前更改只在内存中生效，不会持久化。请修复、重新导入或备份并重置。" : ""
            for index in next.cards.indices {
                next.cards[index].persistenceActionsEnabled = !enabled
                if enabled { next.cards[index].actions.formUnion([.repair, .backupAndReset]) }
            }
        }
        return next
    }
}

struct RenderedProviderCard: Equatable, Sendable { let id: ProviderID; let controls: Set<ProviderCardControl>; let status: String }
struct RenderedProviderSettings: Equatable, Sendable { let cards: [RenderedProviderCard] }
enum ProviderCardRenderer {
    static func render(_ state: ProviderSettingsState) -> RenderedProviderSettings {
        RenderedProviderSettings(cards: state.cards.map { card in
            var controls: Set<ProviderCardControl> = [.preview, .model, .voice, .rate]
            if card.authRoutes.contains(.onePasswordImport) { controls.insert(.onePasswordImport) }
            if card.authRoutes.contains(.manualAPIKey) { controls.insert(.secureField) }
            return RenderedProviderCard(id: card.id, controls: controls, status: card.statusText)
        })
    }
}

struct ProviderSettingsView<DetailFooter: View>: View {
    let state: ProviderSettingsState
    let presentation: ProviderSettingsPresentation
    let exporting: Bool
    @Binding var selectedProviderID: ProviderID
    @ObservedObject var drafts: CredentialDraftState
    let actions: ProviderSettingsViewActions
    let voiceSampleState: VoiceSamplePlaybackState
    let beginCredentialAction: (ProviderID, ProviderCredentialOperation) -> Void
    private let detailFooter: DetailFooter

    init(
        state: ProviderSettingsState,
        presentation: ProviderSettingsPresentation,
        exporting: Bool,
        selectedProviderID: Binding<ProviderID>,
        drafts: CredentialDraftState,
        actions: ProviderSettingsViewActions,
        voiceSampleState: VoiceSamplePlaybackState = .idle,
        beginCredentialAction: @escaping (ProviderID, ProviderCredentialOperation) -> Void,
        @ViewBuilder detailFooter: () -> DetailFooter
    ) {
        self.state = state
        self.presentation = presentation
        self.exporting = exporting
        _selectedProviderID = selectedProviderID
        self.drafts = drafts
        self.actions = actions
        self.voiceSampleState = voiceSampleState
        self.beginCredentialAction = beginCredentialAction
        self.detailFooter = detailFooter()
    }

    var body: some View {
        HStack(spacing: 0) {
            ProviderSidebar(items: presentation.sidebar, selectedProviderID: $selectedProviderID).frame(width: 132)
            Divider()
            Group {
                if exporting {
                    detail
                } else {
                    ScrollView { detail.settingsOverlayScroller() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .top)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.recoveryMode { Text(state.recoveryMessage).font(.caption).foregroundStyle(.orange) }
            ProviderDetail(card: state.card(selectedProviderID), presentation: presentation.detail, exporting: exporting, drafts: drafts, actions: actions, voiceSampleState: voiceSampleState, beginCredentialAction: beginCredentialAction)
            detailFooter
        }.padding(18)
    }
}

private struct ProviderSidebar: View {
    let items: [ProviderSidebarPresentation]
    @Binding var selectedProviderID: ProviderID
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                Button { selectedProviderID = item.id } label: {
                    HStack(spacing: 6) {
                        Circle().fill(item.isEnabled ? .green : .orange).frame(width: 6, height: 6)
                        Text(item.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        if item.isDefault { Text("默认").font(.caption2) }
                    }.padding(.horizontal, 8).padding(.vertical, 8)
                }.buttonStyle(.plain).background(selectedProviderID == item.id ? Color.primary.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
        }.padding(8)
    }
}

struct ProviderDetail: View {
    let card: ProviderCardState
    let presentation: ProviderDetailPresentation
    let exporting: Bool
    @ObservedObject var drafts: CredentialDraftState
    let actions: ProviderSettingsViewActions
    let voiceSampleState: VoiceSamplePlaybackState
    let beginCredentialAction: (ProviderID, ProviderCredentialOperation) -> Void
    @Environment(\.lang) private var lang
    @State private var advancedVoiceSettingsExpanded = false

    private var providerWorking: Bool {
        if case .working = drafts.status[card.id] { return true }
        return false
    }

    private var credentialStatus: ProviderCredentialUIStatus {
        drafts.status[card.id] ?? (card.configuration == .configured ? .configured : .missing)
    }

    private var credentialPrompt: String {
        credentialStatus == .configured && drafts.draft(for: card.id).isEmpty
            ? "已保存的 API Key（安全隐藏）"
            : "API Key"
    }

    private var previewCredentialFieldText: String {
        switch credentialStatus {
        case .configured: return "API Key 已安全保存在系统钥匙串"
        case .working: return presentation.credentialMessage
        case .missing, .blocked, .saveFailed: return "请输入 API Key 后保存"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(presentation.title).font(.headline); Spacer(); Text(presentation.status).foregroundStyle(.secondary) }
            if !card.isDefault { Button("设为默认") { actions.setDefault(card.id) }.disabled(!ProviderSettingsPersistenceGate.canSetDefault(card)) }
            if let selection = card.selection {
                Picker("模型", selection: Binding(get: { selection.modelID }, set: { actions.updateSelection(replacing(selection, modelID: $0)) })) {
                    ForEach(presentation.models) { Text($0.title).tag($0.id) }
                }
                .disabled(providerWorking || !ProviderSettingsPersistenceGate.canMutateSelection(card))
                if !presentation.voices.isEmpty {
                    ProviderVoicePicker(
                        voices: presentation.voices,
                        providerID: card.id,
                        selection: Binding(
                            get: { selection.voiceID ?? presentation.voices[0].id },
                            set: { actions.updateSelection(replacing(selection, voiceID: $0)) }
                        ),
                        sampleState: voiceSampleState,
                        toggleSample: actions.toggleVoiceSample
                    )
                    .disabled(providerWorking || !ProviderSettingsPersistenceGate.canMutateSelection(card))
                }
                DisclosureGroup(T.advancedVoiceSettings(lang), isExpanded: $advancedVoiceSettingsExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        if exporting {
                            Text("\(T.synthRate(lang))：\(selection.rate.value)")
                        } else {
                            Stepper("\(T.synthRate(lang))：\(selection.rate.value)", value: Binding(get: { selection.rate.value }, set: { value in
                                guard let rate = NormalizedRate(version: selection.rate.version, value: value) else { return }
                                actions.updateSelection(replacing(selection, rate: rate))
                            }), in: -100...100)
                            .disabled(providerWorking || !ProviderSettingsPersistenceGate.canMutateSelection(card))
                        }
                        Text(T.synthRateNextReadNote(lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            if card.authRoutes.contains(.manualAPIKey) {
                HStack {
                    if exporting {
                        Text(previewCredentialFieldText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.06)))
                    } else {
                        SecureField(credentialPrompt, text: Binding(get: { drafts.draft(for: card.id) }, set: { drafts.setDraft($0, for: card.id) })).textFieldStyle(.roundedBorder).disabled(providerWorking)
                    }
                    Button("保存") { beginCredentialAction(card.id, .manualSave) }
                        .disabled(providerWorking || card.synthesisBlockedReason != nil || !card.persistenceActionsEnabled || drafts.draft(for: card.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !exporting {
                    Text(drafts.recentSuccessSource[card.id]?.message(lang) ?? "API Key 将安全保存在系统钥匙串")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if card.authRoutes.contains(.onePasswordImport) {
                    Button(card.configuration == .configured ? "从 1Password 更新" : "从 1Password 导入") { beginCredentialAction(card.id, .onePasswordImport) }
                        .disabled(providerWorking || card.synthesisBlockedReason != nil)
                }
                Button("试听") { actions.preview(card.id) }.disabled(providerWorking || !ProviderSettingsPersistenceGate.canSynthesize(card))
                if card.actions.contains(.confirmDisclosure) { Button("确认 AI 语音披露并试听") { actions.confirmDisclosureAndPreview() }.disabled(providerWorking || card.synthesisBlockedReason != nil) }
            }
            if let disclosure = card.disclosure { Text(disclosure).font(.caption) }
            if let billing = card.billingNotice { Text(billing).font(.caption) }
            if let notice = card.previewBillingNotice { Text(notice).font(.caption) }
            DisclosureGroup("技术详情") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.technicalDetails)
                    Text("目录来源：\(card.catalogSource)\(card.catalogFetchedAt.map { " · \($0.formatted())" } ?? "")")
                    ForEach(AccountCatalogPresentationDimension.allCases, id: \.self) { dimension in
                        if let account = card.accountCatalogPresentation[dimension] {
                            Text("账户目录 \(dimension.rawValue)：\(account.authoritySource ?? "未知") · \(account.coverage.rawValue) · \(account.contractVersion.rawValue)\(account.fetchedAt.map { " · \($0.formatted())" } ?? "")")
                        }
                    }
                }.font(.caption2).textSelection(.enabled)
            }
        }
    }
    private func replacing(_ selection: ProviderSelection, modelID: ModelID? = nil, voiceID: VoiceID? = nil, rate: NormalizedRate? = nil) -> ProviderSelection {
        ProviderSelection(providerID: selection.providerID, modelID: modelID ?? selection.modelID, voiceID: voiceID ?? selection.voiceID, rate: rate ?? selection.rate)
    }
}

struct ProviderVoicePicker: View {
    let voices: [ProviderVoiceOption]
    let providerID: ProviderID
    @Binding var selection: VoiceID
    let sampleState: VoiceSamplePlaybackState
    let toggleSample: (ProviderID, VoiceID) -> Void
    var showsFieldLabel = true
    var maximumWidth: CGFloat = 280
    @State private var isPresented = false
    @State private var query = ""

    static func accessibilityLabel(voices: [ProviderVoiceOption], selection: VoiceID) -> String {
        let title = voices.first(where: { $0.id == selection })?.title ?? "选择音色"
        return "音色，\(title)"
    }

    private var selectedTitle: String {
        voices.first(where: { $0.id == selection })?.title ?? "选择音色"
    }

    var body: some View {
        HStack {
            if showsFieldLabel {
                Text("音色")
                Spacer()
            }
            Button {
                query = ""
                isPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text(selectedTitle).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: maximumWidth, alignment: .trailing)
            }
            .accessibilityLabel(Self.accessibilityLabel(voices: voices, selection: selection))
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ProviderVoicePickerPopover(
                    voices: voices,
                    providerID: providerID,
                    selection: $selection,
                    query: $query,
                    isPresented: $isPresented,
                    sampleState: sampleState,
                    toggleSample: toggleSample
                )
            }
        }
    }
}

struct ProviderVoicePickerPopover: View {
    let voices: [ProviderVoiceOption]
    let providerID: ProviderID
    @Binding var selection: VoiceID
    @Binding var query: String
    @Binding var isPresented: Bool
    let sampleState: VoiceSamplePlaybackState
    let toggleSample: (ProviderID, VoiceID) -> Void

    private var sections: [ProviderVoiceSection] {
        ProviderVoicePickerCatalog.sections(voices: voices, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索音色", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(section.options) { option in
                            HStack(spacing: 8) {
                                Button {
                                    selection = option.id
                                    isPresented = false
                                } label: {
                                    Text(option.title)
                                        .lineLimit(1)
                                    Spacer()
                                    if option.id == selection {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                Button {
                                    toggleSample(providerID, option.id)
                                } label: {
                                    Image(systemName: sampleIcon(for: option.id))
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.borderless)
                                .help("试听 \(option.title)")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if sections.isEmpty {
                        Text("没有匹配的音色")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 360, height: 390)
    }

    private func sampleIcon(for voiceID: VoiceID) -> String {
        guard let active = sampleState.activeIdentity,
              active.providerID == providerID, active.stableVoiceID == voiceID else { return "play.circle" }
        switch sampleState {
        case .generating: return "hourglass.circle"
        case .playing: return "stop.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .idle: return "play.circle"
        }
    }
}

struct ProviderSettingsViewActions: @unchecked Sendable {
    let setDefault: (ProviderID) -> Void
    let preview: (ProviderID) -> Void
    let updateSelection: (ProviderSelection) -> Void
    let toggleVoiceSample: (ProviderID, VoiceID) -> Void
    let confirmDisclosureAndPreview: () -> Void
    static let none = ProviderSettingsViewActions(setDefault: { _ in }, preview: { _ in }, updateSelection: { _ in }, toggleVoiceSample: { _, _ in }, confirmDisclosureAndPreview: {})
}

struct PreviewPhraseCatalog: Sendable {
    let phrases: [String: String]
    static let builtIn = PreviewPhraseCatalog(phrases: ["zh-CN": "这是语音试听。", "en-US": "This is a voice preview."])
    func phrase(id: String) -> String? { phrases[id] }
}

enum PreviewCachePolicy: Equatable, Sendable { case bypass }
enum PreviewMutationPolicy: Equatable, Sendable { case forbidden }
struct PreviewIsolationPolicy: Equatable, Sendable { let cache: PreviewCachePolicy; let history: PreviewMutationPolicy; let lastAudio: PreviewMutationPolicy }
enum ProviderPreviewError: Error, Equatable, Sendable { case unknownPhrase, invalidPurpose, insufficientPlaybackEvidence, cancelled, failed }

enum PreviewExecutionCapability: Hashable, Sendable { case nativeSynthesis, verifiedPlayback }

struct PreviewExecutionDependencies: Sendable {
    typealias Synthesize = @Sendable (String, PreviewIsolationPolicy) async throws -> OwnedNativeAudioArtifact
    typealias StartPlayback = @MainActor @Sendable (NativeAudioArtifact) throws -> Void
    typealias VerifyPlayback = @Sendable () async throws -> PlaybackEvidence
    static let capabilities: Set<PreviewExecutionCapability> = [.nativeSynthesis, .verifiedPlayback]
    let synthesize: Synthesize
    let startPlayback: StartPlayback
    let verifyPlayback: VerifyPlayback
}

struct ProviderPreviewTransaction: Sendable {
    let phraseCatalog: PreviewPhraseCatalog
    let execution: PreviewExecutionDependencies

    init(
        phraseCatalog: PreviewPhraseCatalog,
        synthesize: @escaping PreviewExecutionDependencies.Synthesize,
        startPlayback: @escaping PreviewExecutionDependencies.StartPlayback,
        verifyPlayback: @escaping PreviewExecutionDependencies.VerifyPlayback
    ) {
        self.phraseCatalog = phraseCatalog
        self.execution = PreviewExecutionDependencies(synthesize: synthesize, startPlayback: startPlayback, verifyPlayback: verifyPlayback)
    }

    func run(token: SessionCurrentToken, providerID: ProviderID, phraseID: String, editorText: String, historyText: String) async throws -> PlaybackEvidence {
        guard let phrase = phraseCatalog.phrase(id: phraseID), phrase != editorText, phrase != historyText else { throw ProviderPreviewError.unknownPhrase }
        try await token.requireCurrent()
        let owned = try await execution.synthesize(phrase, PreviewIsolationPolicy(cache: .bypass, history: .forbidden, lastAudio: .forbidden))
        defer { owned.cleanupIfOwned() }
        try await token.requireCurrent()
        guard owned.purpose == .preview else { throw ProviderPreviewError.invalidPurpose }
        try await token.performCurrent { try execution.startPlayback(owned.artifact) }
        let evidence = try await execution.verifyPlayback()
        try await token.requireCurrent()
        guard evidence.firstTimePosition.isFinite, evidence.secondTimePosition > evidence.firstTimePosition else { throw ProviderPreviewError.insufficientPlaybackEvidence }
        return evidence
    }

    func runWithoutSessionForTesting(providerID: ProviderID, phraseID: String, editorText: String, historyText: String) async throws -> PlaybackEvidence {
        guard let phrase = phraseCatalog.phrase(id: phraseID), phrase != editorText, phrase != historyText else { throw ProviderPreviewError.unknownPhrase }
        let owned = try await execution.synthesize(phrase, PreviewIsolationPolicy(cache: .bypass, history: .forbidden, lastAudio: .forbidden))
        defer { owned.cleanupIfOwned() }
        guard owned.purpose == .preview else { throw ProviderPreviewError.invalidPurpose }
        try await MainActor.run { try execution.startPlayback(owned.artifact) }
        let evidence = try await execution.verifyPlayback()
        guard evidence.firstTimePosition.isFinite, evidence.secondTimePosition > evidence.firstTimePosition else { throw ProviderPreviewError.insufficientPlaybackEvidence }
        return evidence
    }
}

private final class PreviewPlayerCleanupLease: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var cleaned = false
    private let cleanup: @Sendable () async -> Void
    init(cleanup: @escaping @Sendable () async -> Void) { self.cleanup = cleanup }
    func arm() { lock.withLock { armed = true } }
    func cleanupOnce(requireArmed: Bool) async {
        let shouldCleanup = lock.withLock {
            guard (!requireArmed || armed), !cleaned else { return false }
            cleaned = true
            return true
        }
        if shouldCleanup { await cleanup() }
    }
}

struct ProviderPreviewCoordinator: Sendable {
    typealias Completion = @MainActor @Sendable (Result<PlaybackEvidence, ProviderPreviewError>) -> Void
    let coordinator: SpeechCoordinator
    let transaction: ProviderPreviewTransaction
    let stopAndDrainPlayer: @Sendable () async -> Void

    init(coordinator: SpeechCoordinator, transaction: ProviderPreviewTransaction, stopAndDrainPlayer: @escaping @Sendable () async -> Void = {}) {
        self.coordinator = coordinator
        self.transaction = transaction
        self.stopAndDrainPlayer = stopAndDrainPlayer
    }

    func start(providerID: ProviderID, phraseID: String, completion: @escaping Completion) async -> SpeechSession? {
        let lease = PreviewPlayerCleanupLease(cleanup: stopAndDrainPlayer)
        return await coordinator.start(
            .preview(providerID: providerID, phraseID: phraseID),
            stopPlayer: { _ in await lease.cleanupOnce(requireArmed: false) },
            work: { token in
                do {
                    let gatedTransaction = ProviderPreviewTransaction(
                        phraseCatalog: transaction.phraseCatalog,
                        synthesize: transaction.execution.synthesize,
                        startPlayback: { artifact in
                            lease.arm()
                            try transaction.execution.startPlayback(artifact)
                        },
                        verifyPlayback: transaction.execution.verifyPlayback
                    )
                    let evidence = try await gatedTransaction.run(token: token, providerID: providerID, phraseID: phraseID, editorText: "", historyText: "")
                    try await token.performCurrent { completion(.success(evidence)) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ProviderPreviewError {
                    await lease.cleanupOnce(requireArmed: true)
                    try await token.performCurrent { completion(.failure(error)) }
                    throw error
                } catch {
                    await lease.cleanupOnce(requireArmed: true)
                    try await token.performCurrent { completion(.failure(.failed)) }
                    throw error
                }
            }
        )
    }
}

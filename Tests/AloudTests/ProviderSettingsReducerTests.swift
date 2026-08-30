import XCTest
@testable import Aloud

final class ProviderSettingsReducerTests: XCTestCase {
    func testFourCardsAreOrderedAndExposeExactAuthBillingDisclosureActions() throws {
        let state = try ProviderSettingsState.fixture()
        XCTAssertEqual(state.cards.map(\.id), [.minimax, .openAI, .gemini, .macOS])
        XCTAssertEqual(state.cards[0].authRoutes, [.onePasswordImport, .manualAPIKey])
        XCTAssertEqual(state.cards[1].authRoutes, [.manualAPIKey])
        XCTAssertEqual(state.cards[2].authRoutes, [.manualAPIKey])
        XCTAssertEqual(state.cards[3].authRoutes, [])
        XCTAssertEqual(state.cards[3].saveCapability, .notApplicable)
        XCTAssertEqual(state.cards[1].disclosure, "AI 生成语音")
        XCTAssertEqual(state.cards[2].billingNotice, "费用计入 API Key 关联的 Google Cloud 项目，不是 Gemini 网页订阅。")
        for card in state.cards.prefix(3) { XCTAssertEqual(card.previewBillingNotice, "将请求一次短句合成，可能产生少量可计费用量") }
        XCTAssertFalse(state.cards[2].actions.contains(.login))
        XCTAssertFalse(state.cards[2].actions.contains(.logout))
    }

    func testDefaultRestartHealthRecoveryCatalogAndSelectionStatesReduceDeterministically() throws {
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        state = ProviderSettingsReducer.reduce(state, .setDefault(.openAI))
        XCTAssertTrue(state.card(.openAI).isDefault)
        XCTAssertFalse(state.card(.minimax).isDefault)
        state = ProviderSettingsReducer.reduce(state, .restart)
        XCTAssertEqual(state.card(.openAI).configuration, .configured)
        XCTAssertEqual(state.card(.openAI).health, .unknown)
        state = ProviderSettingsReducer.reduce(state, .synthesisStarted(.openAI))
        XCTAssertEqual(state.card(.openAI).health, .verifying)
        state = ProviderSettingsReducer.reduce(state, .synthesisSucceeded(.openAI))
        XCTAssertEqual(state.card(.openAI).health, .recentSuccess)
        state = ProviderSettingsReducer.reduce(state, .synthesisFailed(.openAI, .recoverableFailure))
        XCTAssertEqual(state.card(.openAI).health, .recoverableFailure)
        state = ProviderSettingsReducer.reduce(state, .credentialDeleted(.openAI))
        XCTAssertTrue(state.card(.openAI).isDefault)
        XCTAssertEqual(state.card(.openAI).statusText, "默认 · 未配置")
        XCTAssertTrue(state.card(.openAI).actions.contains(.configure))
        state = ProviderSettingsReducer.reduce(state, .recoveryModeChanged(true))
        XCTAssertTrue(state.recoveryMessage.contains("不会持久化"))
        XCTAssertFalse(state.card(.openAI).persistenceActionsEnabled)
        XCTAssertTrue(state.card(.openAI).actions.contains(.backupAndReset))
        XCTAssertEqual(state.card(.openAI).accountCoverage[.voice], .authoritativeComplete)
        XCTAssertEqual(state.card(.openAI).catalogSource, "https://developers.openai.com/api/docs/guides/text-to-speech")
        XCTAssertNotNil(state.card(.openAI).catalogFetchedAt)
        XCTAssertNotNil(state.card(.openAI).selection)
        XCTAssertEqual(state.card(.gemini).synthesisBlockedReason, .experimentalFeatureDisabled)
    }

    func testProductionBuilderUsesPersistedDefaultSelectionsAndRecoveryMode() throws {
        var prefs = PrefsV1.defaults
        prefs.defaultProviderID = .openAI
        prefs.selections[.openAI] = ProviderSelection(
            providerID: .openAI,
            modelID: ModelID(rawValue: "tts-1"),
            voiceID: VoiceID(rawValue: "openai.alloy"),
            rate: NormalizedRate(version: "openai-rate-v1", value: 25)!
        )
        let state = try ProviderSettingsState.build(
            prefs: prefs,
            credentialConfigurations: [.minimax: .unconfigured, .openAI: .configured, .gemini: .unconfigured, .macOS: .configured],
            health: [.openAI: .recentSuccess],
            recoveryMode: true
        )
        XCTAssertTrue(state.card(.openAI).isDefault)
        XCTAssertEqual(state.card(.openAI).selection, prefs.selections[.openAI])
        XCTAssertEqual(state.card(.openAI).health, .recentSuccess)
        XCTAssertEqual(state.card(.minimax).configuration, .unconfigured)
        XCTAssertTrue(state.recoveryMode)
        XCTAssertFalse(state.card(.openAI).persistenceActionsEnabled)
    }

    func testUnavailableKindsAllBlockSynthesis() throws {
        for kind in [ProviderAvailabilityKind.disabled, .deprecated, .unknown] {
            var state = try ProviderSettingsState.fixture()
            let card = state.card(.openAI)
            let replacement = ProviderAvailability(
                kind: kind, reason: .evidenceMissing, maturity: .stable,
                featureFlagName: nil, featureFlagEnabled: nil,
                providerContractVersion: card.availability.providerContractVersion,
                evidenceID: nil
            )
            let index = state.cards.firstIndex { $0.id == .openAI }!
            state.cards[index].availability = replacement
            XCTAssertNotNil(state.card(.openAI).synthesisBlockedReason)
            let unchanged = ProviderSettingsReducer.reduce(state, .setDefault(.openAI))
            XCTAssertFalse(unchanged.card(.openAI).isDefault)
            XCTAssertFalse(ProviderSettingsPersistenceGate.canMutateSelection(unchanged.card(.openAI)))
        }
    }

    func testOnlyConfiguredValidCardCanBecomeANewDefaultWhileDeletedCurrentMarkerIsPreserved() throws {
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        let openAI = state.cards.firstIndex { $0.id == .openAI }!
        state.cards[openAI].configuration = .unconfigured
        XCTAssertFalse(ProviderSettingsPersistenceGate.canSetDefault(state.cards[openAI]))
        XCTAssertTrue(ProviderSettingsReducer.reduce(state, .setDefault(.openAI)).card(.minimax).isDefault)

        let miniMax = state.cards.firstIndex { $0.id == .minimax }!
        state.cards[miniMax].configuration = .unconfigured
        XCTAssertTrue(state.cards[miniMax].isDefault)
        XCTAssertEqual(state.cards[miniMax].statusText, "默认 · 未配置")

        state.cards[openAI].configuration = .invalidSelection
        XCTAssertFalse(ProviderSettingsPersistenceGate.canSetDefault(state.cards[openAI]))
    }

    func testRuntimeLoaderReadsEveryCloudCredentialAndAccountEvidence() async throws {
        var prefs = PrefsV1.defaults
        prefs.defaultProviderID = .openAI
        let revisions: [ProviderID: UUID] = [.minimax: UUID(), .openAI: UUID(), .gemini: UUID()]
        let credentialReads = LockedProviderIDs()
        let account = AccountCatalogSnapshot.empty
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                credentialReads.append(providerID)
                if providerID == .openAI {
                    return .available(.init(providerID: providerID, revision: revisions[providerID]!, secret: Data("fake".utf8)))
                }
                return .missing
            },
            accountSnapshot: { providerID in
                XCTAssertTrue([ProviderID.minimax, .openAI, .gemini, .macOS].contains(providerID))
                return account
            }
        )
        let state = try await loader.load(
            prefs: prefs,
            recoveryMode: false,
            health: [.minimax: .recentSuccess, .openAI: .explicitRejected, .gemini: .recoverableFailure],
            resetHealthFor: [.openAI]
        )
        XCTAssertEqual(Set(credentialReads.values()), [.minimax, .openAI, .gemini])
        XCTAssertEqual(state.card(.openAI).configuration, .configured)
        XCTAssertEqual(state.card(.minimax).health, .recentSuccess)
        XCTAssertEqual(state.card(.openAI).health, .unknown)
        XCTAssertEqual(state.card(.gemini).health, .recoverableFailure)
        XCTAssertEqual(state.card(.minimax).configuration, .unconfigured)
        XCTAssertEqual(state.card(.gemini).configuration, .unconfigured)
        XCTAssertEqual(state.card(.macOS).configuration, .configured)
        XCTAssertTrue(state.card(.openAI).isDefault)
    }

    func testRuntimeLoaderMarksContractDeprecatedAndCurrentAuthoritativeAccountInvalidSelectionsOnly() async throws {
        let revision = UUID()
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                .available(CredentialEnvelope(providerID: providerID, revision: revision, secret: Data("fake".utf8)))
            },
            accountSnapshot: { providerID in
                guard providerID == .minimax else { return .empty }
                return try! AccountSettingsFixture.authoritativeInvalidSnapshot(providerID: providerID, revision: revision)
            }
        )
        var deprecated = PrefsV1.defaults
        deprecated.selections[.openAI] = ProviderSelection(
            providerID: .openAI, modelID: ModelID(rawValue: "gpt-4o-mini-tts"),
            voiceID: VoiceID(rawValue: "openai.alloy"), rate: NormalizedRate(version: "openai-rate-v1", value: 0)!
        )
        let contractInvalid = try await loader.load(prefs: deprecated, recoveryMode: false)
        XCTAssertEqual(contractInvalid.card(.openAI).configuration, .invalidSelection)
        XCTAssertFalse(ProviderSettingsPersistenceGate.canSetDefault(contractInvalid.card(.openAI)))

        var accountPrefs = PrefsV1.defaults
        accountPrefs.selections[.minimax] = ProviderSelection(
            providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"),
            voiceID: VoiceID(rawValue: "account.clone.missing"), rate: NormalizedRate(version: MiniMaxRateMappingV1.version, value: 0)!
        )
        let accountInvalid = try await loader.load(prefs: accountPrefs, recoveryMode: false)
        XCTAssertEqual(accountInvalid.card(.minimax).configuration, .invalidSelection)
        XCTAssertFalse(ProviderSettingsPersistenceGate.canSynthesize(accountInvalid.card(.minimax)))
        let relationship = try XCTUnwrap(accountInvalid.card(.minimax).accountCatalogPresentation[.relationship])
        XCTAssertEqual(relationship.authoritySource, "fake-account-directory")
        XCTAssertEqual(relationship.coverage, .authoritativeComplete)
        XCTAssertNotNil(relationship.fetchedAt)
        XCTAssertNotEqual(relationship.authoritySource, accountInvalid.card(.minimax).catalogSource)

        let unknownLoader = ProviderSettingsRuntimeLoader(
            readCredential: loader.readCredential,
            accountSnapshot: { _ in .empty }
        )
        let unknown = try await unknownLoader.load(prefs: accountPrefs, recoveryMode: false)
        XCTAssertEqual(unknown.card(.minimax).configuration, .configured)
    }

    func testAccountCatalogPresentationKeepsEachDimensionEvidenceTuplePaired() async throws {
        let revision = UUID()
        let scope = try RelationshipScope(
            providerID: .openAI, credentialRevision: revision,
            contractVersion: ContractVersion(rawValue: "provider-contracts-v1"),
            parentModelID: ModelID(rawValue: "tts-1"), controlsSchema: "openai-controls-v1",
            queryParameters: ["model": "tts-1"]
        )
        let modelDate = Date(timeIntervalSince1970: 10)
        let voiceDate = Date(timeIntervalSince1970: 20)
        let controlsDate = Date(timeIntervalSince1970: 30)
        let modelContract = ContractVersion(rawValue: "account-model-v1")
        let voiceContract = ContractVersion(rawValue: "account-voice-v2")
        let controlsContract = ContractVersion(rawValue: "account-controls-v3")
        let snapshot = AccountCatalogSnapshot(
            modelEvidence: [scope: [
                AccountResourceKey(dimension: .model, parentModelID: nil): AccountResourceEvidence(
                    scopeRevision: revision, contractVersion: modelContract, fetchedAt: modelDate,
                    refreshID: CatalogRefreshID(rawValue: UUID()), authoritySource: "model-source",
                    coverage: .partial, values: [ModelID(rawValue: "tts-1")]
                )
            ]],
            voiceEvidence: [scope: [
                AccountResourceKey(dimension: .voice, parentModelID: ModelID(rawValue: "tts-1")): AccountResourceEvidence(
                    scopeRevision: revision, contractVersion: voiceContract, fetchedAt: voiceDate,
                    refreshID: CatalogRefreshID(rawValue: UUID()), authoritySource: "voice-source",
                    coverage: .authoritativeComplete, values: [VoiceID(rawValue: "openai.alloy")]
                )
            ]],
            controlsEvidence: [scope: [
                AccountResourceKey(dimension: .controls, parentModelID: ModelID(rawValue: "tts-1")): AccountResourceEvidence(
                    scopeRevision: revision, contractVersion: controlsContract, fetchedAt: controlsDate,
                    refreshID: CatalogRefreshID(rawValue: UUID()), authoritySource: "controls-source",
                    coverage: .unknown, values: [CatalogControlsID(rawValue: "openai-controls-v1")]
                )
            ]]
        )
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                .available(CredentialEnvelope(providerID: providerID, revision: revision, secret: Data("fake".utf8)))
            },
            accountSnapshot: { $0 == .openAI ? snapshot : .empty }
        )
        let state = try await loader.load(prefs: .defaults, recoveryMode: false)
        let presentation = state.card(.openAI).accountCatalogPresentation
        XCTAssertEqual(presentation[.model], AccountCatalogPresentation(authoritySource: "model-source", fetchedAt: modelDate, coverage: .partial, contractVersion: modelContract))
        XCTAssertEqual(presentation[.voice], AccountCatalogPresentation(authoritySource: "voice-source", fetchedAt: voiceDate, coverage: .authoritativeComplete, contractVersion: voiceContract))
        XCTAssertEqual(presentation[.controls], AccountCatalogPresentation(authoritySource: "controls-source", fetchedAt: controlsDate, coverage: .unknown, contractVersion: controlsContract))
    }
}

private enum AccountSettingsFixture {
    static func authoritativeInvalidSnapshot(providerID: ProviderID, revision: UUID) throws -> AccountCatalogSnapshot {
        let scope = try RelationshipScope(
            providerID: providerID, credentialRevision: revision,
            contractVersion: ContractVersion(rawValue: "provider-contracts-v1"),
            parentModelID: ModelID(rawValue: "speech-2.8-hd"), controlsSchema: "v1", queryParameters: [:]
        )
        let refresh = CatalogRefreshID(rawValue: UUID())
        let evidence = AccountRelationshipEvidence(
            scope: scope, scopeRevision: revision, contractVersion: scope.contractVersion,
            fetchedAt: Date(), refreshID: refresh, authoritySource: "fake-account-directory",
            coverage: .authoritativeComplete, paginationComplete: true, values: [], rejections: []
        )
        return AccountCatalogSnapshot(relationshipEvidence: [scope: evidence])
    }
}

private final class LockedProviderIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProviderID] = []
    func append(_ value: ProviderID) { lock.withLock { storage.append(value) } }
    func values() -> [ProviderID] { lock.withLock { storage } }
}

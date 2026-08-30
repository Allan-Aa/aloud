import XCTest
@testable import Aloud

@MainActor
final class ProviderSettingsEngineIntegrationTests: XCTestCase {
    func testColdStartRegistersPersistedHotkeysAfterInitialHydration() async throws {
        var initialPrefs = PrefsV1.defaults
        let persisted = HotkeySpec(keyCode: 17, modifiers: 6_912)
        initialPrefs.hkReadSelection = persisted
        let registrar = RecordingHotkeyRegistrar()
        let engine = try makePreviewEngine(
            provider: PreviewEngineProvider(), player: PreviewEnginePlayback(),
            initialPrefs: initialPrefs, hotkeys: registrar
        )

        await engine.installHotkeysAfterInitialHydration()

        XCTAssertEqual(registrar.installCount, 1)
        XCTAssertEqual(registrar.registrations.count, 1)
        XCTAssertEqual(registrar.registrations[0][.readSelection], persisted)
    }

    func testSettingsBodyLoadsAndInstallsSystemVoicesOnlyForLiveView() async throws {
        let recorder = SettingsSystemVoiceRecorder(voices: [
            SystemVoiceDescriptor(identifier: "voice.fixture", name: "Fixture", language: "en-US")
        ])
        let actions = settingsActions { voices in await recorder.install(voices) }
        let state = try settingsViewState()
        let systemVoices = ProviderSettingsSystemVoices(load: { await recorder.load() })
        let live = SettingsViewBody(
            state: state, exporting: false, credentialActions: .unavailable,
            systemVoices: systemVoices, actions: actions
        )
        let preview = SettingsViewBody(
            state: state, exporting: true, credentialActions: .unavailable,
            systemVoices: systemVoices, actions: actions
        )

        await live.loadLiveProviderDependencies()
        let liveSnapshot = await recorder.snapshot()
        XCTAssertEqual(liveSnapshot, .init(loads: 1, installs: 1))
        await preview.loadLiveProviderDependencies()
        let previewSnapshot = await recorder.snapshot()
        XCTAssertEqual(previewSnapshot, .init(loads: 1, installs: 1))
    }

    func testConcurrentInitialSystemVoiceInstallCommitsExactlyOneCandidate() async throws {
        let loader = ProviderSettingsRuntimeLoader(readCredential: { _ in .missing }, accountSnapshot: { _ in .empty })
        for _ in 0..<20 {
            let engine = try makePreviewEngine(
                provider: PreviewEngineProvider(), player: PreviewEnginePlayback(), loader: loader
            )
            await engine.waitForInitialHydration()
            async let first = engine.installInitialSystemVoiceSelectionIfNeeded(
                [SystemVoiceDescriptor(identifier: "voice.first", name: "First", language: "en-US")],
                preferredLanguages: ["en-US"]
            )
            async let second = engine.installInitialSystemVoiceSelectionIfNeeded(
                [SystemVoiceDescriptor(identifier: "voice.second", name: "Second", language: "en-US")],
                preferredLanguages: ["en-US"]
            )
            let results = await [first, second]
            let persisted = await engine.persistedProviderPrefsForTesting().selections[.macOS]

            XCTAssertEqual(results.filter { $0 }.count, 1)
            XCTAssertTrue(["macos.voice.first", "macos.voice.second"].contains(persisted?.voiceID?.rawValue))
        }
    }

    func testSystemVoiceSelectionPrefersExactLanguageThenBaseAndStableFallback() {
        let voices = [
            SystemVoiceDescriptor(identifier: "voice.zh.tw", name: "Mei", language: "zh-TW"),
            SystemVoiceDescriptor(identifier: "voice.en.gb", name: "Alex", language: "en-GB"),
            SystemVoiceDescriptor(identifier: "voice.en.us", name: "Sam", language: "en-US"),
        ]

        XCTAssertEqual(Engine.preferredInitialSystemVoice(from: voices, preferredLanguages: ["en-US"])?.identifier, "voice.en.us")
        XCTAssertEqual(Engine.preferredInitialSystemVoice(from: voices, preferredLanguages: ["zh-Hans-CN"])?.identifier, "voice.zh.tw")
        XCTAssertEqual(Engine.preferredInitialSystemVoice(from: voices, preferredLanguages: [])?.identifier, "voice.en.gb")
    }

    func testEngineInstallsFreshSystemVoiceSelectionWithoutOverwritingExistingSelection() async throws {
        let loader = ProviderSettingsRuntimeLoader(readCredential: { _ in .missing }, accountSnapshot: { _ in .empty })
        let freshEngine = try makePreviewEngine(
            provider: PreviewEngineProvider(), player: PreviewEnginePlayback(), loader: loader
        )
        await freshEngine.waitForInitialHydration()
        let voices = [
            SystemVoiceDescriptor(identifier: "voice.en.us", name: "Sam", language: "en-US"),
            SystemVoiceDescriptor(identifier: "voice.zh.cn", name: "Tingting", language: "zh-CN"),
        ]

        let initialSelection = await freshEngine.persistedProviderPrefsForTesting().selections[.macOS]
        XCTAssertNil(initialSelection)
        let didInstall = await freshEngine.installInitialSystemVoiceSelectionIfNeeded(voices, preferredLanguages: ["zh-CN"])
        XCTAssertTrue(didInstall)
        let installed = await freshEngine.persistedProviderPrefsForTesting().selections[.macOS]
        XCTAssertEqual(installed?.modelID, SystemVoiceContractV1.modelID)
        XCTAssertEqual(installed?.voiceID, VoiceID(rawValue: "macos.voice.zh.cn"))
        XCTAssertEqual(installed?.rate.version, SystemVoiceRateMappingV1.version)
        XCTAssertEqual(installed?.rate.value, 0)
        XCTAssertEqual(freshEngine.providerSettingsState.card(.macOS).selection, installed)

        var existingPrefs = PrefsV1.defaults
        let existing = ProviderSelection(
            providerID: .macOS, modelID: SystemVoiceContractV1.modelID,
            voiceID: VoiceID(rawValue: "macos.voice.existing"),
            rate: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: 0)!
        )
        existingPrefs.selections[.macOS] = existing
        let existingEngine = try makePreviewEngine(
            provider: PreviewEngineProvider(), player: PreviewEnginePlayback(), loader: loader, initialPrefs: existingPrefs
        )
        await existingEngine.waitForInitialHydration()

        let didOverwrite = await existingEngine.installInitialSystemVoiceSelectionIfNeeded(voices, preferredLanguages: ["zh-CN"])
        let persistedExisting = await existingEngine.persistedProviderPrefsForTesting().selections[.macOS]
        XCTAssertFalse(didOverwrite)
        XCTAssertEqual(persistedExisting, existing)
    }

    func testMiniMaxSettingsSelectionSynchronizesMainControls() async throws {
        let provider = try PreviewEngineProvider(id: .minimax)
        let dynamicVoice = VoiceID(rawValue: "minimax.dynamic.professional-host")
        let envelope = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("fixture".utf8))
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in providerID == .minimax ? .available(envelope) : .missing },
            accountSnapshot: { _ in .empty },
            refreshCatalog: { providerID, _, _ in
                guard providerID == .minimax else { return ProviderCatalogRefresh(snapshot: .empty, voices: []) }
                return ProviderCatalogRefresh(snapshot: .empty, voices: [
                MiniMaxVoiceDescriptor(
                    stableID: dynamicVoice,
                    wireID: "professional-host",
                    displayName: "Professional Female Host",
                    kind: .system
                )
                ])
            }
        )
        let engine = try makePreviewEngine(provider: provider, player: PreviewEnginePlayback(), loader: loader)
        await engine.waitForInitialHydration()
        let current = try XCTUnwrap(engine.providerSettingsState.card(.minimax).selection)
        let selection = ProviderSelection(
            providerID: .minimax,
            modelID: current.modelID,
            voiceID: dynamicVoice,
            rate: current.rate
        )

        let didUpdate = await engine.updateProviderSelectionAndWait(selection)
        XCTAssertTrue(didUpdate)

        XCTAssertEqual(engine.prefs.voice, "minimax:\(dynamicVoice.rawValue)")
        XCTAssertEqual(engine.currentVoiceDisplayLabel, "Professional Female Host")
    }

    func testMainVoiceControlUsesDynamicCatalogAndUpdatesProviderSelection() async throws {
        let provider = try PreviewEngineProvider(id: .minimax)
        let first = MiniMaxVoiceDescriptor(
            stableID: VoiceID(rawValue: "minimax.dynamic.first"),
            wireID: "first-wire",
            displayName: "First Voice",
            kind: .system
        )
        let second = MiniMaxVoiceDescriptor(
            stableID: VoiceID(rawValue: "minimax.dynamic.second"),
            wireID: "second-wire",
            displayName: "Second Voice",
            kind: .cloned
        )
        let envelope = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("fixture".utf8))
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in providerID == .minimax ? .available(envelope) : .missing },
            accountSnapshot: { _ in .empty },
            refreshCatalog: { providerID, _, _ in
                providerID == .minimax
                    ? ProviderCatalogRefresh(snapshot: .empty, voices: [first, second])
                    : ProviderCatalogRefresh(snapshot: .empty, voices: [])
            }
        )
        let engine = try makePreviewEngine(provider: provider, player: PreviewEnginePlayback(), loader: loader)
        await engine.waitForInitialHydration()
        let current = try XCTUnwrap(engine.providerSettingsState.card(.minimax).selection)
        let installedFirst = await engine.updateProviderSelectionAndWait(.init(
            providerID: .minimax, modelID: current.modelID,
            voiceID: first.stableID, rate: current.rate
        ))
        XCTAssertTrue(installedFirst)

        let control = try XCTUnwrap(engine.currentDefaultVoiceControlState)
        XCTAssertEqual(control.selectedVoiceID, first.stableID)
        XCTAssertEqual(control.voices.map(\.id), [first.stableID, second.stableID])

        let installedSecond = await engine.updateCurrentDefaultVoice(second.stableID)
        XCTAssertTrue(installedSecond)
        let persisted = await engine.persistedProviderPrefsForTesting()
        XCTAssertEqual(
            persisted.selections[.minimax]?.voiceID,
            second.stableID
        )
        XCTAssertEqual(engine.currentDefaultVoiceControlState?.selectedVoiceID, second.stableID)
        XCTAssertEqual(engine.currentVoiceDisplayLabel, "Second Voice")
    }

    func testMainRateUpdatesCurrentProviderSelectionWithoutLegacyBridge() async throws {
        let provider = try PreviewEngineProvider(id: .minimax)
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                providerID == .minimax
                    ? .available(.init(providerID: .minimax, revision: UUID(), secret: Data("fixture".utf8)))
                    : .missing
            },
            accountSnapshot: { _ in .empty }
        )
        let engine = try makePreviewEngine(provider: provider, player: PreviewEnginePlayback(), loader: loader)
        await engine.waitForInitialHydration()

        let didUpdate = await engine.updateCurrentDefaultRate(25)
        XCTAssertTrue(didUpdate)

        let selection = (await engine.persistedProviderPrefsForTesting()).selections[.minimax]
        XCTAssertEqual(selection?.rate.value, 25)
        XCTAssertEqual(engine.currentDefaultVoiceControlState?.rate.value, 25)
    }

    func testPersistedCredentialWithReloadFailureReturnsWarningResult() async throws {
        let ingress = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain(update: errSecSuccess)))
        let actions = SettingsCredentialActions(ingress: ingress, providerCredentialDidSave: { _ in false })

        let result = try await actions.saveManual(providerID: .openAI, draft: "private")

        XCTAssertEqual(result, .persistedButRefreshFailed)
        guard case .available = try await ingress.store.read(providerID: .openAI) else {
            return XCTFail("credential must remain persisted")
        }
    }

    func testSettingsViewUsesRootOwnedCredentialDependencies() throws {
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "/Tests/AloudTests/ProviderSettingsEngineIntegrationTests.swift", with: "/Sources/Aloud/SettingsView.swift"))
        XCTAssertFalse(source.contains("CredentialStore.live"))
        XCTAssertFalse(source.contains("OnePasswordPipeClient()"))
    }

    func testSettingsCredentialActionsImportMiniMaxUsesInjectedIngressAndReloadsOnlyMiniMax() async throws {
        let launcher = SettingsRecordingOnePasswordLauncher(output: Data("private".utf8))
        let ingress = CredentialIngress(
            store: CredentialStore(keychain: ScriptedKeychain(update: errSecSuccess)),
            onePassword: OnePasswordPipeClient(launcher: launcher, executableResolver: { "/approved/op" })
        )
        var reloads: [ProviderID] = []
        let actions = SettingsCredentialActions(ingress: ingress, providerCredentialDidSave: { providerID in
            reloads.append(providerID)
            return true
        })

        let result = try await actions.importMiniMaxFromOnePassword()

        XCTAssertEqual(launcher.readCount, 1)
        XCTAssertEqual(reloads, [.minimax])
        XCTAssertEqual(result, .updated)
    }

    func testBannerTokenCannotClearNewerBannerWithSameMessage() {
        let banner = SettingsCredentialBannerState()
        let first = banner.show("已更新")
        let second = banner.show("已更新")
        banner.clear(ifCurrent: first)
        XCTAssertEqual(banner.message, "已更新")
        banner.clear(ifCurrent: second)
        XCTAssertNil(banner.message)
    }

    func testProviderDetailKeepsRecoveryAndEvidenceInsideItsTechnicalStructure() throws {
        let providerSource = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "/Tests/AloudTests/ProviderSettingsEngineIntegrationTests.swift", with: "/Sources/Aloud/ProviderSettingsView.swift"))
        XCTAssertTrue(providerSource.contains("catalogSource"))
        XCTAssertTrue(providerSource.contains("accountCatalogPresentation"))
        XCTAssertTrue(providerSource.contains("providerWorking"))
        XCTAssertTrue(providerSource.contains("state.recoveryMode"))
        let appSource = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "/Tests/AloudTests/ProviderSettingsEngineIntegrationTests.swift", with: "/Sources/Aloud/AloudApp.swift"))
        XCTAssertTrue(appSource.contains("credentialIngress: AppCompositionRoot.live.credentialIngress"))
        XCTAssertTrue(appSource.contains("systemVoices: AppCompositionRoot.live.systemVoices"))
    }

    func testPreviewExecutionHasNoCacheHistoryOrLastAudioSink() async throws {
        XCTAssertEqual(PreviewExecutionDependencies.capabilities, [.nativeSynthesis, .verifiedPlayback])
    }

    func testEngineBlocksUnavailableUnconfiguredAndInvalidSelectionPreviewBeforeSynthesisOrHealthMutation() async throws {
        for blocked in [ProviderConfiguration.unconfigured, .invalidSelection] {
            let provider = try PreviewEngineProvider()
            let player = PreviewEnginePlayback()
            let engine = try makePreviewEngine(provider: provider, player: player)
            await engine.waitForInitialHydration()
            var state = try ProviderSettingsState.fixture(defaultProviderID: .macOS)
            let index = state.cards.firstIndex { $0.id == .macOS }!
            state.cards[index].configuration = blocked
            state.cards[index].health = .recentSuccess
            engine.providerSettingsState = state
            engine.previewProvider(.macOS)
            for _ in 0..<20 { await Task.yield() }
            let synthesisCount = await provider.count()
            XCTAssertEqual(synthesisCount, 0)
            XCTAssertEqual(engine.providerSettingsState.card(.macOS).health, .recentSuccess)
            XCTAssertEqual(player.playCount, 0)
        }
        let provider = try PreviewEngineProvider()
        let player = PreviewEnginePlayback()
        let engine = try makePreviewEngine(provider: provider, player: player)
        await engine.waitForInitialHydration()
        var state = try ProviderSettingsState.fixture(defaultProviderID: .macOS)
        let index = state.cards.firstIndex { $0.id == .macOS }!
        let current = state.cards[index].availability
        state.cards[index].availability = ProviderAvailability(
            kind: .disabled, reason: .explicitlyDisabled, maturity: .stable,
            featureFlagName: nil, featureFlagEnabled: nil,
            providerContractVersion: current.providerContractVersion, evidenceID: current.evidenceID
        )
        state.cards[index].health = .recentSuccess
        engine.providerSettingsState = state
        engine.previewProvider(.macOS)
        for _ in 0..<20 { await Task.yield() }
        let disabledSynthesisCount = await provider.count()
        XCTAssertEqual(disabledSynthesisCount, 0)
        XCTAssertEqual(engine.providerSettingsState.card(.macOS).health, .recentSuccess)
        XCTAssertEqual(player.playCount, 0)
    }

    func testEnginePreviewNormalizesPersistedLegacyMiniMaxSelectionBeforeProviderSplit() async throws {
        let provider = try PreviewEngineProvider(id: .minimax)
        let engine = try makePreviewEngine(provider: provider, player: PreviewEnginePlayback())
        await engine.waitForInitialHydration()
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        let index = state.cards.firstIndex { $0.id == .minimax }!
        state.cards[index].selection = ProviderSelection(
            providerID: .minimax,
            modelID: ModelID(rawValue: "speech-2.8-hd"),
            voiceID: VoiceID(rawValue: "Chinese (Mandarin)_Radio_Host|default"),
            rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 15)!
        )
        engine.providerSettingsState = state

        engine.previewProvider(.minimax)
        for _ in 0..<100 where await provider.splitSelections().isEmpty {
            await Task.yield()
        }

        let splitSelections = await provider.splitSelections()
        let selection = try XCTUnwrap(splitSelections.first)
        XCTAssertEqual(selection.voiceID, VoiceID(rawValue: "minimax.radio-host.default"))
        XCTAssertEqual(selection.rate.version, MiniMaxRateMappingV1.version)
        XCTAssertEqual(selection.rate.value, 15)
    }

    func testEngineStopDuringCancellationIgnoringPreviewSynthesisNeverPlaysAndDrainsExactlyOnce() async throws {
        let barrier = PreviewBarrierForEngine()
        let provider = try PreviewEngineProvider(barrier: barrier)
        let player = PreviewEnginePlayback()
        let engine = try makePreviewEngine(provider: provider, player: player)
        engine.providerSettingsState = try ProviderSettingsState.fixture(defaultProviderID: .macOS)
        engine.previewProvider(.macOS)
        await barrier.waitUntilEntered()
        engine.stop()
        await barrier.release()
        for _ in 0..<100 where player.stopAndWaitCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(player.playCount, 0)
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertEqual(player.stopAndWaitCount, 1)
        XCTAssertEqual(engine.phase, .idle)
    }

    func testEngineRejectsNewUnconfiguredDefaultWithoutPersistOrCancellation() async throws {
        let provider = try PreviewEngineProvider()
        let player = PreviewEnginePlayback()
        let engine = try makePreviewEngine(provider: provider, player: player)
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        let index = state.cards.firstIndex { $0.id == .macOS }!
        state.cards[index].configuration = .unconfigured
        engine.providerSettingsState = state
        engine.setDefaultProvider(.macOS)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(engine.providerSettingsState.card(.minimax).isDefault)
        XCTAssertEqual(player.stopCount, 0)
    }

    func testEngineCredentialReloadResetsOnlyAffectedProviderHealth() async throws {
        let provider = try PreviewEngineProvider()
        let player = PreviewEnginePlayback()
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                .available(CredentialEnvelope(providerID: providerID, revision: UUID(), secret: Data("fake".utf8)))
            },
            accountSnapshot: { _ in .empty }
        )
        let engine = try makePreviewEngine(provider: provider, player: player, loader: loader)
        // Wait for initializer hydration, which intentionally resets every provider,
        // before modeling an in-session credential save.
        await engine.waitForInitialHydration()
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        for index in state.cards.indices { state.cards[index].health = .recentSuccess }
        engine.providerSettingsState = state
        engine.providerCredentialDidSave(.openAI)
        for _ in 0..<100 where engine.providerSettingsState.card(.openAI).health != .unknown { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(engine.providerSettingsState.card(.openAI).health, .unknown)
        XCTAssertEqual(engine.providerSettingsState.card(.minimax).health, .recentSuccess)
        XCTAssertEqual(engine.providerSettingsState.card(.gemini).health, .recentSuccess)
        XCTAssertEqual(engine.providerSettingsState.card(.macOS).health, .recentSuccess)
    }

    func testRuntimeLoaderRefreshesConfiguredMiniMaxCatalogAndCarriesVoiceDescriptors() async throws {
        let envelope = CredentialEnvelope(
            providerID: .minimax,
            revision: UUID(),
            secret: Data("loader-only-fixture".utf8)
        )
        let descriptors = [MiniMaxVoiceDescriptor(
            stableID: VoiceID(rawValue: "minimax.dynamic.fixture"),
            wireID: "fixture-wire-voice",
            displayName: "Fixture Voice",
            kind: .cloned
        )]
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in providerID == .minimax ? .available(envelope) : .missing },
            accountSnapshot: { _ in .empty },
            refreshCatalog: { providerID, captured, _ in
                XCTAssertEqual(providerID, .minimax)
                XCTAssertEqual(captured, envelope)
                return ProviderCatalogRefresh(snapshot: .empty, voices: descriptors)
            }
        )

        let state = try await loader.load(prefs: .defaults, recoveryMode: false)

        XCTAssertEqual(state.card(.minimax).availableVoices, descriptors)
        XCTAssertEqual(state.card(.openAI).availableVoices, [])
    }

    func testOlderMiniMaxRefreshCannotReplaceNewerPublishedStateOrDirectory() async throws {
        let revisionA = UUID()
        let revisionB = UUID()
        let envelopeA = CredentialEnvelope(providerID: .minimax, revision: revisionA, secret: Data("fixture-a".utf8))
        let envelopeB = CredentialEnvelope(providerID: .minimax, revision: revisionB, secret: Data("fixture-b".utf8))
        let credential = SettingsCredentialSource(envelopeA)
        let evidence = SettingsAccountEvidence()
        let responseA = try settingsCatalogResponse(wireID: "late-a", displayName: "Late A")
        let responseB = try settingsCatalogResponse(wireID: "current-b", displayName: "Current B")
        let http = SettingsCatalogBarrierHTTP(first: responseA, later: responseB)
        let directory = MiniMaxVoiceDirectory()
        let provider = MiniMaxProvider(
            httpClient: http,
            nativeDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            voiceDirectory: directory
        )
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                guard providerID == .minimax else { return .missing }
                return .available(await credential.current())
            },
            accountSnapshot: { providerID in await evidence.snapshot(for: providerID) },
            refreshCatalog: { providerID, envelope, _ in
                do {
                    let result = try await provider.loadVoiceCatalog(using: .apiKey(providerID: providerID, envelope: envelope))
                    await evidence.publish(result.snapshot, for: providerID)
                    return ProviderCatalogRefresh(snapshot: result.snapshot, voices: result.voices)
                } catch {
                    return ProviderCatalogRefresh(
                        snapshot: await evidence.snapshot(for: providerID),
                        voices: await provider.voiceDescriptors(revision: envelope.revision)
                    )
                }
            }
        )

        let loadA = Task { try await loader.load(prefs: .defaults, recoveryMode: false) }
        await http.waitUntilFirstRequestIsSuspended()
        await credential.install(envelopeB)
        let stateB = try await loader.load(prefs: .defaults, recoveryMode: false)
        await http.resumeFirstRequest()
        do {
            _ = try await loadA.value
            XCTFail("older refresh must not produce publishable state")
        } catch is CancellationError {
        }

        let currentB = try XCTUnwrap(stateB.card(.minimax).availableVoices.first { $0.wireID == "current-b" })
        let currentDirectoryContainsB = await directory.containsInCurrentCatalog(currentB.stableID)
        let revisionADescriptors = await directory.descriptors(revision: revisionA)
        let publishedRevision = await evidence.revision(for: .minimax)
        XCTAssertTrue(currentDirectoryContainsB)
        XCTAssertFalse(revisionADescriptors.contains { $0.wireID == "late-a" })
        XCTAssertEqual(publishedRevision, revisionB)
    }

    func testOldEvidenceTokenCannotPublishDirectoryAfterNewerStateAndEvidence() async throws {
        let revisionA = UUID()
        let revisionB = UUID()
        let envelopeA = CredentialEnvelope(
            providerID: .minimax, revision: revisionA, secret: Data("token-first-a".utf8)
        )
        let envelopeB = CredentialEnvelope(
            providerID: .minimax, revision: revisionB, secret: Data("current-b".utf8)
        )
        let credential = SettingsCredentialSource(envelopeA)
        let evidence = ProviderAccountEvidenceStore()
        let startBarrier = SettingsRefreshStartBarrier(suspendedRevision: revisionA)
        let directory = MiniMaxVoiceDirectory(publicationStore: evidence)
        let provider = MiniMaxProvider(
            httpClient: SettingsCatalogByCredentialHTTP(),
            nativeDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            voiceDirectory: directory
        )
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                guard providerID == .minimax else { return .missing }
                return .available(await credential.current())
            },
            accountSnapshot: { providerID in await evidence.snapshot(for: providerID) },
            refreshCatalog: { providerID, envelope, publication in
                await startBarrier.suspendIfNeeded(envelope.revision)
                let result = try await provider.loadVoiceCatalog(
                    using: .apiKey(providerID: providerID, envelope: envelope),
                    publication: publication
                )
                return ProviderCatalogRefresh(
                    snapshot: result.snapshot,
                    voices: result.voices,
                    publicationRevision: envelope.revision
                )
            },
            publication: evidence
        )

        let loadA = Task { try await loader.load(prefs: .defaults, recoveryMode: false) }
        await startBarrier.waitUntilSuspended()
        await credential.install(envelopeB)
        let stateB = try await loader.load(prefs: .defaults, recoveryMode: false)
        await startBarrier.release()
        do {
            _ = try await loadA.value
            XCTFail("old publication must be rejected")
        } catch is CancellationError {
        }

        let voiceB = try XCTUnwrap(
            stateB.card(.minimax).availableVoices.first { $0.wireID == "current-b-voice" }
        )
        let evidenceSnapshot = await evidence.snapshot(for: .minimax)
        let oldDescriptors = await directory.descriptors(revision: revisionA)
        let directoryContainsB = await directory.containsInCurrentCatalog(voiceB.stableID)
        XCTAssertTrue(directoryContainsB)
        XCTAssertFalse(oldDescriptors.contains { $0.wireID == "token-first-a-voice" })
        XCTAssertTrue(evidenceSnapshot.relationshipEvidence.keys.contains {
            $0.credentialRevision == revisionB
        })
        XCTAssertFalse(evidenceSnapshot.relationshipEvidence.keys.contains {
            $0.credentialRevision == revisionA
        })
    }

    func testLateOlderPublicationCannotReplaceNewerDirectoryOperation() async throws {
        let revisionA = UUID()
        let revisionB = UUID()
        let envelopeA = CredentialEnvelope(
            providerID: .minimax, revision: revisionA, secret: Data("late-operation-a".utf8)
        )
        let envelopeB = CredentialEnvelope(
            providerID: .minimax, revision: revisionB, secret: Data("current-operation-b".utf8)
        )
        let credential = SettingsCredentialSource(envelopeA)
        let evidence = ProviderAccountEvidenceStore()
        let startBarrier = SettingsRefreshStartBarrier(suspendedRevision: revisionA)
        let http = SettingsCatalogBarrierHTTP(
            first: try settingsCatalogResponse(
                wireID: "current-operation-b-voice", displayName: "Current B"
            ),
            later: try settingsCatalogResponse(
                wireID: "late-operation-a-voice", displayName: "Late A"
            )
        )
        let directory = MiniMaxVoiceDirectory(publicationStore: evidence)
        let provider = MiniMaxProvider(
            httpClient: http,
            nativeDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            voiceDirectory: directory
        )
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                guard providerID == .minimax else { return .missing }
                return .available(await credential.current())
            },
            accountSnapshot: { providerID in await evidence.snapshot(for: providerID) },
            refreshCatalog: { providerID, envelope, publication in
                await startBarrier.suspendIfNeeded(envelope.revision)
                let result = try await provider.loadVoiceCatalog(
                    using: .apiKey(providerID: providerID, envelope: envelope),
                    publication: publication
                )
                return ProviderCatalogRefresh(
                    snapshot: result.snapshot,
                    voices: result.voices,
                    publicationRevision: envelope.revision
                )
            },
            publication: evidence
        )

        let loadA = Task { try await loader.load(prefs: .defaults, recoveryMode: false) }
        await startBarrier.waitUntilSuspended()
        await credential.install(envelopeB)
        let loadB = Task { try await loader.load(prefs: .defaults, recoveryMode: false) }
        await http.waitUntilFirstRequestIsSuspended()

        await startBarrier.release()
        do {
            _ = try await loadA.value
            XCTFail("older publication must be rejected")
        } catch is CancellationError {
        }
        await http.resumeFirstRequest()
        let stateB = try await loadB.value

        let voiceB = try XCTUnwrap(
            stateB.card(.minimax).availableVoices.first {
                $0.wireID == "current-operation-b-voice"
            }
        )
        let evidenceSnapshot = await evidence.snapshot(for: .minimax)
        let directoryContainsB = await directory.containsInCurrentCatalog(voiceB.stableID)
        XCTAssertTrue(directoryContainsB)
        XCTAssertTrue(evidenceSnapshot.relationshipEvidence.keys.contains {
            $0.credentialRevision == revisionB
        })
        XCTAssertFalse(evidenceSnapshot.relationshipEvidence.keys.contains {
            $0.credentialRevision == revisionA
        })
    }

    func testNestedCommittedPublicationsCancelBackToInstalledBaseline() async throws {
        let revisionPrior = UUID()
        let revisionA = UUID()
        let revisionB = UUID()
        let envelopePrior = CredentialEnvelope(
            providerID: .minimax, revision: revisionPrior, secret: Data("prior-publication".utf8)
        )
        let envelopeA = CredentialEnvelope(
            providerID: .minimax, revision: revisionA, secret: Data("committed-publication-a".utf8)
        )
        let envelopeB = CredentialEnvelope(
            providerID: .minimax, revision: revisionB, secret: Data("cancelled-publication-b".utf8)
        )
        let credential = SettingsCredentialSource(envelopePrior)
        let tailBarrier = SettingsPublicationTailBarrier()
        let evidence = ProviderAccountEvidenceStore()
        let directory = MiniMaxVoiceDirectory(publicationStore: evidence)
        let provider = MiniMaxProvider(
            httpClient: SettingsCatalogByCredentialHTTP(),
            nativeDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            voiceDirectory: directory
        )
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                guard providerID == .minimax else { return .missing }
                return .available(await credential.current())
            },
            accountSnapshot: { providerID in await evidence.snapshot(for: providerID) },
            refreshCatalog: { providerID, envelope, publication in
                let result = try await provider.loadVoiceCatalog(
                    using: .apiKey(providerID: providerID, envelope: envelope),
                    publication: publication
                )
                return ProviderCatalogRefresh(
                    snapshot: result.snapshot,
                    voices: result.voices,
                    publicationRevision: envelope.revision
                )
            },
            publication: evidence,
            beforeFinalPublicationValidation: { await tailBarrier.suspendIfArmed() }
        )
        let engine = try makePreviewEngine(
            provider: PreviewEngineProvider(),
            player: PreviewEnginePlayback(),
            loader: loader
        )
        await engine.waitForInitialHydration()
        let priorState = engine.providerSettingsState
        let priorVoice = try XCTUnwrap(
            priorState.card(.minimax).availableVoices.first {
                $0.wireID == "prior-publication-voice"
            }
        )
        let priorSnapshot = await evidence.snapshot(for: .minimax)
        let priorDescriptors = await directory.descriptors(revision: revisionPrior)
        await tailBarrier.armNext(2)

        await credential.install(envelopeA)
        let loadA = Task { await engine.reloadProviderSettingsState() }
        await tailBarrier.waitUntilSuspended(1)
        await credential.install(envelopeB)
        let loadB = Task { await engine.reloadProviderSettingsState() }
        await tailBarrier.waitUntilSuspended(2)
        let stagedDescriptorsA = await directory.descriptors(revision: revisionA)
        let stagedDescriptorsB = await directory.descriptors(revision: revisionB)
        XCTAssertFalse(stagedDescriptorsA.contains { $0.wireID == "committed-publication-a-voice" })
        XCTAssertFalse(stagedDescriptorsB.contains { $0.wireID == "cancelled-publication-b-voice" })

        await tailBarrier.release(1)
        let didPublishA = await loadA.value
        loadB.cancel()
        await tailBarrier.release(2)
        let didPublishB = await loadB.value

        let evidenceSnapshot = await evidence.snapshot(for: .minimax)
        let descriptorsPrior = await directory.descriptors(revision: revisionPrior)
        let descriptorsA = await directory.descriptors(revision: revisionA)
        let descriptorsB = await directory.descriptors(revision: revisionB)
        let directoryContainsPrior = await directory.containsInCurrentCatalog(priorVoice.stableID)
        XCTAssertFalse(didPublishA)
        XCTAssertFalse(didPublishB)
        XCTAssertEqual(engine.providerSettingsState, priorState)
        XCTAssertEqual(evidenceSnapshot, priorSnapshot)
        XCTAssertEqual(descriptorsPrior, priorDescriptors)
        XCTAssertTrue(directoryContainsPrior)
        XCTAssertFalse(descriptorsA.contains { $0.wireID == "committed-publication-a-voice" })
        XCTAssertFalse(descriptorsB.contains { $0.wireID == "cancelled-publication-b-voice" })
    }

    func testInstalledNoCacheStateDoesNotAdoptOlderStagedCatalog() async throws {
        let revisionPrior = UUID()
        let revisionA = UUID()
        let revisionB = UUID()
        let envelopePrior = CredentialEnvelope(
            providerID: .minimax, revision: revisionPrior, secret: Data("prior-no-cache".utf8)
        )
        let envelopeA = CredentialEnvelope(
            providerID: .minimax, revision: revisionA, secret: Data("staged-no-cache-a".utf8)
        )
        let envelopeB = CredentialEnvelope(
            providerID: .minimax, revision: revisionB, secret: Data("rejected-no-cache-b".utf8)
        )
        let credential = SettingsCredentialSource(envelopePrior)
        let tailBarrier = SettingsPublicationTailBarrier()
        let evidence = ProviderAccountEvidenceStore()
        let directory = MiniMaxVoiceDirectory(publicationStore: evidence)
        let provider = MiniMaxProvider(
            httpClient: SettingsCatalogByCredentialHTTP(),
            nativeDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            voiceDirectory: directory
        )
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                guard providerID == .minimax else { return .missing }
                return .available(await credential.current())
            },
            accountSnapshot: { providerID in await evidence.snapshot(for: providerID) },
            refreshCatalog: { providerID, envelope, publication in
                if envelope.revision == revisionB {
                    return ProviderCatalogRefresh(
                        snapshot: await evidence.snapshot(for: providerID),
                        voices: await directory.descriptors(revision: envelope.revision),
                        healthOverride: .explicitRejected
                    )
                }
                let result = try await provider.loadVoiceCatalog(
                    using: .apiKey(providerID: providerID, envelope: envelope),
                    publication: publication
                )
                return ProviderCatalogRefresh(
                    snapshot: result.snapshot,
                    voices: result.voices,
                    publicationRevision: envelope.revision
                )
            },
            publication: evidence,
            beforeFinalPublicationValidation: { await tailBarrier.suspendIfArmed() }
        )
        let engine = try makePreviewEngine(
            provider: PreviewEngineProvider(),
            player: PreviewEnginePlayback(),
            loader: loader
        )
        await engine.waitForInitialHydration()
        let priorSnapshot = await evidence.snapshot(for: .minimax)
        let priorDescriptors = await directory.descriptors(revision: revisionPrior)
        let priorVoice = try XCTUnwrap(
            priorDescriptors.first { $0.wireID == "prior-no-cache-voice" }
        )
        await tailBarrier.armNext(1)

        await credential.install(envelopeA)
        let loadA = Task { await engine.reloadProviderSettingsState() }
        await tailBarrier.waitUntilSuspended(1)
        let stagedDescriptorsA = await directory.descriptors(revision: revisionA)
        XCTAssertFalse(stagedDescriptorsA.contains { $0.wireID == "staged-no-cache-a-voice" })

        await credential.install(envelopeB)
        let didInstallB = await engine.reloadProviderSettingsState()
        await tailBarrier.release(1)
        let didInstallA = await loadA.value

        let card = engine.providerSettingsState.card(.minimax)
        let evidenceSnapshot = await evidence.snapshot(for: .minimax)
        let descriptorsPrior = await directory.descriptors(revision: revisionPrior)
        let descriptorsA = await directory.descriptors(revision: revisionA)
        let directoryContainsPrior = await directory.containsInCurrentCatalog(priorVoice.stableID)
        XCTAssertTrue(didInstallB)
        XCTAssertFalse(didInstallA)
        XCTAssertEqual(card.health, .explicitRejected)
        XCTAssertFalse(card.availableVoices.contains { $0.wireID == "staged-no-cache-a-voice" })
        XCTAssertEqual(evidenceSnapshot, priorSnapshot)
        XCTAssertEqual(descriptorsPrior, priorDescriptors)
        XCTAssertTrue(directoryContainsPrior)
        XCTAssertFalse(descriptorsA.contains { $0.wireID == "staged-no-cache-a-voice" })
    }

    func testCancellationAfterDirectoryCommitPublishesNoDirectoryEvidenceOrState() async throws {
        let revision = UUID()
        let envelope = CredentialEnvelope(
            providerID: .minimax, revision: revision, secret: Data("cancel-after-directory".utf8)
        )
        let evidenceBarrier = SettingsEvidenceCommitBarrier()
        let evidence = ProviderAccountEvidenceStore(
            afterPublish: { await evidenceBarrier.suspend() }
        )
        let directory = MiniMaxVoiceDirectory(publicationStore: evidence)
        let provider = MiniMaxProvider(
            httpClient: SettingsCatalogByCredentialHTTP(),
            nativeDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            voiceDirectory: directory
        )
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                providerID == .minimax ? .available(envelope) : .missing
            },
            accountSnapshot: { providerID in await evidence.snapshot(for: providerID) },
            refreshCatalog: { providerID, captured, publication in
                let result = try await provider.loadVoiceCatalog(
                    using: .apiKey(providerID: providerID, envelope: captured),
                    publication: publication
                )
                return ProviderCatalogRefresh(
                    snapshot: result.snapshot,
                    voices: result.voices,
                    publicationRevision: captured.revision
                )
            },
            publication: evidence
        )
        let load = Task { try await loader.load(prefs: .defaults, recoveryMode: false) }
        await evidenceBarrier.waitUntilSuspended()

        load.cancel()
        await evidenceBarrier.release()
        do {
            _ = try await load.value
            XCTFail("cancelled publication must not return state")
        } catch is CancellationError {
        }

        let evidenceSnapshot = await evidence.snapshot(for: .minimax)
        let descriptors = await directory.descriptors(revision: revision)
        XCTAssertTrue(evidenceSnapshot.relationshipEvidence.isEmpty)
        XCTAssertFalse(descriptors.contains { $0.wireID == "cancel-after-directory-voice" })
    }

    func testInstalledBRemainsAfterStaleACleanup() async throws {
        let revisionA = UUID()
        let revisionB = UUID()
        let envelopeA = CredentialEnvelope(
            providerID: .minimax, revision: revisionA, secret: Data("committed-a".utf8)
        )
        let envelopeB = CredentialEnvelope(
            providerID: .minimax, revision: revisionB, secret: Data("installed-b".utf8)
        )
        let credential = SettingsCredentialSource(envelopeA)
        let returnBarrier = SettingsFirstPublicationReturnBarrier()
        let evidence = ProviderAccountEvidenceStore()
        let directory = MiniMaxVoiceDirectory(publicationStore: evidence)
        let provider = MiniMaxProvider(
            httpClient: SettingsCatalogByCredentialHTTP(),
            nativeDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            voiceDirectory: directory
        )
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                guard providerID == .minimax else { return .missing }
                return .available(await credential.current())
            },
            accountSnapshot: { providerID in await evidence.snapshot(for: providerID) },
            refreshCatalog: { providerID, envelope, publication in
                let result = try await provider.loadVoiceCatalog(
                    using: .apiKey(providerID: providerID, envelope: envelope),
                    publication: publication
                )
                return ProviderCatalogRefresh(
                    snapshot: result.snapshot,
                    voices: result.voices,
                    publicationRevision: envelope.revision
                )
            },
            publication: evidence,
            beforeFinalPublicationValidation: {
                await returnBarrier.suspendFirstPublication()
            }
        )
        let engine = try makePreviewEngine(
            provider: PreviewEngineProvider(),
            player: PreviewEnginePlayback(),
            loader: loader
        )
        await returnBarrier.waitUntilFirstPublicationIsSuspended()

        await credential.install(envelopeB)
        let didInstallB = await engine.reloadProviderSettingsState()
        let installedBState = engine.providerSettingsState
        await returnBarrier.releaseFirstPublication()
        await engine.waitForInitialHydration()

        let card = engine.providerSettingsState.card(.minimax)
        let evidenceSnapshot = await evidence.snapshot(for: .minimax)
        let voiceB = try XCTUnwrap(card.availableVoices.first { $0.wireID == "installed-b-voice" })
        let directoryContainsB = await directory.containsInCurrentCatalog(voiceB.stableID)
        XCTAssertTrue(didInstallB)
        XCTAssertEqual(engine.providerSettingsState, installedBState)
        XCTAssertFalse(card.availableVoices.contains { $0.wireID == "committed-a-voice" })
        XCTAssertTrue(directoryContainsB)
        XCTAssertTrue(evidenceSnapshot.relationshipEvidence.keys.contains {
            $0.credentialRevision == revisionB
        })
        XCTAssertFalse(evidenceSnapshot.relationshipEvidence.keys.contains {
            $0.credentialRevision == revisionA
        })
    }

    func testEngineDoesNotInstallFirstRefreshAfterNewerRefreshHasBegunButNotPublished() async throws {
        let envelopeA = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("engine-a".utf8))
        let envelopeB = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("engine-b".utf8))
        let credential = SettingsCredentialSource(envelopeA)
        let barrier = SettingsRefreshPublicationBarrier(refreshes: [
            envelopeA.revision: ProviderCatalogRefresh(snapshot: .empty, voices: [settingsDescriptor("engine-a")]),
            envelopeB.revision: ProviderCatalogRefresh(snapshot: .empty, voices: [settingsDescriptor("engine-b")]),
        ])
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                guard providerID == .minimax else { return .missing }
                return .available(await credential.current())
            },
            accountSnapshot: { _ in .empty },
            refreshCatalog: { _, envelope, _ in await barrier.refresh(envelope) }
        )
        let engine = try makePreviewEngine(
            provider: PreviewEngineProvider(),
            player: PreviewEnginePlayback(),
            loader: loader
        )

        await barrier.waitUntilEntered(envelopeA.revision)
        let stateBeforeACompletes = engine.providerSettingsState
        await credential.install(envelopeB)
        let loadB = Task { await engine.reloadProviderSettingsState() }
        await barrier.waitUntilEntered(envelopeB.revision)
        await barrier.release(envelopeA.revision)
        await engine.waitForInitialHydration()

        XCTAssertEqual(engine.providerSettingsState, stateBeforeACompletes)
        await barrier.release(envelopeB.revision)
        let didPublishB = await loadB.value
        XCTAssertTrue(didPublishB)
        XCTAssertEqual(
            engine.providerSettingsState.card(.minimax).availableVoices,
            [settingsDescriptor("engine-b")]
        )
    }

    func testOpenAIPreviewRequiresExplicitDurableDisclosureAckBeforeSynthesisThenRetries() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-openai-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = try PreviewEngineProvider(id: .openAI)
        let player = PreviewEnginePlayback()
        let revision = UUID()
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                providerID == .openAI
                    ? .available(CredentialEnvelope(providerID: providerID, revision: revision, secret: Data("fake".utf8)))
                    : .missing
            },
            accountSnapshot: { _ in .empty }
        )
        let operations = Store.Operations(
            dir: root, cacheDir: root, runtimeDir: root,
            read: { url in try? Data(contentsOf: url) },
            write: { data, url in try data.write(to: url, options: .atomic) }
        )
        try JSONEncoder().encode(PrefsV1.defaults).write(to: root.appendingPathComponent("prefs.json"), options: .atomic)
        let engine = Store.withOperations(operations) {
            Engine(
                player: player,
                speech: EngineSpeechDependencies(
                    cachePath: { _, _, _ in root.appendingPathComponent("unused.wav") }, cacheHit: { _ in false },
                    synthesize: { _, _, _, _ in }, concat: { _, _, _ in },
                    providerForID: { $0 == .openAI ? provider : nil },
                    captureCredential: { providerID in CredentialEnvelope(providerID: providerID, revision: UUID(), secret: Data("fake".utf8)) },
                    verifyPlayback: { PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()) }
                ),
                credentialRegistry: CredentialScopeRegistry(), installCredentialHook: false,
                providerSettingsRuntimeLoader: loader
            )
        }
        await engine.waitForInitialHydration()
        engine.providerSettingsState = try ProviderSettingsState.fixture(defaultProviderID: .openAI)
        engine.previewProvider(.openAI)
        for _ in 0..<50 { await Task.yield() }
        let countBeforeAck = await provider.count()
        XCTAssertEqual(countBeforeAck, 0)
        XCTAssertTrue(engine.providerSettingsState.card(.openAI).actions.contains(.confirmDisclosure))

        engine.confirmOpenAIDisclosureAndPreview()
        for _ in 0..<200 where await provider.count() == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let countAfterAck = await provider.count()
        XCTAssertEqual(countAfterAck, 1, "toast=\(engine.toast ?? "nil") status=\(engine.providerSettingsState.card(.openAI).statusText) configured=\(engine.providerSettingsState.card(.openAI).configuration) actions=\(engine.providerSettingsState.card(.openAI).actions)")
        let persisted = try JSONDecoder().decode(PrefsV1.self, from: Data(contentsOf: root.appendingPathComponent("prefs.json")))
        XCTAssertEqual(persisted.openAIDisclosureAck?.modelID, ModelID(rawValue: "tts-1"))
        XCTAssertEqual(persisted.openAIDisclosureAck?.voiceID, VoiceID(rawValue: "openai.alloy"))
    }

    func testOpenAIDisclosureRecoveryAndWriteFailureStayBlockedBeforePreviewTransport() async throws {
        for fixture in DisclosurePreviewFailure.allCases {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-openai-preview-failure-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let prefsURL = root.appendingPathComponent("prefs.json")
            switch fixture {
            case .recovery: try Data("invalid".utf8).write(to: prefsURL)
            case .writeFailure: try JSONEncoder().encode(PrefsV1.defaults).write(to: prefsURL)
            }
            let provider = try PreviewEngineProvider(id: .openAI)
            let player = PreviewEnginePlayback()
            let revision = UUID()
            let loader = ProviderSettingsRuntimeLoader(
                readCredential: { providerID in .available(CredentialEnvelope(providerID: providerID, revision: revision, secret: Data("fake".utf8))) },
                accountSnapshot: { _ in .empty }
            )
            let disclosureURL = URL(fileURLWithPath: "/test/openai-preview-disclosure-\(fixture)-\(UUID().uuidString).json")
            let disclosureFiles = RecordingAtomicFileStore(initial: [
                disclosureURL: fixture == .recovery
                    ? Data("invalid".utf8)
                    : try JSONEncoder().encode(PrefsV1.defaults)
            ])
            let disclosureStore = ProviderSettingsStore.open(url: disclosureURL, files: disclosureFiles)
            let persistedBeforeConfirmation = try XCTUnwrap(disclosureFiles.data(at: disclosureURL))
            if fixture == .writeFailure { disclosureFiles.failWrites = true }
            let disclosureCoordinator = OpenAIDisclosureCoordinator(store: disclosureStore)
            let operations = Store.Operations(
                dir: root, cacheDir: root, runtimeDir: root,
                read: { url in try? Data(contentsOf: url) },
                write: { data, url in try data.write(to: url, options: .atomic) }
            )
            let engine = Store.withOperations(operations) {
                Engine(
                    player: player,
                    speech: EngineSpeechDependencies(
                        cachePath: { _, _, _ in root.appendingPathComponent("unused.wav") }, cacheHit: { _ in false }, synthesize: { _, _, _, _ in }, concat: { _, _, _ in },
                        providerForID: { $0 == .openAI ? provider : nil }, captureCredential: { providerID in CredentialEnvelope(providerID: providerID, revision: revision, secret: Data("fake".utf8)) }
                    ),
                    credentialRegistry: CredentialScopeRegistry(), installCredentialHook: false,
                    providerSettingsRuntimeLoader: loader,
                    openAIDisclosureCoordinator: disclosureCoordinator
                )
            }
            await engine.waitForInitialHydration()
            engine.providerSettingsState = try ProviderSettingsState.fixture(defaultProviderID: .openAI)
            engine.confirmOpenAIDisclosureAndPreview()
            for _ in 0..<100 { await Task.yield() }
            let transportCount = await provider.count()
            XCTAssertEqual(transportCount, 0, "\(fixture)")
            XCTAssertEqual(player.playCount, 0, "\(fixture)")
            XCTAssertEqual(disclosureFiles.data(at: disclosureURL), persistedBeforeConfirmation, "\(fixture)")
        }
    }

    func testSuspendedOpenAIAuthorizationIsCoordinatorOwnedAndAllInvalidationsLeaveZeroEffects() async throws {
        for invalidation in DisclosurePreparationInvalidation.allCases {
            let fixture = try await OpenAIPreviewPreparationFixture.make()
            fixture.engine.previewProvider(.openAI)
            await fixture.authorizationBarrier.waitUntilEntered()
            var credentialTask: Task<Void, Never>?
            switch invalidation {
            case .stop: fixture.engine.stop()
            case .selection:
                var selection = fixture.engine.providerSettingsState.card(.openAI).selection!
                selection = ProviderSelection(providerID: .openAI, modelID: selection.modelID, voiceID: VoiceID(rawValue: "openai.echo"), rate: selection.rate)
                fixture.engine.updateProviderSelection(selection)
            case .defaultProvider: fixture.engine.setDefaultProvider(.macOS)
            case .credential:
                credentialTask = Task {
                    let token = await fixture.registry.begin(.openAI)
                    await fixture.registry.commit(token, .missing)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
            await fixture.authorizationBarrier.release()
            await credentialTask?.value
            for _ in 0..<100 { await Task.yield() }
            let transportCount = await fixture.provider.count()
            XCTAssertEqual(transportCount, 0, "\(invalidation)")
            XCTAssertEqual(fixture.player.playCount, 0, "\(invalidation)")
            XCTAssertNotEqual(fixture.engine.providerSettingsState.card(.openAI).health, .verifying, "\(invalidation)")
        }
    }

    func testSelectionChangedWhileAuthorizationSuspendedCannotStartOldPreview() async throws {
        let fixture = try await OpenAIPreviewPreparationFixture.make()
        fixture.engine.previewProvider(.openAI)
        await fixture.authorizationBarrier.waitUntilEntered()
        let old = fixture.engine.providerSettingsState.card(.openAI).selection!
        let index = fixture.engine.providerSettingsState.cards.firstIndex { $0.id == .openAI }!
        fixture.engine.providerSettingsState.cards[index].selection = ProviderSelection(
            providerID: .openAI, modelID: old.modelID, voiceID: VoiceID(rawValue: "openai.echo"), rate: old.rate
        )
        await fixture.authorizationBarrier.release()
        for _ in 0..<100 { await Task.yield() }
        let transportCount = await fixture.provider.count()
        XCTAssertEqual(transportCount, 0)
        XCTAssertEqual(fixture.player.playCount, 0)
    }

    private func makePreviewEngine(provider: PreviewEngineProvider, player: PreviewEnginePlayback, loader: ProviderSettingsRuntimeLoader? = nil, initialPrefs: PrefsV1? = nil, hotkeys: any HotkeyRegistering = Hotkeys.shared) throws -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-preview-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let initialPrefs {
            try JSONEncoder().encode(initialPrefs).write(to: root.appendingPathComponent("prefs.json"), options: .atomic)
        }
        let operations = Store.Operations(dir: root, cacheDir: root, runtimeDir: root, read: { _ in nil }, write: { _, _ in })
        let safeLoader = loader ?? ProviderSettingsRuntimeLoader(
            readCredential: { _ in .missing }, accountSnapshot: { _ in .empty }
        )
        return Store.withOperations(operations) {
            Engine(
                player: player,
                speech: EngineSpeechDependencies(
                    cachePath: { _, _, _ in root.appendingPathComponent("unused.wav") },
                    cacheHit: { _ in false }, synthesize: { _, _, _, _ in }, concat: { _, _, _ in },
                    providerForID: { $0 == provider.id ? provider : nil },
                    verifyPlayback: { PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()) }
                ),
                credentialRegistry: CredentialScopeRegistry(), installCredentialHook: false,
                hotkeys: hotkeys,
                providerSettingsRuntimeLoader: safeLoader
            )
        }
    }

    private func settingsViewState() throws -> SettingsViewState {
        let providerSettings = try ProviderSettingsState.fixture()
        return SettingsViewState(
            initialTab: 0, hasKey: false, voice: "", rate: 0,
            stripMarkdown: false, skipCode: false,
            hotkeyReadSelection: "", hotkeyReadClipboard: "", hotkeyTogglePause: "",
            recordingHotkey: nil, hotkeyChime: false, launchAtLogin: false,
            menuBarOnly: false, rules: [], cacheLimitMB: 0, binaryStatuses: [],
            providerSettings: providerSettings, selectedProviderID: .minimax,
            credentialStatuses: [:], systemVoices: []
        )
    }

    private func settingsActions(
        install: @escaping ([SystemVoiceDescriptor]) async -> Void
    ) -> SettingsViewActions {
        SettingsViewActions(
            setVoice: { _ in }, setRate: { _ in }, setStripMarkdown: { _ in }, setSkipCode: { _ in },
            startRecording: { _ in }, setHotkeyChime: { _ in }, setLaunchAtLogin: { _ in },
            setMenuBarOnly: { _ in }, addRule: {}, setRule: { _ in }, deleteRule: { _ in },
            setDefaultProvider: { _ in }, previewProvider: { _ in }, updateProviderSelection: { _ in }, toggleVoiceSample: { _, _ in },
            installInitialSystemVoiceSelection: install, confirmOpenAIDisclosureAndPreview: {}
        )
    }
}

@MainActor
private final class RecordingHotkeyRegistrar: HotkeyRegistering {
    private(set) var installCount = 0
    private(set) var registrations: [[HotkeyAction: HotkeySpec]] = []

    func install(_ callback: @escaping (HotkeyAction) -> Void) {
        _ = callback
        installCount += 1
    }

    func register(_ action: HotkeyAction, _ spec: HotkeySpec) -> Bool {
        _ = action
        _ = spec
        return true
    }

    func registerAll(_ specs: [HotkeyAction: HotkeySpec]) -> [HotkeyAction: Bool] {
        registrations.append(specs)
        return Dictionary(uniqueKeysWithValues: specs.keys.map { ($0, true) })
    }
}

private actor SettingsCredentialSource {
    private var envelope: CredentialEnvelope
    init(_ envelope: CredentialEnvelope) { self.envelope = envelope }
    func current() -> CredentialEnvelope { envelope }
    func install(_ envelope: CredentialEnvelope) { self.envelope = envelope }
}

private actor SettingsAccountEvidence {
    private var snapshots: [ProviderID: AccountCatalogSnapshot] = [:]
    func snapshot(for providerID: ProviderID) -> AccountCatalogSnapshot { snapshots[providerID] ?? .empty }
    func publish(_ snapshot: AccountCatalogSnapshot, for providerID: ProviderID) { snapshots[providerID] = snapshot }
    func revision(for providerID: ProviderID) -> UUID? {
        snapshots[providerID]?.relationshipEvidence.keys.first?.credentialRevision
    }
}

private actor SettingsCatalogBarrierHTTP: MiniMaxHTTPClient {
    private let first: MiniMaxHTTPResponse
    private let later: MiniMaxHTTPResponse
    private var requestCount = 0
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstResponseContinuation: CheckedContinuation<MiniMaxHTTPResponse, Never>?

    init(first: MiniMaxHTTPResponse, later: MiniMaxHTTPResponse) {
        self.first = first
        self.later = later
    }

    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        _ = request
        requestCount += 1
        guard requestCount == 1 else { return later }
        let waiters = firstRequestWaiters
        firstRequestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            firstResponseContinuation = continuation
        }
    }

    func waitUntilFirstRequestIsSuspended() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    func resumeFirstRequest() {
        firstResponseContinuation?.resume(returning: first)
        firstResponseContinuation = nil
    }
}

private actor SettingsRefreshPublicationBarrier {
    private let refreshes: [UUID: ProviderCatalogRefresh]
    private var entered: Set<UUID> = []
    private var entryWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(refreshes: [UUID: ProviderCatalogRefresh]) { self.refreshes = refreshes }

    func refresh(_ envelope: CredentialEnvelope) async -> ProviderCatalogRefresh? {
        entered.insert(envelope.revision)
        entryWaiters.removeValue(forKey: envelope.revision)?.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters[envelope.revision] = $0 }
        return refreshes[envelope.revision]
    }

    func waitUntilEntered(_ revision: UUID) async {
        guard !entered.contains(revision) else { return }
        await withCheckedContinuation { entryWaiters[revision, default: []].append($0) }
    }

    func release(_ revision: UUID) {
        releaseWaiters.removeValue(forKey: revision)?.resume()
    }
}

private actor SettingsRefreshStartBarrier {
    private let suspendedRevision: UUID
    private var suspended = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(suspendedRevision: UUID) {
        self.suspendedRevision = suspendedRevision
    }

    func suspendIfNeeded(_ revision: UUID) async {
        guard revision == suspendedRevision else { return }
        suspended = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SettingsEvidenceCommitBarrier {
    private var suspended = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SettingsPublicationTailBarrier {
    private var armedCount = 0
    private var nextID = 0
    private var suspended: Set<Int> = []
    private var entryWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func armNext(_ count: Int) { armedCount += count }

    func suspendIfArmed() async {
        guard armedCount > 0 else { return }
        armedCount -= 1
        nextID += 1
        let id = nextID
        suspended.insert(id)
        let waiters = entryWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuations[id] = $0 }
        suspended.remove(id)
    }

    func waitUntilSuspended(_ id: Int) async {
        guard !suspended.contains(id) else { return }
        await withCheckedContinuation { entryWaiters[id, default: []].append($0) }
    }

    func release(_ id: Int) {
        releaseContinuations.removeValue(forKey: id)?.resume()
    }
}

private actor SettingsFirstPublicationReturnBarrier {
    private var publicationCount = 0
    private var firstPublicationSuspended = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendFirstPublication() async {
        publicationCount += 1
        guard publicationCount == 1 else { return }
        firstPublicationSuspended = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilFirstPublicationIsSuspended() async {
        guard !firstPublicationSuspended else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseFirstPublication() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SettingsCatalogByCredentialHTTP: MiniMaxHTTPClient {
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        let key = request.value(forHTTPHeaderField: "Authorization")?
            .replacingOccurrences(of: "Bearer ", with: "") ?? "missing"
        return try settingsCatalogResponse(
            wireID: "\(key)-voice",
            displayName: key
        )
    }
}

private func settingsDescriptor(_ wireID: String) -> MiniMaxVoiceDescriptor {
    MiniMaxVoiceDescriptor(
        stableID: VoiceID(rawValue: "minimax.dynamic.\(wireID)"),
        wireID: wireID,
        displayName: wireID,
        kind: .cloned
    )
}

private func settingsCatalogResponse(wireID: String, displayName: String) throws -> MiniMaxHTTPResponse {
    let payload: [String: Any] = [
        "system_voice": [],
        "voice_cloning": [["voice_id": wireID, "voice_name": displayName]],
        "voice_generation": [],
        "base_resp": ["status_code": 0],
    ]
    return MiniMaxHTTPResponse(
        statusCode: 200,
        body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    )
}

private actor SettingsSystemVoiceRecorder {
    struct Snapshot: Equatable { let loads: Int; let installs: Int }
    let voices: [SystemVoiceDescriptor]
    private var loads = 0
    private var installs = 0
    init(voices: [SystemVoiceDescriptor]) { self.voices = voices }
    func load() -> [SystemVoiceDescriptor] { loads += 1; return voices }
    func install(_ voices: [SystemVoiceDescriptor]) { _ = voices; installs += 1 }
    func snapshot() -> Snapshot { Snapshot(loads: loads, installs: installs) }
}

private final class SettingsRecordingOnePasswordLauncher: @unchecked Sendable, OnePasswordLaunching {
    private let lock = NSLock()
    private let output: Data
    private var count = 0
    init(output: Data) { self.output = output }
    var readCount: Int { lock.withLock { count } }
    func read(executable: String, arguments: [String], environment: [String: String], stdout: OnePasswordOutputSink, stderr: OnePasswordErrorSink, timeout: Duration) async throws -> Data {
        _ = executable; _ = arguments; _ = environment; _ = stdout; _ = stderr; _ = timeout
        lock.withLock { count += 1 }
        return output
    }
}

private enum DisclosurePreparationInvalidation: CaseIterable { case stop, selection, defaultProvider, credential }

@MainActor
private struct OpenAIPreviewPreparationFixture {
    let engine: Engine
    let provider: PreviewEngineProvider
    let player: PreviewEnginePlayback
    let registry: CredentialScopeRegistry
    let authorizationBarrier: PreviewBarrierForEngine

    static func make() async throws -> OpenAIPreviewPreparationFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-openai-preparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(PrefsV1.defaults).write(to: root.appendingPathComponent("prefs.json"), options: .atomic)
        let provider = try PreviewEngineProvider(id: .openAI)
        let player = PreviewEnginePlayback()
        let registry = CredentialScopeRegistry()
        let authorizationBarrier = PreviewBarrierForEngine()
        let revision = UUID()
        let settings = ProviderSettingsStore.open(url: root.appendingPathComponent("prefs.json"))
        let disclosure = OpenAIDisclosureCoordinator(store: settings, beforeAuthorizationRead: { await authorizationBarrier.enterAndWait() })
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in .available(CredentialEnvelope(providerID: providerID, revision: revision, secret: Data("fake".utf8))) },
            accountSnapshot: { _ in .empty }
        )
        let operations = Store.Operations(dir: root, cacheDir: root, runtimeDir: root, read: { url in try? Data(contentsOf: url) }, write: { data, url in try data.write(to: url, options: .atomic) })
        let engine = Store.withOperations(operations) {
            Engine(
                player: player,
                speech: EngineSpeechDependencies(
                    cachePath: { _, _, _ in root.appendingPathComponent("unused.wav") }, cacheHit: { _ in false }, synthesize: { _, _, _, _ in }, concat: { _, _, _ in },
                    providerForID: { $0 == .openAI ? provider : nil }, captureCredential: { providerID in CredentialEnvelope(providerID: providerID, revision: revision, secret: Data("fake".utf8)) }
                ),
                credentialRegistry: registry, installCredentialHook: true,
                providerSettingsRuntimeLoader: loader, openAIDisclosureCoordinator: disclosure
            )
        }
        await engine.waitForInitialHydration()
        engine.providerSettingsState = try ProviderSettingsState.fixture(defaultProviderID: .openAI)
        let selection = engine.providerSettingsState.card(.openAI).selection!
        try await settings.persistOpenAIDisclosureAck(OpenAIDisclosureAck(policyVersion: OpenAIDisclosurePolicy.version, modelID: selection.modelID, voiceID: selection.voiceID!))
        await engine.installCredentialCancellationHook()
        return Self(engine: engine, provider: provider, player: player, registry: registry, authorizationBarrier: authorizationBarrier)
    }
}

private enum DisclosurePreviewFailure: CaseIterable, Sendable { case recovery, writeFailure }
private struct DisclosurePreviewWriteError: Error {}

private actor PreviewBarrierForEngine {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enterAndWait() async {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { enteredWaiter = $0 } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor PreviewEngineProvider: VoiceProvider {
    let id: ProviderID
    let capabilities: ProviderCapabilities
    private let barrier: PreviewBarrierForEngine?
    private(set) var synthesisCount = 0
    private var observedSplitSelections: [ProviderSelection] = []
    init(id: ProviderID = .macOS, barrier: PreviewBarrierForEngine? = nil) throws {
        self.id = id
        let version = ContractVersion(rawValue: "preview-engine-v1")
        capabilities = try ProviderCapabilities(
            inputLimits: [try InputLimit(endpoint: "fake", unit: .graphemes, maximum: 1000, safetyMargin: 0, contractVersion: version)],
            outputFormat: .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true), contractVersion: version
        )
        self.barrier = barrier
    }
    func measureInput(_ text: String, requestOverhead: RequestOverhead) async throws -> InputMeasurement { try await InputMeasurement.measure(text, limits: capabilities.inputLimits, requestOverhead: requestOverhead) }
    func split(_ text: String, selection: ProviderSelection) async throws -> [ValidatedSpeechChunk] {
        observedSplitSelections.append(selection)
        return try await ProviderInputSplitter(capabilities: capabilities).split(text)
    }
    func loadCatalog(using credential: ProviderCredential) async throws -> AccountCatalogSnapshot { .empty }
    func synthesize(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact {
        let expectedOutput: String
        switch id {
        case .minimax: expectedOutput = MiniMaxWireContractV1.outputFormatID
        case .openAI: expectedOutput = OpenAIWireContractV1.outputFormatID
        case .gemini: expectedOutput = GeminiWireContractV1.outputFormatID
        case .macOS: expectedOutput = SystemVoiceContractV1.outputFormatID
        default: throw InputValidationError.invalidFingerprintFields
        }
        guard request.outputFormatID == expectedOutput else { throw InputValidationError.invalidFingerprintFields }
        synthesisCount += 1
        if let barrier { await barrier.enterAndWait() }
        return OwnedNativeAudioArtifact(
            artifact: NativeAudioArtifact(url: URL(fileURLWithPath: "/tmp/engine-preview.pcm"), format: capabilities.outputFormat, purpose: .preview), cleanup: {}
        )
    }
    func count() -> Int { synthesisCount }
    func splitSelections() -> [ProviderSelection] { observedSplitSelections }
}

@MainActor
private final class PreviewEnginePlayback: EnginePlayback {
    var alive = false, paused = false
    var position = 0.0, duration = 0.0
    private(set) var playCount = 0, stopCount = 0, stopAndWaitCount = 0
    func play(file: URL, prefs: Prefs, streaming: Bool) throws { playCount += 1; alive = true }
    func append(file: URL) throws {}
    func finishStream(prefs: Prefs) {}
    func stop() { stopCount += 1; alive = false }
    func stopAndWait() async { stopAndWaitCount += 1 }
    func togglePause() { paused.toggle() }
    func seek(relative: Double) {}
    func setSpeed(_ speed: Double) {}
}

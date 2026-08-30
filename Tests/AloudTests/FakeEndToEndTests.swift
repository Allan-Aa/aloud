import Security
import XCTest
@testable import Aloud

@MainActor
final class FakeEndToEndTests: XCTestCase {
    func testCredentialExternalBoundariesAreReachedIndependentlyAndStopBeforeProviderWork() async throws {
        for boundary in [ExternalServiceName.keychainRead, .keychainUpdate, .keychainAdd, .keychainDelete, .onePassword] {
            let rig = try FakeReleaseRig(providerID: .minimax, armedBoundary: boundary)
            await rig.engine.waitForInitialHydration()
            switch boundary {
            case .keychainRead:
                break
            case .keychainUpdate, .keychainAdd:
                await XCTAssertThrowsAsync(try await rig.compositionRoot.credentialIngress.saveManual(providerID: .minimax, draft: runtimeCredentialDraft()))
            case .keychainDelete:
                _ = try await rig.credentials.save(providerID: .minimax, normalizedSecret: Data(runtimeCredentialDraft().utf8))
                await XCTAssertThrowsAsync(try await rig.credentials.delete(providerID: .minimax))
            case .onePassword:
                await XCTAssertThrowsAsync(try await rig.compositionRoot.credentialIngress.importMiniMaxFrom1Password())
            default:
                XCTFail("unexpected credential boundary")
            }
            XCTAssertEqual(rig.tripwire.calls, [boundary], boundary.rawValue)
            let catalogCount = await rig.catalogCount()
            let synthesisCount = await rig.synthesisCount()
            XCTAssertEqual(catalogCount, 0, boundary.rawValue)
            XCTAssertEqual(synthesisCount, 0, boundary.rawValue)
            XCTAssertEqual(rig.player.playCount, 0, boundary.rawValue)
            await rig.shutdown()
        }
    }

    func testProviderTransportBoundariesStopBeforePlaybackAndGeminiDisabledRouteCallsNothing() async throws {
        for (providerID, boundary) in [(ProviderID.minimax, ExternalServiceName.miniMaxHTTP), (.openAI, .openAIHTTP)] {
            let rig = try FakeReleaseRig(providerID: providerID, armedBoundary: boundary)
            await rig.engine.waitForInitialHydration()
            await rig.engine.installCredentialCancellationHook()
            _ = try await rig.compositionRoot.credentialIngress.saveManual(providerID: providerID, draft: runtimeCredentialDraft())
            rig.engine.providerSettingsState = try await rig.runtimeLoader.load(prefs: rig.prefs, recoveryMode: false)
            if providerID == .openAI { rig.engine.confirmOpenAIDisclosureAndPreview() }
            else { rig.engine.previewProvider(providerID) }
            try await rig.waitForTripwire(boundary)
            XCTAssertEqual(rig.tripwire.calls, [boundary])
            XCTAssertEqual(rig.player.playCount, 0)
            await rig.shutdown()
        }

        let gemini = try FakeReleaseRig(providerID: .gemini, armedBoundary: .geminiHTTP)
        await gemini.engine.waitForInitialHydration()
        await gemini.engine.installCredentialCancellationHook()
        _ = try await gemini.compositionRoot.credentialIngress.saveManual(providerID: .gemini, draft: runtimeCredentialDraft())
        gemini.engine.previewProvider(.gemini)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(gemini.tripwire.calls.isEmpty)
        let geminiSynthesisCount = await gemini.synthesisCount()
        XCTAssertEqual(geminiSynthesisCount, 0)
        XCTAssertEqual(gemini.player.playCount, 0)
        await gemini.shutdown()
    }

    func testSystemSpeechWAVAndPlayerBoundariesStopAtTheirInjectedSeams() async throws {
        for boundary in [ExternalServiceName.systemSpeechCatalog, .systemSpeechWrite, .player] {
            let rig = try FakeReleaseRig(providerID: .macOS, armedBoundary: boundary)
            await rig.engine.waitForInitialHydration()
            await rig.engine.installCredentialCancellationHook()
            rig.engine.providerSettingsState = try await rig.runtimeLoader.load(prefs: rig.prefs, recoveryMode: false)
            rig.engine.previewProvider(.macOS)
            try await rig.waitForTripwire(boundary)
            XCTAssertEqual(rig.tripwire.calls, [boundary])
            if boundary != .player { XCTAssertEqual(rig.player.playCount, 0) }
            await rig.shutdown()
        }

        let wav = try FakeReleaseRig(providerID: .minimax, armedBoundary: .wavProcess)
        await wav.engine.waitForInitialHydration()
        await wav.engine.installCredentialCancellationHook()
        _ = try await wav.compositionRoot.credentialIngress.saveManual(providerID: .minimax, draft: runtimeCredentialDraft())
        wav.engine.providerSettingsState = try await wav.runtimeLoader.load(prefs: wav.prefs, recoveryMode: false)
        wav.engine.previewProvider(.minimax)
        try await wav.waitForTripwire(.wavProcess)
        XCTAssertEqual(wav.tripwire.calls, [.wavProcess])
        XCTAssertEqual(wav.player.playCount, 0)
        await wav.shutdown()
    }

    func testProductionCompositionUsesHydratedFFmpegPathForPreviewCanonicalization() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax)
        await rig.engine.waitForInitialHydration()
        await rig.engine.installCredentialCancellationHook()
        _ = try await rig.compositionRoot.credentialIngress.saveManual(providerID: .minimax, draft: runtimeCredentialDraft())
        rig.engine.providerSettingsState = try await rig.runtimeLoader.load(prefs: rig.prefs, recoveryMode: false)

        rig.engine.previewProvider(.minimax)
        try await rig.waitForPlayback(count: 1)

        XCTAssertEqual(rig.wavInvocations.executablePaths, ["/fixture/ffmpeg"])
        await rig.shutdown()
    }

    func testAccountCatalogBoundaryIsReachedDuringHydrationBeforeSynthesis() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax, armedBoundary: .accountCatalog)
        await rig.engine.waitForInitialHydration()
        try await rig.waitForTripwire(.accountCatalog)
        XCTAssertEqual(rig.tripwire.calls, [.accountCatalog])
        let catalogCount = await rig.catalogCount()
        let synthesisCount = await rig.synthesisCount()
        XCTAssertEqual(catalogCount, 0)
        XCTAssertEqual(synthesisCount, 0)
        XCTAssertEqual(rig.player.playCount, 0)
        await rig.shutdown()
    }

    func testStorePasteboardScreenshotClockAndDiagnosticsReachOnlyTheirInjectedBoundary() async throws {
        let storeRead = try FakeReleaseRig(providerID: .macOS, armedBoundary: .storeRead)
        await storeRead.engine.waitForInitialHydration()
        try await storeRead.waitForTripwire(.storeRead)
        XCTAssertEqual(storeRead.tripwire.calls, [.storeRead])
        await storeRead.shutdown()

        let storeWrite = try FakeReleaseRig(providerID: .macOS, armedBoundary: .storeWrite)
        Store.withOperations(storeWrite.operations) {
            storeWrite.engine.rules = [.init(find: runtimeText(), replace: runtimeText(), enabled: true)]
        }
        try await storeWrite.waitForTripwire(.storeWrite)
        XCTAssertEqual(storeWrite.tripwire.calls, [.storeWrite])
        await storeWrite.shutdown()

        for boundary in [ExternalServiceName.systemPasteboard, .screenshot, .clock, .diagnostics] {
            let rig = try FakeReleaseRig(providerID: .macOS, armedBoundary: boundary)
            switch boundary {
            case .systemPasteboard:
                _ = rig.compositionRoot.pasteboard.readString()
            case .screenshot:
                XCTAssertThrowsError(try rig.compositionRoot.screenshot.export(rig.root))
            case .clock:
                _ = rig.compositionRoot.clock.now()
            case .diagnostics:
                rig.compositionRoot.diagnostics.record(.providerFailure(providerID: .macOS, code: .recoverableFailure))
            default:
                XCTFail("unexpected root utility boundary")
            }
            XCTAssertEqual(rig.tripwire.calls, [boundary])
            await rig.shutdown()
        }
    }

    func testForbiddenLoginAndSessionBoundariesStayUnreachableFromBuiltFakeGraph() async throws {
        for boundary in [ExternalServiceName.browserLogin, .cliLogin, .chatGPTSession, .geminiSession] {
            let rig = try FakeReleaseRig(providerID: .macOS, armedBoundary: boundary)
            await rig.engine.waitForInitialHydration()
            await rig.engine.installCredentialCancellationHook()
            rig.engine.providerSettingsState = try await rig.runtimeLoader.load(prefs: rig.prefs, recoveryMode: false)
            rig.engine.previewProvider(.macOS)
            try await rig.waitForPlayback(count: 1)
            XCTAssertTrue(rig.tripwire.calls.isEmpty, boundary.rawValue)
            await rig.shutdown()
        }
    }

    func testProductionCompositionRootOwnsOneEngineAndLastAudioGraph() {
        XCTAssertNoThrow(try FakeReleaseRig(providerID: .macOS))
    }

    func testBuiltGraphHydratesMiniMaxCatalogThroughInjectedCredentialAndHTTPExactlyOnce() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax)
        await rig.engine.waitForInitialHydration()
        _ = try await rig.credentials.save(
            providerID: .minimax,
            normalizedSecret: Data("assembled-graph-only".utf8)
        )

        let reloaded = await rig.engine.reloadProviderSettingsState()
        let requests = await rig.transports.miniMax.requestSnapshot()

        XCTAssertTrue(reloaded)
        XCTAssertEqual(requests.catalog, 1)
        XCTAssertEqual(requests.synthesis, 0)
        XCTAssertTrue(requests.usedAssembledGraphCredential)
        XCTAssertTrue(rig.engine.providerSettingsState.card(.minimax).availableVoices.contains {
            $0.wireID == "assembled-cloned-voice"
        })
        XCTAssertTrue(rig.tripwire.calls.isEmpty)
        await rig.shutdown()
    }

    func testBuiltGraphKeepsPreviousMiniMaxCatalogAndCurrentRevisionVoicesWhenRefreshFails() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax)
        await rig.engine.waitForInitialHydration()
        _ = try await rig.credentials.save(
            providerID: .minimax,
            normalizedSecret: Data("assembled-graph-only".utf8)
        )
        let initialReload = await rig.engine.reloadProviderSettingsState()
        XCTAssertTrue(initialReload)
        let beforeFailure = rig.engine.providerSettingsState.card(.minimax)
        await rig.transports.miniMax.setCatalogFailure(true)

        let failedReload = await rig.engine.reloadProviderSettingsState()
        XCTAssertTrue(failedReload)
        let afterFailure = rig.engine.providerSettingsState.card(.minimax)
        let requests = await rig.transports.miniMax.requestSnapshot()

        XCTAssertEqual(afterFailure.configuration, .configured)
        XCTAssertEqual(afterFailure.accountCoverage, beforeFailure.accountCoverage)
        XCTAssertEqual(afterFailure.availableVoices, beforeFailure.availableVoices)
        XCTAssertTrue(afterFailure.availableVoices.contains { $0.wireID == "assembled-cloned-voice" })
        XCTAssertEqual(requests.catalog, 2)
        XCTAssertEqual(requests.synthesis, 0)
        XCTAssertTrue(rig.tripwire.calls.isEmpty)
        await rig.shutdown()
    }

    func testBuiltGraphRejectsMiniMaxCatalogCredentialsAndBlocksPreviewBeforeSynthesis() async throws {
        for rejection in [E2EMiniMaxCatalogRejection.http401, .baseCode1004] {
            let rig = try FakeReleaseRig(providerID: .minimax)
            await rig.engine.waitForInitialHydration()
            _ = try await rig.credentials.save(
                providerID: .minimax,
                normalizedSecret: Data("rejected-catalog".utf8)
            )
            await rig.transports.miniMax.rejectCatalog(
                credential: "rejected-catalog", as: rejection
            )

            let didReload = await rig.engine.reloadProviderSettingsState()
            let card = rig.engine.providerSettingsState.card(.minimax)

            XCTAssertTrue(didReload)
            XCTAssertEqual(card.configuration, .configured)
            XCTAssertEqual(card.health, .explicitRejected)
            XCTAssertEqual(card.selection, rig.prefs.selections[.minimax])
            XCTAssertFalse(ProviderSettingsPersistenceGate.canSynthesize(card))
            rig.engine.previewProvider(.minimax)
            XCTAssertEqual(rig.engine.toast, "当前服务商尚不可试听")
            await rig.engine.shutdownSpeech()
            let requests = await rig.transports.miniMax.requestSnapshot()
            XCTAssertEqual(requests.catalog, 1)
            XCTAssertEqual(requests.synthesis, 0)
            XCTAssertEqual(rig.player.playCount, 0)
            await rig.shutdown()
        }
    }

    func testOlderMiniMaxCredentialRejectionCannotOverrideNewerSuccessfulCatalog() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax)
        await rig.engine.waitForInitialHydration()
        let envelopeA = try await rig.credentials.save(
            providerID: .minimax,
            normalizedSecret: Data("rejected-old".utf8)
        )
        await rig.transports.miniMax.rejectCatalog(
            credential: "rejected-old", as: .http401
        )
        await rig.transports.miniMax.suspendNextCatalogRequest()
        let loadA = Task { await rig.engine.reloadProviderSettingsState() }
        await rig.transports.miniMax.waitUntilCatalogRequestIsSuspended()

        let envelopeB = try await rig.credentials.save(
            providerID: .minimax,
            normalizedSecret: Data("accepted-new".utf8)
        )
        let didPublishB = await rig.engine.reloadProviderSettingsState()
        await rig.transports.miniMax.resumeCatalogRequest()
        let didPublishA = await loadA.value
        let card = rig.engine.providerSettingsState.card(.minimax)
        let evidence = await rig.evidenceStore.snapshot(for: .minimax)
        let requests = await rig.transports.miniMax.requestSnapshot()

        XCTAssertTrue(didPublishB)
        XCTAssertFalse(didPublishA)
        XCTAssertNotEqual(card.health, .explicitRejected)
        XCTAssertTrue(card.availableVoices.contains { $0.wireID == "accepted-new-voice" })
        XCTAssertTrue(evidence.relationshipEvidence.keys.contains {
            $0.credentialRevision == envelopeB.revision
        })
        XCTAssertFalse(evidence.relationshipEvidence.keys.contains {
            $0.credentialRevision == envelopeA.revision
        })
        XCTAssertEqual(requests.catalog, 2)
        XCTAssertEqual(requests.synthesis, 0)
        await rig.shutdown()
    }

    func testCancelledBuiltGraphHydrationDoesNotInstallStateOrPublishEvidence() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax)
        await rig.engine.waitForInitialHydration()
        let envelope = try await rig.credentials.save(
            providerID: .minimax,
            normalizedSecret: Data("cancelled-assembled-graph".utf8)
        )
        let stateBeforeRefresh = rig.engine.providerSettingsState
        await rig.transports.miniMax.suspendNextCatalogRequest()
        let reload = Task { await rig.engine.reloadProviderSettingsState() }
        await rig.transports.miniMax.waitUntilCatalogRequestIsSuspended()

        reload.cancel()
        await rig.transports.miniMax.resumeCatalogRequest()
        let didReload = await reload.value
        let evidence = await rig.evidenceStore.snapshot(for: .minimax)

        XCTAssertFalse(didReload)
        XCTAssertEqual(rig.engine.providerSettingsState, stateBeforeRefresh)
        XCTAssertFalse(evidence.relationshipEvidence.keys.contains {
            $0.credentialRevision == envelope.revision
        })
        await rig.shutdown()
    }

    func testOlderCatalogCannotPublishEvidenceAfterNewerCatalogCommitsAndPublishes() async throws {
        let evidenceBarrier = E2EEvidencePublicationBarrier()
        let rig = try FakeReleaseRig(
            providerID: .minimax,
            evidencePublicationBarrier: evidenceBarrier
        )
        await rig.engine.waitForInitialHydration()
        let envelopeA = try await rig.credentials.save(
            providerID: .minimax,
            normalizedSecret: Data("evidence-a".utf8)
        )
        let loadA = Task { await rig.engine.reloadProviderSettingsState() }
        await evidenceBarrier.waitUntilFirstPublishIsSuspended()

        let envelopeB = try await rig.credentials.save(
            providerID: .minimax,
            normalizedSecret: Data("evidence-b".utf8)
        )
        let didPublishB = await rig.engine.reloadProviderSettingsState()
        await evidenceBarrier.resumeFirstPublish()
        let didPublishA = await loadA.value
        let evidence = await rig.evidenceStore.snapshot(for: .minimax)

        XCTAssertTrue(didPublishB)
        XCTAssertFalse(didPublishA)
        XCTAssertTrue(rig.engine.providerSettingsState.card(.minimax).availableVoices.contains {
            $0.wireID == "evidence-b-voice"
        })
        XCTAssertFalse(rig.engine.providerSettingsState.card(.minimax).availableVoices.contains {
            $0.wireID == "evidence-a-voice"
        })
        XCTAssertTrue(evidence.relationshipEvidence.keys.contains {
            $0.credentialRevision == envelopeB.revision
        })
        XCTAssertFalse(evidence.relationshipEvidence.keys.contains {
            $0.credentialRevision == envelopeA.revision
        })
        await rig.shutdown()
    }

    func testCancellationAfterCatalogCommitCannotPublishEvidenceOrState() async throws {
        let evidenceBarrier = E2EEvidencePublicationBarrier()
        let rig = try FakeReleaseRig(
            providerID: .minimax,
            evidencePublicationBarrier: evidenceBarrier
        )
        await rig.engine.waitForInitialHydration()
        let envelope = try await rig.credentials.save(
            providerID: .minimax,
            normalizedSecret: Data("cancel-after-commit".utf8)
        )
        let stateBeforeRefresh = rig.engine.providerSettingsState
        let reload = Task { await rig.engine.reloadProviderSettingsState() }
        await evidenceBarrier.waitUntilFirstPublishIsSuspended()

        reload.cancel()
        await evidenceBarrier.resumeFirstPublish()
        let didReload = await reload.value
        let evidence = await rig.evidenceStore.snapshot(for: .minimax)

        XCTAssertFalse(didReload)
        XCTAssertEqual(rig.engine.providerSettingsState, stateBeforeRefresh)
        XCTAssertFalse(evidence.relationshipEvidence.keys.contains {
            $0.credentialRevision == envelope.revision
        })
        await rig.shutdown()
    }

    func testMiniMaxManualSaveRestartPreviewSpeakCanonicalPlaybackHistoryAndExport() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax)
        await rig.engine.waitForInitialHydration()
        await rig.engine.installCredentialCancellationHook()
        let ingress = CredentialIngress(store: rig.credentials)
        let envelope = try await ingress.saveManual(providerID: .minimax, draft: runtimeCredentialDraft())
        let restarted = try await rig.runtimeLoader.load(prefs: rig.prefs, recoveryMode: false)
        XCTAssertEqual(restarted.card(.minimax).configuration, .configured)
        XCTAssertEqual(restarted.card(.minimax).health, .unknown)
        rig.engine.providerSettingsState = restarted

        rig.engine.previewProvider(.minimax)
        try await rig.waitForSynthesis(count: 1)
        try await rig.waitForPlayback(count: 1)
        XCTAssertEqual(rig.player.playCount, 1)

        rig.engine.text = runtimeText()
        rig.engine.speak()
        try await rig.waitForHistory(count: 1)
        XCTAssertEqual(rig.engine.history.first?.providerID, .minimax)
        XCTAssertEqual(rig.engine.history.first?.modelID, rig.prefs.selections[.minimax]?.modelID)
        XCTAssertGreaterThanOrEqual(rig.player.playCount, 2)
        let currentArtifact = await rig.lastAudio.currentArtifact()
        let retained = try XCTUnwrap(currentArtifact)
        XCTAssertEqual(try Data(contentsOf: retained.url).prefix(4), Data("RIFF".utf8))
        XCTAssertTrue(retained.isCanonical)

        let destination = rig.root.appendingPathComponent("export.wav")
        let exported = try await AudioExporter.saveAudio(from: rig.lastAudio, to: destination)
        XCTAssertEqual(try Data(contentsOf: exported.url).prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(envelope.providerID, .minimax)
        XCTAssertTrue(rig.tripwire.calls.isEmpty)
        await rig.shutdown()
    }

    func testMiniMaxOnePasswordRouteFailureThenManualRecovery() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax)
        await rig.engine.waitForInitialHydration()
        let launcher = E2EOnePasswordLauncher(error: .nonZeroExit)
        let failed = CredentialIngress(
            store: rig.credentials,
            onePassword: OnePasswordPipeClient(
                launcher: launcher,
                environment: [:], executableResolver: { "/fake/op" }
            )
        )
        await XCTAssertThrowsAsync(try await failed.importMiniMaxFrom1Password())
        XCTAssertEqual(launcher.timeout, .seconds(30))
        let missing = try await rig.credentials.read(providerID: .minimax)
        XCTAssertEqual(missing, .missing)
        _ = try await CredentialIngress(store: rig.credentials).saveManual(providerID: .minimax, draft: runtimeCredentialDraft())
        guard case .available = try await rig.credentials.read(providerID: .minimax) else { return XCTFail("manual recovery was not durable") }
        XCTAssertTrue(rig.tripwire.calls.isEmpty)
        await rig.shutdown()
    }

    func testSameBuilderRouteHitsInjectedNetworkTripwireInsteadOfAnyLiveAdapter() async throws {
        let rig = try FakeReleaseRig(providerID: .minimax, armedBoundary: .miniMaxHTTP)
        await rig.engine.waitForInitialHydration()
        await rig.engine.installCredentialCancellationHook()
        _ = try await rig.compositionRoot.credentialIngress.saveManual(providerID: .minimax, draft: runtimeCredentialDraft())
        rig.engine.providerSettingsState = try await rig.runtimeLoader.load(prefs: rig.prefs, recoveryMode: false)
        rig.engine.previewProvider(.minimax)
        for _ in 0..<1_000 {
            if rig.tripwire.calls.contains(.miniMaxHTTP) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(rig.tripwire.calls, [.miniMaxHTTP])
        XCTAssertEqual(rig.player.playCount, 0)
        await rig.shutdown()
    }

    func testOpenAIFirstSpeakBlocksUntilExactDisclosureIsPersisted() async throws {
        let rig = try FakeReleaseRig(providerID: .openAI)
        await rig.engine.waitForInitialHydration()
        await rig.engine.installCredentialCancellationHook()
        _ = try await CredentialIngress(store: rig.credentials).saveManual(providerID: .openAI, draft: runtimeCredentialDraft())
        rig.engine.providerSettingsState = try await rig.runtimeLoader.load(prefs: rig.prefs, recoveryMode: false)
        rig.engine.text = runtimeText()
        rig.engine.speak()
        try await Task.sleep(for: .milliseconds(30))
        let beforeDisclosure = await rig.synthesisCount()
        XCTAssertEqual(beforeDisclosure, 0)
        XCTAssertTrue(rig.engine.providerSettingsState.card(.openAI).actions.contains(.confirmDisclosure))

        rig.engine.confirmOpenAIDisclosureAndPreview()
        try await rig.waitForSynthesis(count: 1)
        rig.engine.speak()
        try await rig.waitForHistory(count: 1)
        XCTAssertEqual(rig.engine.history.first?.providerID, .openAI)
        let invalidKey = OpenAIErrorClassifier.classify(
            status: 401,
            body: try JSONSerialization.data(withJSONObject: ["error": ["code": "invalid_api_key"]]),
            retryAfter: nil
        )
        let unknownRate = OpenAIErrorClassifier.classify(status: 429, body: Data(), retryAfter: nil)
        XCTAssertEqual(invalidKey.category, .credentialRejected)
        XCTAssertTrue(invalidKey.shouldRejectCredential)
        XCTAssertEqual(unknownRate.category, .rateOrQuotaUnknown)
        XCTAssertFalse(unknownRate.shouldRejectCredential)
        XCTAssertTrue(rig.tripwire.calls.isEmpty)
        await rig.shutdown()
    }

    func testGeminiFlagOffIsDisplayedExperimentalAndExcludedFromReleaseTotals() throws {
        let state = try ProviderSettingsState.build(
            prefs: .defaults,
            credentialConfigurations: [.gemini: .configured, .macOS: .configured],
            health: [:], recoveryMode: false
        )
        let gemini = state.card(.gemini)
        XCTAssertEqual(gemini.availability.kind, .experimental)
        XCTAssertEqual(gemini.availability.featureFlagEnabled, false)
        XCTAssertEqual(FakeReleaseAccounting.countedProviderIDs(from: state), [.minimax, .openAI, .macOS])
    }

    func testMacOSCredentialNotApplicableRestartDefaultPreviewAndSpeak() async throws {
        let rig = try FakeReleaseRig(providerID: .macOS)
        await rig.engine.waitForInitialHydration()
        await rig.engine.installCredentialCancellationHook()
        let restarted = try await rig.runtimeLoader.load(prefs: rig.prefs, recoveryMode: false)
        XCTAssertEqual(restarted.card(.macOS).configuration, .configured)
        XCTAssertEqual(restarted.card(.macOS).saveCapability, .notApplicable)
        XCTAssertTrue(restarted.card(.macOS).isDefault)
        rig.engine.providerSettingsState = restarted
        rig.engine.previewProvider(.macOS)
        try await rig.waitForSynthesis(count: 1)
        try await rig.waitForPlayback(count: 1)
        rig.engine.text = runtimeText()
        rig.engine.speak()
        try await rig.waitForHistory(count: 1)
        XCTAssertEqual(rig.engine.history.first?.providerID, .macOS)
        XCTAssertTrue(rig.tripwire.calls.isEmpty)
        await rig.shutdown()
    }

    func testTwoFakeAppGraphsDoNotLeakHistoryLastAudioOrProviderCalls() async throws {
        let first = try FakeReleaseRig(providerID: .macOS)
        let second = try FakeReleaseRig(providerID: .macOS)
        await first.engine.waitForInitialHydration()
        await second.engine.waitForInitialHydration()
        await first.engine.installCredentialCancellationHook()
        await second.engine.installCredentialCancellationHook()
        first.engine.providerSettingsState = try await first.runtimeLoader.load(prefs: first.prefs, recoveryMode: false)
        second.engine.providerSettingsState = try await second.runtimeLoader.load(prefs: second.prefs, recoveryMode: false)
        first.engine.text = runtimeText()
        first.engine.speak()
        try await first.waitForHistory(count: 1)
        XCTAssertEqual(second.engine.history.count, 0)
        let secondCount = await second.synthesisCount()
        let secondArtifact = await second.lastAudio.currentArtifact()
        XCTAssertEqual(secondCount, 0)
        XCTAssertNil(secondArtifact)
        await first.shutdown()
        await second.shutdown()
    }
}

enum FakeReleaseAccounting {
    static func countedProviderIDs(from state: ProviderSettingsState) -> Set<ProviderID> {
        Set(state.cards.compactMap { card in
            card.id == .gemini && card.availability.featureFlagEnabled != true ? nil : card.id
        })
    }
}

@MainActor
private final class FakeReleaseRig {
    let root: URL
    let tripwire = ExternalServiceTripwire()
    let credentials: CredentialStore
    let runtimeLoader: ProviderSettingsRuntimeLoader
    let evidenceStore: ProviderAccountEvidenceStore
    let transports: E2ETransportBundle
    let player: E2EPlayback
    let lastAudio = LastAudioArtifactStore()
    let wavInvocations = E2EWAVInvocationRecorder()
    let compositionRoot: AppCompositionRoot
    let operations: Store.Operations
    var engine: Engine { compositionRoot.engine }
    let prefs: PrefsV1

    init(
        providerID: ProviderID,
        armedBoundary: ExternalServiceName? = nil,
        evidencePublicationBarrier: E2EEvidencePublicationBarrier? = nil
    ) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-fake-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = root
        let keychain = E2EKeychain(tripwire: tripwire, armedBoundary: armedBoundary)
        credentials = CredentialStore(keychain: keychain, invalidator: .noop, gate: CredentialNamespaceGate())
        evidenceStore = ProviderAccountEvidenceStore(
            afterPublish: { await evidencePublicationBarrier?.afterPublish() }
        )
        transports = E2ETransportBundle(directory: root, tripwire: tripwire, armedBoundary: armedBoundary)
        player = E2EPlayback(tripwire: tripwire, armedBoundary: armedBoundary)
        var configuredPrefs = PrefsV1.defaults
        configuredPrefs.ffmpegBin = "/fixture/ffmpeg"
        configuredPrefs.defaultProviderID = providerID
        if providerID == .minimax {
            configuredPrefs.selections[.minimax] = .init(providerID: .minimax, modelID: MiniMaxWireContractV1.modelID, voiceID: VoiceID(rawValue: "minimax.radio-host.default"), rate: NormalizedRate(version: MiniMaxRateMappingV1.version, value: 0)!)
        } else if providerID == .openAI {
            configuredPrefs.selections[.openAI] = .init(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"), rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!)
        } else if providerID == .macOS {
            configuredPrefs.selections[.macOS] = .init(providerID: .macOS, modelID: SystemVoiceContractV1.modelID, voiceID: VoiceID(rawValue: "macos.fake"), rate: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: 0)!)
        }
        prefs = configuredPrefs
        try JSONEncoder().encode(configuredPrefs).write(to: root.appendingPathComponent("prefs.json"), options: .atomic)
        let credentialsRef = credentials
        let evidenceStoreRef = evidenceStore
        runtimeLoader = ProviderSettingsRuntimeLoader(
            readCredential: { (try? await credentialsRef.read(providerID: $0)) ?? .blocked(.keychainReadFailed) },
            accountSnapshot: { _ in .empty }
        )
        let runtimeLoaderRef = runtimeLoader
        let lastAudioRef = lastAudio
        let playerRef = player
        let tripwireRef = tripwire
        operations = Store.Operations(
            dir: root, cacheDir: root.appendingPathComponent("cache"), runtimeDir: root,
            read: { url in
                if armedBoundary == .storeRead { tripwireRef.record(.storeRead); return nil }
                return try? Data(contentsOf: url)
            },
            write: { data, url in
                if armedBoundary == .storeWrite { try tripwireRef.call(.storeWrite) }
                try data.write(to: url, options: .atomic)
            }
        )
        try FileManager.default.createDirectory(at: operations.cacheDir, withIntermediateDirectories: true)
        _ = (credentialsRef, runtimeLoaderRef, rootURL)
        let transportRef = transports
        let dependencies = AppCompositionDependencies(
            credentialStore: credentials,
            accountEvidenceStore: evidenceStoreRef,
            onePassword: OnePasswordPipeClient(launcher: E2EOnePasswordLauncher(error: .nonZeroExit, tripwire: tripwire, armedBoundary: armedBoundary), environment: [:], executableResolver: { "/dependency/op" }),
            miniMaxHTTP: transportRef.miniMax, openAIHTTP: transportRef.openAI,
            geminiHTTP: transportRef.gemini, systemSpeech: transportRef.systemSpeech,
            accountSnapshot: { providerID in
                if armedBoundary == .accountCatalog { tripwireRef.record(.accountCatalog) }
                return await evidenceStoreRef.snapshot(for: providerID)
            }, player: playerRef,
            wavProcessDriver: E2EWAVProcessDriver(
                tripwire: tripwire, armedBoundary: armedBoundary, invocations: wavInvocations
            ), storeOperations: operations,
            pasteboard: .init(
                readString: {
                    if armedBoundary == .systemPasteboard { tripwireRef.record(.systemPasteboard) }
                    return nil
                },
                copyString: { _ in
                    if armedBoundary == .systemPasteboard { tripwireRef.record(.systemPasteboard) }
                }
            ),
            screenshot: .init(export: { _ in
                if armedBoundary == .screenshot { try tripwireRef.call(.screenshot) }
            }),
            clock: .init(now: {
                if armedBoundary == .clock { tripwireRef.record(.clock) }
                return Date(timeIntervalSince1970: 1_700_000_000)
            }),
            diagnostics: .init(record: { _ in
                if armedBoundary == .diagnostics { tripwireRef.record(.diagnostics) }
            }),
            lastAudioStore: lastAudioRef, credentialRegistry: CredentialScopeRegistry()
        )
        compositionRoot = try AppCompositionRoot.build(dependencies: dependencies)
        XCTAssertTrue(compositionRoot.lastAudioStore === lastAudioRef)
    }

    func waitForSynthesis(count: Int) async throws {
        for _ in 0..<500 {
            if await synthesisCount() >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        let stages = await transports.systemSpeech.stages()
        XCTFail("fake synthesis did not reach \(count); toast=\(engine.toast ?? "nil") phase=\(engine.phase) health=\(engine.providerSettingsState.cards.map { ($0.id.rawValue, $0.health) }) system=\(stages)")
    }

    func catalogCount() async -> Int { await transports.catalogCount() }

    func synthesisCount() async -> Int { await transports.synthesisCount() }

    func waitForHistory(count: Int) async throws {
        for _ in 0..<1_000 {
            if engine.history.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        let systemStages = await transports.systemSpeech.stages()
        XCTFail("history did not reach \(count); phase=\(engine.phase); toast=\(engine.toast ?? "nil") system=\(systemStages)")
    }

    func waitForPlayback(count: Int) async throws {
        for _ in 0..<1_000 {
            if player.playCount >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("playback did not reach \(count); toast=\(engine.toast ?? "nil")")
    }

    func waitForTripwire(_ boundary: ExternalServiceName) async throws {
        for _ in 0..<1_000 {
            if tripwire.calls.contains(boundary) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("tripwire did not reach \(boundary.rawValue)")
    }

    func shutdown() async {
        await engine.shutdownSpeech()
        _ = await lastAudio.beginShutdown()
        _ = await lastAudio.commitShutdownIfDrained()
    }
}

private final class E2ETransportBundle: @unchecked Sendable {
    let miniMax: E2EMiniMaxHTTP
    let openAI: E2EOpenAIHTTP
    let gemini: E2EGeminiHTTP
    let systemSpeech: E2ESystemSpeech
    init(directory: URL, tripwire: ExternalServiceTripwire, armedBoundary: ExternalServiceName?) {
        miniMax = E2EMiniMaxHTTP(tripwire: tripwire, armedBoundary: armedBoundary)
        openAI = E2EOpenAIHTTP(tripwire: tripwire, armedBoundary: armedBoundary)
        gemini = E2EGeminiHTTP(tripwire: tripwire, armedBoundary: armedBoundary)
        systemSpeech = E2ESystemSpeech(directory: directory, tripwire: tripwire, armedBoundary: armedBoundary)
    }
    func catalogCount() async -> Int {
        await miniMax.requestSnapshot().catalog
    }

    func synthesisCount() async -> Int {
        let miniMaxCount = await miniMax.requestSnapshot().synthesis
        let openAICount = await openAI.synthesisRequestCount
        let systemSpeechCount = await systemSpeech.stages().write
        return miniMaxCount + openAICount + systemSpeechCount
    }
}

private actor E2EMiniMaxHTTP: MiniMaxHTTPClient {
    private(set) var catalogRequestCount = 0
    private(set) var synthesisRequestCount = 0
    private(set) var usedAssembledGraphCredential = false
    private var catalogFailure = false
    private var catalogRejections: [String: E2EMiniMaxCatalogRejection] = [:]
    private var suspendNextCatalog = false
    private var catalogRequestSuspended = false
    private var catalogSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var catalogResumeContinuation: CheckedContinuation<Void, Never>?
    private var tripwire: ExternalServiceTripwire?
    private let armedBoundary: ExternalServiceName?
    init(tripwire: ExternalServiceTripwire? = nil, armedBoundary: ExternalServiceName? = nil) {
        self.tripwire = tripwire; self.armedBoundary = armedBoundary
    }
    func requestSnapshot() -> (catalog: Int, synthesis: Int, usedAssembledGraphCredential: Bool) {
        (catalogRequestCount, synthesisRequestCount, usedAssembledGraphCredential)
    }
    func setCatalogFailure(_ enabled: Bool) { catalogFailure = enabled }
    func rejectCatalog(credential: String, as rejection: E2EMiniMaxCatalogRejection) {
        catalogRejections[credential] = rejection
    }
    func suspendNextCatalogRequest() { suspendNextCatalog = true }
    func waitUntilCatalogRequestIsSuspended() async {
        guard !catalogRequestSuspended else { return }
        await withCheckedContinuation { catalogSuspensionWaiters.append($0) }
    }
    func resumeCatalogRequest() {
        catalogResumeContinuation?.resume()
        catalogResumeContinuation = nil
    }
    func installTripwire(_ value: ExternalServiceTripwire) { tripwire = value }
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        if armedBoundary == .miniMaxHTTP, let tripwire { try tripwire.call(.miniMaxHTTP) }
        if request.url == MiniMaxVoiceManagementContractV1.endpoint {
            catalogRequestCount += 1
            if suspendNextCatalog {
                suspendNextCatalog = false
                catalogRequestSuspended = true
                let waiters = catalogSuspensionWaiters
                catalogSuspensionWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { catalogResumeContinuation = $0 }
                catalogRequestSuspended = false
            }
            if catalogFailure { throw MiniMaxProviderError.transport }
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            usedAssembledGraphCredential = authorization == "Bearer assembled-graph-only"
            let credential = authorization?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
            if let rejection = catalogRejections[credential] {
                switch rejection {
                case .http401:
                    return MiniMaxHTTPResponse(
                        statusCode: 401, body: Data("catalog-rejected".utf8)
                    )
                case .baseCode1004:
                    let payload: [String: Any] = ["base_resp": ["status_code": 1004]]
                    return MiniMaxHTTPResponse(
                        statusCode: 200,
                        body: try JSONSerialization.data(withJSONObject: payload)
                    )
                }
            }
            let wireID: String
            switch authorization {
            case "Bearer evidence-a": wireID = "evidence-a-voice"
            case "Bearer evidence-b": wireID = "evidence-b-voice"
            case "Bearer accepted-new": wireID = "accepted-new-voice"
            default: wireID = "assembled-cloned-voice"
            }
            let payload: [String: Any] = [
                "system_voice": [],
                "voice_cloning": [["voice_id": wireID, "voice_name": "Assembled Clone"]],
                "voice_generation": [],
                "base_resp": ["status_code": 0],
            ]
            return MiniMaxHTTPResponse(
                statusCode: 200,
                body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        }
        synthesisRequestCount += 1
        let payload: [String: Any] = [
            "data": ["audio": Data([1, 2, 3, 4]).map { String(format: "%02x", $0) }.joined()],
            "base_resp": ["status_code": 0],
        ]
        return MiniMaxHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: payload))
    }
}

private enum E2EMiniMaxCatalogRejection: Sendable {
    case http401
    case baseCode1004
}

private actor E2EEvidencePublicationBarrier {
    private var publishCount = 0
    private var firstPublishSuspended = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func afterPublish() async {
        publishCount += 1
        guard publishCount == 1 else { return }
        firstPublishSuspended = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
        firstPublishSuspended = false
    }

    func waitUntilFirstPublishIsSuspended() async {
        guard !firstPublishSuspended else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func resumeFirstPublish() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor E2EOpenAIHTTP: OpenAIHTTPClient {
    private(set) var synthesisRequestCount = 0
    private let tripwire: ExternalServiceTripwire?
    private let armedBoundary: ExternalServiceName?
    init(tripwire: ExternalServiceTripwire? = nil, armedBoundary: ExternalServiceName? = nil) {
        self.tripwire = tripwire; self.armedBoundary = armedBoundary
    }
    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse {
        synthesisRequestCount += 1
        if armedBoundary == .openAIHTTP, let tripwire { try tripwire.call(.openAIHTTP) }
        return OpenAIHTTPResponse(statusCode: 200, body: E2EWAV.make())
    }
}

private actor E2EGeminiHTTP: GeminiHTTPClient {
    private(set) var count = 0
    private let tripwire: ExternalServiceTripwire?
    private let armedBoundary: ExternalServiceName?
    init(tripwire: ExternalServiceTripwire? = nil, armedBoundary: ExternalServiceName? = nil) {
        self.tripwire = tripwire; self.armedBoundary = armedBoundary
    }
    func send(_ request: URLRequest) async throws -> GeminiHTTPResponse {
        count += 1
        if armedBoundary == .geminiHTTP, let tripwire { try tripwire.call(.geminiHTTP) }
        throw GeminiProviderError.releaseBlocked(.featureFlagDisabled)
    }
}

private actor E2ESystemSpeech: SystemSpeechSynthesizing {
    let directory: URL
    private(set) var count = 0
    private var catalogCount = 0
    private let tripwire: ExternalServiceTripwire?
    private let armedBoundary: ExternalServiceName?
    init(directory: URL, tripwire: ExternalServiceTripwire? = nil, armedBoundary: ExternalServiceName? = nil) {
        self.directory = directory; self.tripwire = tripwire; self.armedBoundary = armedBoundary
    }
    func installedVoices() async -> [SystemVoiceDescriptor] {
        catalogCount += 1
        if armedBoundary == .systemSpeechCatalog { tripwire?.record(.systemSpeechCatalog); return [] }
        return [.init(identifier: "fake", name: "fixture", language: "en-US")]
    }
    func write(_ request: SystemSpeechWriteRequest, to destination: URL) async throws -> NativeAudioFormat {
        count += 1
        if armedBoundary == .systemSpeechWrite, let tripwire { try tripwire.call(.systemSpeechWrite) }
        try E2EWAV.make().write(to: destination)
        return .encoded(container: "wav", codec: "pcm")
    }
    func stages() -> (catalog: Int, write: Int) { (catalogCount, count) }
}

private struct E2EWAVProcessDriver: WAVProcessDriver {
    let tripwire: ExternalServiceTripwire?
    let armedBoundary: ExternalServiceName?
    let invocations: E2EWAVInvocationRecorder?
    init(
        tripwire: ExternalServiceTripwire? = nil,
        armedBoundary: ExternalServiceName? = nil,
        invocations: E2EWAVInvocationRecorder? = nil
    ) {
        self.tripwire = tripwire; self.armedBoundary = armedBoundary; self.invocations = invocations
    }
    func launch(executableURL: URL, arguments: [String], terminated: @escaping @Sendable (Int32) -> Void) throws -> any WAVChildProcess {
        invocations?.record(executableURL.path)
        if armedBoundary == .wavProcess, let tripwire { try tripwire.call(.wavProcess) }
        guard let output = arguments.last else { throw WAVAudioError.processFailed(1) }
        try E2EWAV.make().write(to: URL(fileURLWithPath: output))
        let child = E2EWAVChild()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) {
            child.complete()
            terminated(0)
        }
        return child
    }
}

private final class E2EWAVInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var executablePaths: [String] { lock.withLock { paths } }
    func record(_ path: String) { lock.withLock { paths.append(path) } }
}

private final class E2EWAVChild: WAVChildProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    var isRunning: Bool { lock.withLock { running } }
    func complete() { lock.withLock { running = false } }
    func terminate() { complete() }
    func kill() throws { complete() }
    func waitForTermination(for deadline: Duration) async -> Bool {
        for _ in 0..<1_000 {
            if !isRunning { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private final class E2EKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]
    private let tripwire: ExternalServiceTripwire?
    private let armedBoundary: ExternalServiceName?
    init(tripwire: ExternalServiceTripwire? = nil, armedBoundary: ExternalServiceName? = nil) {
        self.tripwire = tripwire; self.armedBoundary = armedBoundary
    }
    private func isArmed(_ boundary: ExternalServiceName) -> Bool {
        guard armedBoundary == boundary else { return false }
        tripwire?.record(boundary)
        return true
    }
    func read(service: String, account: String) -> CredentialKeychainRead {
        if isArmed(.keychainRead) { return .failure(errSecInteractionNotAllowed) }
        return lock.withLock { values[account].map(CredentialKeychainRead.success) ?? .failure(errSecItemNotFound) }
    }
    func update(data: Data, service: String, account: String) -> OSStatus {
        if isArmed(.keychainUpdate) { return errSecInteractionNotAllowed }
        return lock.withLock { guard values[account] != nil else { return errSecItemNotFound }; values[account] = data; return errSecSuccess }
    }
    func add(data: Data, service: String, account: String) -> OSStatus {
        if isArmed(.keychainAdd) { return errSecInteractionNotAllowed }
        return lock.withLock { values[account] = data; return errSecSuccess }
    }
    func delete(service: String, account: String) -> OSStatus {
        if isArmed(.keychainDelete) { return errSecInteractionNotAllowed }
        return lock.withLock { values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess }
    }
}

private final class E2EOnePasswordLauncher: OnePasswordLaunching, @unchecked Sendable {
    let error: OnePasswordPipeError
    private(set) var timeout: Duration?
    private let tripwire: ExternalServiceTripwire?
    private let armedBoundary: ExternalServiceName?
    init(error: OnePasswordPipeError, tripwire: ExternalServiceTripwire? = nil, armedBoundary: ExternalServiceName? = nil) {
        self.error = error; self.tripwire = tripwire; self.armedBoundary = armedBoundary
    }
    func read(executable: String, arguments: [String], environment: [String : String], stdout: OnePasswordOutputSink, stderr: OnePasswordErrorSink, timeout: Duration) async throws -> Data {
        self.timeout = timeout
        if armedBoundary == .onePassword, let tripwire { try tripwire.call(.onePassword) }
        throw error
    }
}

@MainActor
private final class E2EPlayback: EnginePlayback, @unchecked Sendable {
    var alive = false; var paused = false; var position = 0.2; var duration = 0.01
    private(set) var playCount = 0
    private let tripwire: ExternalServiceTripwire?
    private let armedBoundary: ExternalServiceName?
    init(tripwire: ExternalServiceTripwire? = nil, armedBoundary: ExternalServiceName? = nil) {
        self.tripwire = tripwire; self.armedBoundary = armedBoundary
    }
    func play(file: URL, prefs: Prefs, streaming: Bool) throws {
        if armedBoundary == .player, let tripwire { try tripwire.call(.player) }
        _ = try WAVValidator.validate(file, purpose: .preview); alive = true; playCount += 1
    }
    func append(file: URL) throws {}; func finishStream(prefs: Prefs) {}; func stop() { alive = false }
    func togglePause() {}; func seek(relative: Double) {}; func setSpeed(_ speed: Double) {}
}

private enum E2EWAV {
    static func make() -> Data {
        let samples = Data(repeating: 0, count: 4_800)
        var fmt = Data(); fmt.appendLE(UInt16(1)); fmt.appendLE(UInt16(1)); fmt.appendLE(UInt32(48_000)); fmt.appendLE(UInt32(96_000)); fmt.appendLE(UInt16(2)); fmt.appendLE(UInt16(16))
        var chunks = chunk("fmt ", fmt); chunks.append(chunk("data", samples))
        var result = Data("RIFF".utf8); result.appendLE(UInt32(4 + chunks.count)); result.append(Data("WAVE".utf8)); result.append(chunks); return result
    }
    private static func chunk(_ id: String, _ payload: Data) -> Data { var result = Data(id.utf8); result.appendLE(UInt32(payload.count)); result.append(payload); return result }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) { append(UInt8(value & 0xff)); append(UInt8(value >> 8)) }
    mutating func appendLE(_ value: UInt32) { append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8((value >> 16) & 0xff)); append(UInt8(value >> 24)) }
}

private extension EngineSpeechDependencies {
    @MainActor static var unavailable: Self { .init(cachePath: { _, _, _ in URL(fileURLWithPath: "/unused") }, cacheHit: { _ in false }, synthesize: { _, _, _, _ in }, concat: { _, _, _ in }) }
}

private func runtimeCredentialDraft() -> String {
    " \(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\n"
}

private func runtimeText() -> String {
    String(repeating: Character(UnicodeScalar(120)!), count: 24)
}

private func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected error", file: file, line: line) } catch {}
}

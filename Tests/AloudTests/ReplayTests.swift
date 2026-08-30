import XCTest
@testable import Aloud

final class ReplayTests: XCTestCase {
    @MainActor
    func testReplayFixtureInitialHydrationUsesInjectedCredentialReader() async {
        let reads = ReplayCredentialReadProbe()
        let engine = ReplayFixture.engine(
            providerForID: { _ in nil },
            runtimeCredentialRead: { providerID in
                await reads.record(providerID)
                return .missing
            }
        )

        await engine.waitForInitialHydration()
        let providers = await reads.providers()

        XCTAssertEqual(providers, [.minimax, .openAI, .gemini])
    }

    @MainActor
    func testLoadedTextThenOrdinarySpeakUsesCurrentDefaultSelectionAndPreprocessing() async throws {
        let provider = ReplayProvider(id: .openAI)
        let revision = UUID()
        let selection = ProviderSelection(
            providerID: .openAI, modelID: ModelID(rawValue: "tts-1-hd"),
            voiceID: VoiceID(rawValue: "openai.nova"), rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 37)!
        )
        let disclosureURL = URL(fileURLWithPath: "/test/replay-speak-disclosure-\(UUID().uuidString).json")
        let disclosureFiles = RecordingAtomicFileStore(initial: [disclosureURL: try JSONEncoder().encode(PrefsV1.defaults)])
        let disclosure = OpenAIDisclosureCoordinator(store: ProviderSettingsStore.open(url: disclosureURL, files: disclosureFiles))
        _ = try await disclosure.confirm(modelID: selection.modelID, voiceID: try XCTUnwrap(selection.voiceID), explicitlyAccepted: true)
        let engine = ReplayFixture.engine(
            providerForID: { $0 == .openAI ? provider : nil },
            captureCredential: { id in CredentialEnvelope(providerID: id, revision: revision, secret: Data("fake".utf8)) },
            disclosure: disclosure
        )
        await engine.waitForInitialHydration()
        var state = try ProviderSettingsState.fixture(defaultProviderID: .openAI)
        let index = state.cards.firstIndex { $0.id == .openAI }!
        state.cards[index].selection = selection
        engine.providerSettingsState = state
        let loaded = HistoryEntry(
            id: UUID(), version: 1, text: "**THE FOX**", contentResolution: .valid, seconds: 1,
            providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"), voiceID: nil,
            rate: NormalizedRate(version: MiniMaxRateMappingV1.version, value: 0)!, displayLabelSnapshot: "legacy",
            selectionResolution: .unresolvedLegacyVoice, date: nil, legacyAgoSnapshot: nil
        )
        engine.loadHistory(loaded)
        await engine.installCredentialCancellationHook()
        engine.speak()
        for _ in 0..<200 {
            if !(await provider.requests).isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let recorded = await provider.requests
        let diagnosticToast = engine.toast ?? "nil"
        let diagnosticDefault = engine.providerSettingsState.cards.first(where: \.isDefault)?.id.rawValue ?? "nil"
        let diagnosticStages = await provider.stages
        XCTAssertFalse(recorded.isEmpty, "phase=\(engine.phase) toast=\(diagnosticToast) default=\(diagnosticDefault) stages=\(diagnosticStages)")
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.selection, selection)
        XCTAssertEqual(request.chunk.text, "the fox")
    }

    @MainActor
    func testFreshLegacyDefaultNormalizesOnlyRuntimeRequestAndDoesNotRewritePersistedPrefs() async throws {
        let provider = ReplayProvider(id: .minimax)
        let revision = UUID()
        let engine = ReplayFixture.engine(
            providerForID: { $0 == .minimax ? provider : nil },
            captureCredential: { id in CredentialEnvelope(providerID: id, revision: revision, secret: Data("fake".utf8)) }
        )
        await engine.installCredentialCancellationHook()
        let persistedBefore = await engine.persistedProviderPrefsForTesting()
        engine.text = "fresh default"
        engine.speak()
        for _ in 0..<100 {
            if await provider.requestCount > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let requests = await provider.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.selection.voiceID, VoiceID(rawValue: "minimax.radio-host.default"))
        XCTAssertEqual(request.selection.rate.version, MiniMaxRateMappingV1.version)
        let persistedAfter = await engine.persistedProviderPrefsForTesting()
        XCTAssertEqual(persistedAfter, persistedBefore)
    }

    @MainActor
    func testReadSelectionUsesCurrentDefaultMiniMaxIdentityInsteadOfLegacyBridge() async throws {
        let provider = ReplayProvider(id: .minimax)
        let revision = UUID()
        let selected = ProviderSelection(
            providerID: .minimax,
            modelID: MiniMaxWireContractV1.modelID,
            voiceID: VoiceID(rawValue: "minimax.radio-host.default"),
            rate: NormalizedRate(version: MiniMaxRateMappingV1.version, value: 15)!
        )
        let engine = ReplayFixture.engine(
            providerForID: { $0 == .minimax ? provider : nil },
            captureCredential: { id in
                CredentialEnvelope(providerID: id, revision: revision, secret: Data("fake".utf8))
            },
            readSelection: { "selected words" }
        )
        await engine.waitForInitialHydration()
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        state.cards[state.cards.firstIndex { $0.id == .minimax }!].selection = selected
        engine.providerSettingsState = state
        await engine.installCredentialCancellationHook()

        engine.readSelection()
        for _ in 0..<200 where await provider.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }

        let requests = await provider.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.selection, selected)
        XCTAssertEqual(request.chunk.text, "selected words")
    }

    func testResolvedHistoryUsesExactStoredSelectionAndNeverCurrentFallback() throws {
        let entry = try ReplayFixture.entry(providerID: .openAI, model: "tts-1-hd", voice: "openai.nova", rate: 37)
        let current = ProviderSelection(
            providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"),
            voiceID: VoiceID(rawValue: "minimax.radio-host.default"),
            rate: NormalizedRate(version: MiniMaxRateMappingV1.version, value: 0)!
        )
        let decision = ReplayDecision.evaluate(
            entry: entry, currentSelection: current,
            providerAvailable: true, credentialConfigured: true, storedSelectionValid: true
        )
        XCTAssertEqual(decision, .ready(selection: ProviderSelection(
            providerID: .openAI, modelID: ModelID(rawValue: "tts-1-hd"),
            voiceID: VoiceID(rawValue: "openai.nova"), rate: entry.rate
        ), billingProviderID: .openAI))
    }

    func testUnavailableCredentialOrInvalidSelectionBlocksWithoutFallback() throws {
        let entry = try ReplayFixture.entry(providerID: .openAI, model: "tts-1", voice: "openai.alloy", rate: 0)
        let cases: [(Bool, Bool, Bool, ReplayBlockReason)] = [
            (false, true, true, .providerUnavailable),
            (true, false, true, .credentialMissing),
            (true, true, false, .selectionInvalid),
        ]
        for (available, configured, valid, reason) in cases {
            XCTAssertEqual(
                ReplayDecision.evaluate(entry: entry, currentSelection: nil, providerAvailable: available, credentialConfigured: configured, storedSelectionValid: valid),
                .blocked(reason)
            )
        }
    }

    func testExactStoredIdentityKeepsFingerprintWhileAnyIdentityChangeRotatesIt() async throws {
        let provider = ReplayProvider(id: .openAI)
        let rate = NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!
        let original = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"), rate: rate)
        let chunks = try await provider.split("same replay text", selection: original)
        let chunk = try XCTUnwrap(chunks.first)
        func fingerprint(_ selection: ProviderSelection) throws -> RequestFingerprint {
            try SpeechRequest.make(
                id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk,
                controls: OpenAIRateMappingV1.controls(for: selection.rate), credentialScopeRevision: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                capabilities: provider.capabilities, outputFormatID: OpenAIWireContractV1.outputFormatID,
                canonicalizerVersion: "canonical-wav-v1"
            ).requestFingerprint
        }
        let exactA = try fingerprint(original)
        let exactB = try fingerprint(original)
        XCTAssertEqual(exactA, exactB)
        for changed in [
            ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1-hd"), voiceID: original.voiceID, rate: rate),
            ProviderSelection(providerID: .openAI, modelID: original.modelID, voiceID: VoiceID(rawValue: "openai.nova"), rate: rate),
            ProviderSelection(providerID: .openAI, modelID: original.modelID, voiceID: original.voiceID, rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 1)!),
        ] {
            XCTAssertNotEqual(exactA, try fingerprint(changed))
        }
    }

    @MainActor
    func testEngineReplayExactIdentityUsesCacheAndChangedIdentityResynthesizesWithoutFallback() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-replay-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("ready.wav")
        try WAVTestFixture.wav(samples: 480).write(to: wav)
        let artifact = try WAVValidator.validate(wav, purpose: .reading(.replay))
        let resolver = ReplayCacheResolver(artifact: artifact)
        let provider = ReplayProvider(id: .minimax)
        let revision = UUID()
        let engine = ReplayFixture.engine(
            providerForID: { $0 == .minimax ? provider : nil },
            captureCredential: { id in CredentialEnvelope(providerID: id, revision: revision, secret: Data("fake".utf8)) },
            canonicalChunkResolver: { key, _, _, producer in try await resolver.resolve(key, producer: producer) }
        )
        await engine.waitForInitialHydration()
        await engine.installCredentialCancellationHook()
        let exact = try ReplayFixture.entry(providerID: .minimax, model: "speech-2.8-hd", voice: "minimax.radio-host.default", rate: 0)
        engine.replay(exact)
        await resolver.waitUntilResolveCount(1)
        engine.replay(exact)
        await resolver.waitUntilResolveCount(2)
        let exactRequestCount = await provider.requestCount
        XCTAssertEqual(exactRequestCount, 0, "exact stored identity must remain a cache hit")

        let changed = try ReplayFixture.entry(providerID: .minimax, model: "speech-2.8-hd", voice: "minimax.radio-host.default", rate: 1)
        engine.replay(changed)
        await provider.waitUntilRequestCount(1)
        let changedRequestCount = await provider.requestCount
        let changedRequests = await provider.requests
        XCTAssertEqual(changedRequestCount, 1, "identity change must rotate the fingerprint and synthesize")
        XCTAssertEqual(changedRequests.first?.selection, ProviderSelection(
            providerID: .minimax, modelID: changed.modelID, voiceID: changed.voiceID, rate: changed.rate
        ))
    }

    func testHistoryPolicyAllowsLoadForValidUnresolvedButNeverReplayAndDeniesMissingText() throws {
        let unresolved = HistoryEntry(
            id: UUID(), version: 1, text: "load only", contentResolution: .valid, seconds: 1,
            providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"), voiceID: nil,
            rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 0)!, displayLabelSnapshot: "unknown",
            selectionResolution: .unresolvedLegacyVoice, date: nil, legacyAgoSnapshot: nil
        )
        XCTAssertTrue(HistoryActionPolicy(entry: unresolved).allows(.load))
        XCTAssertFalse(HistoryActionPolicy(entry: unresolved).allows(.replay))
        let missing = HistoryEntry(
            id: UUID(), version: 1, text: nil, contentResolution: .missing, seconds: 0,
            providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"), voiceID: nil,
            rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 0)!, displayLabelSnapshot: "",
            selectionResolution: .unresolvedLegacyVoice, date: nil, legacyAgoSnapshot: nil
        )
        XCTAssertTrue(HistoryActionPolicy(entry: missing).actions.isEmpty)
    }

    @MainActor
    func testEngineReplayUnavailableStoredProviderNeverFallsBackToCurrentProvider() async throws {
        let entry = try ReplayFixture.entry(providerID: .openAI, model: "tts-1", voice: "openai.alloy", rate: 0)
        let fallback = ReplayProvider(id: .minimax)
        let engine = ReplayFixture.engine(providerForID: { $0 == .minimax ? fallback : nil })
        await engine.installCredentialCancellationHook()
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        let index = state.cards.firstIndex { $0.id == .openAI }!
        state.cards[index].configuration = .unconfigured
        engine.providerSettingsState = state
        engine.replay(entry)
        for _ in 0..<20 { await Task.yield() }
        let requests = await fallback.requestCount
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(engine.toast?.contains("无法按历史语音重播") == true)
    }

    @MainActor
    func testOpenAIReplayRequiresExactDisclosureBeforeTransportAndKeepsOriginalBillingNotice() async throws {
        let provider = ReplayProvider(id: .openAI)
        let revision = UUID()
        let engine = ReplayFixture.engine(
            providerForID: { $0 == .openAI ? provider : nil },
            captureCredential: { id in CredentialEnvelope(providerID: id, revision: revision, secret: Data("fake".utf8)) }
        )
        await engine.installCredentialCancellationHook()
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        let index = state.cards.firstIndex { $0.id == .openAI }!
        state.cards[index].configuration = .configured
        engine.providerSettingsState = state
        engine.replay(try ReplayFixture.entry(providerID: .openAI, model: "tts-1", voice: "openai.alloy", rate: 0))
        for _ in 0..<100 { await Task.yield() }
        let blockedRequests = await provider.requests
        XCTAssertTrue(blockedRequests.isEmpty)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertTrue(engine.toast?.contains("AI 生成语音") == true)
        XCTAssertTrue(engine.toast?.contains("OpenAI") == true)
    }

    @MainActor
    func testAuthorizedOpenAIReplayPublishesOriginalProviderBillingBeforePlayback() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-replay-disclosure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("cached.wav")
        try WAVTestFixture.wav(samples: 480).write(to: wav)
        let artifact = try WAVValidator.validate(wav, purpose: .reading(.replay))
        let prefsURL = root.appendingPathComponent("prefs.json")
        let files = RecordingAtomicFileStore(initial: [prefsURL: try JSONEncoder().encode(PrefsV1.defaults)])
        let disclosure = OpenAIDisclosureCoordinator(store: ProviderSettingsStore.open(url: prefsURL, files: files))
        _ = try await disclosure.confirm(modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"), explicitlyAccepted: true)
        let barrier = ReplayBarrier()
        let provider = ReplayProvider(id: .openAI)
        let revision = UUID()
        let engine = ReplayFixture.engine(
            providerForID: { $0 == .openAI ? provider : nil },
            captureCredential: { id in CredentialEnvelope(providerID: id, revision: revision, secret: Data("fake".utf8)) },
            canonicalChunkResolver: { _, _, _, _ in artifact },
            beforePlayback: { await barrier.enterAndWait() },
            disclosure: disclosure
        )
        await engine.installCredentialCancellationHook()
        engine.replay(try ReplayFixture.entry(providerID: .openAI, model: "tts-1", voice: "openai.alloy", rate: 0))
        await barrier.waitUntilEntered()
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 0, "exact cached replay must not synthesize")
        XCTAssertTrue(engine.toast?.contains("OpenAI") == true)
        XCTAssertTrue(engine.toast?.contains("API 账户") == true)
        XCTAssertTrue(engine.toast?.contains("AI 生成") == true)
        await barrier.release()
    }

    @MainActor
    func testReplayValidatesStoredTupleNotDifferentCurrentCardSelectionBeforeSessionUI() async throws {
        let provider = ReplayProvider(id: .openAI)
        let revision = UUID()
        let invalidSnapshot = try ReplayFixture.authoritativeInvalidOpenAISnapshot(revision: revision)
        let engine = ReplayFixture.engine(
            providerForID: { $0 == .openAI ? provider : nil },
            captureCredential: { id in CredentialEnvelope(providerID: id, revision: revision, secret: Data("fake".utf8)) },
            accountSnapshot: { _ in invalidSnapshot }
        )
        var state = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        let index = state.cards.firstIndex { $0.id == .openAI }!
        state.cards[index].configuration = .configured
        state.cards[index].selection = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.nova"), rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!)
        engine.providerSettingsState = state
        let originalText = engine.text
        await engine.installCredentialCancellationHook()
        engine.replay(try ReplayFixture.entry(providerID: .openAI, model: "tts-1", voice: "openai.alloy", rate: 0))
        for _ in 0..<100 { await Task.yield() }
        let invalidRequests = await provider.requests
        XCTAssertTrue(invalidRequests.isEmpty)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(engine.text, originalText)
    }

    @MainActor
    func testSpeakAndReplayUseSameAuthoritativeAccountSelectionGateBeforeProviderSplit() async throws {
        let provider = ReplayProvider(id: .openAI)
        let revision = UUID()
        let invalidSnapshot = try ReplayFixture.authoritativeInvalidOpenAISnapshot(revision: revision)
        let engine = ReplayFixture.engine(
            providerForID: { $0 == .openAI ? provider : nil },
            captureCredential: { id in CredentialEnvelope(providerID: id, revision: revision, secret: Data("fake".utf8)) },
            accountSnapshot: { _ in invalidSnapshot }
        )
        await engine.installCredentialCancellationHook()
        var state = try ProviderSettingsState.fixture(defaultProviderID: .openAI)
        let index = state.cards.firstIndex { $0.id == .openAI }!
        state.cards[index].selection = ProviderSelection(
            providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "account.custom"),
            rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!
        )
        engine.providerSettingsState = state
        engine.text = "ordinary"
        engine.speak()
        for _ in 0..<50 { await Task.yield() }
        engine.replay(try ReplayFixture.entry(providerID: .openAI, model: "tts-1", voice: "account.custom", rate: 0))
        for _ in 0..<50 { await Task.yield() }
        let stages = await provider.stages
        let requests = await provider.requests
        XCTAssertTrue(stages.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testLoadOnlyChangesEditorAndLaterSpeakUsesCurrentDefaultPreprocessing() throws {
        let engine = ReplayFixture.engine(providerForID: { _ in nil })
        let unresolved = HistoryEntry(
            id: UUID(), version: 1, text: "**stored**", contentResolution: .valid, seconds: 1,
            providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: nil,
            rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!, displayLabelSnapshot: "legacy",
            selectionResolution: .unresolvedLegacyVoice, date: nil, legacyAgoSnapshot: nil
        )
        let prefsBefore = engine.prefs
        engine.loadHistory(unresolved)
        XCTAssertEqual(engine.text, "**stored**")
        XCTAssertEqual(engine.prefs, prefsBefore)
        XCTAssertTrue(engine.providerSettingsState.card(.minimax).isDefault)
    }
}

private enum ReplayFixture {
    static func entry(providerID: ProviderID, model: String, voice: String, rate: Int) throws -> HistoryEntry {
        HistoryEntry(
            id: UUID(), version: 1, text: "stored text", contentResolution: .valid, seconds: 1,
            providerID: providerID, modelID: ModelID(rawValue: model), voiceID: VoiceID(rawValue: voice),
            rate: try XCTUnwrap(NormalizedRate(version: providerID == .openAI ? OpenAIRateMappingV1.version : MiniMaxRateMappingV1.version, value: rate)),
            displayLabelSnapshot: voice, selectionResolution: .resolved, date: nil, legacyAgoSnapshot: nil
        )
    }

    @MainActor
    static func engine(
        providerForID: @escaping (ProviderID) -> (any VoiceProvider)?,
        captureCredential: @escaping @Sendable (ProviderID) async throws -> CredentialEnvelope? = { _ in nil },
        runtimeCredentialRead: @escaping @Sendable (ProviderID) async -> CredentialReadResult = { _ in .missing },
        accountSnapshot: @escaping @Sendable (ProviderID) async -> AccountCatalogSnapshot = { _ in .empty },
        canonicalChunkResolver: @escaping @Sendable (CacheFlightKey, SessionGeneration, SpeechPurpose, @escaping @Sendable () async throws -> UnpublishedArtifact) async throws -> AudioArtifact = { _, _, _, producer in try await producer().artifact },
        beforePlayback: @escaping @Sendable () async -> Void = {},
        readSelection: @escaping @Sendable () async throws -> String = { "fixture" },
        disclosure: OpenAIDisclosureCoordinator? = nil
    ) -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-replay-fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let operations = Store.Operations(
            dir: root, cacheDir: root, runtimeDir: root,
            read: { try? Data(contentsOf: $0) }, write: { try $0.write(to: $1, options: .atomic) }
        )
        return Store.withOperations(operations) {
            Engine(
                player: ReplayPlayback(),
                speech: EngineSpeechDependencies(
                    cachePath: { _, _, _ in root.appendingPathComponent("replay-unused.wav") },
                    cacheHit: { _ in false }, synthesize: { _, _, _, _ in }, concat: { _, _, _ in }, beforePlayback: beforePlayback,
                    readSelection: readSelection,
                    providerForID: providerForID, accountSnapshot: accountSnapshot, captureCredential: captureCredential,
                    canonicalChunkResolver: canonicalChunkResolver
                ),
                credentialRegistry: CredentialScopeRegistry(), installCredentialHook: false,
                providerSettingsRuntimeLoader: ProviderSettingsRuntimeLoader(
                    readCredential: runtimeCredentialRead,
                    accountSnapshot: accountSnapshot
                ),
                openAIDisclosureCoordinator: disclosure
            )
        }
    }

    static func authoritativeInvalidOpenAISnapshot(revision: UUID) throws -> AccountCatalogSnapshot {
        let contract = ContractVersion(rawValue: "provider-contracts-v1")
        let scope = try RelationshipScope(providerID: .openAI, credentialRevision: revision, contractVersion: contract, parentModelID: ModelID(rawValue: "tts-1"), controlsSchema: "openai-controls-v1", queryParameters: [:])
        let evidence = AccountRelationshipEvidence(
            scope: scope, scopeRevision: revision, contractVersion: contract, fetchedAt: Date(),
            refreshID: CatalogRefreshID(rawValue: UUID()), authoritySource: "fake-account", coverage: .authoritativeComplete,
            paginationComplete: true,
            values: [AccountRelationshipTuple(modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.nova"), controlsID: nil, controlsVersion: nil)],
            rejections: []
        )
        return AccountCatalogSnapshot(relationshipEvidence: [scope: evidence])
    }
}

private actor ReplayCacheResolver {
    let artifact: AudioArtifact
    private var cachedFingerprint: RequestFingerprint?
    private var resolveCount = 0
    private var resolveWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    init(artifact: AudioArtifact) { self.artifact = artifact }
    func resolve(_ key: CacheFlightKey, producer: @escaping @Sendable () async throws -> UnpublishedArtifact) async throws -> AudioArtifact {
        resolveCount += 1
        let readyCounts = resolveWaiters.keys.filter { $0 <= resolveCount }
        for count in readyCounts { resolveWaiters.removeValue(forKey: count)?.forEach { $0.resume() } }
        if cachedFingerprint == nil { cachedFingerprint = key.fingerprint; return artifact }
        if cachedFingerprint == key.fingerprint { return artifact }
        return try await producer().artifact
    }
    func waitUntilResolveCount(_ expected: Int) async {
        if resolveCount >= expected { return }
        await withCheckedContinuation { resolveWaiters[expected, default: []].append($0) }
    }
}

private actor ReplayBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() { releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll() }
}

private actor ReplayCredentialReadProbe {
    private var recordedProviders: [ProviderID] = []
    func record(_ providerID: ProviderID) { recordedProviders.append(providerID) }
    func providers() -> [ProviderID] { recordedProviders }
}

private actor ReplayProvider: VoiceProvider {
    let id: ProviderID
    let capabilities: ProviderCapabilities
    private var count = 0
    private var recordedRequests: [SpeechRequest] = []
    private var recordedStages: [String] = []
    private var requestWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    init(id: ProviderID) {
        self.id = id
        let version = ContractVersion(rawValue: "replay-fixture-v1")
        capabilities = try! ProviderCapabilities(
            inputLimits: [try! InputLimit(endpoint: "fixture", unit: .utf8Bytes, maximum: 1000, safetyMargin: 0, contractVersion: version)],
            outputFormat: .encoded(container: "wav", codec: "pcm"), contractVersion: version
        )
    }
    var requestCount: Int { count }
    var requests: [SpeechRequest] { recordedRequests }
    var stages: [String] { recordedStages }
    func measureInput(_ text: String, requestOverhead: RequestOverhead) async throws -> InputMeasurement { recordedStages.append("measure"); return try await InputMeasurement.measure(text, limits: capabilities.inputLimits, requestOverhead: requestOverhead) }
    func split(_ text: String, selection: ProviderSelection) async throws -> [ValidatedSpeechChunk] { recordedStages.append("split"); return try await ProviderInputSplitter(capabilities: capabilities).split(text) }
    func loadCatalog(using credential: ProviderCredential) async throws -> AccountCatalogSnapshot { .empty }
    func synthesize(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact {
        recordedStages.append("synthesize"); count += 1; recordedRequests.append(request)
        let readyCounts = requestWaiters.keys.filter { $0 <= count }
        for count in readyCounts { requestWaiters.removeValue(forKey: count)?.forEach { $0.resume() } }
        throw CancellationError()
    }
    func waitUntilRequestCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { requestWaiters[expected, default: []].append($0) }
    }
}

@MainActor private final class ReplayPlayback: EnginePlayback {
    var alive = false; var paused = false; var position = 0.0; var duration = 0.0
    func play(file: URL, prefs: Prefs, streaming: Bool) throws {}
    func append(file: URL) throws {}
    func finishStream(prefs: Prefs) {}
    func stop() {}; func togglePause() {}; func seek(relative: Double) {}; func setSpeed(_ speed: Double) {}
}

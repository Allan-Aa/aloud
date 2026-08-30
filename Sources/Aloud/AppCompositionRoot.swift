import AppKit
import Foundation

struct AppPasteboardDependency: Sendable {
    let readString: @MainActor @Sendable () -> String?
    let copyString: @MainActor @Sendable (String) -> Void
}

struct AppScreenshotDependency: Sendable {
    let export: @MainActor @Sendable (URL) throws -> Void
}

struct AppClockDependency: Sendable {
    let now: @Sendable () -> Date
}

struct AppDiagnosticsDependency: Sendable {
    let record: @Sendable (DiagnosticEvent) -> Void
}

struct ProviderSettingsSystemVoices: Sendable {
    let load: @Sendable () async -> [SystemVoiceDescriptor]
}

/// Every operating-system or remote boundary required by the app graph is an
/// explicit value. `build(dependencies:)` contains no live adapter constructor;
/// shipping and fake graphs differ only in the values supplied here.
struct AppCompositionDependencies: Sendable {
    let credentialStore: CredentialStore
    let accountEvidenceStore: ProviderAccountEvidenceStore
    let onePassword: OnePasswordPipeClient?
    let miniMaxHTTP: any MiniMaxHTTPClient
    let openAIHTTP: any OpenAIHTTPClient
    let geminiHTTP: any GeminiHTTPClient
    let systemSpeech: any SystemSpeechSynthesizing
    let accountSnapshot: @Sendable (ProviderID) async -> AccountCatalogSnapshot
    let player: any EnginePlayback
    let wavProcessDriver: any WAVProcessDriver
    let storeOperations: Store.Operations
    let pasteboard: AppPasteboardDependency
    let screenshot: AppScreenshotDependency
    let clock: AppClockDependency
    let diagnostics: AppDiagnosticsDependency
    let lastAudioStore: LastAudioArtifactStore
    let credentialRegistry: CredentialScopeRegistry
}

@MainActor
final class AppCompositionRoot {
    static let live = try! build(dependencies: liveDependencies())

    let engine: Engine
    let lastAudioStore: LastAudioArtifactStore
    let credentialIngress: CredentialIngress
    let systemVoices: ProviderSettingsSystemVoices
    let pasteboard: AppPasteboardDependency
    let screenshot: AppScreenshotDependency
    let clock: AppClockDependency
    let diagnostics: AppDiagnosticsDependency

    init(
        engine: Engine,
        lastAudioStore: LastAudioArtifactStore,
        credentialIngress: CredentialIngress? = nil,
        systemVoices: ProviderSettingsSystemVoices = .init(load: { [] }),
        pasteboard: AppPasteboardDependency = .init(readString: { nil }, copyString: { _ in }),
        screenshot: AppScreenshotDependency = .init(export: { _ in }),
        clock: AppClockDependency = .init(now: { Date(timeIntervalSince1970: 0) }),
        diagnostics: AppDiagnosticsDependency = .init(record: { _ in })
    ) {
        self.engine = engine
        self.lastAudioStore = lastAudioStore
        self.credentialIngress = credentialIngress ?? CredentialIngress(store: CredentialStore(keychain: UnavailableCompositionKeychain()))
        self.systemVoices = systemVoices
        self.pasteboard = pasteboard
        self.screenshot = screenshot
        self.clock = clock
        self.diagnostics = diagnostics
    }

    static func build(dependencies: AppCompositionDependencies) throws -> AppCompositionRoot {
        let runtime = dependencies.storeOperations.runtimeDir
        let cache = CanonicalChunkCacheCoordinator(
            cache: CanonicalAudioCache(directory: dependencies.storeOperations.cacheDir)
        )
        let accountEvidenceStore = dependencies.accountEvidenceStore
        let miniMax = MiniMaxProvider(
            httpClient: dependencies.miniMaxHTTP,
            nativeDirectory: runtime,
            voiceDirectory: MiniMaxVoiceDirectory(publicationStore: accountEvidenceStore)
        )
        let openAI: any VoiceProvider = try OpenAIProvider(
            modelID: ModelID(rawValue: "tts-1"), httpClient: dependencies.openAIHTTP,
            nativeDirectory: runtime
        )
        let catalog = try ProviderContractCatalog.bundled()
        let gemini: any VoiceProvider = try GeminiProvider(
            releaseGate: .production(featureFlags: .defaults, catalog: catalog),
            httpClient: dependencies.geminiHTTP, nativeDirectory: runtime
        )
        let macOS: any VoiceProvider = try SystemVoiceProvider(
            synthesizer: dependencies.systemSpeech, nativeDirectory: runtime
        )
        let providers: [ProviderID: any VoiceProvider] = [
            .minimax: miniMax, .openAI: openAI, .gemini: gemini, .macOS: macOS,
        ]
        let credentialStore = dependencies.credentialStore
        let accountSnapshot = dependencies.accountSnapshot
        let player = dependencies.player
        let registry = dependencies.credentialRegistry
        let loader = ProviderSettingsRuntimeLoader(
            readCredential: { providerID in
                (try? await credentialStore.read(providerID: providerID)) ?? .blocked(.keychainReadFailed)
            },
            accountSnapshot: accountSnapshot,
            refreshCatalog: { providerID, envelope, publication in
                guard providerID == .minimax else { return nil }
                do {
                    let result = try await miniMax.loadVoiceCatalog(
                        using: .apiKey(providerID: providerID, envelope: envelope),
                        publication: publication
                    )
                    try Task.checkCancellation()
                    return ProviderCatalogRefresh(
                        snapshot: result.snapshot,
                        voices: result.voices,
                        publicationRevision: envelope.revision
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch MiniMaxProviderError.credentialRejected {
                    return ProviderCatalogRefresh(
                        snapshot: await accountSnapshot(.minimax),
                        voices: await miniMax.voiceDescriptors(revision: envelope.revision),
                        healthOverride: .explicitRejected
                    )
                } catch {
                    return ProviderCatalogRefresh(
                        snapshot: await accountSnapshot(.minimax),
                        voices: await miniMax.voiceDescriptors(revision: envelope.revision)
                    )
                }
            },
            publication: accountEvidenceStore
        )
        let engine = Store.withOperations(dependencies.storeOperations) {
            Engine(
                player: player,
                speech: EngineSpeechDependencies(
                    cachePath: AudioCache.path, cacheHit: AudioCache.hit,
                    synthesize: { _, _, _, _ in throw MiniMaxProviderError.invalidRequest },
                    concat: AudioJoin.concat,
                    providerForID: { providers[$0] }, accountSnapshot: accountSnapshot,
                    canonicalizeNative: { native, purpose, ffmpeg in
                        let runner = WAVProcessRunner(
                            executableURL: URL(fileURLWithPath: ffmpeg),
                            driver: dependencies.wavProcessDriver
                        )
                        return OwnedAudioArtifact(artifact: try await WAVCanonicalizer(runner: runner).canonicalize(
                            .init(url: native.url, format: native.format, purpose: purpose),
                            destinationDirectory: runtime
                        ))
                    },
                    captureCredential: { providerID in
                        guard providerID != .macOS else { return nil }
                        let result = try await credentialStore.read(providerID: providerID)
                        return try MiniMaxCredentialCapture.envelope(from: result, providerID: providerID)
                    },
                    advanceCanonicalScope: { providerID, revision, generation in
                        await cache.advance(providerID: providerID, revision: revision, generation: generation)
                    },
                    canonicalChunkResolver: { key, generation, purpose, producer in
                        try await cache.resolve(key: key, generation: generation, purpose: purpose, produce: producer)
                    },
                    verifyPlayback: {
                        guard let client = player as? any PlayerClient else {
                            return PlaybackEvidence(firstTimePosition: 0, secondTimePosition: 0.001, observedAt: dependencies.clock.now())
                        }
                        return try await PlaybackVerifier.verify(client: client, timeout: .seconds(8), cleanup: {})
                    },
                    prepareSessionArtifact: { urls, purpose in
                        try WAVConcatenator.concatenate(
                            urls,
                            to: runtime.appendingPathComponent("aloud-last-audio-\(UUID().uuidString).wav"),
                            purpose: purpose
                        )
                    }
                ),
                credentialRegistry: registry,
                historyController: HistoryMutationController(url: dependencies.storeOperations.dir.appendingPathComponent("history.json")),
                lastAudioStore: dependencies.lastAudioStore,
                providerSettingsRuntimeLoader: loader,
                voiceSampleStore: VoiceSampleStore(
                    directory: dependencies.storeOperations.dir.appendingPathComponent("Voice Samples", isDirectory: true)
                )
            )
        }
        return AppCompositionRoot(
            engine: engine, lastAudioStore: dependencies.lastAudioStore,
            credentialIngress: CredentialIngress(store: credentialStore, onePassword: dependencies.onePassword),
            systemVoices: ProviderSettingsSystemVoices(load: { await dependencies.systemSpeech.installedVoices() }),
            pasteboard: dependencies.pasteboard, screenshot: dependencies.screenshot,
            clock: dependencies.clock, diagnostics: dependencies.diagnostics
        )
    }

    static func liveDependencies() -> AppCompositionDependencies {
        let pasteboard = NSPasteboard.general
        return AppCompositionDependencies(
            credentialStore: .live,
            accountEvidenceStore: .shared,
            onePassword: OnePasswordPipeClient(launcher: ProcessOnePasswordLauncher()),
            miniMaxHTTP: URLSessionMiniMaxHTTPClient(),
            openAIHTTP: URLSessionOpenAIHTTPClient(),
            geminiHTTP: URLSessionGeminiHTTPClient(),
            systemSpeech: AVSpeechSynthesizerClient(),
            accountSnapshot: { providerID in await ProviderAccountEvidenceStore.shared.snapshot(for: providerID) },
            player: Player.shared,
            wavProcessDriver: FoundationWAVProcessDriver(),
            storeOperations: .init(
                dir: Store.dir, cacheDir: Store.cacheDir, runtimeDir: Store.runtimeDir,
                read: { try? Data(contentsOf: $0) }, write: { try $0.write(to: $1, options: .atomic) }
            ),
            pasteboard: .init(
                readString: { pasteboard.string(forType: .string) },
                copyString: { value in pasteboard.clearContents(); pasteboard.setString(value, forType: .string) }
            ),
            screenshot: .init(export: { directory in
                try ScreenshotExporter().export(scenes: PreviewSceneCatalog.all, sink: DirectoryScreenshotSink(directory: directory))
            }),
            clock: .init(now: { Date() }), diagnostics: .init(record: { Diag.record($0) }),
            lastAudioStore: .shared, credentialRegistry: .shared
        )
    }
}

private struct UnavailableCompositionKeychain: KeychainClient {
    func read(service: String, account: String) -> CredentialKeychainRead { .failure(errSecInteractionNotAllowed) }
    func update(data: Data, service: String, account: String) -> OSStatus { errSecInteractionNotAllowed }
    func add(data: Data, service: String, account: String) -> OSStatus { errSecInteractionNotAllowed }
    func delete(service: String, account: String) -> OSStatus { errSecInteractionNotAllowed }
}

enum ExternalServiceName: String, CaseIterable, Sendable {
    case keychainRead
    case keychainUpdate
    case keychainAdd
    case keychainDelete
    case onePassword
    case miniMaxHTTP
    case openAIHTTP
    case geminiHTTP
    case accountCatalog
    case systemSpeechCatalog
    case systemSpeechWrite
    case player
    case wavProcess
    case storeRead
    case storeWrite
    case clock
    case diagnostics
    case browserLogin
    case cliLogin
    case chatGPTSession
    case geminiSession
    case systemPasteboard
    case screenshot
}
struct ExternalServiceTripwireError: Error, Equatable, Sendable { let service: ExternalServiceName }
final class ExternalServiceTripwire: @unchecked Sendable {
    private let lock = NSLock(); private var recorded: Set<ExternalServiceName> = []
    var calls: Set<ExternalServiceName> { lock.withLock { recorded } }
    func record(_ service: ExternalServiceName) { _ = lock.withLock { recorded.insert(service) } }
    func call(_ service: ExternalServiceName) throws -> Never { _ = lock.withLock { recorded.insert(service) }; throw ExternalServiceTripwireError(service: service) }
}

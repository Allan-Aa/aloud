import XCTest
import CryptoKit
@testable import Aloud

final class PrivacyDataFlowTests: XCTestCase {
    func testSpeechFailureDiagnosticsClassifyTheFailedPipelineBoundaryWithoutRawErrorText() {
        XCTAssertEqual(SpeechFailureDiagnostic.code(for: MiniMaxProviderError.credentialRejected), .credentialRejected)
        XCTAssertEqual(SpeechFailureDiagnostic.code(for: MiniMaxProviderError.unsupportedSelection), .invalidSelection)
        XCTAssertEqual(SpeechFailureDiagnostic.code(for: MiniMaxProviderError.transport), .transport)
        XCTAssertEqual(SpeechFailureDiagnostic.code(for: MiniMaxProviderError.service(9)), .service)
        XCTAssertEqual(SpeechFailureDiagnostic.code(for: MiniMaxProviderError.invalidResponse), .audioInvalid)
        XCTAssertEqual(SpeechFailureDiagnostic.code(for: WAVAudioError.processFailed(1)), .canonicalization)
        XCTAssertEqual(SpeechFailureDiagnostic.code(for: PlaybackVerificationError.timeout), .playback)

        let raw = NSError(
            domain: "secret-\(UUID().uuidString)", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "private provider response"]
        )
        let rendered = PrivacySafeDiagnostics.render(.providerFailure(
            providerID: .minimax, code: SpeechFailureDiagnostic.code(for: raw)
        ))
        XCTAssertEqual(rendered, "provider id=minimax code=recoverableFailure")
        XCTAssertFalse(rendered.contains(raw.localizedDescription))
    }

    func testStructuredDiagnosticsContainOnlyClosedFieldsAndNoCanaryFragments() {
        let canary = "secret-\(UUID().uuidString)-authorized-body"
        let diagnostics = PrivacySafeDiagnostics()
        diagnostics.record(.selectionRead(status: .success, characterCount: canary.count))
        diagnostics.record(.providerFailure(providerID: .openAI, code: .credentialRejected))
        let rendered = diagnostics.renderedForTesting()
        let findings = SensitiveSinkScanner.scan(canary: canary, sinks: [.diagnostics: Data(rendered.utf8)])
        XCTAssertTrue(findings.isEmpty)
        XCTAssertFalse(rendered.contains(canary))
    }

    func testScannerFindsFullPrefixMiddleSuffixAndCommonTruncationsWithoutReportingCanary() {
        let canary = "CANARY-\(UUID().uuidString)-PRIVATE-TEXT"
        let samples = SensitiveSinkScanner.fragments(for: canary)
        XCTAssertTrue(samples.count > 6)
        let sinks = Dictionary(uniqueKeysWithValues: samples.enumerated().map { index, fragment in
            (SensitiveSinkCategory(rawValue: "sink-\(index)"), Data(fragment.utf8))
        })
        let findings = SensitiveSinkScanner.scan(canary: canary, sinks: sinks)
        XCTAssertEqual(findings.count, samples.count)
        XCTAssertFalse(findings.description.contains(canary))
        for fragment in samples { XCTAssertFalse(findings.description.contains(fragment)) }
    }

    func testSelectionDiagnosticFailureNeverAcceptsRawLocalizedErrorOrText() {
        let diagnostics = PrivacySafeDiagnostics()
        diagnostics.record(.selectionRead(status: .failed, characterCount: nil))
        let rendered = diagnostics.renderedForTesting()
        XCTAssertEqual(rendered, "selection status=failed")
    }

    func testUserVisibleErrorMessagesNeverIncludeRawCanary() {
        let canary = "raw-error-\(UUID().uuidString)"
        let raw = NSError(domain: canary, code: 7, userInfo: [NSLocalizedDescriptionKey: canary])
        let messages = [
            PrivacySafeMessage.settingsLoadFailed(raw), PrivacySafeMessage.settingsSaveFailed(raw),
            PrivacySafeMessage.speechFailed(raw), PrivacySafeMessage.selectionFailed(raw), PrivacySafeMessage.exportFailed(raw)
        ]
        for message in messages {
            XCTAssertTrue(SensitiveSinkScanner.scan(canary: canary, sinks: [SensitiveSinkCategory(rawValue: "toast"): Data(message.utf8)]).isEmpty)
        }
    }

    @MainActor
    func testExportFilenameCannotContainAuthorizedTextCanary() {
        let canary = "authorized-\(UUID().uuidString)"
        let filename = Engine.exportFilenameStem(Date(timeIntervalSince1970: 0)) + ".wav"
        XCTAssertTrue(SensitiveSinkScanner.scan(canary: canary, sinks: [SensitiveSinkCategory(rawValue: "export-filename"): Data(filename.utf8)]).isEmpty)
        XCTAssertEqual(filename, "念-音频-19700101-000000.wav")
    }

    @MainActor
    func testExplicitSourceByActualProductionSinkCaptureMatrix() async throws {
        let rig = try PrivacySourceSinkIntegrationRig()
        let matrix = try await rig.captureAllSources()
        XCTAssertEqual(Set(matrix.keys), Set(PrivacySourceCategory.allCases))
        for (source, result) in matrix {
            XCTAssertEqual(Set(result.captures.keys), Set(PrivacyIntegrationSink.allCases), "source=\(source.rawValue)")
            let findings = SensitiveSinkScanner.scan(canary: result.canary, sinks: result.captures.mapKeys { .init(rawValue: $0.rawValue) })
            XCTAssertEqual(Set(findings.map(\.sink.rawValue)), Set(result.expectedMatches.map(\.rawValue)), "source=\(source.rawValue) findings=\(findings)")
        }
        try PrivacyAuditCanaryRegistry.write(matrix.values.map(\.canary))
    }

    func testPostAuditScannerExecutesSuccessAndFailsOnCanaryAndRawPattern() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/privacy-audit-scan.sh")
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let evidence = directory.url.appendingPathComponent("evidence", isDirectory: true)
        let sources = directory.url.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        for name in ["changes.diff", "after.sha256", "report.md"] { try Data("safe\n".utf8).write(to: evidence.appendingPathComponent(name)) }
        try Data("let status = 1\n".utf8).write(to: sources.appendingPathComponent("Sources/Safe.swift"))
        let canary = "寀宂寁宄寂宊寃宖寅宐寈宕"
        let registry = directory.url.appendingPathComponent("registry.txt")
        try PrivacyAuditCanaryRegistry.write([canary], to: registry, runID: UUID(uuidString: "01234567-89AB-CDEF-8123-456789ABCDEF")!)

        let success = try PrivacyAuditScript.run(script: script, evidence: evidence, sources: sources, registry: registry)
        XCTAssertEqual(success.status, 0, success.stderr)
        XCTAssertTrue(success.stdout.contains("sources=1")); XCTAssertTrue(success.stdout.contains("registry_sha256="))

        try Data(("test-log-" + String(canary.prefix(8)) + "\n").utf8).write(to: evidence.appendingPathComponent("parallel-full.log"))
        let logFailure = try PrivacyAuditScript.run(script: script, evidence: evidence, sources: sources, registry: registry)
        XCTAssertNotEqual(logFailure.status, 0); XCTAssertTrue(logFailure.stderr.contains("parallel-full.log"))
        try FileManager.default.removeItem(at: evidence.appendingPathComponent("parallel-full.log"))

        try Data("prefix-\(String(canary.prefix(8)))-suffix".utf8).write(to: evidence.appendingPathComponent("report.md"))
        let canaryFailure = try PrivacyAuditScript.run(script: script, evidence: evidence, sources: sources, registry: registry)
        XCTAssertNotEqual(canaryFailure.status, 0); XCTAssertTrue(canaryFailure.stderr.contains("fragment="))
        XCTAssertFalse(canaryFailure.stderr.contains(canary))
        try Data("safe\n".utf8).write(to: evidence.appendingPathComponent("report.md"))
        try Data("Diag.log(raw)\n".utf8).write(to: sources.appendingPathComponent("Sources/Safe.swift"))
        let staticFailure = try PrivacyAuditScript.run(script: script, evidence: evidence, sources: sources, registry: registry)
        XCTAssertNotEqual(staticFailure.status, 0); XCTAssertTrue(staticFailure.stderr.contains("raw-sensitive-sink-pattern"))
    }

    func testPostAuditScannerRejectsStructuredProviderResponseFixtureCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/privacy-audit-scan.sh")
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let evidence = directory.url.appendingPathComponent("evidence", isDirectory: true)
        let sources = directory.url.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let forbiddenFixture = "invalid" + "_api_key"
        try Data("safe\n".utf8).write(to: evidence.appendingPathComponent("changes.diff"))
        try Data("safe\n".utf8).write(to: evidence.appendingPathComponent("after.sha256"))
        try Data("fixture=\(forbiddenFixture)\n".utf8).write(to: evidence.appendingPathComponent("report.md"))
        try Data("let status = 1\n".utf8).write(to: sources.appendingPathComponent("Sources/Safe.swift"))
        let registry = directory.url.appendingPathComponent("registry.txt")
        try PrivacyAuditCanaryRegistry.write(["寀宂寁宄寂宊寃宖寅宐寈宕"], to: registry, runID: UUID())

        let result = try PrivacyAuditScript.run(script: script, evidence: evidence, sources: sources, registry: registry)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("known-fixture-pattern"))
        XCTAssertFalse(result.stderr.contains(forbiddenFixture))
    }

    func testAuditDiffSanitizerRedactsStructuredProviderResponseFixtureCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/audit-diff-sanitize.sh")
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let raw = directory.url.appendingPathComponent("raw.diff")
        let sanitized = directory.url.appendingPathComponent("sanitized.diff")
        let forbiddenFixture = "invalid" + "_api_key"
        try Data(("+ response-code=" + forbiddenFixture + "\n").utf8).write(to: raw)
        let process = Process(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = script; process.arguments = [raw.path, sanitized.path]
        process.standardOutput = stdout; process.standardError = stderr
        try process.run(); process.waitUntilExit()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, error)
        let output = try String(contentsOf: sanitized, encoding: .utf8)
        XCTAssertFalse(output.contains(forbiddenFixture))
        XCTAssertTrue(output.contains("<redacted-response-code-fixture>"))
    }

    @MainActor
    func testRandomCanariesTraverseRealProductionSerializersAndInjectedStores() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-privacy-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let secret = "\(UUID().uuidString)-secret-random"
        let keychain = PrivacyKeychainCapture()
        let credentials = CredentialStore(keychain: keychain, invalidator: .noop, gate: CredentialNamespaceGate())
        _ = try await credentials.save(providerID: .openAI, normalizedSecret: Data(secret.utf8))
        XCTAssertFalse(SensitiveSinkScanner.scan(canary: secret, sinks: [.init(rawValue: "keychain"): keychain.bytes]).isEmpty)

        let text = "\(UUID().uuidString)-authorized-random"
        let historyURL = root.appendingPathComponent("history.json")
        let history = HistoryMutationController(url: historyURL)
        _ = try await history.append(HistoryEntry(
            id: UUID(), version: 1, text: text, contentResolution: .valid, seconds: 1,
            providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"),
            rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!, displayLabelSnapshot: "OpenAI",
            selectionResolution: .resolved, date: nil, legacyAgoSnapshot: nil
        ))
        let historyBytes = try Data(contentsOf: historyURL)
        XCTAssertFalse(SensitiveSinkScanner.scan(canary: text, sinks: [.init(rawValue: "history"): historyBytes]).isEmpty)

        for canary in [secret, text, "\(UUID().uuidString)-raw-error"] {
            let error = NSError(domain: "provider", code: 500, userInfo: [NSLocalizedDescriptionKey: canary])
            let diagnostics = PrivacySafeDiagnostics(); diagnostics.record(.providerFailure(providerID: .openAI, code: .recoverableFailure))
            let cli = CLIDispatcher.route(arguments: PrivacyCLIArguments(["Aloud", canary]))
            let cliBytes: Data = if case .terminate(_, let stdout, let stderr) = cli { stdout + stderr } else { Data() }
            let denied: [SensitiveSinkCategory: Data] = [
                .diagnostics: Data(diagnostics.renderedForTesting().utf8),
                .init(rawValue: "toast"): Data(PrivacySafeMessage.speechFailed(error).utf8),
                .init(rawValue: "prefs"): try JSONEncoder().encode(PrefsV1.defaults),
                .init(rawValue: "cli-stdout-stderr"): cliBytes,
                .init(rawValue: "export-filename"): Data(Engine.exportFilenameStem(Date(timeIntervalSince1970: 0)).utf8),
            ]
            XCTAssertTrue(SensitiveSinkScanner.scan(canary: canary, sinks: denied).isEmpty)
        }
    }

    func testProviderAndProcessProductionBoundariesKeepRawCanaryOutOfDeniedOutputs() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-privacy-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let canary = privacyAuditCanary()
        let rawBody = try JSONSerialization.data(withJSONObject: ["error": ["code": "unknown", "type": "server", "message": canary]])
        let client = PrivacyOpenAIHTTPClient(response: .init(statusCode: 500, body: rawBody))
        let provider = try OpenAIProvider(modelID: ModelID(rawValue: "tts-1"), httpClient: client, nativeDirectory: root)
        let revision = UUID(); let selection = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"), rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!)
        let chunks = try await provider.split(canary, selection: selection)
        let chunk = try XCTUnwrap(chunks.first)
        let request = try SpeechRequest.make(id: .init(rawValue: UUID()), selection: selection, chunk: chunk, controls: OpenAIRateMappingV1.controls(for: selection.rate), credentialScopeRevision: revision, capabilities: provider.capabilities, outputFormatID: OpenAIWireContractV1.outputFormatID, canonicalizerVersion: "canonical-wav-v1")
        do { _ = try await provider.synthesize(request, credential: .apiKey(providerID: .openAI, envelope: .init(providerID: .openAI, revision: revision, secret: Data("fake".utf8)))) } catch {
            XCTAssertTrue(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "provider-error"): Data(PrivacySafeMessage.speechFailed(error).utf8)]).isEmpty)
        }
        let capturedRequest = await client.capturedRequest()
        let sent = try XCTUnwrap(capturedRequest)
        XCTAssertFalse(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "provider-outbound"): sent.httpBody ?? Data()]).isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains(canary) })

        let driver = PrivacyWAVDriver(); let input = root.appendingPathComponent("input.wav"); let output = root.appendingPathComponent("output.wav")
        try await WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/ffmpeg"), driver: driver).run(.init(id: UUID(), inputURL: input, inputFormat: .encoded(container: "wav", codec: "pcm"), outputURL: output), deadline: .seconds(1))
        let invocation = try XCTUnwrap(driver.invocation)
        XCTAssertEqual(invocation.arguments, ["-y", "-i", input.path, "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", output.path])
        XCTAssertTrue(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "process-argv"): Data(invocation.arguments.joined(separator: "\0").utf8)]).isEmpty)
    }

    func testAudioCanaryTraversesProviderTempCacheLastAudioAndExportProductionPaths() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-privacy-audio-\(UUID().uuidString)", isDirectory: true)
        let nativeDirectory = root.appendingPathComponent("native", isDirectory: true)
        let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let canary = "audio-\(UUID().uuidString)-payload"
        var wav = WAVTestFixture.wav(samples: 480)
        let payload = Data(canary.utf8)
        wav.replaceSubrange(44..<(44 + payload.count), with: payload)
        let client = PrivacyOpenAIHTTPClient(response: .init(statusCode: 200, body: wav))
        let provider = try OpenAIProvider(modelID: ModelID(rawValue: "tts-1"), httpClient: client, nativeDirectory: nativeDirectory)
        let revision = UUID()
        let selection = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"), rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!)
        let chunks = try await provider.split("fixed production-boundary text", selection: selection)
        let chunk = try XCTUnwrap(chunks.first)
        let request = try SpeechRequest.make(id: .init(rawValue: UUID()), selection: selection, chunk: chunk, controls: OpenAIRateMappingV1.controls(for: selection.rate), credentialScopeRevision: revision, capabilities: provider.capabilities, outputFormatID: OpenAIWireContractV1.outputFormatID, canonicalizerVersion: "canonical-wav-v1")
        let owned = try await provider.synthesize(request, credential: .apiKey(providerID: .openAI, envelope: .init(providerID: .openAI, revision: revision, secret: Data("fake".utf8))))
        defer { owned.cleanupIfOwned() }
        let nativeBytes = try Data(contentsOf: owned.url)
        XCTAssertFalse(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "native-temp"): nativeBytes]).isEmpty)
        XCTAssertTrue(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "native-filename"): Data(owned.url.lastPathComponent.utf8)]).isEmpty)

        let fingerprint = try XCTUnwrap(RequestFingerprint(rawValue: Data(repeating: 9, count: 32)))
        let cache = CanonicalAudioCache(directory: cacheDirectory)
        let coordinator = CanonicalChunkCacheCoordinator(cache: cache)
        let generation = SessionGeneration(rawValue: 1)
        await coordinator.advance(providerID: .openAI, revision: revision, generation: generation)
        let validated = try WAVValidator.validate(owned.url, purpose: .reading(.speak))
        let cached = try await coordinator.resolve(key: .init(providerID: .openAI, fingerprint: fingerprint, scopeRevision: revision), generation: generation, purpose: .reading(.speak)) {
            UnpublishedArtifact(artifact: validated)
        }
        let cacheBytes = try Data(contentsOf: cached.url)
        XCTAssertFalse(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "cache"): cacheBytes]).isEmpty)
        XCTAssertTrue(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "cache-filename"): Data(cached.url.lastPathComponent.utf8)]).isEmpty)

        let lastAudio = LastAudioArtifactStore()
        try await lastAudio.promote(cached, generation: generation, purpose: .reading(.speak), evidence: .init(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()))
        let currentArtifact = await lastAudio.currentArtifact()
        let retained = try XCTUnwrap(currentArtifact)
        XCTAssertFalse(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "last-audio"): try Data(contentsOf: retained.url)]).isEmpty)
        let export = root.appendingPathComponent("export.wav")
        _ = try await AudioExporter.saveAudio(from: lastAudio, to: export)
        XCTAssertFalse(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "export"): try Data(contentsOf: export)]).isEmpty)
        XCTAssertTrue(SensitiveSinkScanner.scan(canary: canary, sinks: [.init(rawValue: "export-filename"): Data(export.lastPathComponent.utf8)]).isEmpty)
    }
}

private actor PrivacyOpenAIHTTPClient: OpenAIHTTPClient {
    let response: OpenAIHTTPResponse; private(set) var request: URLRequest?
    init(response: OpenAIHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> OpenAIHTTPResponse { self.request = request; return response }
    func capturedRequest() -> URLRequest? { request }
}
private final class PrivacyWAVChild: @unchecked Sendable, WAVChildProcess {
    var isRunning = false; func terminate() {}; func kill() throws {}; func waitForTermination(for deadline: Duration) async -> Bool { true }
}
private final class PrivacyWAVDriver: @unchecked Sendable, WAVProcessDriver {
    private let lock = NSLock(); private var captured: (URL, [String])?
    var invocation: (executable: URL, arguments: [String])? { lock.withLock { captured.map { ($0.0, $0.1) } } }
    func launch(executableURL: URL, arguments: [String], terminated: @escaping @Sendable (Int32) -> Void) throws -> any WAVChildProcess {
        lock.withLock { captured = (executableURL, arguments) }; terminated(0); return PrivacyWAVChild()
    }
}

private final class PrivacyKeychainCapture: @unchecked Sendable, KeychainClient {
    private let lock = NSLock(); private var stored = Data()
    var bytes: Data { lock.withLock { stored } }
    func read(service: String, account: String) -> CredentialKeychainRead { bytes.isEmpty ? .failure(errSecItemNotFound) : .success(bytes) }
    func update(data: Data, service: String, account: String) -> OSStatus { errSecItemNotFound }
    func add(data: Data, service: String, account: String) -> OSStatus { lock.withLock { stored = data }; return errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { lock.withLock { stored = Data() }; return errSecSuccess }
}
private struct PrivacyCLIArguments: CLIArgumentSource {
    let values: [String]; init(_ values: [String]) { self.values = values }
    var count: Int { values.count }; func argument(at index: Int) -> String { values[index] }
}

private enum PrivacyIntegrationSink: String, CaseIterable, Hashable {
    case stdout, stderr, diagnostics, crashCapture, prefs
    case tempFilename, tempContents, cacheFilename, cacheContents
    case processArgv, processEnvironment, toast, history, keychain
    case lastAudio, exportFilename, exportContents, providerOutbound, parserMemory
}

private struct PrivacyIntegrationResult {
    let canary: String
    let captures: [PrivacyIntegrationSink: Data]
    let expectedMatches: Set<PrivacyIntegrationSink>
}

@MainActor
private final class PrivacySourceSinkIntegrationRig {
    private let root: URL
    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-privacy-matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func captureAllSources() async throws -> [PrivacySourceCategory: PrivacyIntegrationResult] {
        var matrix: [PrivacySourceCategory: PrivacyIntegrationResult] = [:]
        for source in PrivacySourceCategory.allCases { matrix[source] = try await capture(source) }
        return matrix
    }

    private func capture(_ source: PrivacySourceCategory) async throws -> PrivacyIntegrationResult {
        let canary = privacyAuditCanary()
        let sourceRoot = root.appendingPathComponent(source.rawValue, isDirectory: true)
        let nativeDirectory = sourceRoot.appendingPathComponent("native", isDirectory: true)
        let cacheDirectory = sourceRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        var captures: [PrivacyIntegrationSink: Data] = [:]

        let cli = CLIDispatcher.route(arguments: PrivacyCLIArguments(["Aloud", "--synth", canary]))
        if case .terminate(_, let stdout, let stderr) = cli { captures[.stdout] = stdout; captures[.stderr] = stderr }

        let diagnostics = PrivacySafeDiagnostics()
        diagnostics.record(.selectionRead(status: .failed, characterCount: canary.count))
        diagnostics.record(.providerFailure(providerID: .openAI, code: .recoverableFailure))
        captures[.diagnostics] = Data(diagnostics.renderedForTesting().utf8)
        let rawError = NSError(domain: canary, code: 500, userInfo: [NSLocalizedDescriptionKey: canary])
        captures[.crashCapture] = PrivacySafeCrashCapture.capture(rawError)
        captures[.prefs] = try JSONEncoder().encode(PrefsV1.defaults)
        captures[.toast] = Data(PrivacySafeMessage.speechFailed(rawError).utf8)

        let launcher = PrivacyOnePasswordCapture(output: Data("safe-key".utf8))
        let pipe = OnePasswordPipeClient(
            launcher: launcher,
            environment: ["SAFE": "yes", "API_KEY_\(source.rawValue.uppercased())": canary],
            executableResolver: { "/fake/op" }
        )
        let buffer = try await pipe.readMiniMaxSecretBuffer(); buffer.zeroize()
        XCTAssertEqual(launcher.timeout, .seconds(30))
        captures[.processArgv] = Data((launcher.arguments ?? []).joined(separator: "\0").utf8)
        captures[.processEnvironment] = Data((launcher.environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\0").utf8)

        let keychain = PrivacyKeychainCapture()
        let credentialStore = CredentialStore(keychain: keychain, invalidator: .noop, gate: CredentialNamespaceGate())
        let keychainValue = source == .secret ? canary : "safe-secret"
        _ = try await credentialStore.save(providerID: .openAI, normalizedSecret: Data(keychainValue.utf8))
        captures[.keychain] = keychain.bytes

        let historyURL = sourceRoot.appendingPathComponent("history.json")
        let history = HistoryMutationController(url: historyURL)
        _ = try await history.append(HistoryEntry(
            id: UUID(), version: 1, text: source == .authorizedText ? canary : "safe history text",
            contentResolution: .valid, seconds: 1, providerID: .openAI,
            modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"),
            rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!, displayLabelSnapshot: "OpenAI",
            selectionResolution: .resolved, date: nil, legacyAgoSnapshot: nil
        ))
        captures[.history] = try Data(contentsOf: historyURL)

        let providerCapture = try await exerciseProvider(source: source, canary: canary, nativeDirectory: nativeDirectory)
        captures[.toast, default: Data()].append(providerCapture.safeError)
        captures[.providerOutbound] = providerCapture.outbound
        captures[.parserMemory] = providerCapture.parserMemory
        captures[.tempFilename] = try directoryNames(nativeDirectory)
        captures[.tempContents] = try directoryContents(nativeDirectory)

        let cache = CanonicalAudioCache(directory: cacheDirectory)
        let lastAudio = LastAudioArtifactStore()
        if source == .canonicalAudio {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            var wav = WAVTestFixture.wav(samples: 480)
            let payload = Data(canary.utf8); wav.replaceSubrange(44..<(44 + payload.count), with: payload)
            let canonicalTemp = sourceRoot.appendingPathComponent("aloud-canonical-\(UUID().uuidString).wav")
            try wav.write(to: canonicalTemp)
            let revision = UUID(); let generation = SessionGeneration(rawValue: 1)
            let coordinator = CanonicalChunkCacheCoordinator(cache: cache)
            await coordinator.advance(providerID: .openAI, revision: revision, generation: generation)
            let fingerprint = RequestFingerprint(rawValue: Data(repeating: 7, count: 32))!
            let validated = try WAVValidator.validate(canonicalTemp, purpose: .reading(.speak))
            let cached = try await coordinator.resolve(key: .init(providerID: .openAI, fingerprint: fingerprint, scopeRevision: revision), generation: generation, purpose: .reading(.speak)) { UnpublishedArtifact(artifact: validated) }
            try await lastAudio.promote(cached, generation: generation, purpose: .reading(.speak), evidence: .init(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date()))
            let destination = sourceRoot.appendingPathComponent(Engine.exportFilenameStem(Date(timeIntervalSince1970: 0)) + ".wav")
            _ = try await AudioExporter.saveAudio(from: lastAudio, to: destination)
            captures[.exportFilename] = Data(destination.lastPathComponent.utf8)
            captures[.exportContents] = try Data(contentsOf: destination)
        } else {
            captures[.exportFilename] = Data((Engine.exportFilenameStem(Date(timeIntervalSince1970: 0)) + ".wav").utf8)
            captures[.exportContents] = Data()
        }
        captures[.cacheFilename] = try directoryNames(cacheDirectory)
        captures[.cacheContents] = try directoryContents(cacheDirectory)
        if let retained = await lastAudio.currentArtifact() { captures[.lastAudio] = try Data(contentsOf: retained.url) }
        else { captures[.lastAudio] = Data() }

        for sink in PrivacyIntegrationSink.allCases where captures[sink] == nil { captures[sink] = Data() }
        let expected: Set<PrivacyIntegrationSink> = switch source {
        case .secret: [.keychain, .providerOutbound]
        case .authorizedText: [.history, .providerOutbound]
        case .fixedPreview: [.providerOutbound]
        case .rawErrorHeader: [.parserMemory]
        case .nativeAudio: [.tempContents, .parserMemory]
        case .canonicalAudio: [.cacheContents, .lastAudio, .exportContents]
        }
        return PrivacyIntegrationResult(canary: canary, captures: captures, expectedMatches: expected)
    }

    private func exerciseProvider(source: PrivacySourceCategory, canary: String, nativeDirectory: URL) async throws -> (safeError: Data, outbound: Data, parserMemory: Data) {
        var successfulWAV = WAVTestFixture.wav(samples: 480)
        if source == .nativeAudio {
            let payload = Data(canary.utf8); successfulWAV.replaceSubrange(44..<(44 + payload.count), with: payload)
        }
        let rawFailure = try JSONSerialization.data(withJSONObject: ["error": ["message": source == .rawErrorHeader ? canary : "safe"]])
        let response = source == .nativeAudio ? OpenAIHTTPResponse(statusCode: 200, body: successfulWAV) : OpenAIHTTPResponse(statusCode: 500, body: rawFailure)
        let client = PrivacyOpenAIHTTPClient(response: response)
        let provider = try OpenAIProvider(modelID: ModelID(rawValue: "tts-1"), httpClient: client, nativeDirectory: nativeDirectory)
        let revision = UUID(); let selection = ProviderSelection(providerID: .openAI, modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy"), rate: NormalizedRate(version: OpenAIRateMappingV1.version, value: 0)!)
        let input = (source == .authorizedText || source == .fixedPreview) ? canary : "safe input"
        let chunks = try await provider.split(input, selection: selection)
        let request = try SpeechRequest.make(id: .init(rawValue: UUID()), selection: selection, chunk: chunks[0], controls: OpenAIRateMappingV1.controls(for: selection.rate), credentialScopeRevision: revision, capabilities: provider.capabilities, outputFormatID: OpenAIWireContractV1.outputFormatID, canonicalizerVersion: "canonical-wav-v1")
        let secret = source == .secret ? canary : "safe-key"
        do {
            let owned = try await provider.synthesize(request, credential: .apiKey(providerID: .openAI, envelope: .init(providerID: .openAI, revision: revision, secret: Data(secret.utf8))))
            // The native temp remains long enough for the matrix to capture its
            // actual bytes; the source-root cleanup owns its final removal.
            _ = owned
            let request = await client.capturedRequest()
            return (Data(), serialize(request), response.body)
        } catch {
            let request = await client.capturedRequest()
            return (Data(PrivacySafeMessage.speechFailed(error).utf8), serialize(request), response.body)
        }
    }

    private func serialize(_ request: URLRequest?) -> Data {
        guard let request else { return Data() }
        var data = Data((request.url?.absoluteString ?? "").utf8)
        for (name, value) in request.allHTTPHeaderFields?.sorted(by: { $0.key < $1.key }) ?? [] { data.append(Data("\0\(name):\(value)".utf8)) }
        data.append(request.httpBody ?? Data())
        return data
    }

    private func directoryNames(_ directory: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: directory.path) else { return Data() }
        return Data(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().joined(separator: "\0").utf8)
    }
    private func directoryContents(_ directory: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: directory.path) else { return Data() }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }.reduce(into: Data()) { bytes, url in
            if let data = try? Data(contentsOf: url) { bytes.append(data) }
        }
    }

}

private func privacyAuditCanary() -> String {
    (UUID().uuidString + UUID().uuidString).unicodeScalars.map { scalar in
        String(UnicodeScalar(0x3400 + Int(scalar.value % 1_000))!)
    }.joined()
}

private final class PrivacyOnePasswordCapture: @unchecked Sendable, OnePasswordLaunching {
    private let lock = NSLock(); private let output: Data
    private var capturedArguments: [String]?; private var capturedEnvironment: [String: String]?; private var capturedTimeout: Duration?
    init(output: Data) { self.output = output }
    var arguments: [String]? { lock.withLock { capturedArguments } }
    var environment: [String: String]? { lock.withLock { capturedEnvironment } }
    var timeout: Duration? { lock.withLock { capturedTimeout } }
    func read(executable: String, arguments: [String], environment: [String : String], stdout: OnePasswordOutputSink, stderr: OnePasswordErrorSink, timeout: Duration) async throws -> Data {
        lock.withLock { capturedArguments = arguments; capturedEnvironment = environment; capturedTimeout = timeout }
        return output
    }
}

private enum PrivacyAuditCanaryRegistry {
    static func write(_ canaries: [String]) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = root.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try write(canaries, to: build.appendingPathComponent("task-21-fix6-canaries.txt"), runID: UUID())
    }
    static func write(_ canaries: [String], to url: URL, runID: UUID) throws {
        let payload = canaries.sorted().joined(separator: "\n") + "\n"
        let digest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        let registry = "version=1\nrun=\(runID.uuidString)\npayload_sha256=\(digest)\n" + payload
        try Data(registry.utf8).write(to: url, options: .atomic)
    }
}


private enum PrivacyAuditScript {
    static func run(script: URL, evidence: URL, sources: URL, registry: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process(); let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = script; process.arguments = [evidence.path, sources.path, registry.path]
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"]
        process.standardOutput = stdout; process.standardError = stderr
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

private extension Dictionary {
    func mapKeys<NewKey: Hashable>(_ transform: (Key) -> NewKey) -> [NewKey: Value] {
        Dictionary<NewKey, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

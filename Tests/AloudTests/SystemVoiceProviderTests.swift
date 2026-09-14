import AVFoundation
import XCTest
@testable import Aloud

final class SystemVoiceProviderTests: XCTestCase {
    func testNoneCredentialLoadsInstalledVoicesAsStableLocalIDs() async throws {
        let synthesizer = RecordingSystemSpeechSynthesizer(
            voices: [
                SystemVoiceDescriptor(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US"),
                SystemVoiceDescriptor(identifier: "com.apple.voice.compact.zh-CN.Tingting", name: "Tingting", language: "zh-CN"),
            ]
        )
        let provider = try SystemVoiceProvider(
            synthesizer: synthesizer,
            nativeDirectory: FileManager.default.temporaryDirectory
        )

        let catalog = try await provider.systemCatalog(using: .none)

        XCTAssertEqual(catalog.availability.kind, .available)
        XCTAssertEqual(
            catalog.voices.map(\.id),
            [
                VoiceID(rawValue: "macos.com.apple.voice.compact.en-US.Samantha"),
                VoiceID(rawValue: "macos.com.apple.voice.compact.zh-CN.Tingting"),
            ]
        )
        let voiceCallCount = await synthesizer.installedVoiceCallCount()
        XCTAssertEqual(voiceCallCount, 1)
    }

    func testNoInstalledVoiceIsLocallyUnavailableAndAPIKeyIsRejectedWithoutWriterAccess() async throws {
        let synthesizer = RecordingSystemSpeechSynthesizer(voices: [])
        let provider = try SystemVoiceProvider(
            synthesizer: synthesizer,
            nativeDirectory: FileManager.default.temporaryDirectory
        )
        let catalog = try await provider.systemCatalog(using: .none)
        XCTAssertEqual(catalog.voices, [])
        XCTAssertEqual(catalog.availability.kind, .disabled)
        XCTAssertEqual(catalog.availability.reason, .noEligibleLocalVoice)

        let credential = ProviderCredential.apiKey(
            providerID: .macOS,
            envelope: CredentialEnvelope(providerID: .macOS, revision: UUID(), secret: Data("trap".utf8))
        )
        await XCTAssertThrowsErrorAsync(try await provider.loadCatalog(using: credential))
        let request = try await makeSystemRequest(provider: provider, voiceIdentifier: "missing", rate: 0)
        await XCTAssertThrowsErrorAsync(
            try await ProviderSynthesisGate(provider: provider).synthesize(request, credential: credential)
        )
        let voiceCalls = await synthesizer.installedVoiceCallCount()
        let writeCalls = await synthesizer.writeCallCount()
        XCTAssertEqual(voiceCalls, 1)
        XCTAssertEqual(writeCalls, 0)
        let model = try XCTUnwrap(
            try ProviderContractCatalog.bundled().contract(for: .macOS)?.models[SystemVoiceContractV1.modelID]?.availability
        )
        XCTAssertEqual(
            SelectionGate.evaluate(
                credential: .noneRequired,
                provider: catalog.availability,
                model: model,
                account: .unknown,
                featureFlag: false,
                releaseApproved: false
            ),
            .blocked(.providerDisabled)
        )
        XCTAssertEqual(try ProviderContractCatalog.bundled().providerAvailability(for: .openAI).kind, .available)
    }

    func testNoneCredentialSynthesizesOwnedPCMAndCanonicalizesThroughFakeWAVBoundary() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let voice = SystemVoiceDescriptor(identifier: "voice.fixture", name: "Fixture", language: "en-US")
        let synthesizer = RecordingSystemSpeechSynthesizer(
            voices: [voice],
            output: .success((Data(repeating: 0, count: 640), .pcm(sampleRate: 32_000, channels: 1, bitDepth: 16, littleEndian: true)))
        )
        let provider = try SystemVoiceProvider(synthesizer: synthesizer, nativeDirectory: directory.url)
        let request = try await makeSystemRequest(provider: provider, voiceIdentifier: voice.identifier, rate: 0)
        let native = try await ProviderSynthesisGate(provider: provider).synthesize(request, credential: .none)
        defer { native.cleanupIfOwned() }

        XCTAssertEqual(native.format, .pcm(sampleRate: 32_000, channels: 1, bitDepth: 16, littleEndian: true))
        XCTAssertEqual(try Data(contentsOf: native.url), Data(repeating: 0, count: 640))
        let writes = await synthesizer.recordedWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].request.voiceIdentifier, voice.identifier)
        XCTAssertEqual(writes[0].request.rate, SystemVoiceRateMappingV1.systemRate(for: request.selection.rate))

        let driver = ScriptedWAVDriver(mode: .succeed)
        let canonical = try await WAVCanonicalizer(
            runner: WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver)
        ).canonicalize(native.artifact, destinationDirectory: directory.url)
        XCTAssertTrue(canonical.isCanonical)
        XCTAssertEqual(canonical.format, AudioFormatID())
    }

    func testStableScopeAndEveryLocalMappingDimensionRotatesFingerprint() async throws {
        let voice = SystemVoiceDescriptor(identifier: "voice.a", name: "A", language: "en-US")
        let provider = try SystemVoiceProvider(
            synthesizer: RecordingSystemSpeechSynthesizer(voices: [voice]),
            nativeDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(SystemVoiceContractV1.scopeRevision, UUID(uuidString: "7893a629-c6e8-5e8c-b7d4-e8fdb6cd5768"))
        let base = try await makeSystemRequest(provider: provider, voiceIdentifier: voice.identifier, rate: 0)
        let changedVoice = try await makeSystemRequest(provider: provider, voiceIdentifier: "voice.b", rate: 0)
        let changedRate = try systemRequestVariant(base, controls: try SynthesisControls(
            renderedFields: [SynthesisControlField(name: "rate", value: "0.5")],
            mappingVersion: "macos-rate-v2",
            templateVersion: nil
        ))
        let changedOutput = try systemRequestVariant(base, outputFormatID: "runtime-pcm|macos-native-v2")
        let changedCanonical = try systemRequestVariant(base, canonicalizerVersion: "canonical-wav-v2")
        XCTAssertEqual(Set([base.requestFingerprint, changedVoice.requestFingerprint, changedRate.requestFingerprint, changedOutput.requestFingerprint, changedCanonical.requestFingerprint]).count, 5)
        XCTAssertEqual(SystemVoiceRateMappingV1.systemRate(for: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: -100)!), 0, accuracy: 0.0001)
        XCTAssertEqual(SystemVoiceRateMappingV1.systemRate(for: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: 0)!), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SystemVoiceRateMappingV1.systemRate(for: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: 100)!), 1, accuracy: 0.0001)
    }

    func testCancellationAfterWriterCreatesNativeFileRemovesIt() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let barrier = SystemWriteBarrier()
        let voice = SystemVoiceDescriptor(identifier: "voice.cancel", name: "Cancel", language: "en-US")
        let synthesizer = RecordingSystemSpeechSynthesizer(
            voices: [voice],
            output: .success((Data([0, 0]), .pcm(sampleRate: 24_000, channels: 1, bitDepth: 16, littleEndian: true))),
            afterWrite: { await barrier.suspend() }
        )
        let provider = try SystemVoiceProvider(synthesizer: synthesizer, nativeDirectory: directory.url)
        let request = try await makeSystemRequest(provider: provider, voiceIdentifier: voice.identifier, rate: 0)
        let task = Task { try await ProviderSynthesisGate(provider: provider).synthesize(request, credential: .none) }
        await barrier.waitUntilReached()
        task.cancel()
        await barrier.release()
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [])
    }

    func testAVClientWritesEveryPCMFrameAndCompletesOnceAtTerminalBuffer() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let destination = directory.url.appendingPathComponent("native.caf")
        let source = RecordingSystemBufferSource(voices: [])
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 32_000, channels: 1, interleaved: true))
        let first = try pcmBuffer(format: format, frames: 3, value: 0.25)
        let second = try pcmBuffer(format: format, frames: 2, value: -0.5)
        let terminal = try pcmBuffer(format: format, frames: 0, value: 0)
        source.buffersOnStart = [first, second, terminal, terminal]

        let nativeFormat = try await AVSpeechSynthesizerClient(source: source).write(
            SystemSpeechWriteRequest(text: "fixture", voiceIdentifier: "voice.fixture", rate: 0.5),
            to: destination
        )

        XCTAssertEqual(nativeFormat, .pcm(sampleRate: 32_000, channels: 1, bitDepth: 16, littleEndian: true))
        XCTAssertEqual(try Data(contentsOf: destination).count, 10)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 0)
    }

    func testAVClientCapturesFirstBufferFormatForMonoAndStereo() async throws {
        let cases: [(Double, AVAudioChannelCount, NativeAudioFormat)] = [
            (32_000, 1, .pcm(sampleRate: 32_000, channels: 1, bitDepth: 16, littleEndian: true)),
            (48_000, 2, .pcm(sampleRate: 48_000, channels: 2, bitDepth: 16, littleEndian: true)),
        ]
        for (sampleRate, channels, expected) in cases {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let destination = directory.url.appendingPathComponent("native.pcm")
            let source = RecordingSystemBufferSource(voices: [])
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: true
            ))
            source.buffersOnStart = [
                try pcmBuffer(format: format, frames: 4, value: 0.25),
                try pcmBuffer(format: format, frames: 0, value: 0),
            ]
            let result = try await AVSpeechSynthesizerClient(source: source).write(
                SystemSpeechWriteRequest(text: "fixture", voiceIdentifier: "voice.fixture", rate: 0.5),
                to: destination
            )
            XCTAssertEqual(result, expected)
            XCTAssertEqual(try Data(contentsOf: destination).count, 4 * Int(channels) * 2)
        }
    }

    func testAVClientConvertsSystemFloatBuffersToInterleavedInt16() async throws {
        for channels: AVAudioChannelCount in [1, 2] {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let destination = directory.url.appendingPathComponent("system.pcm")
            let source = RecordingSystemBufferSource(voices: [])
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: channels))
            let buffer = try pcmBuffer(format: format, frames: 4, value: 0.25)
            if channels == 2 {
                for frame in 0..<4 { buffer.floatChannelData![1][frame] = -0.5 }
            }
            source.buffersOnStart = [buffer, try pcmBuffer(format: format, frames: 0, value: 0)]
            let result = try await AVSpeechSynthesizerClient(source: source).write(
                SystemSpeechWriteRequest(text: "fixture", voiceIdentifier: "voice.fixture", rate: 0.5), to: destination
            )
            XCTAssertEqual(result, .pcm(sampleRate: 22_050, channels: Int(channels), bitDepth: 16, littleEndian: true))
            let data = try Data(contentsOf: destination)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            XCTAssertEqual(samples.count, 4 * Int(channels))
            for (index, sample) in samples.enumerated() {
                XCTAssertEqual(Double(sample), channels == 2 && index % 2 == 1 ? -16_384 : 8_192, accuracy: 1)
            }
        }
    }

    func testAVClientRejectsFormatChangesAndUnsupportedFloat64WithoutLeavingDestination() async throws {
        let valid = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 32_000, channels: 1, interleaved: true))
        let changed = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        let float = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 24_000, channels: 1, interleaved: false))
        let cases = [
            [try pcmBuffer(format: valid, frames: 2, value: 0.1), try pcmBuffer(format: changed, frames: 2, value: 0.1)],
            [try pcmBuffer(format: float, frames: 2, value: 0.1)],
        ]
        for buffers in cases {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let destination = directory.url.appendingPathComponent("invalid.pcm")
            let source = RecordingSystemBufferSource(voices: [])
            source.buffersOnStart = buffers
            await XCTAssertThrowsErrorAsync(
                try await AVSpeechSynthesizerClient(source: source).write(
                    SystemSpeechWriteRequest(text: "fixture", voiceIdentifier: "voice.fixture", rate: 0.5),
                    to: destination
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testAVClientStartFailureRemovesPreexistingPartialDestination() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let destination = directory.url.appendingPathComponent("start-failure.pcm")
        try Data("partial".utf8).write(to: destination)
        let source = RecordingSystemBufferSource(voices: [])
        source.startError = SystemVoiceProviderError.nativeWriteFailed
        await XCTAssertThrowsErrorAsync(
            try await AVSpeechSynthesizerClient(source: source).write(
                SystemSpeechWriteRequest(text: "fixture", voiceIdentifier: "voice.fixture", rate: 0.5),
                to: destination
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAVClientCancellationStopsImmediatelyAndProviderOwnsPartialFileCleanup() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let source = RecordingSystemBufferSource(voices: [
            SystemVoiceDescriptor(identifier: "voice.cancel", name: "Cancel", language: "en-US")
        ])
        source.holdOpen = true
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
        source.buffersOnStart = [try pcmBuffer(format: format, frames: 2, value: 0.5)]
        let client = AVSpeechSynthesizerClient(source: source)
        let provider = try SystemVoiceProvider(synthesizer: client, nativeDirectory: directory.url)
        let request = try await makeSystemRequest(provider: provider, voiceIdentifier: "voice.cancel", rate: 0)
        let task = Task { try await ProviderSynthesisGate(provider: provider).synthesize(request, credential: .none) }
        await source.waitUntilStarted()
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [])
    }

    func testTwentyPreStartCancellationsNeverStartOrLeaveAFile() async throws {
        for round in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let barrier = SystemWriteBarrier()
            let source = RecordingSystemBufferSource(voices: [])
            let client = AVSpeechSynthesizerClient(source: source, beforeStart: { await barrier.suspend() })
            let destination = directory.url.appendingPathComponent("prestart-\(round).pcm")
            let task = Task {
                try await client.write(
                    SystemSpeechWriteRequest(text: "fixture", voiceIdentifier: "voice.fixture", rate: 0.5),
                    to: destination
                )
            }
            await barrier.waitUntilReached()
            task.cancel()
            await barrier.release()
            await XCTAssertThrowsErrorAsync(try await task.value)
            XCTAssertEqual(source.startCount, 0, "round=\(round)")
            XCTAssertEqual(source.stopCount, 0, "round=\(round)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "round=\(round)")
        }
    }
}

private actor RecordingSystemSpeechSynthesizer: SystemSpeechSynthesizing {
    private let voices: [SystemVoiceDescriptor]
    private let output: Result<(Data, NativeAudioFormat), Error>
    private let afterWrite: @Sendable () async -> Void
    private var voiceCalls = 0
    private var writes: [(request: SystemSpeechWriteRequest, destination: URL)] = []

    init(
        voices: [SystemVoiceDescriptor],
        output: Result<(Data, NativeAudioFormat), Error> = .failure(SystemVoiceProviderError.nativeWriteFailed),
        afterWrite: @escaping @Sendable () async -> Void = {}
    ) {
        self.voices = voices
        self.output = output
        self.afterWrite = afterWrite
    }

    func installedVoices() async -> [SystemVoiceDescriptor] {
        voiceCalls += 1
        return voices
    }

    func write(_ request: SystemSpeechWriteRequest, to destination: URL) async throws -> NativeAudioFormat {
        writes.append((request, destination))
        let (data, format) = try output.get()
        try data.write(to: destination, options: .atomic)
        await afterWrite()
        try Task.checkCancellation()
        return format
    }

    func installedVoiceCallCount() -> Int { voiceCalls }
    func writeCallCount() -> Int { writes.count }
    func recordedWrites() -> [(request: SystemSpeechWriteRequest, destination: URL)] { writes }
}

private actor SystemWriteBarrier {
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        reached = true
        reachedWaiters.forEach { $0.resume() }
        reachedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class RecordingSystemBufferSource: SystemSpeechBufferSource, @unchecked Sendable {
    let voices: [SystemVoiceDescriptor]
    var buffersOnStart: [AVAudioPCMBuffer] = []
    var holdOpen = false
    var startError: Error?
    private let lock = NSLock()
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(voices: [SystemVoiceDescriptor]) { self.voices = voices }
    func installedVoices() -> [SystemVoiceDescriptor] { voices }
    func start(
        _ request: SystemSpeechWriteRequest,
        callback: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        if let startError { throw startError }
        let (buffers, waiters): ([AVAudioPCMBuffer], [CheckedContinuation<Void, Never>]) = lock.withLock {
            startCount += 1
            started = true
            activeCallback = callback
            let waiters = startWaiters
            startWaiters.removeAll()
            return (buffersOnStart, waiters)
        }
        waiters.forEach { $0.resume() }
        for buffer in buffers { callback(buffer) }
        if !holdOpen, buffers.isEmpty {
            let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
            let terminal = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            terminal.frameLength = 0
            callback(terminal)
        }
    }
    func stopImmediately() {
        let callback = lock.withLock {
            stopCount += 1
            return activeCallback
        }
        if let callback {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
            let terminal = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            terminal.frameLength = 0
            callback(terminal)
        }
    }
    func waitUntilStarted() async {
        let alreadyStarted = lock.withLock { started }
        guard !alreadyStarted else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if started { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private func pcmBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, value: Float) throws -> AVAudioPCMBuffer {
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
    buffer.frameLength = frames
    if format.commonFormat == .pcmFormatInt16 {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let audioBuffer = try XCTUnwrap(list.first)
        let pointer = try XCTUnwrap(audioBuffer.mData?.assumingMemoryBound(to: Int16.self))
        for sample in 0..<(Int(frames) * Int(format.channelCount)) {
            pointer[sample] = Int16(value * Float(Int16.max))
        }
    } else if let channels = buffer.floatChannelData {
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) { channels[channel][frame] = value }
        }
    }
    return buffer
}

private func makeSystemRequest(
    provider: SystemVoiceProvider,
    voiceIdentifier: String,
    rate: Int
) async throws -> SpeechRequest {
    let selection = ProviderSelection(
        providerID: .macOS,
        modelID: SystemVoiceContractV1.modelID,
        voiceID: VoiceID(rawValue: "macos.\(voiceIdentifier)"),
        rate: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: rate)!
    )
    let chunks = try await provider.split("fixture", selection: selection)
    let chunk = try XCTUnwrap(chunks.first)
    return try SpeechRequest.make(
        id: SpeechRequestID(rawValue: UUID()),
        selection: selection,
        chunk: chunk,
        controls: SystemVoiceRateMappingV1.controls(for: selection.rate),
        credentialScopeRevision: SystemVoiceContractV1.scopeRevision,
        capabilities: provider.capabilities,
        outputFormatID: SystemVoiceContractV1.outputFormatID,
        canonicalizerVersion: "canonical-wav-v1"
    )
}

private func systemRequestVariant(
    _ base: SpeechRequest,
    controls: SynthesisControls? = nil,
    outputFormatID: String? = nil,
    canonicalizerVersion: String? = nil
) throws -> SpeechRequest {
    try SpeechRequest.make(
        id: base.id,
        selection: base.selection,
        chunk: base.chunk,
        controls: controls ?? base.controls,
        credentialScopeRevision: base.credentialScopeRevision,
        capabilities: SystemVoiceContractV1.capabilities,
        outputFormatID: outputFormatID ?? base.outputFormatID,
        canonicalizerVersion: canonicalizerVersion ?? base.canonicalizerVersion
    )
}

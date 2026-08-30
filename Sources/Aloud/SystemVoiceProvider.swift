import AVFoundation
import Foundation

struct SystemVoiceDescriptor: Equatable, Hashable, Sendable {
    let identifier: String
    let name: String
    let language: String
}

struct SystemVoiceCatalogEntry: Equatable, Hashable, Sendable {
    let id: VoiceID
    let systemIdentifier: String
    let name: String
    let language: String
}

struct SystemVoiceCatalog: Equatable, Sendable {
    let voices: [SystemVoiceCatalogEntry]
    let availability: ProviderAvailability
}

struct SystemSpeechWriteRequest: Equatable, Sendable {
    let text: String
    let voiceIdentifier: String
    let rate: Float
}

protocol SystemSpeechSynthesizing: Sendable {
    func installedVoices() async -> [SystemVoiceDescriptor]
    func write(_ request: SystemSpeechWriteRequest, to destination: URL) async throws -> NativeAudioFormat
}

protocol SystemSpeechBufferSource: Sendable {
    func installedVoices() -> [SystemVoiceDescriptor]
    func start(
        _ request: SystemSpeechWriteRequest,
        callback: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws
    func stopImmediately()
}

final class AVSpeechSynthesizerBufferSource: SystemSpeechBufferSource, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    func installedVoices() -> [SystemVoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SystemVoiceDescriptor(identifier: $0.identifier, name: $0.name, language: $0.language)
        }
    }

    func start(
        _ request: SystemSpeechWriteRequest,
        callback: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        guard let voice = AVSpeechSynthesisVoice(identifier: request.voiceIdentifier) else {
            throw SystemVoiceProviderError.unsupportedSelection
        }
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = voice
        utterance.rate = request.rate
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            callback(pcm)
        }
    }

    func stopImmediately() { _ = synthesizer.stopSpeaking(at: .immediate) }
}

struct AVSpeechSynthesizerClient: SystemSpeechSynthesizing {
    private let source: any SystemSpeechBufferSource
    private let beforeStart: @Sendable () async -> Void

    init(
        source: any SystemSpeechBufferSource = AVSpeechSynthesizerBufferSource(),
        beforeStart: @escaping @Sendable () async -> Void = {}
    ) {
        self.source = source
        self.beforeStart = beforeStart
    }

    func installedVoices() async -> [SystemVoiceDescriptor] { source.installedVoices() }

    func write(_ request: SystemSpeechWriteRequest, to destination: URL) async throws -> NativeAudioFormat {
        let state = SystemSpeechBufferWriteState(destination: destination)
        let lifecycle = SystemSpeechStartStopGate(source: source, state: state)
        do {
            let format = try await withTaskCancellationHandler(operation: {
                await beforeStart()
                return try await withCheckedThrowingContinuation { continuation in
                    state.install(continuation)
                    lifecycle.start(request)
                }
            }, onCancel: {
                lifecycle.cancel()
            })
            try Task.checkCancellation()
            return format
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

private final class SystemSpeechStartStopGate: @unchecked Sendable {
    private let lock = NSLock()
    private let source: any SystemSpeechBufferSource
    private let state: SystemSpeechBufferWriteState

    init(source: any SystemSpeechBufferSource, state: SystemSpeechBufferWriteState) {
        self.source = source
        self.state = state
    }

    func start(_ request: SystemSpeechWriteRequest) {
        lock.lock()
        guard state.claimStart() else {
            lock.unlock()
            return
        }
        do {
            try source.start(request) { [state] buffer in state.consume(buffer) }
            lock.unlock()
        } catch {
            lock.unlock()
            state.fail(error)
        }
    }

    func cancel() {
        lock.lock()
        let disposition = state.requestCancellation()
        if disposition == .stopStarted { source.stopImmediately() }
        lock.unlock()
        if disposition == .finishBeforeStart { state.fail(CancellationError()) }
    }
}

private final class SystemSpeechBufferWriteState: @unchecked Sendable {
    enum CancellationDisposition: Equatable { case none, finishBeforeStart, stopStarted }
    private let lock = NSLock()
    private let destination: URL
    private var continuation: CheckedContinuation<NativeAudioFormat, Error>?
    private var file: FileHandle?
    private var nativeFormat: NativeAudioFormat?
    private var streamSignature: SystemPCMStreamSignature?
    private var completed = false
    private var started = false
    private var cancellationRequested = false
    private var sawFrames = false

    init(destination: URL) { self.destination = destination }

    func install(_ continuation: CheckedContinuation<NativeAudioFormat, Error>) {
        lock.withLock {
            guard !completed else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
        }
    }

    func claimStart() -> Bool {
        lock.withLock {
            guard !completed, !cancellationRequested, !started else { return false }
            started = true
            return true
        }
    }

    func requestCancellation() -> CancellationDisposition {
        lock.withLock {
            guard !completed else { return .none }
            cancellationRequested = true
            return started ? .stopStarted : .finishBeforeStart
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let result: Result<NativeAudioFormat, Error>?
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        do {
            if buffer.frameLength == 0 {
                guard sawFrames, let nativeFormat else { throw SystemVoiceProviderError.nativeWriteFailed }
                try file?.close()
                file = nil
                result = cancellationRequested ? .failure(CancellationError()) : .success(nativeFormat)
            } else {
                let parsed = try SystemPCMStreamSignature(buffer: buffer)
                if let streamSignature {
                    guard streamSignature == parsed else { throw SystemVoiceProviderError.nativeWriteFailed }
                } else {
                    streamSignature = parsed
                    nativeFormat = parsed.nativeFormat
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                        throw SystemVoiceProviderError.nativeWriteFailed
                    }
                    file = try FileHandle(forWritingTo: destination)
                }
                try file?.write(contentsOf: parsed.frameData(from: buffer))
                sawFrames = true
                result = nil
            }
        } catch {
            result = .failure(error)
        }
        lock.unlock()
        if let result { finish(result) }
    }

    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<NativeAudioFormat, Error>) {
        let completion: (CheckedContinuation<NativeAudioFormat, Error>?, Bool)? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            try? file?.close()
            file = nil
            let current = self.continuation
            self.continuation = nil
            if case .failure = result { return (current, true) }
            return (current, false)
        }
        guard let completion else { return }
        if completion.1 { try? FileManager.default.removeItem(at: destination) }
        completion.0?.resume(with: result)
    }
}

private struct SystemPCMStreamSignature: Equatable {
    let sampleRate: Int
    let channels: Int
    let bitDepth: Int
    let bytesPerFrame: Int

    init(buffer: AVAudioPCMBuffer) throws {
        let stream = buffer.format.streamDescription.pointee
        let flags = stream.mFormatFlags
        guard stream.mFormatID == kAudioFormatLinearPCM,
              flags & kAudioFormatFlagIsSignedInteger != 0,
              flags & kAudioFormatFlagIsPacked != 0,
              flags & kAudioFormatFlagIsNonInterleaved == 0,
              flags & kAudioFormatFlagIsBigEndian == 0,
              stream.mSampleRate.isFinite,
              stream.mSampleRate > 0,
              stream.mSampleRate.rounded() == stream.mSampleRate,
              stream.mChannelsPerFrame > 0,
              stream.mBitsPerChannel == 16,
              stream.mBytesPerFrame == stream.mChannelsPerFrame * 2 else {
            throw SystemVoiceProviderError.nativeWriteFailed
        }
        sampleRate = Int(stream.mSampleRate)
        channels = Int(stream.mChannelsPerFrame)
        bitDepth = Int(stream.mBitsPerChannel)
        bytesPerFrame = Int(stream.mBytesPerFrame)
    }

    var nativeFormat: NativeAudioFormat {
        .pcm(sampleRate: sampleRate, channels: channels, bitDepth: bitDepth, littleEndian: true)
    }

    func frameData(from buffer: AVAudioPCMBuffer) throws -> Data {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard buffers.count == 1,
              let bytes = buffers[0].mData,
              Int(buffers[0].mDataByteSize) == Int(buffer.frameLength) * bytesPerFrame else {
            throw SystemVoiceProviderError.nativeWriteFailed
        }
        return Data(bytes: bytes, count: Int(buffers[0].mDataByteSize))
    }
}

enum SystemVoiceProviderError: Error, Equatable, Sendable {
    case credentialNotAllowed
    case noEligibleLocalVoice
    case unsupportedSelection
    case nativeWriteFailed
}

enum SystemVoiceContractV1 {
    static let modelID = ModelID(rawValue: "system-speech")
    static let version = ContractVersion(rawValue: "macos-system-speech-v1")
    static let rateMappingVersion = "macos-rate-v1"
    static let outputMappingVersion = "macos-native-v1"
    static let outputFormatID = "runtime-pcm|macos-native-v1"
    static let scopeRevision = UUID(uuidString: "7893a629-c6e8-5e8c-b7d4-e8fdb6cd5768")!
    static let capabilities: ProviderCapabilities = {
        let limit = try! InputLimit(
            endpoint: "AVSpeechSynthesizer.write",
            unit: .utf8Bytes,
            maximum: Int.max,
            safetyMargin: 0,
            contractVersion: version
        )
        return try! ProviderCapabilities(
            inputLimits: [limit],
            outputFormat: .encoded(container: "runtime-pcm", codec: outputMappingVersion),
            contractVersion: version
        )
    }()
}

enum SystemVoiceRateMappingV1 {
    static let version = SystemVoiceContractV1.rateMappingVersion

    static func systemRate(for rate: NormalizedRate) -> Float {
        guard rate.version == version else { return AVSpeechUtteranceDefaultSpeechRate }
        if rate.value <= 0 {
            let fraction = Float(rate.value + 100) / 100
            return AVSpeechUtteranceMinimumSpeechRate +
                fraction * (AVSpeechUtteranceDefaultSpeechRate - AVSpeechUtteranceMinimumSpeechRate)
        }
        let fraction = Float(rate.value) / 100
        return AVSpeechUtteranceDefaultSpeechRate +
            fraction * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceDefaultSpeechRate)
    }

    static func controls(for rate: NormalizedRate) throws -> SynthesisControls {
        guard rate.version == version else { throw InputValidationError.invalidLimit }
        return try SynthesisControls(
            renderedFields: [
                SynthesisControlField(
                    name: "rate",
                    value: String(
                        format: "%.4f",
                        locale: Locale(identifier: "en_US_POSIX"),
                        systemRate(for: rate)
                    )
                )
            ],
            mappingVersion: version,
            templateVersion: nil
        )
    }
}

struct SystemVoiceProvider: VoiceProvider {
    let id = ProviderID.macOS
    let capabilities = SystemVoiceContractV1.capabilities
    let synthesizer: any SystemSpeechSynthesizing
    let nativeDirectory: URL

    init(synthesizer: any SystemSpeechSynthesizing, nativeDirectory: URL) throws {
        self.synthesizer = synthesizer
        self.nativeDirectory = nativeDirectory
    }

    func systemCatalog(using credential: ProviderCredential) async throws -> SystemVoiceCatalog {
        try requireNone(credential)
        let voices = await synthesizer.installedVoices()
            .filter { !$0.identifier.isEmpty }
            .map {
                SystemVoiceCatalogEntry(
                    id: VoiceID(rawValue: "macos.\($0.identifier)"),
                    systemIdentifier: $0.identifier,
                    name: $0.name,
                    language: $0.language
                )
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        let availability = ProviderAvailability(
            kind: voices.isEmpty ? .disabled : .available,
            reason: voices.isEmpty ? .noEligibleLocalVoice : nil,
            maturity: .stable,
            featureFlagName: nil,
            featureFlagEnabled: nil,
            providerContractVersion: ContractVersion(rawValue: "provider-contracts-v1"),
            evidenceID: "macos-provider"
        )
        return SystemVoiceCatalog(voices: voices, availability: availability)
    }

    func measureInput(_ text: String, requestOverhead: RequestOverhead) async throws -> InputMeasurement {
        guard requestOverhead == capabilities.requestOverhead else { throw InputValidationError.invalidLimit }
        return try await InputMeasurement.measure(text, limits: capabilities.inputLimits, requestOverhead: requestOverhead)
    }

    func split(_ text: String, selection: ProviderSelection) async throws -> [ValidatedSpeechChunk] {
        try validateStaticSelection(selection)
        return try await ProviderInputSplitter(capabilities: capabilities) { text, overhead in
            try await measureInput(text, requestOverhead: overhead)
        }.split(text)
    }

    func loadCatalog(using credential: ProviderCredential) async throws -> AccountCatalogSnapshot {
        _ = try await systemCatalog(using: credential)
        return .empty
    }

    func synthesize(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact {
        try requireNone(credential)
        try Task.checkCancellation()
        try validateStaticSelection(request.selection)
        guard request.credentialScopeRevision == SystemVoiceContractV1.scopeRevision,
              request.outputFormatID == SystemVoiceContractV1.outputFormatID,
              request.controls == (try SystemVoiceRateMappingV1.controls(for: request.selection.rate)),
              let selectedVoiceID = request.selection.voiceID else {
            throw SystemVoiceProviderError.unsupportedSelection
        }
        let catalog = try await systemCatalog(using: .none)
        guard catalog.availability.kind == .available else {
            throw SystemVoiceProviderError.noEligibleLocalVoice
        }
        guard let selected = catalog.voices.first(where: { $0.id == selectedVoiceID }) else {
            throw SystemVoiceProviderError.unsupportedSelection
        }
        let output = nativeDirectory.appendingPathComponent("aloud-system-native-\(UUID().uuidString).pcm")
        var returned = false
        defer { if !returned { try? FileManager.default.removeItem(at: output) } }
        do {
            try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
            let format = try await synthesizer.write(
                SystemSpeechWriteRequest(
                    text: request.chunk.text,
                    voiceIdentifier: selected.systemIdentifier,
                    rate: SystemVoiceRateMappingV1.systemRate(for: request.selection.rate)
                ),
                to: output
            )
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw SystemVoiceProviderError.nativeWriteFailed
            }
            switch format {
            case .pcm(let sampleRate, let channels, let bitDepth, let littleEndian):
                guard sampleRate > 0, channels > 0, bitDepth == 16, littleEndian else {
                    throw SystemVoiceProviderError.nativeWriteFailed
                }
            case .encoded(let container, let codec):
                guard !container.isEmpty, !codec.isEmpty else {
                    throw SystemVoiceProviderError.nativeWriteFailed
                }
            }
            returned = true
            return OwnedNativeAudioArtifact(
                artifact: NativeAudioArtifact(
                    url: output,
                    format: format,
                    purpose: .reading(.speak)
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SystemVoiceProviderError {
            throw error
        } catch {
            throw SystemVoiceProviderError.nativeWriteFailed
        }
    }

    private func requireNone(_ credential: ProviderCredential) throws {
        guard case .none = credential else { throw SystemVoiceProviderError.credentialNotAllowed }
    }

    private func validateStaticSelection(_ selection: ProviderSelection) throws {
        guard selection.providerID == .macOS,
              selection.modelID == SystemVoiceContractV1.modelID,
              selection.rate.version == SystemVoiceContractV1.rateMappingVersion,
              selection.voiceID != nil else {
            throw SystemVoiceProviderError.unsupportedSelection
        }
    }
}

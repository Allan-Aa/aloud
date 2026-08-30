import Foundation

struct AudioFormatID: Codable, Hashable, Sendable {
    let container: String
    let codec: String
    let sampleRate: Int
    let channels: Int
    let bitDepth: Int
    let canonicalizerVersion: Int

    init() { container = "riff-wave"; codec = "pcm-s16le"; sampleRate = 48_000; channels = 1; bitDepth = 16; canonicalizerVersion = 1 }
    private enum CodingKeys: String, CodingKey { case container, codec, sampleRate, channels, bitDepth, canonicalizerVersion }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); let container = try c.decode(String.self, forKey: .container); let codec = try c.decode(String.self, forKey: .codec); let rate = try c.decode(Int.self, forKey: .sampleRate); let channels = try c.decode(Int.self, forKey: .channels); let bits = try c.decode(Int.self, forKey: .bitDepth); let version = try c.decode(Int.self, forKey: .canonicalizerVersion); guard container == "riff-wave", codec == "pcm-s16le", rate == 48_000, channels == 1, bits == 16, version == 1 else { throw WAVAudioError.unsupportedFormat }; self.init() }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(container, forKey: .container); try c.encode(codec, forKey: .codec); try c.encode(sampleRate, forKey: .sampleRate); try c.encode(channels, forKey: .channels); try c.encode(bitDepth, forKey: .bitDepth); try c.encode(canonicalizerVersion, forKey: .canonicalizerVersion) }
}

struct AudioArtifact: Hashable, Sendable {
    let url: URL
    let format: AudioFormatID
    let duration: TimeInterval
    let purpose: SpeechPurpose
    let isCanonical: Bool
    fileprivate init(url: URL, duration: TimeInterval, purpose: SpeechPurpose) { self.url = url; format = AudioFormatID(); self.duration = duration; self.purpose = purpose; isCanonical = true }
}

enum WAVAudioError: Error, Equatable {
    case invalidContainer, invalidChunk, unsupportedFormat, invalidDuration, invalidNativePCM, overflow, legacyAudioRequiresCanonicalization, processCancellationUnacknowledged, processBusy, processDeadlineExceeded, processFailed(Int32), exportDestinationExists
}

extension WAVAudioError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .legacyAudioRequiresCanonicalization:
            return "Audio must be regenerated in the current WAV format."
        default:
            return "Audio could not be prepared safely."
        }
    }
}

enum LegacyAudioIsolation {
    static func requireCanonical(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "wav" else { throw WAVAudioError.legacyAudioRequiresCanonicalization }
        _ = try WAVValidator.validate(url, purpose: .preview)
    }
}

struct WAVHeader: Hashable, Sendable {
    let dataOffset: Int
    let dataLength: Int
    let format: AudioFormatID
}

enum WAVValidator {
    static func validate(_ url: URL, purpose: SpeechPurpose) throws -> AudioArtifact {
        let data = try Data(contentsOf: url)
        let header = try parse(data)
        let duration = TimeInterval(header.dataLength) / 96_000
        guard duration.isFinite, duration > 0 else { throw WAVAudioError.invalidDuration }
        return AudioArtifact(url: url, duration: duration, purpose: purpose)
    }

    static func pcmData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url); let header = try parse(data)
        return data.subdata(in: header.dataOffset..<(header.dataOffset + header.dataLength))
    }

    static func parse(_ data: Data) throws -> WAVHeader {
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WAVE".utf8), data.count >= 8 else { throw WAVAudioError.invalidContainer }
        let declared = try le32(data, 4)
        guard declared == data.count - 8 else { throw WAVAudioError.invalidContainer }
        var index = 12
        var foundFormat = false
        var dataOffset: Int?
        var dataLength: Int?
        while index < data.count {
            guard index <= data.count - 8 else { throw WAVAudioError.invalidChunk }
            let id = data.subdata(in: index..<(index + 4)); let count = Int(try le32(data, index + 4)); index += 8
            guard count >= 0, count <= data.count - index else { throw WAVAudioError.invalidChunk }
            let payloadStart = index; index += count
            if count.isMultiple(of: 2) == false {
                guard index < data.count else { throw WAVAudioError.invalidChunk }
                index += 1
            }
            if id == Data("fmt ".utf8) {
                guard !foundFormat, count == 16 else { throw WAVAudioError.unsupportedFormat }
                let formatCode = try le16(data, payloadStart)
                let channels = try le16(data, payloadStart + 2)
                let sampleRate = try le32(data, payloadStart + 4)
                let byteRate = try le32(data, payloadStart + 8)
                let blockAlign = try le16(data, payloadStart + 12)
                let bitDepth = try le16(data, payloadStart + 14)
                guard formatCode == 1, channels == 1, sampleRate == 48_000, byteRate == 96_000, blockAlign == 2, bitDepth == 16 else { throw WAVAudioError.unsupportedFormat }
                foundFormat = true
            } else if id == Data("data".utf8) {
                guard dataOffset == nil, count > 0, count.isMultiple(of: 2) else { throw WAVAudioError.invalidChunk }
                dataOffset = payloadStart; dataLength = count
            }
        }
        guard index == data.count, foundFormat, let dataOffset, let dataLength else { throw WAVAudioError.invalidChunk }
        return WAVHeader(dataOffset: dataOffset, dataLength: dataLength, format: AudioFormatID())
    }

    private static func le16(_ data: Data, _ offset: Int) throws -> Int {
        guard offset + 2 <= data.count else { throw WAVAudioError.invalidChunk }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }
    private static func le32(_ data: Data, _ offset: Int) throws -> Int {
        guard offset + 4 <= data.count else { throw WAVAudioError.invalidChunk }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }
}

struct WAVConversionCommand: Sendable {
    let id: UUID
    let inputURL: URL
    let inputFormat: NativeAudioFormat
    let outputURL: URL
}

struct WAVCanonicalizer: Sendable {
    let runner: WAVProcessRunner
    let deadline: Duration
    init(runner: WAVProcessRunner, deadline: Duration = .seconds(10)) { self.runner = runner; self.deadline = deadline }

    func canonicalize(_ native: NativeAudioArtifact, destinationDirectory: URL) async throws -> AudioArtifact {
        let token = UUID().uuidString
        let nativeInput: URL
        let ownsNativeInput: Bool
        switch native.format {
        case .pcm(let sampleRate, let channels, let bitDepth, let littleEndian):
            guard sampleRate > 0, channels > 0, bitDepth == 16, littleEndian else { throw WAVAudioError.invalidNativePCM }
            nativeInput = destinationDirectory.appendingPathComponent("aloud-native-\(token).wav")
            try wrapPCM(try Data(contentsOf: native.url), sampleRate: sampleRate, channels: channels, bitDepth: bitDepth).write(to: nativeInput)
            ownsNativeInput = true
        case .encoded:
            nativeInput = native.url
            ownsNativeInput = false
        }
        defer { if ownsNativeInput { try? FileManager.default.removeItem(at: nativeInput) } }
        let output = destinationDirectory.appendingPathComponent("aloud-canonical-\(token).wav")
        do {
            let command = WAVConversionCommand(id: UUID(), inputURL: nativeInput, inputFormat: native.format, outputURL: output)
            try await runner.run(command, deadline: deadline)
            try Task.checkCancellation()
            let artifact = try WAVValidator.validate(output, purpose: native.purpose)
            try Task.checkCancellation()
            return artifact
        } catch {
            let quarantined = await runner.isQuarantined(output)
            if !quarantined { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

    private func wrapPCM(_ pcm: Data, sampleRate: Int, channels: Int, bitDepth: Int) throws -> Data {
        let bytesPerSample = bitDepth / 8
        guard let blockAlign = checkedMultiply(channels, bytesPerSample), let byteRate = checkedMultiply(sampleRate, blockAlign), let channel16 = UInt16(exactly: channels), let align16 = UInt16(exactly: blockAlign), let rate32 = UInt32(exactly: sampleRate), let byteRate32 = UInt32(exactly: byteRate), !pcm.isEmpty, pcm.count.isMultiple(of: blockAlign) else { throw WAVAudioError.invalidNativePCM }
        var fmt = Data(); fmt.appendLE(UInt16(1)); fmt.appendLE(channel16); fmt.appendLE(rate32); fmt.appendLE(byteRate32); fmt.appendLE(align16); fmt.appendLE(UInt16(bitDepth))
        return try WAVWriter.container(pcm: pcm, sampleRate: sampleRate, channels: channels, bitDepth: bitDepth, fmt: fmt)
    }
}

enum WAVConcatenator {
    static func concatenate(_ parts: [URL], to destination: URL, purpose: SpeechPurpose) throws -> AudioArtifact {
        guard !parts.isEmpty else { throw WAVAudioError.invalidDuration }
        let pcm = try parts.reduce(into: Data()) { $0.append(try WAVValidator.pcmData(from: $1)) }
        try WAVWriter.canonical(pcm).write(to: destination)
        return try WAVValidator.validate(destination, purpose: purpose)
    }
}

enum WAVAudioExporter {
    static func save(source: URL, to destination: URL, purpose: SpeechPurpose, fileManager: FileManager = .default) throws -> AudioArtifact {
        _ = try WAVValidator.validate(source, purpose: purpose)
        guard !fileManager.fileExists(atPath: destination.path) else { throw WAVAudioError.exportDestinationExists }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".aloud-export-\(UUID().uuidString).wav")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        _ = try WAVValidator.validate(temporary, purpose: purpose)
        try fileManager.moveItem(at: temporary, to: destination)
        return try WAVValidator.validate(destination, purpose: purpose)
    }
}

enum CanonicalSilencePad {
    static func make(duration: TimeInterval, destinationDirectory: URL, purpose: SpeechPurpose) throws -> AudioArtifact {
        guard duration.isFinite, duration > 0, duration <= Double(Int.max) / 48_000 else { throw WAVAudioError.invalidDuration }
        let samples = Int((duration * 48_000).rounded())
        guard samples > 0, let bytes = checkedMultiply(samples, 2) else { throw WAVAudioError.invalidDuration }
        let url = destinationDirectory.appendingPathComponent("aloud-silence-\(UUID().uuidString).wav")
        try WAVWriter.canonical(Data(repeating: 0, count: bytes)).write(to: url)
        return try WAVValidator.validate(url, purpose: purpose)
    }
}

private enum WAVWriter {
    static func canonical(_ pcm: Data) throws -> Data {
        var fmt = Data(); fmt.appendLE(UInt16(1)); fmt.appendLE(UInt16(1)); fmt.appendLE(UInt32(48_000)); fmt.appendLE(UInt32(96_000)); fmt.appendLE(UInt16(2)); fmt.appendLE(UInt16(16))
        return try container(pcm: pcm, sampleRate: 48_000, channels: 1, bitDepth: 16, fmt: fmt)
    }
    static func container(pcm: Data, sampleRate: Int, channels: Int, bitDepth: Int, fmt: Data) throws -> Data {
        let first = 8.addingReportingOverflow(fmt.count)
        let second = first.partialValue.addingReportingOverflow(8)
        let third = second.partialValue.addingReportingOverflow(pcm.count)
        let riff = 4.addingReportingOverflow(third.partialValue)
        guard !first.overflow, !second.overflow, !third.overflow, !riff.overflow, let pcm32 = UInt32(exactly: pcm.count), let riff32 = UInt32(exactly: riff.partialValue) else { throw WAVAudioError.overflow }
        var body = Data("fmt ".utf8); body.appendLE(UInt32(fmt.count)); body.append(fmt)
        body.append(Data("data".utf8)); body.appendLE(pcm32); body.append(pcm)
        var result = Data("RIFF".utf8); result.appendLE(riff32); result.append(Data("WAVE".utf8)); result.append(body); return result
    }
}

private func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? { let r = lhs.multipliedReportingOverflow(by: rhs); return r.overflow ? nil : r.partialValue }

private extension Data {
    mutating func appendLE(_ value: UInt16) { append(UInt8(value & 0xff)); append(UInt8(value >> 8)) }
    mutating func appendLE(_ value: UInt32) { append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8((value >> 16) & 0xff)); append(UInt8(value >> 24)) }
}

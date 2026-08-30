import Foundation
import XCTest
@testable import Aloud

final class WAVAudioTests: XCTestCase {
    func testValidatorAcceptsLiteralTenMillisecondCanonicalPCM() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let file = directory.url.appendingPathComponent("ten-ms.wav")
        try WAVTestFixture.wav(samples: 480).write(to: file)

        let artifact = try WAVValidator.validate(file, purpose: .preview)

        XCTAssertEqual(artifact.format, AudioFormatID())
        XCTAssertEqual(artifact.duration, 0.01, accuracy: 0.000_001)
        XCTAssertTrue(artifact.isCanonical)
    }

    func testValidatorRejectsTruncatedExtraAndNonWAVData() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let good = WAVTestFixture.wav(samples: 480)
        let cases: [(String, Data)] = [
            ("truncated.wav", good.dropLast()),
            ("extra-declared.wav", WAVTestFixture.wav(samples: 480, declaredDataBytes: 961)),
            ("old-minimax.mp3", Data("ID3 old cache".utf8)),
            ("silence-2s.mp3", Data("ID3 silence".utf8)),
        ]
        for (name, data) in cases {
            let file = directory.url.appendingPathComponent(name)
            try data.write(to: file)
            XCTAssertThrowsError(try WAVValidator.validate(file, purpose: .preview), name)
        }
    }

    func testValidatorAllowsUnknownPaddedChunkButRequiresOneFmtAndData() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let accepted = directory.url.appendingPathComponent("with-junk.wav")
        try WAVTestFixture.wav(samples: 480, extraChunk: ("JUNK", Data([1, 2, 3]))).write(to: accepted)
        XCTAssertNoThrow(try WAVValidator.validate(accepted, purpose: .preview))

        let duplicate = directory.url.appendingPathComponent("two-data.wav")
        try WAVTestFixture.wav(samples: 480, extraChunk: ("data", Data([0, 0]))).write(to: duplicate)
        XCTAssertThrowsError(try WAVValidator.validate(duplicate, purpose: .preview))

        let duplicateFmt = directory.url.appendingPathComponent("two-fmt.wav")
        try WAVTestFixture.wav(samples: 480, extraChunk: ("fmt ", WAVTestFixture.canonicalFmt())).write(to: duplicateFmt)
        XCTAssertThrowsError(try WAVValidator.validate(duplicateFmt, purpose: .preview))
    }

    func testValidatorRejectsNative32kHeaderAndEveryWrongCanonicalFmtField() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let wrongs: [(String, Data)] = [
            ("32k.wav", WAVTestFixture.wav(samples: 480, fmt: WAVTestFixture.fmt(sampleRate: 32_000, byteRate: 64_000, blockAlign: 2, bitDepth: 16))),
            ("stereo.wav", WAVTestFixture.wav(samples: 480, fmt: WAVTestFixture.fmt(channels: 2, sampleRate: 48_000, byteRate: 192_000, blockAlign: 4, bitDepth: 16))),
            ("float.wav", WAVTestFixture.wav(samples: 480, fmt: WAVTestFixture.fmt(formatCode: 3))),
            ("bits.wav", WAVTestFixture.wav(samples: 480, fmt: WAVTestFixture.fmt(byteRate: 144_000, blockAlign: 3, bitDepth: 24))),
        ]
        for (name, data) in wrongs { let url = directory.url.appendingPathComponent(name); try data.write(to: url); XCTAssertThrowsError(try WAVValidator.validate(url, purpose: .preview), name) }
    }

    func testCanonicalizerWrapsRaw32kPCMBeforeFakeConversionAndReturnsUnpublishedCanonicalArtifact() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let raw = directory.url.appendingPathComponent("input.pcm")
        try Data(repeating: 0, count: 640).write(to: raw) // 10 ms at 32 kHz mono 16-bit
        let driver = ScriptedWAVDriver(mode: .succeed)
        let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver)
        let canonicalizer = WAVCanonicalizer(runner: runner)

        let artifact = try await canonicalizer.canonicalize(
            NativeAudioArtifact(url: raw, format: .pcm(sampleRate: 32_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview),
            destinationDirectory: directory.url
        )

        XCTAssertEqual(artifact.format, AudioFormatID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
        let nativeContainer = try XCTUnwrap(driver.capturedInputData)
        XCTAssertEqual(nativeContainer.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(nativeContainer.subdata(in: 8..<12), Data("WAVE".utf8))
        XCTAssertEqual(nativeContainer.subdata(in: 12..<16), Data("fmt ".utf8))
        XCTAssertEqual(nativeContainer[22], 1) // mono, little-endian
        XCTAssertEqual(nativeContainer[24], 0) // 32,000 Hz = 0x00007d00
        XCTAssertEqual(nativeContainer[25], 125)
        XCTAssertEqual(nativeContainer[34], 16) // signed 16-bit PCM
    }
}

enum WAVTestFixture {
    static func wav(samples: Int, declaredDataBytes: Int? = nil, extraChunk: (String, Data)? = nil, fmt: Data? = nil) -> Data {
        let data = Data(repeating: 0, count: samples * 2)
        var chunks = Data()
        chunks.append(chunk("fmt ", fmt ?? canonicalFmt()))
        chunks.append(chunk("data", data, declaredLength: declaredDataBytes))
        if let extraChunk { chunks.append(chunk(extraChunk.0, extraChunk.1)) }
        var output = Data("RIFF".utf8)
        output.appendLE(UInt32(4 + chunks.count))
        output.append(Data("WAVE".utf8)); output.append(chunks)
        return output
    }

    static func canonicalFmt() -> Data { fmt() }
    static func fmt(formatCode: UInt16 = 1, channels: UInt16 = 1, sampleRate: UInt32 = 48_000, byteRate: UInt32 = 96_000, blockAlign: UInt16 = 2, bitDepth: UInt16 = 16) -> Data {
        var data = Data()
        data.appendLE(formatCode); data.appendLE(channels); data.appendLE(sampleRate)
        data.appendLE(byteRate); data.appendLE(blockAlign); data.appendLE(bitDepth)
        return data
    }

    private static func chunk(_ id: String, _ payload: Data, declaredLength: Int? = nil) -> Data {
        var result = Data(id.utf8); result.appendLE(UInt32(declaredLength ?? payload.count)); result.append(payload)
        if payload.count.isMultiple(of: 2) == false { result.append(0) }
        return result
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) { append(UInt8(value & 0xff)); append(UInt8(value >> 8)) }
    mutating func appendLE(_ value: UInt32) { append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8((value >> 16) & 0xff)); append(UInt8(value >> 24)) }
}

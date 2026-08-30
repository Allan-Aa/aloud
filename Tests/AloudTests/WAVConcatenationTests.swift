import Foundation
import XCTest
@testable import Aloud

final class WAVConcatenationTests: XCTestCase {
    func testConcatenatorRebuildsOneHeaderForTenAndTwentyMillisecondParts() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let first = directory.url.appendingPathComponent("10.wav")
        let second = directory.url.appendingPathComponent("20.wav")
        let output = directory.url.appendingPathComponent("joined.wav")
        try WAVTestFixture.wav(samples: 480).write(to: first)
        try WAVTestFixture.wav(samples: 960).write(to: second)

        let artifact = try WAVConcatenator.concatenate([first, second], to: output, purpose: .reading(.speak))

        XCTAssertEqual(artifact.duration, 0.03, accuracy: 0.000_001)
        XCTAssertEqual(try WAVValidator.pcmData(from: output).count, 2_880)
        XCTAssertEqual(try Data(contentsOf: output).prefix(4), Data("RIFF".utf8))
    }

    func testCanonicalSilencePadIsValidatedWAVAndNeverMP3() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let pad = try CanonicalSilencePad.make(duration: 0.01, destinationDirectory: directory.url, purpose: .preview)
        XCTAssertEqual(pad.url.pathExtension, "wav")
        XCTAssertEqual(pad.duration, 0.01, accuracy: 0.000_001)
        XCTAssertNoThrow(try WAVValidator.validate(pad.url, purpose: .preview))
    }

    func testCanonicalSilencePadRejectsNonFiniteAndUnrepresentableDurationsWithoutWriting() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        for duration in [Double.nan, Double.infinity, -Double.infinity, 0, -0.01, Double(Int.max)] {
            XCTAssertThrowsError(try CanonicalSilencePad.make(duration: duration, destinationDirectory: directory.url, purpose: .preview))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    func testConcatenatorRejectsCorruptInputWithoutCreatingDestination() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let good = directory.url.appendingPathComponent("good.wav"); let corrupt = directory.url.appendingPathComponent("corrupt.wav"); let out = directory.url.appendingPathComponent("out.wav")
        try WAVTestFixture.wav(samples: 480).write(to: good); try Data("not wav".utf8).write(to: corrupt)
        XCTAssertThrowsError(try WAVConcatenator.concatenate([good, corrupt], to: out, purpose: .preview))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        let existing = Data("existing destination".utf8); try existing.write(to: out)
        XCTAssertThrowsError(try WAVConcatenator.concatenate([good, corrupt], to: out, purpose: .preview))
        XCTAssertEqual(try Data(contentsOf: out), existing)
    }

    func testExporterValidatesSourceAndLeavesNewDestinationAbsentOnFailure() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let corrupt = directory.url.appendingPathComponent("corrupt.wav")
        let destination = directory.url.appendingPathComponent("export.wav")
        try Data("not wav".utf8).write(to: corrupt)
        XCTAssertThrowsError(try WAVAudioExporter.save(source: corrupt, to: destination, purpose: .reading(.speak)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExporterAtomicallyPublishesValidatedWAVAndPreservesExistingDestination() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let source = directory.url.appendingPathComponent("source.wav")
        let destination = directory.url.appendingPathComponent("export.wav")
        try WAVTestFixture.wav(samples: 480).write(to: source)
        let exported = try WAVAudioExporter.save(source: source, to: destination, purpose: .reading(.speak))
        XCTAssertEqual(exported.url, destination)
        XCTAssertEqual(exported.duration, 0.01, accuracy: 0.000_001)

        let prior = Data("existing user export".utf8)
        try prior.write(to: destination)
        XCTAssertThrowsError(try WAVAudioExporter.save(source: source, to: destination, purpose: .reading(.speak)))
        XCTAssertEqual(try Data(contentsOf: destination), prior)
    }
}

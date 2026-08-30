import XCTest
@testable import Aloud

final class AudioExportTests: XCTestCase {
    func testExportUsesUniqueDestinationDirectoryTempValidatesThenAtomicallyReplaces() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let source = directory.url.appendingPathComponent("source.wav")
        let destination = directory.url.appendingPathComponent("chosen.wav")
        try WAVTestFixture.wav(samples: 480).write(to: source)
        try Data("old destination".utf8).write(to: destination)
        let artifact = try WAVValidator.validate(source, purpose: .reading(.speak))
        let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        try await store.promote(artifact, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
        let files = RecordingAudioExportFiles()

        let exported = try await AudioExporter.saveAudio(from: store, to: destination, files: files)

        XCTAssertEqual(exported.url, destination)
        XCTAssertEqual(files.copyDestinations.count, 1)
        XCTAssertEqual(files.copyDestinations[0].deletingLastPathComponent(), destination.deletingLastPathComponent())
        XCTAssertNotEqual(files.copyDestinations[0], destination)
        XCTAssertEqual(files.replacements.count, 1)
        XCTAssertEqual(files.replacements[0].0, files.copyDestinations[0])
        XCTAssertEqual(files.replacements[0].1, destination)
        XCTAssertNoThrow(try WAVValidator.validate(destination, purpose: .reading(.speak)))
    }

    func testCopyFailurePreservesExistingDestinationAndRetainedSourceAndDeletesOnlyTemp() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let source = directory.url.appendingPathComponent("source.wav")
        let destination = directory.url.appendingPathComponent("chosen.wav")
        let oldDestination = Data("old destination".utf8)
        try WAVTestFixture.wav(samples: 480).write(to: source)
        try oldDestination.write(to: destination)
        let artifact = try WAVValidator.validate(source, purpose: .reading(.speak))
        let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        try await store.promote(artifact, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
        let files = RecordingAudioExportFiles(failCopy: true)

        await XCTAssertThrowsErrorAsync(try await AudioExporter.saveAudio(from: store, to: destination, files: files))

        XCTAssertEqual(try Data(contentsOf: destination), oldDestination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(files.replacements.count, 0)
        XCTAssertEqual(files.removals, files.copyDestinations)
    }

    func testCorruptCopiedTempNeverReplacesDestination() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let source = directory.url.appendingPathComponent("source.wav")
        let destination = directory.url.appendingPathComponent("chosen.wav")
        let oldDestination = Data("old destination".utf8)
        try WAVTestFixture.wav(samples: 480).write(to: source)
        try oldDestination.write(to: destination)
        let artifact = try WAVValidator.validate(source, purpose: .reading(.speak))
        let evidence = PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        try await store.promote(artifact, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak), evidence: evidence)
        let files = RecordingAudioExportFiles(corruptCopy: true)

        await XCTAssertThrowsErrorAsync(try await AudioExporter.saveAudio(from: store, to: destination, files: files))

        XCTAssertEqual(try Data(contentsOf: destination), oldDestination)
        XCTAssertEqual(files.replacements.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAtomicReplaceFailurePreservesExistingDestinationAndRetainedSource() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let store = LastAudioArtifactStore()
        let source = directory.url.appendingPathComponent("source.wav")
        let destination = directory.url.appendingPathComponent("chosen.wav")
        let oldDestination = Data("old destination".utf8)
        try WAVTestFixture.wav(samples: 480).write(to: source)
        try oldDestination.write(to: destination)
        let artifact = try WAVValidator.validate(source, purpose: .reading(.speak))
        try await store.promote(
            artifact, generation: SessionGeneration(rawValue: 1), purpose: .reading(.speak),
            evidence: PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
        )
        let files = RecordingAudioExportFiles(failReplace: true)

        await XCTAssertThrowsErrorAsync(try await AudioExporter.saveAudio(from: store, to: destination, files: files))

        XCTAssertEqual(try Data(contentsOf: destination), oldDestination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(files.replacements.count, 1)
        XCTAssertEqual(files.removals, files.copyDestinations)
    }
}

private final class RecordingAudioExportFiles: @unchecked Sendable, AudioExportFileOperations {
    enum Error: Swift.Error { case copyFailed, replaceFailed }
    private let lock = NSLock()
    private let failCopy: Bool
    private let corruptCopy: Bool
    private let failReplace: Bool
    private var copies: [URL] = []
    private var replaced: [(URL, URL)] = []
    private var removed: [URL] = []
    init(failCopy: Bool = false, corruptCopy: Bool = false, failReplace: Bool = false) { self.failCopy = failCopy; self.corruptCopy = corruptCopy; self.failReplace = failReplace }
    var copyDestinations: [URL] { lock.withLock { copies } }
    var replacements: [(URL, URL)] { lock.withLock { replaced } }
    var removals: [URL] { lock.withLock { removed } }
    func copy(from source: URL, to temporary: URL) throws {
        lock.withLock { copies.append(temporary) }
        if failCopy { throw Error.copyFailed }
        if corruptCopy { try Data("not wav".utf8).write(to: temporary) }
        else { try FileManager.default.copyItem(at: source, to: temporary) }
    }
    func atomicReplace(temporary: URL, destination: URL) throws {
        lock.withLock { replaced.append((temporary, destination)) }
        if failReplace { throw Error.replaceFailed }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    func remove(_ url: URL) { lock.withLock { removed.append(url) }; try? FileManager.default.removeItem(at: url) }
}

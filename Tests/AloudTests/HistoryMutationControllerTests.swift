import XCTest
@testable import Aloud

final class ProgrammableHistoryStore: @unchecked Sendable, AtomicFileStore {
    enum Mode { case normal, failBeforeWrite, writeThenFail, corruptNextRead, failRestore }
    private let lock = NSLock(); private var files: [URL: Data]; private var mode: Mode = .normal; private var writes = 0
    init(_ files: [URL: Data]) { self.files = files }
    func setMode(_ value: Mode) { lock.withLock { mode = value } }
    func read(_ url: URL) throws -> Data { try lock.withLock {
        guard let value = files[url] else { throw AtomicFileStoreError.notFound }
        if mode == .corruptNextRead && writes > 0 { mode = .normal; return Data("[]".utf8) }
        if mode == .failRestore && writes > 0 { return Data("[]".utf8) }
        return value
    }}
    func atomicWrite(_ data: Data, to url: URL) throws { try lock.withLock {
        writes += 1
        if mode == .failBeforeWrite { mode = .normal; throw HistoryMutationError.persistenceFailed }
        files[url] = data
        if mode == .writeThenFail { mode = .normal; throw HistoryMutationError.persistenceFailed }
        if mode == .failRestore && writes > 1 { throw HistoryMutationError.restorationFailed }
    }}
    func atomicCopy(from source: URL, to destination: URL) throws { try atomicWrite(try read(source), to: destination) }
    func atomicCopyIfAbsent(from source: URL, to destination: URL) throws { try lock.withLock { guard files[destination] == nil else { throw AtomicFileStoreError.destinationExists }; guard let value = files[source] else { throw AtomicFileStoreError.notFound }; files[destination] = value } }
    func bytes(_ url: URL) -> Data? { lock.withLock { files[url] } }
    func writeCount() -> Int { lock.withLock { writes } }
}

final class HistoryMutationControllerTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/history.json")
    private func entry(_ text: String) -> HistoryEntry { HistoryEntry(id: UUID(), version: 1, text: text, contentResolution: .valid, seconds: 1, providerID: .minimax, modelID: ModelID(rawValue: "m"), voiceID: VoiceID(rawValue: "v"), rate: NormalizedRate(version: "v", value: 1)!, displayLabelSnapshot: "v", selectionResolution: .resolved, date: nil, legacyAgoSnapshot: nil) }
    private func store() throws -> (ProgrammableHistoryStore, Data) { let source = try JSONEncoder().encode([entry("base")]); return (ProgrammableHistoryStore([url: source]), source) }

    func testConcurrentAppendsSerializeWithoutLoss() async throws {
        let (files, _) = try store(); let controller = HistoryMutationController(url: url, files: files)
        async let a = controller.append(entry("a")); async let b = controller.append(entry("b")); _ = try await [a, b]
        let result = await controller.snapshot(); XCTAssertEqual(Set(result.compactMap(\.text)), Set(["base", "a", "b"]))
    }
    func testWriteFailureKeepsBytesAndCanRetry() async throws {
        let (files, source) = try store(); let controller = HistoryMutationController(url: url, files: files); files.setMode(.failBeforeWrite)
        await XCTAssertThrowsErrorAsync(try await controller.append(entry("new")))
        let snapshot = await controller.snapshot(); XCTAssertEqual(files.bytes(url), source); XCTAssertEqual(snapshot.count, 1)
        files.setMode(.normal); let result = try await controller.append(entry("new")); XCTAssertEqual(result.count, 2)
    }
    func testPartialWriteFailureRestoresExactSource() async throws {
        let (files, source) = try store(); let controller = HistoryMutationController(url: url, files: files); files.setMode(.writeThenFail)
        await XCTAssertThrowsErrorAsync(try await controller.append(entry("new")))
        let snapshot = await controller.snapshot(); XCTAssertEqual(files.bytes(url), source); XCTAssertEqual(snapshot.count, 1)
    }
    func testCorruptReadbackRestoresExactSource() async throws {
        let (files, source) = try store(); let controller = HistoryMutationController(url: url, files: files); files.setMode(.corruptNextRead)
        await XCTAssertThrowsErrorAsync(try await controller.append(entry("new")))
        let snapshot = await controller.snapshot(); XCTAssertEqual(files.bytes(url), source); XCTAssertEqual(snapshot.count, 1)
    }
    func testRestoreFailureBlocksFutureWrites() async throws {
        let (files, _) = try store(); let controller = HistoryMutationController(url: url, files: files); files.setMode(.failRestore)
        await XCTAssertThrowsErrorAsync(try await controller.append(entry("new")))
        let writes = files.writeCount(); await XCTAssertThrowsErrorAsync(try await controller.append(entry("again")))
        XCTAssertEqual(files.writeCount(), writes)
    }

    func testMigrationBackupFailureMakesControllerReadOnlyWithoutWrites() async throws {
        let source = try Fixture.data(named: "legacy-history-v0.json"), files = RecordingAtomicFileStore(initial: [url: source], failCopies: true)
        let controller = HistoryMutationController(url: url, files: files); let writes = files.writes.count
        do { _ = try await controller.append(entry("new")); XCTFail("expected recoveryRequired") }
        catch let error as HistoryMutationError { XCTAssertEqual(error, .recoveryRequired) }
        XCTAssertEqual(files.writes.count, writes); XCTAssertEqual(files.data(at: url), source)
    }

    func testMigrationReplacementFailureMakesControllerReadOnlyWithoutWrites() async throws {
        let source = try Fixture.data(named: "legacy-history-v0.json"), files = MigrationTestFailureStore(url: url, source: source)
        let controller = HistoryMutationController(url: url, files: files); let writes = files.writeCount()
        do { _ = try await controller.append(entry("new")); XCTFail("expected recoveryRequired") }
        catch let error as HistoryMutationError { XCTAssertEqual(error, .recoveryRequired) }
        XCTAssertEqual(files.writeCount(), writes); XCTAssertEqual(files.bytes(url), source)
    }
}

final class MigrationTestFailureStore: @unchecked Sendable, AtomicFileStore {
    private let lock = NSLock(); private var files: [URL: Data]; private var writes = 0
    init(url: URL, source: Data) { files = [url: source] }
    func read(_ url: URL) throws -> Data { try lock.withLock { guard let data = files[url] else { throw AtomicFileStoreError.notFound }; return data } }
    func atomicWrite(_ data: Data, to url: URL) throws { try lock.withLock { writes += 1; files[url] = data; if writes == 1 { throw HistoryMutationError.persistenceFailed } } }
    func atomicCopy(from source: URL, to destination: URL) throws { try lock.withLock { files[destination] = try files[source].unwrap(or: AtomicFileStoreError.notFound) } }
    func atomicCopyIfAbsent(from source: URL, to destination: URL) throws { try atomicCopy(from: source, to: destination) }
    func writeCount() -> Int { lock.withLock { writes } }; func bytes(_ url: URL) -> Data? { lock.withLock { files[url] } }
}
private extension Optional { func unwrap(or error: Error) throws -> Wrapped { guard let self else { throw error }; return self } }

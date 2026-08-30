import Foundation
import XCTest
@testable import Aloud

enum Fixture {
    enum Error: Swift.Error, LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case let .notFound(name):
                return "Fixture not found: \(name)"
            }
        }
    }

    static func data(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw Error.notFound(name)
        }
        return try Data(contentsOf: url)
    }
}

struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}

final class TrapService {
    private(set) var errors: [Swift.Error] = []

    func trap(_ error: Swift.Error) {
        errors.append(error)
    }
}

final class RecordingFileStore {
    private(set) var files: [String: Data] = [:]

    func data(named name: String) -> Data? {
        files[name]
    }

    func write(_ data: Data, named name: String) {
        files[name] = data
    }
}

/// NSLock serializes all state used by cross-actor tests, making this @unchecked Sendable safe.
final class RecordingAtomicFileStore: @unchecked Sendable, AtomicFileStore {
    enum Error: Swift.Error { case copyFailed }
    private let lock = NSLock()
    private var files: [URL: Data]
    private let failCopies: Bool
    private var recordedWrites: [URL] = []
    private var shouldFailWrites = false

    init(initial: [URL: Data], failCopies: Bool = false) {
        files = initial
        self.failCopies = failCopies
    }

    var writes: [URL] { lock.withLock { recordedWrites } }
    func clearWrites() { lock.withLock { recordedWrites.removeAll() } }
    var failWrites: Bool {
        get { lock.withLock { shouldFailWrites } }
        set { lock.withLock { shouldFailWrites = newValue } }
    }
    func data(at url: URL) -> Data? { lock.withLock { files[url] } }
    func overwrite(_ data: Data, at url: URL) { lock.withLock { files[url] = data } }
    func read(_ url: URL) throws -> Data { try lock.withLock { guard let data = files[url] else { throw AtomicFileStoreError.notFound }; return data } }
    func atomicWrite(_ data: Data, to url: URL) throws {
        try lock.withLock {
            guard !shouldFailWrites else { throw Error.copyFailed }
            recordedWrites.append(url)
            files[url] = data
        }
    }
    func atomicCopy(from source: URL, to destination: URL) throws {
        try lock.withLock {
            if failCopies { throw Error.copyFailed }
            guard let data = files[source] else { throw AtomicFileStoreError.notFound }
            files[destination] = data
        }
    }
    func atomicCopyIfAbsent(from source: URL, to destination: URL) throws {
        try lock.withLock {
            if failCopies { throw Error.copyFailed }
            guard files[destination] == nil else { throw AtomicFileStoreError.destinationExists }
            guard let data = files[source] else { throw AtomicFileStoreError.notFound }
            files[destination] = data
        }
    }
}

struct FixedClock: PrefsClock {
    let value: String
    init(_ value: String) { self.value = value }
    func backupTimestamp() -> String { value }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

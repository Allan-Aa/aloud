import XCTest
@testable import Aloud

final class AtomicFileStoreTests: XCTestCase {
    func testLocalCopyIfAbsentIsSameProcessExclusive() throws {
        let temporary = try TemporaryDirectory(); defer { try? temporary.remove() }
        let first = temporary.url.appendingPathComponent("first"), second = temporary.url.appendingPathComponent("second"), destination = temporary.url.appendingPathComponent("backup")
        try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
        let store = LocalAtomicFileStore(), queue = DispatchQueue(label: "copy", attributes: .concurrent), group = DispatchGroup(), lock = NSLock()
        var successes: [Data] = [], errors: [AtomicFileStoreError] = []
        for source in [first, second] { group.enter(); queue.async { defer { group.leave() }; do { try store.atomicCopyIfAbsent(from: source, to: destination); lock.withLock { successes.append(try! Data(contentsOf: source)) } } catch let error as AtomicFileStoreError { lock.withLock { errors.append(error) } } catch { XCTFail("unexpected \(error)") } } }
        group.wait()
        XCTAssertEqual(successes.count, 1); XCTAssertEqual(errors, [.destinationExists]); XCTAssertEqual(try Data(contentsOf: destination), successes[0])
        let prior = try Data(contentsOf: destination); XCTAssertThrowsError(try store.atomicCopyIfAbsent(from: first, to: destination)); XCTAssertEqual(try Data(contentsOf: destination), prior)
    }
}

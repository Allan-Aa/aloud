import XCTest
@testable import Aloud

final class MiniMaxVoiceDirectoryTests: XCTestCase {
    func testFallbackAndDynamicDescriptorsHaveStableIDsAndExactWireIDs() async throws {
        let directory = MiniMaxVoiceDirectory()
        let revision = UUID()
        let operation = await directory.begin(revision: revision)
        let committed = await directory.commit([
            .init(kind: .system, wireID: "Chinese (Mandarin)_News_Anchor", displayName: "新闻主播"),
            .init(kind: .cloned, wireID: "clone-1", displayName: "我的声音"),
            .init(kind: .generated, wireID: "generated-1", displayName: nil),
            .init(kind: .system, wireID: "shared", displayName: "系统声音"),
            .init(kind: .cloned, wireID: "shared", displayName: "克隆声音"),
            .init(kind: .generated, wireID: "shared", displayName: "生成声音"),
        ], operation: operation)
        XCTAssertNotNil(committed)

        let values = await directory.descriptors(revision: revision)
        XCTAssertTrue(values.contains { $0.stableID == VoiceID(rawValue: "minimax.radio-host.default") })
        XCTAssertTrue(values.contains { $0.stableID == VoiceID(rawValue: "minimax.laid-back-girl.default") })
        XCTAssertEqual(values.filter { $0.wireID == "shared" }.count, 1)
        XCTAssertEqual(values.first { $0.wireID == "shared" }?.kind, .system)

        let cloned = try XCTUnwrap(values.first { $0.kind == .cloned })
        XCTAssertEqual(cloned.stableID, VoiceID(rawValue: "minimax.dynamic.f52c0eb87bf88d30d2f19fc4133788510e8f629a9e7dbe638141d1fd3f025c5e"))
        let resolved = await directory.resolve(cloned.stableID, revision: revision)
        XCTAssertEqual(resolved?.voiceID, "clone-1")
    }

    func testLateOldRevisionCannotReplaceNewDirectory() async {
        let directory = MiniMaxVoiceDirectory()
        let old = UUID(), current = UUID()
        let oldOperation = await directory.begin(revision: old)
        let currentOperation = await directory.begin(revision: current)

        let publishedOld = await directory.commit([.fixture("old")], operation: oldOperation)
        let publishedCurrent = await directory.commit([.fixture("new")], operation: currentOperation)
        XCTAssertNil(publishedOld)
        XCTAssertNotNil(publishedCurrent)

        let oldDescriptors = await directory.descriptors(revision: old)
        let currentDescriptors = await directory.descriptors(revision: current)
        XCTAssertFalse(oldDescriptors.contains { $0.wireID == "old" })
        XCTAssertTrue(currentDescriptors.contains { $0.wireID == "new" })
        XCTAssertFalse(currentDescriptors.contains { $0.wireID == "old" })
    }

    func testCancelledOperationCannotCommitDecodedCandidates() async {
        let directory = MiniMaxVoiceDirectory()
        let revision = UUID()
        let operation = await directory.begin(revision: revision)
        let barrier = MiniMaxDirectoryCommitBarrier()
        let task = Task {
            await barrier.suspend()
            return await directory.commit([.fixture("cancelled")], operation: operation)
        }

        await barrier.waitUntilEntered()
        task.cancel()
        await barrier.release()
        let committed = await task.value
        XCTAssertNil(committed)
        let descriptors = await directory.descriptors(revision: revision)
        XCTAssertFalse(descriptors.contains { $0.wireID == "cancelled" })
    }

    func testUnpublishedRevisionStillListsAndResolvesFallbackDescriptors() async {
        let directory = MiniMaxVoiceDirectory()
        let revision = UUID()
        _ = await directory.begin(revision: revision)

        let values = await directory.descriptors(revision: revision)
        XCTAssertEqual(Set(values.map(\.stableID)), [
            VoiceID(rawValue: "minimax.radio-host.default"),
            VoiceID(rawValue: "minimax.laid-back-girl.default"),
        ])

        let resolved = await directory.resolve(VoiceID(rawValue: "minimax.radio-host.default"), revision: revision)
        XCTAssertEqual(resolved?.voiceID, "Chinese (Mandarin)_Radio_Host")
    }
}

private actor MiniMaxDirectoryCommitBarrier {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private extension MiniMaxVoiceCandidate {
    static func fixture(_ wireID: String) -> Self {
        .init(kind: .system, wireID: wireID, displayName: wireID)
    }
}

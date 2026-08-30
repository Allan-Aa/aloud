import XCTest
@testable import Aloud

final class CredentialScopeRegistryTests: XCTestCase {
    func testOldTokenCannotUnblockNewCredentialScope() async {
        let registry = CredentialScopeRegistry()
        let old = await registry.begin(.minimax)
        let newer = await registry.begin(.minimax)
        await registry.commit(old, .missing)
        let blocked = await registry.isBlocked(.minimax)
        XCTAssertTrue(blocked)
        await registry.commit(newer, .missing)
        let unblocked = await registry.isBlocked(.minimax)
        XCTAssertFalse(unblocked)
    }

    func testBeginCallsRegisteredCancellationHook() async {
        let registry = CredentialScopeRegistry()
        let counter = RegistryCounter()
        _ = await registry.registerCancellation(providerID: .minimax) { counter.increment() }
        _ = await registry.begin(.minimax)
        XCTAssertEqual(counter.value, 1)
    }

    func testBeginDoesNotReturnOrAllowKeychainMutationUntilCancellationHookAcknowledges() async throws {
        let registry = CredentialScopeRegistry()
        let barrier = SuspendedTransport()
        let didReturn = RegistryCounter()
        _ = await registry.registerCancellation(providerID: .minimax) { await barrier.enterAndWait() }
        let keychain = ScriptedKeychain(update: errSecSuccess)
        let store = CredentialStore(keychain: keychain, invalidator: .init(
            begin: { provider in didReturn.increment(); return await registry.begin(provider) },
            commit: { token, result in await registry.commit(token, result) },
            rollback: { token, result in await registry.rollback(token, result) }
        ), gate: CredentialNamespaceGate())
        let mutation = Task { try await store.save(providerID: .minimax, normalizedSecret: Data("x".utf8)) }
        await barrier.waitUntilEntered()
        XCTAssertEqual(didReturn.value, 1)
        XCTAssertEqual(keychain.operations.map(\.kind), [.read])
        await barrier.release()
        _ = try await mutation.value
    }

    func testCredentialBeginCancelsInFlightMiniMaxTaskBeforeReleasedTransportCanWriteOutput() async throws {
        let registry = CredentialScopeRegistry()
        let barrier = SuspendedTransport()
        let relay = SynthesisTaskRelay()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-task8-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("fake-key".utf8))
        let provider = MiniMaxProvider(httpClient: SuspendedMiniMaxHTTPClient(barrier: barrier), nativeDirectory: directory)
        let request = try await task8MiniMaxRequest(provider: provider, credential: credential)

        let task = Task<Void, Error> {
            _ = try await provider.synthesize(request, credential: .apiKey(providerID: .minimax, envelope: credential))
        }
        relay.install(task)
        _ = await registry.registerCancellation(providerID: .minimax) { relay.cancel() }
        await barrier.waitUntilEntered()

        let token = await registry.begin(.minimax)
        let blockedAfterBegin = await registry.isBlocked(.minimax)
        XCTAssertTrue(blockedAfterBegin)
        await barrier.release()
        do {
            try await task.value
            XCTFail("cancelled synthesis must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])

        await registry.commit(token, .missing)
        let blockedAfterCommit = await registry.isBlocked(.minimax)
        XCTAssertFalse(blockedAfterCommit)
    }
}

private struct SuspendedMiniMaxHTTPClient: MiniMaxHTTPClient {
    let barrier: SuspendedTransport
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        await barrier.enterAndWait()
        return MiniMaxHTTPResponse(statusCode: 200, body: Data("{\"base_resp\":{\"status_code\":0},\"data\":{\"audio\":\"00\"}}".utf8))
    }
}

private func task8MiniMaxRequest(provider: MiniMaxProvider, credential: CredentialEnvelope) async throws -> SpeechRequest {
    let selection = ProviderSelection(providerID: .minimax, modelID: MiniMaxWireContractV1.modelID, voiceID: VoiceID(rawValue: "minimax.radio-host.default"), rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 0)!)
    let chunks = try await provider.split("x", selection: selection)
    return try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: try XCTUnwrap(chunks.first), controls: MiniMaxRateMappingV1.controls(for: selection.rate), credentialScopeRevision: credential.revision, capabilities: provider.capabilities, outputFormatID: MiniMaxWireContractV1.outputFormatID, canonicalizerVersion: "canonical-wav-v1")
}

private final class RegistryCounter: @unchecked Sendable {
    private let lock = NSLock(); private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private actor SuspendedTransport {
    private var entered: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func enterAndWait() async {
        didEnter = true; entered?.resume(); entered = nil
        await withCheckedContinuation { released = $0 }
    }
    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { released?.resume(); released = nil }
}

private final class SynthesisTaskRelay: @unchecked Sendable {
    private let lock = NSLock(); private var task: Task<Void, Error>?
    func install(_ task: Task<Void, Error>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task }?.cancel() }
}

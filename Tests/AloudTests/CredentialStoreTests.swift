import XCTest
@testable import Aloud

final class CredentialStoreTests: XCTestCase {
    func testBlockedBeginPreventsQueuedReadSaveDeleteSideEffectsAndCancelledReadDoesNotWedgeFIFO() async throws {
        let gate = CredentialNamespaceGate()
        let barrier = BeginBarrier()
        let events = LockedEvents()
        let keychain = ScriptedKeychain(update: errSecSuccess, delete: errSecSuccess)
        let invalidator = CredentialScopeInvalidator(
            begin: { provider in
                events.append("begin:\(provider.rawValue)")
                if provider == .minimax { await barrier.enterAndWait() }
                return CredentialScopeToken(providerID: provider)
            },
            commit: { _, _ in events.append("commit") },
            rollback: { _, _ in events.append("rollback") }
        )
        let store = CredentialStore(keychain: keychain, invalidator: invalidator, gate: gate)
        let a = Task { try await store.save(providerID: .minimax, normalizedSecret: Data("a".utf8)) }
        await barrier.waitUntilEntered()
        let bRead = Task { try await store.read(providerID: .openAI) }
        let bSave = Task { try await store.save(providerID: .openAI, normalizedSecret: Data("b".utf8)) }
        while await gate.waiterCount() != 2 { await Task.yield() }
        let bDelete = Task { try await store.delete(providerID: .gemini) }
        while await gate.waiterCount() != 3 { await Task.yield() }
        XCTAssertEqual(events.values, ["begin:minimax"])
        XCTAssertEqual(keychain.operations.map(\.kind), [.read])
        bRead.cancel()
        while await gate.waiterCount() != 2 { await Task.yield() }
        await barrier.release()
        _ = try await a.value
        _ = try await bSave.value
        try await bDelete.value
        await XCTAssertThrowsErrorAsync(try await bRead.value)
        let c = try await store.read(providerID: .openAI)
        guard case .available = c else { return XCTFail("C read should observe B's completed FIFO save") }
        XCTAssertEqual(events.values, ["begin:minimax", "commit", "begin:openai", "commit", "begin:gemini", "commit"])
    }

    func testCommitFailureKeepsPersistedEnvelopeBlockedUntilReconcile() async throws {
        let keychain = ScriptedKeychain(update: errSecSuccess)
        let events = LockedEvents()
        let invalidator = CredentialScopeInvalidator(
            begin: { provider in events.append("begin:\(provider.rawValue)"); return CredentialScopeToken(providerID: provider) },
            commit: { _, _ in events.append("commit"); if events.values.filter({ $0 == "commit" }).count == 1 { throw TestFailure.failed } },
            rollback: { _, result in
                if case .available = result { events.append("rollback:persisted") }
                else { events.append("rollback:old") }
            }
        )
        let store = CredentialStore(keychain: keychain, invalidator: invalidator, gate: CredentialNamespaceGate())
        await XCTAssertThrowsErrorAsync(try await store.save(providerID: .openAI, normalizedSecret: Data("x".utf8)))
        XCTAssertEqual(events.values, ["begin:openai", "commit"])
        let blocked = try await store.current(providerID: .openAI)
        XCTAssertEqual(blocked, .blocked(.needsReconcile))
        guard case .available = try await store.reconcile(providerID: .openAI) else { return XCTFail("expected persisted envelope") }
    }

    func testRollbackFailureRemainsBlockedUntilRollbackReconcileSucceeds() async throws {
        let events = LockedEvents()
        let invalidator = CredentialScopeInvalidator(
            begin: { CredentialScopeToken(providerID: $0) },
            commit: { _, _ in },
            rollback: { _, _ in events.append("rollback"); if events.values.count == 1 { throw TestFailure.failed } }
        )
        let store = CredentialStore(keychain: ScriptedKeychain(update: errSecParam), invalidator: invalidator, gate: CredentialNamespaceGate())
        await XCTAssertThrowsErrorAsync(try await store.save(providerID: .openAI, normalizedSecret: Data("x".utf8)))
        let blocked = try await store.read(providerID: .openAI)
        XCTAssertEqual(blocked, .blocked(.needsReconcile))
        let reconciled = try await store.reconcile(providerID: .openAI)
        XCTAssertEqual(reconciled, .missing)
        XCTAssertEqual(events.values, ["rollback", "rollback"])
    }

    func testNamespaceGateCancellationDoesNotBlockNextFIFOLease() async throws {
        let gate = CredentialNamespaceGate()
        let first = try await gate.acquire()
        let waiting = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await gate.release(first)
        await XCTAssertThrowsErrorAsync(try await waiting.value)
        let next = try await gate.acquire()
        await gate.release(next)
    }

    func testExplicitSaveUpdatesBeforeAdding() async throws {
        let keychain = ScriptedKeychain(update: errSecSuccess, add: errSecParam)
        let store = CredentialStore(keychain: keychain)
        let saved = try await store.save(providerID: .openAI, normalizedSecret: Data("abc".utf8))
        XCTAssertEqual(keychain.operations.map(\.kind), [.read, .update])
        XCTAssertEqual(keychain.operations.last?.service, "com.allan.aloud")
        XCTAssertEqual(keychain.operations.last?.account, "openai-api-key")
        XCTAssertEqual(saved.providerID, .openAI)
    }

    func testNotFoundUpdateAddsAndOtherUpdateFailureDoesNotAdd() async throws {
        let missing = ScriptedKeychain(update: errSecItemNotFound, add: errSecSuccess)
        _ = try await CredentialStore(keychain: missing).save(providerID: .gemini, normalizedSecret: Data("abc".utf8))
        XCTAssertEqual(missing.operations.map(\.kind), [.read, .update, .add])
        let failed = ScriptedKeychain(update: errSecParam, add: errSecSuccess)
        await XCTAssertThrowsErrorAsync(try await CredentialStore(keychain: failed).save(providerID: .gemini, normalizedSecret: Data("abc".utf8)))
        XCTAssertEqual(failed.operations.map(\.kind), [.read, .update])
        let addFailed = ScriptedKeychain(update: errSecItemNotFound, add: errSecParam)
        await XCTAssertThrowsErrorAsync(try await CredentialStore(keychain: addFailed).save(providerID: .gemini, normalizedSecret: Data("abc".utf8)))
        XCTAssertEqual(addFailed.operations.map(\.kind), [.read, .update, .add])
    }

    func testProviderAccountsAreExactAndMacOSHasNoCredentialAccount() {
        XCTAssertEqual(CredentialStore.account(for: .minimax), "minimax-api-key")
        XCTAssertEqual(CredentialStore.account(for: .openAI), "openai-api-key")
        XCTAssertEqual(CredentialStore.account(for: .gemini), "gemini-api-key")
        XCTAssertNil(CredentialStore.account(for: .macOS))
    }

    func testReadPreservesMissingErrorsAndInvalidItems() async throws {
        let missing = CredentialStore(keychain: ScriptedKeychain(read: errSecItemNotFound))
        let missingResult = try await missing.read(providerID: .minimax); XCTAssertEqual(missingResult, .missing)
        let failed = CredentialStore(keychain: ScriptedKeychain(read: errSecParam))
        let failedResult = try await failed.read(providerID: .minimax); XCTAssertEqual(failedResult, .blocked(.keychainReadFailed))
        let raw = Data("legacy-key".utf8)
        let legacyKeychain = ScriptedKeychain(readData: raw)
        let legacyResult = try await CredentialStore(keychain: legacyKeychain).read(providerID: .minimax); XCTAssertEqual(legacyResult, .blocked(.nonV1Item))
        XCTAssertEqual(legacyKeychain.operations.map(\.kind), [.read])
        let corrupt = CredentialStore(keychain: ScriptedKeychain(readData: Data("ALOUDAK1broken".utf8)))
        let corruptResult = try await corrupt.read(providerID: .minimax); XCTAssertEqual(corruptResult, .blocked(.corruptEnvelope))
        let other = try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: UUID(), secret: Data("abc".utf8)))
        let mismatchResult = try await CredentialStore(keychain: ScriptedKeychain(readData: other)).read(providerID: .gemini); XCTAssertEqual(mismatchResult, .blocked(.providerMismatch))
    }

    func testConcurrentReadsReturnTheSamePersistedRevision() async throws {
        let envelope = CredentialEnvelope(providerID: .openAI, revision: UUID(), secret: Data("abc".utf8))
        let keychain = ScriptedKeychain(readData: try CredentialEnvelopeCodec.encode(envelope))
        let store = CredentialStore(keychain: keychain)
        async let left = store.read(providerID: .openAI)
        async let right = store.read(providerID: .openAI)
        let leftResult = try await left; let rightResult = try await right
        XCTAssertEqual(leftResult, .available(envelope)); XCTAssertEqual(rightResult, .available(envelope))
    }

    func testReplaceAndDeleteInvalidateBeforeMutationAndFailuresKeepKnownEnvelope() async throws {
        let old = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("old".utf8))
        let keychain = ScriptedKeychain(readData: try CredentialEnvelopeCodec.encode(old), update: errSecParam, delete: errSecParam)
        let events = LockedEvents()
        let store = CredentialStore(keychain: keychain, scopeInvalidator: { provider in events.append("invalidate:\(provider.rawValue)") })
        let original = try await store.read(providerID: .minimax); XCTAssertEqual(original, .available(old))
        await XCTAssertThrowsErrorAsync(try await store.replace(providerID: .minimax, normalizedSecret: Data("new".utf8)))
        await XCTAssertThrowsErrorAsync(try await store.delete(providerID: .minimax))
        XCTAssertEqual(events.values, ["invalidate:minimax", "invalidate:minimax"])
        let afterFailure = try await store.current(providerID: .minimax); XCTAssertEqual(afterFailure, .available(old))
    }

    func testDeleteMissingIsIdempotentAndDoesNotExposeRevision() async throws {
        let keychain = ScriptedKeychain(delete: errSecItemNotFound)
        let store = CredentialStore(keychain: keychain)
        try await store.delete(providerID: .openAI)
        let current = try await store.current(providerID: .openAI); XCTAssertEqual(current, .missing)
        XCTAssertEqual(keychain.operations.map(\.kind), [.read, .delete])
    }

    func testManualTrimAndDraftClearsOnlyAfterSuccessfulPersistence() async throws {
        let successful = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain(update: errSecSuccess)))
        var draft = " \nabc\u{3000}"
        _ = try await successful.saveManual(providerID: .openAI, draft: draft)
        draft = ""
        XCTAssertEqual(draft, "")
        let failing = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain(update: errSecParam)))
        draft = " abc "
        await XCTAssertThrowsErrorAsync(try await failing.saveManual(providerID: .openAI, draft: draft))
        XCTAssertEqual(draft, " abc ")
    }

    func testPersistedV1CredentialFlowsThroughStoreLoaderToMiniMaxBearerAndLegacyNeverStartsTransport() async throws {
        let v1Keychain = ScriptedKeychain(update: errSecSuccess)
        let v1Store = CredentialStore(keychain: v1Keychain)
        _ = try await v1Store.save(providerID: .minimax, normalizedSecret: Data("saved-fake-key".utf8))
        let headers = LockedEvents()
        let client = Task8RecordingMiniMaxClient(headers: headers)
        let provider = MiniMaxProvider(httpClient: client, nativeDirectory: URL(fileURLWithPath: "/tmp"))
        let read = try await v1Store.read(providerID: .minimax)
        guard case .available(let envelope) = read else { return XCTFail("saved V1 must be readable") }
        let request = try await credentialStoreMiniMaxRequest(provider: provider, envelope: envelope)
        await XCTAssertThrowsErrorAsync(try await provider.synthesize(request, credential: .apiKey(providerID: .minimax, envelope: envelope)))
        XCTAssertEqual(headers.values, ["Bearer saved-fake-key"])

        let legacyStore = CredentialStore(keychain: ScriptedKeychain(readData: Data("old-unwrapped-key".utf8)))
        let legacyRead = try await legacyStore.read(providerID: .minimax)
        guard case .blocked(.nonV1Item) = legacyRead else { return XCTFail("legacy key must stay blocked") }
        XCTAssertEqual(headers.values, ["Bearer saved-fake-key"])
    }
}

private struct Task8RecordingMiniMaxClient: MiniMaxHTTPClient {
    let headers: LockedEvents
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        headers.append(request.value(forHTTPHeaderField: "Authorization") ?? "missing")
        throw URLError(.cannotConnectToHost)
    }
}

private func credentialStoreMiniMaxRequest(provider: MiniMaxProvider, envelope: CredentialEnvelope) async throws -> SpeechRequest {
    let selection = ProviderSelection(providerID: .minimax, modelID: MiniMaxWireContractV1.modelID, voiceID: VoiceID(rawValue: "minimax.radio-host.default"), rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 0)!)
    let chunks = try await provider.split("x", selection: selection)
    return try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: try XCTUnwrap(chunks.first), controls: MiniMaxRateMappingV1.controls(for: selection.rate), credentialScopeRevision: envelope.revision, capabilities: provider.capabilities, outputFormatID: MiniMaxWireContractV1.outputFormatID, canonicalizerVersion: "canonical-wav-v1")
}

private enum TestFailure: Error { case failed }

private actor BeginBarrier {
    private var entered: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func enterAndWait() async {
        didEnter = true; entered?.resume(); entered = nil
        await withCheckedContinuation { released = $0 }
    }
    func waitUntilEntered() async { if didEnter { return }; await withCheckedContinuation { entered = $0 } }
    func release() { released?.resume(); released = nil }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

final class ScriptedKeychain: @unchecked Sendable, KeychainClient {
    enum Kind: Equatable { case read, update, add, delete }
    struct Operation: Equatable { let kind: Kind; let service: String; let account: String }
    private let lock = NSLock()
    private let readStatus: OSStatus; private var payload: Data?
    private let updateStatus: OSStatus; private let addStatus: OSStatus; private let deleteStatus: OSStatus
    private(set) var operations: [Operation] = []
    init(read: OSStatus = errSecSuccess, readData: Data? = nil, update: OSStatus = errSecSuccess, add: OSStatus = errSecSuccess, delete: OSStatus = errSecSuccess) { self.readStatus = read; self.payload = readData; self.updateStatus = update; self.addStatus = add; self.deleteStatus = delete }
    func read(service: String, account: String) -> CredentialKeychainRead { lock.withLock { operations.append(.init(kind: .read, service: service, account: account)); return readStatus == errSecSuccess ? (payload.map(CredentialKeychainRead.success) ?? .failure(errSecItemNotFound)) : .failure(readStatus) } }
    func update(data: Data, service: String, account: String) -> OSStatus { lock.withLock { operations.append(.init(kind: .update, service: service, account: account)); if updateStatus == errSecSuccess { payload = data }; return updateStatus } }
    func add(data: Data, service: String, account: String) -> OSStatus { lock.withLock { operations.append(.init(kind: .add, service: service, account: account)); if addStatus == errSecSuccess { payload = data }; return addStatus } }
    func delete(service: String, account: String) -> OSStatus { lock.withLock { operations.append(.init(kind: .delete, service: service, account: account)); return deleteStatus } }
}

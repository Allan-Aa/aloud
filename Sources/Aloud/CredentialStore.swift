import Foundation
import Security

enum CredentialKeychainRead: Sendable { case success(Data), failure(OSStatus) }
protocol KeychainClient: Sendable { func read(service: String, account: String) -> CredentialKeychainRead; func update(data: Data, service: String, account: String) -> OSStatus; func add(data: Data, service: String, account: String) -> OSStatus; func delete(service: String, account: String) -> OSStatus }
struct SecurityKeychainClient: KeychainClient {
    func read(service: String, account: String) -> CredentialKeychainRead { let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]; var output: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &output); return status == errSecSuccess && output is Data ? .success(output as! Data) : .failure(status) }
    func update(data: Data, service: String, account: String) -> OSStatus { SecItemUpdate([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account] as CFDictionary, [kSecValueData as String:data] as CFDictionary) }
    func add(data: Data, service: String, account: String) -> OSStatus { SecItemAdd([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecValueData as String:data] as CFDictionary, nil) }
    func delete(service: String, account: String) -> OSStatus { SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account] as CFDictionary) }
}

enum CredentialBlockReason: String, Equatable, Sendable { case nonV1Item, corruptEnvelope, providerMismatch, keychainReadFailed, keychainWriteFailed, needsReconcile }
enum CredentialReadResult: Equatable, Sendable { case missing, available(CredentialEnvelope), blocked(CredentialBlockReason) }
enum CredentialMutation: Equatable, Sendable { case saved(CredentialEnvelope), deleted(ProviderID) }
enum CredentialStoreError: Error, Equatable, Sendable { case unsupportedProvider, keychainWriteFailed, needsReconcile, invalidationFailed }

struct CredentialScopeToken: Sendable, Hashable { fileprivate let id = UUID(); fileprivate let providerID: ProviderID; init(providerID: ProviderID) { self.providerID = providerID } }
struct CredentialScopeInvalidator: Sendable {
    let begin: @Sendable (ProviderID) async throws -> CredentialScopeToken
    let commit: @Sendable (CredentialScopeToken, CredentialReadResult) async throws -> Void
    let rollback: @Sendable (CredentialScopeToken, CredentialReadResult) async throws -> Void
    static let noop = CredentialScopeInvalidator(begin: { CredentialScopeToken(providerID: $0) }, commit: { _, _ in }, rollback: { _, _ in })
}

/// Production scope registry blocks new synthesis while a credential transaction
/// is in flight. Sessions can register a cancellation hook without retaining key data.
actor CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    private var blocked: [ProviderID: CredentialScopeToken] = [:]
    private var hooks: [ProviderID: [UUID: @Sendable () async -> Void]] = [:]
    func begin(_ providerID: ProviderID) async -> CredentialScopeToken {
        let token = CredentialScopeToken(providerID: providerID)
        blocked[providerID] = token
        if let hooks = hooks[providerID] {
            for hook in hooks.values { await hook() }
        }
        return token
    }
    func commit(_ token: CredentialScopeToken, _: CredentialReadResult) { if blocked[token.providerID] == token { blocked[token.providerID] = nil } }
    func rollback(_ token: CredentialScopeToken, _: CredentialReadResult) { if blocked[token.providerID] == token { blocked[token.providerID] = nil } }
    func isBlocked(_ providerID: ProviderID) -> Bool { blocked[providerID] != nil }
    func registerCancellation(providerID: ProviderID, _ hook: @escaping @Sendable () async -> Void) -> UUID { let id = UUID(); hooks[providerID, default: [:]][id] = hook; return id }
    func unregister(providerID: ProviderID, id: UUID) { hooks[providerID]?[id] = nil }
}

struct CredentialLease: Sendable, Hashable { fileprivate let id: UUID }

/// Lease gate keeps the whole Keychain + invalidation transaction non-reentrant, even while begin/rollback await.
actor CredentialNamespaceGate {
    static let shared = CredentialNamespaceGate()
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<CredentialLease, Error> }
    private var held: CredentialLease?
    private var waiters: [Waiter] = []

    func acquire() async throws -> CredentialLease {
        try Task.checkCancellation()
        let id = UUID()
        let lease = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancel(id: id) }
        })
        // Cancellation can race a release: if this waiter was handed the lease
        // first, return it before surfacing cancellation so FIFO cannot wedge.
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    private func enqueue(id: UUID, continuation: CheckedContinuation<CredentialLease, Error>) {
        if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
        if held == nil && waiters.isEmpty {
            let lease = CredentialLease(id: id)
            held = lease
            continuation.resume(returning: lease)
        } else {
            waiters.append(.init(id: id, continuation: continuation))
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release(_ lease: CredentialLease) {
        guard held == lease else { return }
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            let next = CredentialLease(id: waiter.id)
            held = next
            waiter.continuation.resume(returning: next)
            return
        }
        held = nil
    }

    // Test-only observability for deterministic transaction-queue assertions.
    func waiterCount() -> Int { waiters.count }
}

actor CredentialStore {
    static let service = "com.allan.aloud"; static let live = CredentialStore()
    private let keychain: any KeychainClient; private let invalidator: CredentialScopeInvalidator; private let gate: CredentialNamespaceGate
    private var visible: [ProviderID: CredentialReadResult] = [:]
    private enum ReconcilePhase: Sendable { case commit, rollback }
    private struct PendingReconcile: Sendable { let token: CredentialScopeToken; let durableResult: CredentialReadResult; let phase: ReconcilePhase }
    private var pending: [ProviderID: PendingReconcile] = [:]
    static let liveInvalidator = CredentialScopeInvalidator(begin: { await CredentialScopeRegistry.shared.begin($0) }, commit: { token, result in await CredentialScopeRegistry.shared.commit(token, result) }, rollback: { token, result in await CredentialScopeRegistry.shared.rollback(token, result) })
    init(keychain: any KeychainClient = SecurityKeychainClient(), invalidator: CredentialScopeInvalidator? = nil, gate: CredentialNamespaceGate = .shared) { self.keychain = keychain; self.invalidator = invalidator ?? Self.liveInvalidator; self.gate = gate }
    init(keychain: any KeychainClient, scopeInvalidator: @escaping @Sendable (ProviderID) async -> Void) { self.keychain = keychain; self.invalidator = .init(begin: { provider in await scopeInvalidator(provider); return .init(providerID: provider) }, commit: { _, _ in }, rollback: { _, _ in }); self.gate = .shared }

    func read(providerID: ProviderID) async throws -> CredentialReadResult {
        let lease = try await gate.acquire()
        guard pending[providerID] == nil else { await gate.release(lease); return .blocked(.needsReconcile) }
        let result = readLocked(providerID)
        await gate.release(lease)
        return result
    }
    func current(providerID: ProviderID) async throws -> CredentialReadResult {
        let lease = try await gate.acquire()
        guard pending[providerID] == nil else { await gate.release(lease); return .blocked(.needsReconcile) }
        let result = visible[providerID] ?? .missing
        await gate.release(lease)
        return result
    }
    func reconcile(providerID: ProviderID) async throws -> CredentialReadResult {
        let lease = try await gate.acquire()
        guard let item = pending[providerID] else { let result = readLocked(providerID); await gate.release(lease); return result }
        do {
            switch item.phase { case .commit: try await invalidator.commit(item.token, item.durableResult); case .rollback: try await invalidator.rollback(item.token, item.durableResult) }
            pending[providerID] = nil
            visible[providerID] = item.durableResult
            await gate.release(lease)
            return item.durableResult
        } catch {
            visible[providerID] = .blocked(.needsReconcile)
            await gate.release(lease)
            return .blocked(.needsReconcile)
        }
    }
    func save(providerID: ProviderID, normalizedSecret: Data) async throws -> CredentialEnvelope { guard let value = try await mutate(providerID: providerID, secret: normalizedSecret, deleting: false) else { throw CredentialStoreError.keychainWriteFailed }; return value }
    func replace(providerID: ProviderID, normalizedSecret: Data) async throws -> CredentialEnvelope { guard let value = try await mutate(providerID: providerID, secret: normalizedSecret, deleting: false) else { throw CredentialStoreError.keychainWriteFailed }; return value }
    func delete(providerID: ProviderID) async throws { _ = try await mutate(providerID: providerID, secret: nil, deleting: true) }

    private func mutate(providerID: ProviderID, secret: Data?, deleting: Bool) async throws -> CredentialEnvelope? {
        guard let account = Self.account(for: providerID) else { throw CredentialStoreError.unsupportedProvider }
        let lease = try await gate.acquire()
        guard pending[providerID] == nil else { await gate.release(lease); throw CredentialStoreError.needsReconcile }
        let old = visible[providerID] ?? readLocked(providerID)
        let token: CredentialScopeToken
        do { token = try await invalidator.begin(providerID) }
        catch { await gate.release(lease); throw CredentialStoreError.invalidationFailed }
        let result: CredentialReadResult
        let returned: CredentialEnvelope?
        do {
            if deleting {
                let status = keychain.delete(service: Self.service, account: account)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychainWriteFailed }
                result = .missing; returned = nil
            } else {
                guard let secret else { throw CredentialStoreError.keychainWriteFailed }
                let envelope = CredentialEnvelope(providerID: providerID, revision: UUID(), secret: secret)
                var encoded = try CredentialEnvelopeCodec.encode(envelope)
                defer { encoded.resetBytes(in: 0..<encoded.count) }
                let updated = keychain.update(data: encoded, service: Self.service, account: account)
                let status = updated == errSecItemNotFound ? keychain.add(data: encoded, service: Self.service, account: account) : updated
                guard status == errSecSuccess else { throw CredentialStoreError.keychainWriteFailed }
                result = .available(envelope); returned = envelope
            }
        } catch {
            do { try await invalidator.rollback(token, old); visible[providerID] = old }
            catch { pending[providerID] = .init(token: token, durableResult: old, phase: .rollback); visible[providerID] = .blocked(.needsReconcile); await gate.release(lease); throw CredentialStoreError.needsReconcile }
            await gate.release(lease); throw error
        }
        visible[providerID] = result
        do { try await invalidator.commit(token, result) }
        catch {
            // The Keychain has already changed. Never run the old-state rollback
            // here: that would lie about the durable credential.
            pending[providerID] = .init(token: token, durableResult: result, phase: .commit)
            visible[providerID] = .blocked(.needsReconcile)
            await gate.release(lease)
            throw CredentialStoreError.needsReconcile
        }
        await gate.release(lease)
        return returned
    }
    private func readLocked(_ providerID: ProviderID) -> CredentialReadResult {
        guard let account = Self.account(for: providerID) else { return .missing }
        let result: CredentialReadResult
        switch keychain.read(service: Self.service, account: account) {
        case .failure(let s) where s == errSecItemNotFound: result = .missing
        case .failure: result = .blocked(.keychainReadFailed)
        case .success(let raw):
            guard raw.starts(with: Data("ALOUDAK1".utf8)) else { result = .blocked(.nonV1Item); visible[providerID] = result; return result }
            do { result = .available(try CredentialEnvelopeCodec.decode(raw, expectedProviderID: providerID)) }
            catch CredentialEnvelopeError.providerMismatch { result = .blocked(.providerMismatch) }
            catch { result = .blocked(.corruptEnvelope) }
        }; visible[providerID] = result; return result
    }
    static func account(for p: ProviderID) -> String? { switch p { case .minimax: "minimax-api-key"; case .openAI: "openai-api-key"; case .gemini: "gemini-api-key"; default: nil } }
}

enum OnePasswordOutputSink: Equatable, Sendable { case anonymousPipe }; enum OnePasswordErrorSink: Equatable, Sendable { case discard }
protocol OnePasswordLaunching: Sendable {
    func read(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdout: OnePasswordOutputSink,
        stderr: OnePasswordErrorSink,
        timeout: Duration
    ) async throws -> Data
}
enum OnePasswordPipeError: Error, Equatable, Sendable { case launchFailed, nonZeroExit, malformedOutput, timedOut, cancelled }

/// Owns a mutable copy only for the shortest possible credential boundary. Swift
/// `String` copies cannot be reliably wiped, so ingress never retains one beyond
/// UTF-8 normalization; tests observe this buffer's explicit wipe event.
final class OwnedMutableSecretBuffer: @unchecked Sendable {
    private(set) var data: Data
    private let didZeroize: (@Sendable (Data) -> Void)?
    init(_ data: Data, didZeroize: (@Sendable (Data) -> Void)? = nil) { self.data = data; self.didZeroize = didZeroize }
    var isZeroized: Bool { data.allSatisfy { $0 == 0 } }
    func zeroize() {
        data.resetBytes(in: 0..<data.count)
        // Data is copy-on-write: the observer receives an owned snapshot only
        // after the mutable buffer has been wiped, never the original secret.
        didZeroize?(data)
    }
}
struct OnePasswordPipeClient: Sendable {
    private let launcher: any OnePasswordLaunching; private let environment: [String:String]; private let didZeroize: (@Sendable (Data) -> Void)?; private let executableResolver: @Sendable () -> String?
    init(launcher: any OnePasswordLaunching = ProcessOnePasswordLauncher(), environment: [String:String] = ProcessInfo.processInfo.environment, didZeroize: (@Sendable (Data) -> Void)? = nil, executableResolver: @escaping @Sendable () -> String? = { OnePasswordPipeClient.resolveExecutable() }) { self.launcher=launcher; self.environment=environment; self.didZeroize=didZeroize; self.executableResolver=executableResolver }
    static func resolveExecutable() -> String? { ["/usr/local/bin/op", "/opt/homebrew/bin/op", "/usr/bin/op"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    func readMiniMaxSecretBuffer(timeout: Duration = ProcessOnePasswordLauncher.importTimeout) async throws -> OwnedMutableSecretBuffer {
        guard let executable = executableResolver() else { throw OnePasswordPipeError.launchFailed }
        let bytes = try await launcher.read(
            executable: executable,
            arguments: ["read", "op://Private/Aloud MiniMax API Key/credential"],
            environment: filtered(environment),
            stdout: .anonymousPipe,
            stderr: .discard,
            timeout: timeout
        )
        let raw = OwnedMutableSecretBuffer(bytes, didZeroize: didZeroize)
        defer { raw.zeroize() }
        guard let input = String(data: raw.data, encoding: .utf8) else { throw OnePasswordPipeError.malformedOutput }
        return OwnedMutableSecretBuffer(try SecretIngressV1.normalize(input), didZeroize: didZeroize)
    }
    private func filtered(_ e:[String:String])->[String:String] { e.filter { key,_ in let u=key.uppercased(); return !["SECRET","TOKEN","PASSWORD","CREDENTIAL","API_KEY"].contains(where:u.contains) } }
}
struct CredentialIngress: Sendable {
    let store: CredentialStore; let onePassword: OnePasswordPipeClient?
    init(store: CredentialStore, onePassword: OnePasswordPipeClient? = nil) { self.store=store; self.onePassword=onePassword }
    func supportsOnePasswordImport(for p: ProviderID)->Bool { p == .minimax && onePassword != nil }
    func saveManual(providerID: ProviderID, draft: String) async throws -> CredentialEnvelope { try await store.replace(providerID: providerID, normalizedSecret: SecretIngressV1.normalize(draft)) }
    func importMiniMaxFrom1Password() async throws -> CredentialEnvelope {
        guard let onePassword else { throw OnePasswordPipeError.launchFailed }
        let secret = try await onePassword.readMiniMaxSecretBuffer()
        defer { secret.zeroize() }
        return try await store.replace(providerID:.minimax, normalizedSecret:secret.data)
    }
}

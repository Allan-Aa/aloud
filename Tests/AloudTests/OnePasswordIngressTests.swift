import XCTest
@testable import Aloud

final class OnePasswordIngressTests: XCTestCase {
    func testOwnedBufferWipesItsActualBytes() {
        let buffer = OwnedMutableSecretBuffer(Data([1, 2, 3]))
        buffer.zeroize()
        XCTAssertTrue(buffer.isZeroized)
    }
    func testInjectedHomebrewResolverUsesApprovedPathAndMissingResolverDoesNotLaunch() async throws {
        let launcher = RecordingOnePasswordLauncher(output: Data("key".utf8))
        let homebrew = OnePasswordPipeClient(launcher: launcher, executableResolver: { "/opt/homebrew/bin/op" })
        let owned = try await homebrew.readMiniMaxSecretBuffer(); owned.zeroize()
        XCTAssertEqual(launcher.executable, "/opt/homebrew/bin/op")
        XCTAssertEqual(launcher.timeout, .seconds(30))
        let missing = OnePasswordPipeClient(launcher: launcher, executableResolver: { nil })
        await XCTAssertThrowsErrorAsync(try await missing.readMiniMaxSecretBuffer())
    }
    func testImportZeroizesRawAndNormalizedOwnedBuffersAfterPersistence() async throws {
        let events = LockedCounter()
        let client = OnePasswordPipeClient(
            launcher: RecordingOnePasswordLauncher(output: Data("key".utf8)),
            didZeroize: { _ in events.increment() }
        )
        let ingress = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain(update: errSecSuccess)), onePassword: client)
        _ = try await ingress.importMiniMaxFrom1Password()
        XCTAssertEqual(events.value, 2)
    }

    func testImportReportsWipedBytesForBothRawAndNormalizedBuffersAfterSuccess() async throws {
        let wipes = WipedSnapshots()
        let client = OnePasswordPipeClient(
            launcher: RecordingOnePasswordLauncher(output: Data(" key\\n".utf8)),
            didZeroize: { wipes.append($0) }
        )
        let ingress = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain(update: errSecSuccess)), onePassword: client)
        _ = try await ingress.importMiniMaxFrom1Password()
        XCTAssertEqual(wipes.values.count, 2)
        XCTAssertTrue(wipes.values.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 == 0 } })
    }

    func testImportZeroizesRawAndNormalizedOwnedBuffersAfterFailedPersistence() async throws {
        let events = LockedCounter()
        let client = OnePasswordPipeClient(launcher: RecordingOnePasswordLauncher(output: Data("key".utf8)), didZeroize: { _ in events.increment() })
        let ingress = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain(update: errSecParam)), onePassword: client)
        await XCTAssertThrowsErrorAsync(try await ingress.importMiniMaxFrom1Password())
        XCTAssertEqual(events.value, 2)
    }

    func testImportReportsWipedBytesForBothRawAndNormalizedBuffersAfterFailure() async throws {
        let wipes = WipedSnapshots()
        let client = OnePasswordPipeClient(
            launcher: RecordingOnePasswordLauncher(output: Data(" key\\n".utf8)),
            didZeroize: { wipes.append($0) }
        )
        let ingress = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain(update: errSecParam)), onePassword: client)
        await XCTAssertThrowsErrorAsync(try await ingress.importMiniMaxFrom1Password())
        XCTAssertEqual(wipes.values.count, 2)
        XCTAssertTrue(wipes.values.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 == 0 } })
    }

    func testProcessLauncherDiscardsLargeStderrWithoutDeadlockOrReturningIt() async throws {
        let executable = "/usr/bin/perl"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("perl unavailable") }
        let output = try await ProcessOnePasswordLauncher().read(
            executable: executable,
            arguments: ["-e", "print STDERR 'x' x 1048576; print 'ok'"],
            environment: [:],
            stdout: .anonymousPipe,
            stderr: .discard,
            timeout: .seconds(1)
        )
        XCTAssertEqual(output, Data("ok".utf8))
    }

    func testPrivatePipeUsesExactExecutableArgumentsFilteredEnvironmentAndNoOtherSinks() async throws {
        let secret = Data(" \nprivate-key\u{3000}".utf8)
        let launcher = RecordingOnePasswordLauncher(output: secret)
        let ingress = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain(update: errSecSuccess)), onePassword: OnePasswordPipeClient(launcher: launcher, environment: ["SAFE": "yes", "API_KEY": "forbidden", "TOKEN": "forbidden"], executableResolver: { "/usr/local/bin/op" }))
        _ = try await ingress.importMiniMaxFrom1Password()
        XCTAssertEqual(launcher.executable, "/usr/local/bin/op")
        XCTAssertEqual(launcher.arguments, ["read", "op://Private/Aloud MiniMax API Key/credential"])
        XCTAssertEqual(launcher.environment?["SAFE"], "yes")
        XCTAssertNil(launcher.environment?["API_KEY"])
        XCTAssertNil(launcher.environment?["TOKEN"])
        XCTAssertTrue(launcher.usedAnonymousStdoutPipe)
        XCTAssertTrue(launcher.usedDiscardedStderrPipe)
        XCTAssertEqual(launcher.timeout, .seconds(30))
        XCTAssertNil(launcher.stdoutString)
    }

    func testOnlyMiniMaxExposesOnePasswordRoute() async throws {
        let ingress = CredentialIngress(store: CredentialStore(keychain: ScriptedKeychain()), onePassword: OnePasswordPipeClient(launcher: RecordingOnePasswordLauncher(output: Data())))
        XCTAssertTrue(ingress.supportsOnePasswordImport(for: .minimax))
        XCTAssertFalse(ingress.supportsOnePasswordImport(for: .openAI))
        XCTAssertFalse(ingress.supportsOnePasswordImport(for: .gemini))
    }

    func testMalformedUTF8FromPipeIsRejectedWithoutStringFallback() async throws {
        let client = OnePasswordPipeClient(launcher: RecordingOnePasswordLauncher(output: Data([0xff])))
        await XCTAssertThrowsErrorAsync(try await client.readMiniMaxSecretBuffer())
    }

    func testProductionLauncherDoesNotBlockMainActorWhileChildIsRunning() async throws {
        let driver = OnePasswordDriverProbe(result: .success(Data("key".utf8)))
        let launcher = ProcessOnePasswordLauncher(driver: driver, terminationGrace: .milliseconds(20))
        let task = Task {
            try await launcher.read(
                executable: "/approved/op",
                arguments: ["read", "private-reference"],
                environment: [:],
                stdout: .anonymousPipe,
                stderr: .discard,
                timeout: .seconds(1)
            )
        }
        await driver.waitUntilLaunched()
        let heartbeat = await MainActor.run { true }
        XCTAssertTrue(heartbeat)
        driver.finish(status: 0)
        _ = try await task.value
    }

    func testTimeoutTerminatesThenForceKillsAndWaitsForTerminationOnce() async {
        let driver = OnePasswordDriverProbe(result: .success(Data()))
        let launcher = ProcessOnePasswordLauncher(driver: driver, terminationGrace: .milliseconds(10))
        do {
            _ = try await launcher.read(
                executable: "/approved/op",
                arguments: ["read", "private-reference"],
                environment: [:],
                stdout: .anonymousPipe,
                stderr: .discard,
                timeout: .milliseconds(20)
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? OnePasswordPipeError, .timedOut)
        }
        XCTAssertEqual(driver.terminateCount, 1)
        XCTAssertEqual(driver.forceKillCount, 1)
        XCTAssertEqual(driver.terminationAcknowledgementCount, 1)
    }

    func testTimeoutWaitsForDelayedTerminationAcknowledgementBeforeReturning() async {
        let driver = OnePasswordDriverProbe(result: .success(Data()), acknowledgeForceKill: false)
        let launcher = ProcessOnePasswordLauncher(driver: driver, terminationGrace: .milliseconds(5))
        let completion = LockedFlag()
        let task = Task {
            defer { completion.set() }
            return try await launcher.read(
                executable: "/approved/op",
                arguments: ["read", "private-reference"],
                environment: [:],
                stdout: .anonymousPipe,
                stderr: .discard,
                timeout: .milliseconds(5)
            )
        }
        await driver.waitUntilForceKilled()
        XCTAssertFalse(completion.value)
        driver.finish(status: 0)
        do { _ = try await task.value; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? OnePasswordPipeError, .timedOut) }
        XCTAssertEqual(driver.terminateCount, 1)
        XCTAssertEqual(driver.forceKillCount, 1)
        XCTAssertEqual(driver.terminationAcknowledgementCount, 1)
    }

    func testTimeoutLinearizesInsideLaunchBarrierAndReapsLateChildBeforeReturning() async {
        let driver = BarrierOnePasswordDriver()
        let completion = LockedFlag()
        let task = Task {
            defer { completion.set() }
            return try await ProcessOnePasswordLauncher(driver: driver, terminationGrace: .milliseconds(100)).read(
                executable: "/approved/op", arguments: [], environment: [:],
                stdout: .anonymousPipe, stderr: .discard, timeout: .milliseconds(10)
            )
        }
        await driver.waitUntilLaunchEntered()
        await driver.waitUntilTerminationRequested()
        XCTAssertFalse(completion.value)
        driver.releaseLaunch()
        await driver.waitUntilLateChildTerminated()
        XCTAssertFalse(completion.value)
        driver.acknowledgeExit(status: 0)
        driver.acknowledgeExit(status: 0)
        do { _ = try await task.value; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? OnePasswordPipeError, .timedOut) }
        XCTAssertEqual(driver.spawnCount, 1)
        XCTAssertEqual(driver.terminateCount, 1)
        XCTAssertEqual(driver.terminationAcknowledgementCount, 1)
    }

    func testCancellationLinearizesInsideLaunchBarrierAndReapsLateChildBeforeReturning() async {
        let driver = BarrierOnePasswordDriver()
        let completion = LockedFlag()
        let task = Task {
            defer { completion.set() }
            return try await ProcessOnePasswordLauncher(driver: driver, terminationGrace: .milliseconds(100)).read(
                executable: "/approved/op", arguments: [], environment: [:],
                stdout: .anonymousPipe, stderr: .discard, timeout: .seconds(30)
            )
        }
        await driver.waitUntilLaunchEntered()
        task.cancel()
        await driver.waitUntilTerminationRequested()
        XCTAssertFalse(completion.value)
        driver.releaseLaunch()
        await driver.waitUntilLateChildTerminated()
        XCTAssertFalse(completion.value)
        driver.acknowledgeExit(status: 0)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? OnePasswordPipeError, .cancelled) }
        XCTAssertEqual(driver.spawnCount, 1)
        XCTAssertEqual(driver.terminateCount, 1)
        XCTAssertEqual(driver.terminationAcknowledgementCount, 1)
    }

    func testParentCancellationBeforeLaunchStartsNoChild() async {
        let driver = OnePasswordDriverProbe(result: .success(Data()))
        let task = Task {
            try await ProcessOnePasswordLauncher(driver: driver).read(
                executable: "/approved/op",
                arguments: [],
                environment: [:],
                stdout: .anonymousPipe,
                stderr: .discard,
                timeout: .seconds(30)
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? OnePasswordPipeError, .cancelled)
        }
        XCTAssertEqual(driver.launchCount, 0)
    }

    func testFoundationPreparedHandleReleasesAfterTerminationProof() async throws {
        let driver = FoundationOnePasswordProcessDriver()
        weak var retainedHandle: (any OnePasswordProcessChild)?
        do {
            let handle = try driver.prepare(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], environment: [:], stdout: .anonymousPipe, stderr: .discard
            )
            retainedHandle = handle
            let startResult = await handle.start()
            XCTAssertEqual(startResult, .started)
            guard case .exited(let status, _) = await handle.waitForTermination() else {
                return XCTFail("Expected reaped child")
            }
            XCTAssertEqual(status, 0)
        }
        for _ in 0..<20 where retainedHandle != nil { await Task.yield() }
        XCTAssertNil(retainedHandle)
    }

    func testFoundationPreparedHandleCancellationBeforeStartProvesNoSpawn() async throws {
        let handle = try FoundationOnePasswordProcessDriver().prepare(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], environment: [:], stdout: .anonymousPipe, stderr: .discard
        )
        try handle.terminate()
        let startResult = await handle.start()
        let proof = await handle.waitForTermination()
        XCTAssertEqual(startResult, .prevented)
        XCTAssertEqual(proof, .notSpawned)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class WipedSnapshots: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [Data] = []
    var values: [Data] { lock.withLock { storage } }
    func append(_ data: Data) { lock.withLock { storage.append(data) } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}

private final class RecordingOnePasswordLauncher: @unchecked Sendable, OnePasswordLaunching {
    let output: Data; private(set) var executable: String?; private(set) var arguments: [String]?; private(set) var environment: [String: String]?; private(set) var usedAnonymousStdoutPipe = false; private(set) var usedDiscardedStderrPipe = false; private(set) var stdoutString: String?; private(set) var timeout: Duration?
    init(output: Data) { self.output = output }
    func read(executable: String, arguments: [String], environment: [String: String], stdout: OnePasswordOutputSink, stderr: OnePasswordErrorSink, timeout: Duration) async throws -> Data { self.executable = executable; self.arguments = arguments; self.environment = environment; usedAnonymousStdoutPipe = stdout == .anonymousPipe; usedDiscardedStderrPipe = stderr == .discard; self.timeout = timeout; return output }
}

private final class OnePasswordDriverProbe: @unchecked Sendable, OnePasswordProcessDriving {
    private let lock = NSLock()
    private let result: Result<Data, Error>
    private let acknowledgeForceKill: Bool
    private var child: OnePasswordChildProbe?
    private var launchWaiter: CheckedContinuation<Void, Never>?
    private var forceKillWaiter: CheckedContinuation<Void, Never>?
    private var launches = 0
    private var terminations = 0
    private var forceKills = 0
    private var acknowledgements = 0

    init(result: Result<Data, Error>, acknowledgeForceKill: Bool = true) {
        self.result = result
        self.acknowledgeForceKill = acknowledgeForceKill
    }
    var launchCount: Int { lock.withLock { launches } }
    var terminateCount: Int { lock.withLock { terminations } }
    var forceKillCount: Int { lock.withLock { forceKills } }
    var terminationAcknowledgementCount: Int { lock.withLock { acknowledgements } }

    func prepare(executable: URL, arguments: [String], environment: [String: String], stdout: OnePasswordOutputSink, stderr: OnePasswordErrorSink) throws -> any OnePasswordProcessChild {
        _ = executable; _ = arguments; _ = environment; _ = stdout; _ = stderr
        let child = OnePasswordChildProbe(driver: self)
        lock.withLock { self.child = child }
        return child
    }

    fileprivate func start() -> OnePasswordProcessStartResult {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            launches += 1; let waiter = launchWaiter; launchWaiter = nil; return waiter
        }
        waiter?.resume()
        return .started
    }

    func waitUntilLaunched() async {
        if launchCount > 0 { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if launches > 0 { return true }
                launchWaiter = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func finish(status: Int32) {
        let delivery = lock.withLock { () -> (OnePasswordChildProbe, Data)? in
            guard let child else { return nil }
            self.child = nil
            acknowledgements += 1
            return (child, (try? result.get()) ?? Data())
        }
        delivery?.0.complete(.exited(status, delivery?.1 ?? Data()))
    }

    fileprivate func terminate() { lock.withLock { terminations += 1 } }
    fileprivate func forceKill() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            forceKills += 1; let waiter = forceKillWaiter; forceKillWaiter = nil; return waiter
        }
        waiter?.resume()
        if acknowledgeForceKill { finish(status: 0) }
    }
    func waitUntilForceKilled() async {
        if forceKillCount > 0 { return }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if forceKills > 0 { return true }; forceKillWaiter = continuation; return false
            }
            if resume { continuation.resume() }
        }
    }
}

private final class OnePasswordChildProbe: @unchecked Sendable, OnePasswordProcessChild {
    private let driver: OnePasswordDriverProbe
    private let lock = NSLock()
    private var proof: OnePasswordProcessTermination?
    private var waiter: CheckedContinuation<OnePasswordProcessTermination, Never>?
    init(driver: OnePasswordDriverProbe) { self.driver = driver }
    func start() async -> OnePasswordProcessStartResult { driver.start() }
    func terminate() throws { driver.terminate() }
    func forceKill() throws { driver.forceKill() }
    func waitForTermination() async -> OnePasswordProcessTermination {
        if let proof = lock.withLock({ proof }) { return proof }
        return await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> OnePasswordProcessTermination? in
                if let proof { return proof }; waiter = continuation; return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
    func complete(_ proof: OnePasswordProcessTermination) {
        let waiter = lock.withLock { () -> CheckedContinuation<OnePasswordProcessTermination, Never>? in
            guard self.proof == nil else { return nil }
            self.proof = proof; let waiter = self.waiter; self.waiter = nil; return waiter
        }
        waiter?.resume(returning: proof)
    }
}

private final class BarrierOnePasswordDriver: @unchecked Sendable, OnePasswordProcessDriving {
    private let child = BarrierOnePasswordChild()
    var spawnCount: Int { child.spawnCount }
    var terminateCount: Int { child.terminateCount }
    var terminationAcknowledgementCount: Int { child.acknowledgementCount }
    func prepare(executable: URL, arguments: [String], environment: [String : String], stdout: OnePasswordOutputSink, stderr: OnePasswordErrorSink) throws -> any OnePasswordProcessChild {
        _ = executable; _ = arguments; _ = environment; _ = stdout; _ = stderr; return child
    }
    func waitUntilLaunchEntered() async { await child.waitUntilLaunchEntered() }
    func waitUntilTerminationRequested() async { await child.waitUntilTerminationRequested() }
    func waitUntilLateChildTerminated() async { await child.waitUntilLateChildTerminated() }
    func releaseLaunch() { child.releaseLaunch() }
    func acknowledgeExit(status: Int32) { child.acknowledgeExit(status: status) }
}

private final class BarrierOnePasswordChild: @unchecked Sendable, OnePasswordProcessChild {
    private enum State { case prepared, launching, running, terminal }
    private let lock = NSLock()
    private var state = State.prepared
    private var stopRequested = false
    private var launchReleased = false
    private var launches = 0, spawns = 0, terminations = 0, acknowledgements = 0
    private var launchEnteredWaiter: CheckedContinuation<Void, Never>?
    private var launchBarrier: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var terminatedWaiter: CheckedContinuation<Void, Never>?
    private var proof: OnePasswordProcessTermination?
    private var proofWaiter: CheckedContinuation<OnePasswordProcessTermination, Never>?
    var spawnCount: Int { lock.withLock { spawns } }
    var terminateCount: Int { lock.withLock { terminations } }
    var acknowledgementCount: Int { lock.withLock { acknowledgements } }

    func start() async -> OnePasswordProcessStartResult {
        let entered = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            launches += 1; state = .launching; let waiter = launchEnteredWaiter; launchEnteredWaiter = nil; return waiter
        }
        entered?.resume()
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if launchReleased { return true }
                launchBarrier = continuation
                return false
            }
            if resume { continuation.resume() }
        }
        let terminated = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            spawns += 1; state = .running
            guard stopRequested else { return nil }
            terminations += 1; let waiter = terminatedWaiter; terminatedWaiter = nil; return waiter
        }
        terminated?.resume()
        return .started
    }

    func terminate() throws { requestStop() }
    func forceKill() throws { requestStop() }
    private func requestStop() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if case .terminal = state { return nil }
            stopRequested = true; let waiter = stopWaiter; stopWaiter = nil; return waiter
        }
        waiter?.resume()
    }
    func waitForTermination() async -> OnePasswordProcessTermination {
        if let proof = lock.withLock({ proof }) { return proof }
        return await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> OnePasswordProcessTermination? in
                if let proof { return proof }; proofWaiter = continuation; return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
    func waitUntilLaunchEntered() async { await wait(until: { self.launches > 0 }, store: { self.launchEnteredWaiter = $0 }) }
    func waitUntilTerminationRequested() async { await wait(until: { self.stopRequested }, store: { self.stopWaiter = $0 }) }
    func waitUntilLateChildTerminated() async { await wait(until: { self.terminations > 0 }, store: { self.terminatedWaiter = $0 }) }
    private func wait(until predicate: () -> Bool, store: (CheckedContinuation<Void, Never>) -> Void) async {
        if lock.withLock(predicate) { return }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in if predicate() { return true }; store(continuation); return false }
            if resume { continuation.resume() }
        }
    }
    func releaseLaunch() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            launchReleased = true; let waiter = launchBarrier; launchBarrier = nil; return waiter
        }
        waiter?.resume()
    }
    func acknowledgeExit(status: Int32) {
        let delivery = lock.withLock { () -> CheckedContinuation<OnePasswordProcessTermination, Never>? in
            guard proof == nil else { return nil }
            acknowledgements += 1; state = .terminal; proof = .exited(status, Data())
            let waiter = proofWaiter; proofWaiter = nil; return waiter
        }
        delivery?.resume(returning: .exited(status, Data()))
    }
}

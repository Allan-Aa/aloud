import Darwin
import Foundation

enum OnePasswordProcessStartResult: Equatable, Sendable {
    case started
    case prevented
    case launchFailed
}

enum OnePasswordProcessTermination: Equatable, Sendable {
    case notSpawned
    case launchFailed
    case exited(Int32, Data)
}

protocol OnePasswordProcessDriving: Sendable {
    func prepare(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdout: OnePasswordOutputSink,
        stderr: OnePasswordErrorSink
    ) throws -> any OnePasswordProcessChild
}

protocol OnePasswordProcessChild: AnyObject, Sendable {
    func start() async -> OnePasswordProcessStartResult
    func terminate() throws
    func forceKill() throws
    func waitForTermination() async -> OnePasswordProcessTermination
}

private final class FoundationOnePasswordProcessChild: OnePasswordProcessChild, @unchecked Sendable {
    private enum Signal { case terminate, forceKill }
    private enum State {
        case prepared
        case launching(Signal?)
        case running
        case terminal(OnePasswordProcessTermination)
    }

    private let process: Process
    private let output: Pipe
    private let lock = NSLock()
    private var state: State = .prepared
    private var waiter: CheckedContinuation<OnePasswordProcessTermination, Never>?
    private var writerClosed = false

    init(process: Process, output: Pipe) {
        self.process = process
        self.output = output
    }

    func installTerminationHandler() {
        process.terminationHandler = { [weak self] process in
            self?.didTerminate(status: process.terminationStatus)
        }
    }

    func start() async -> OnePasswordProcessStartResult {
        let initial = lock.withLock { () -> OnePasswordProcessStartResult? in
            switch state {
            case .prepared:
                state = .launching(nil)
                return nil
            case .terminal(.notSpawned):
                return .prevented
            case .terminal(.launchFailed):
                return .launchFailed
            case .terminal(.exited):
                return .started
            case .launching, .running:
                return .started
            }
        }
        if let initial { return initial }

        let launchResult = await Task.detached { [process] in
            do { try process.run(); return true }
            catch { return false }
        }.value
        guard launchResult else {
            complete(.launchFailed)
            return .launchFailed
        }

        closeParentWriterOnce()
        let pendingSignal = lock.withLock { () -> Signal? in
            switch state {
            case .launching(let signal):
                state = .running
                return signal
            case .terminal, .running, .prepared:
                return nil
            }
        }
        if let pendingSignal { send(pendingSignal) }
        return .started
    }

    func terminate() throws { request(.terminate) }
    func forceKill() throws { request(.forceKill) }

    func waitForTermination() async -> OnePasswordProcessTermination {
        if let proof = lock.withLock({ terminalProof }) { return proof }
        return await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> OnePasswordProcessTermination? in
                if let proof = terminalProof { return proof }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    private var terminalProof: OnePasswordProcessTermination? {
        if case .terminal(let proof) = state { return proof }
        return nil
    }

    private func request(_ signal: Signal) {
        var completion: (CheckedContinuation<OnePasswordProcessTermination, Never>, OnePasswordProcessTermination)?
        var sendNow: Signal?
        lock.withLock {
            switch state {
            case .prepared:
                let proof = OnePasswordProcessTermination.notSpawned
                state = .terminal(proof)
                if let waiter { completion = (waiter, proof); self.waiter = nil }
            case .launching(let pending):
                state = .launching(merge(pending, signal))
            case .running:
                sendNow = signal
            case .terminal:
                return
            }
        }
        if let completion { completion.0.resume(returning: completion.1) }
        if let sendNow { send(sendNow) }
    }

    private func merge(_ current: Signal?, _ next: Signal) -> Signal {
        if current == .forceKill || next == .forceKill { return .forceKill }
        return .terminate
    }

    private func send(_ signal: Signal) {
        switch signal {
        case .terminate:
            if process.isRunning { process.terminate() }
        case .forceKill:
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            if Darwin.kill(pid, SIGKILL) != 0 && errno != ESRCH { return }
        }
    }

    private func didTerminate(status: Int32) {
        closeParentWriterOnce()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        complete(.exited(status, data))
        process.terminationHandler = nil
    }

    private func closeParentWriterOnce() {
        let shouldClose = lock.withLock { () -> Bool in
            if writerClosed { return false }
            writerClosed = true
            return true
        }
        if shouldClose { output.fileHandleForWriting.closeFile() }
    }

    private func complete(_ proof: OnePasswordProcessTermination) {
        let waiter = lock.withLock { () -> CheckedContinuation<OnePasswordProcessTermination, Never>? in
            guard terminalProof == nil else { return nil }
            state = .terminal(proof)
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        waiter?.resume(returning: proof)
    }

    deinit {
        process.terminationHandler = nil
        closeParentWriterOnce()
        try? output.fileHandleForReading.close()
    }
}

struct FoundationOnePasswordProcessDriver: OnePasswordProcessDriving {
    func prepare(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdout: OnePasswordOutputSink,
        stderr: OnePasswordErrorSink
    ) throws -> any OnePasswordProcessChild {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        switch stdout { case .anonymousPipe: process.standardOutput = output }
        switch stderr { case .discard: process.standardError = FileHandle.nullDevice }
        let child = FoundationOnePasswordProcessChild(process: process, output: output)
        child.installTerminationHandler()
        return child
    }
}

private final class OnePasswordCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

actor OnePasswordProcessRun {
    private enum State {
        case pending((any OnePasswordProcessChild)?)
        case running(any OnePasswordProcessChild)
        case stopping(any OnePasswordProcessChild, OnePasswordPipeError)
        case finished
    }

    private let driver: any OnePasswordProcessDriving
    private let terminationGrace: Duration
    private nonisolated let cancellation = OnePasswordCancellationRelay()
    private var state: State = .pending(nil)
    private var continuation: CheckedContinuation<Result<Data, Error>, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var forceKillTask: Task<Void, Never>?

    init(driver: any OnePasswordProcessDriving, terminationGrace: Duration) {
        self.driver = driver
        self.terminationGrace = terminationGrace
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdout: OnePasswordOutputSink,
        stderr: OnePasswordErrorSink,
        timeout: Duration
    ) async throws -> Data {
        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
            guard !cancellation.isCancelled else {
                finish(.failure(OnePasswordPipeError.cancelled))
                return
            }
            do {
                let child = try driver.prepare(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    stdout: stdout,
                    stderr: stderr
                )
                state = .pending(child)
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: timeout)
                timeoutTask = Task.detached { [weak self] in
                    do { try await clock.sleep(until: deadline) } catch { return }
                    await self?.requestStop(reason: .timedOut)
                }
                terminationTask = Task.detached { [weak self, child] in
                    let proof = await child.waitForTermination()
                    await self?.didTerminate(child: child, proof: proof)
                }
                launchTask = Task.detached { [weak self, child] in
                    let result = await child.start()
                    await self?.didStart(child: child, result: result)
                }
                if cancellation.isCancelled { requestStop(reason: .cancelled) }
            } catch {
                finish(.failure(cancellation.isCancelled ? OnePasswordPipeError.cancelled : OnePasswordPipeError.launchFailed))
            }
        }
        return try result.get()
    }

    nonisolated func requestCancellation() {
        cancellation.cancel()
        Task { await requestStop(reason: .cancelled) }
    }

    private func didStart(child: any OnePasswordProcessChild, result: OnePasswordProcessStartResult) {
        switch state {
        case .pending(let current) where current === child:
            if result == .started { state = .running(child) }
        case .stopping(let current, _) where current === child:
            return
        case .pending, .running, .stopping, .finished:
            return
        }
    }

    private func requestStop(reason: OnePasswordPipeError) {
        let linearizedReason = cancellation.isCancelled ? OnePasswordPipeError.cancelled : reason
        switch state {
        case .pending(nil):
            return
        case .pending(let child?):
            beginStopping(child: child, reason: linearizedReason)
        case .running(let child):
            beginStopping(child: child, reason: linearizedReason)
        case .stopping, .finished:
            return
        }
    }

    private func beginStopping(child: any OnePasswordProcessChild, reason: OnePasswordPipeError) {
        state = .stopping(child, reason)
        timeoutTask?.cancel()
        timeoutTask = nil
        try? child.terminate()
        let grace = terminationGrace
        forceKillTask = Task.detached { [weak self, child] in
            do { try await Task.sleep(for: grace) } catch { return }
            await self?.forceKillIfNeeded(child: child)
        }
    }

    private func forceKillIfNeeded(child: any OnePasswordProcessChild) {
        guard case .stopping(let current, _) = state, current === child else { return }
        try? child.forceKill()
    }

    private func didTerminate(child: any OnePasswordProcessChild, proof: OnePasswordProcessTermination) {
        switch state {
        case .pending(let current) where current === child:
            finishNormalTermination(proof)
        case .running(let current) where current === child:
            finishNormalTermination(proof)
        case .stopping(let current, let reason) where current === child:
            finish(.failure(reason))
        case .pending, .running, .stopping, .finished:
            return
        }
    }

    private func finishNormalTermination(_ proof: OnePasswordProcessTermination) {
        if cancellation.isCancelled {
            finish(.failure(OnePasswordPipeError.cancelled))
            return
        }
        switch proof {
        case .exited(let status, let data):
            finish(status == 0 ? .success(data) : .failure(OnePasswordPipeError.nonZeroExit))
        case .notSpawned, .launchFailed:
            finish(.failure(OnePasswordPipeError.launchFailed))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        if case .finished = state { return }
        timeoutTask?.cancel()
        launchTask?.cancel()
        terminationTask?.cancel()
        forceKillTask?.cancel()
        timeoutTask = nil
        launchTask = nil
        terminationTask = nil
        forceKillTask = nil
        state = .finished
        let continuation = self.continuation
        self.continuation = nil
        let finalResult: Result<Data, Error>
        if case .success = result, cancellation.isCancelled {
            finalResult = .failure(OnePasswordPipeError.cancelled)
        } else {
            finalResult = result
        }
        continuation?.resume(returning: finalResult)
    }
}

struct ProcessOnePasswordLauncher: OnePasswordLaunching {
    static let importTimeout: Duration = .seconds(30)
    private let driver: any OnePasswordProcessDriving
    private let terminationGrace: Duration

    init(
        driver: any OnePasswordProcessDriving = FoundationOnePasswordProcessDriver(),
        terminationGrace: Duration = .milliseconds(500)
    ) {
        self.driver = driver
        self.terminationGrace = terminationGrace
    }

    func read(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdout: OnePasswordOutputSink,
        stderr: OnePasswordErrorSink,
        timeout: Duration
    ) async throws -> Data {
        guard timeout > .zero else { throw OnePasswordPipeError.timedOut }
        guard !Task.isCancelled else { throw OnePasswordPipeError.cancelled }
        let run = OnePasswordProcessRun(driver: driver, terminationGrace: terminationGrace)
        let data = try await withTaskCancellationHandler {
            try await run.start(
                executable: URL(fileURLWithPath: executable),
                arguments: arguments,
                environment: environment,
                stdout: stdout,
                stderr: stderr,
                timeout: timeout
            )
        } onCancel: {
            run.requestCancellation()
        }
        guard !Task.isCancelled else { throw OnePasswordPipeError.cancelled }
        return data
    }
}

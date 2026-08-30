import Darwin
import Foundation

/// The only production boundary allowed to execute ffmpeg.  It receives a
/// resolved executable URL and an argv array, never a shell command.
protocol WAVProcessDriver: Sendable {
    func launch(executableURL: URL, arguments: [String], terminated: @escaping @Sendable (Int32) -> Void) throws -> any WAVChildProcess
}

protocol WAVChildProcess: Sendable {
    var isRunning: Bool { get }
    func terminate()
    func kill() throws
    func waitForTermination(for deadline: Duration) async -> Bool
}

final class FoundationWAVChild: WAVChildProcess, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var exited = false
    init(process: Process) { self.process = process }
    func markExited() { lock.withLock { exited = true } }
    var isRunning: Bool { lock.withLock { !exited && process.isRunning } }
    func terminate() { lock.withLock { if !exited && process.isRunning { process.terminate() } } }
    func kill() throws {
        let pid: pid_t? = lock.withLock { !exited && process.isRunning ? process.processIdentifier : nil }
        guard let pid else { return }
        guard Darwin.kill(pid, SIGKILL) == 0 else {
            if errno == ESRCH { return }
            throw POSIXError(.init(rawValue: errno) ?? .ESRCH)
        }
    }
    func waitForTermination(for deadline: Duration) async -> Bool {
        let clock = ContinuousClock(); let end = clock.now.advanced(by: deadline)
        while isRunning, clock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        return !isRunning
    }
}

struct FoundationWAVProcessDriver: WAVProcessDriver {
    func launch(executableURL: URL, arguments: [String], terminated: @escaping @Sendable (Int32) -> Void) throws -> any WAVChildProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let child = FoundationWAVChild(process: process)
        process.terminationHandler = { process in child.markExited(); terminated(process.terminationStatus) }
        try process.run()
        return child
    }
}

private final class WAVCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Actor-owned lifecycle: completion is resumed exactly once, and cancellation
/// does not return until the child termination handler has acknowledged exit.
actor ManagedWAVProcess {
    private enum State {
        case idle
        case pending(UUID, WAVCancellationRelay)
        case running(UUID, any WAVChildProcess, WAVCancellationRelay)
        case stopping(UUID, any WAVChildProcess, WAVCancellationRelay, Error)
    }
    private let executableURL: URL
    private let driver: any WAVProcessDriver
    private let grace: Duration
    private var state: State = .idle
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var killTask: Task<Void, Never>?
    private var quarantinedOutputs: Set<String> = []

    init(executableURL: URL, driver: any WAVProcessDriver = FoundationWAVProcessDriver(), grace: Duration = .milliseconds(250)) {
        self.executableURL = executableURL; self.driver = driver; self.grace = grace
    }

    func run(arguments: [String], deadline: Duration) async throws {
        guard deadline > .zero else { throw WAVAudioError.processDeadlineExceeded }
        let runID = UUID()
        let relay = WAVCancellationRelay()
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.begin(runID: runID, arguments: arguments, deadline: deadline, relay: relay, continuation: continuation)
            }
        }, onCancel: {
            relay.cancel()
            Task { await self.requestCancel(runID: runID, reason: CancellationError()) }
        })
        switch result {
        case .failure:
            try result.get()
        case .success:
            try Task.checkCancellation()
        }
    }

    func isQuarantined(_ outputURL: URL) -> Bool { quarantinedOutputs.contains(outputURL.path) }
    func quarantine(_ outputURL: URL) { quarantinedOutputs.insert(outputURL.path) }

    private func begin(runID: UUID, arguments: [String], deadline: Duration, relay: WAVCancellationRelay, continuation: CheckedContinuation<Result<Void, Error>, Never>) {
        guard case .idle = state else { continuation.resume(returning: .failure(WAVAudioError.processBusy)); return }
        self.continuation = continuation
        guard !relay.isCancelled else { finish(.failure(CancellationError())); return }
        state = .pending(runID, relay)
        do {
            let child = try driver.launch(executableURL: executableURL, arguments: arguments) { [weak self] status in
                Task { await self?.didTerminate(status: status) }
            }
            guard case let .pending(currentID, currentRelay) = state, currentID == runID, currentRelay === relay else { return }
            state = .running(runID, child, relay)
            if relay.isCancelled {
                beginStopping(runID: runID, child: child, relay: relay, reason: CancellationError())
                return
            }
            deadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: deadline) } catch { return }
                await self?.requestCancel(runID: runID, reason: WAVAudioError.processDeadlineExceeded)
            }
        } catch { finish(.failure(error)) }
    }

    private func didTerminate(status: Int32) {
        switch state {
        case .idle: return
        case let .pending(_, relay):
            finish(relay.isCancelled ? .failure(CancellationError()) : .failure(WAVAudioError.processFailed(status)))
        case let .running(_, _, relay):
            finish(relay.isCancelled ? .failure(CancellationError()) : (status == 0 ? .success(()) : .failure(WAVAudioError.processFailed(status))))
        case let .stopping(_, _, _, reason):
            finish(.failure(reason))
        }
    }

    private func requestCancel(runID: UUID, reason: Error) {
        switch state {
        case .idle: return
        case let .pending(activeID, relay):
            guard activeID == runID else { return }
            relay.cancel()
            finish(.failure(reason))
        case .stopping: return
        case let .running(activeID, child, relay):
            guard activeID == runID else { return }
            relay.cancel()
            beginStopping(runID: activeID, child: child, relay: relay, reason: reason)
        }
    }

    private func beginStopping(runID: UUID, child: any WAVChildProcess, relay: WAVCancellationRelay, reason: Error) {
        state = .stopping(runID, child, relay, reason)
        child.terminate()
        killTask = Task.detached { [weak self] in
            do { try await Task.sleep(for: self?.grace ?? .zero) } catch { return }
            await self?.forceKill()
        }
    }

    private func forceKill() async {
        guard case let .stopping(runID, child, _, reason) = state else { return }
        do { try child.kill() }
        catch { }
        let acknowledged = await child.waitForTermination(for: grace)
        guard case let .stopping(currentID, currentChild, _, _) = state, currentID == runID else { return }
        if !acknowledged {
            _ = currentChild
            finish(.failure(WAVAudioError.processCancellationUnacknowledged))
        } else { finish(.failure(reason)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        let relay: WAVCancellationRelay? = switch state {
        case .idle: nil
        case let .pending(_, relay), let .running(_, _, relay), let .stopping(_, _, relay, _): relay
        }
        deadlineTask?.cancel(); deadlineTask = nil
        killTask?.cancel(); killTask = nil
        state = .idle
        let continuation = self.continuation; self.continuation = nil
        let finalResult: Result<Void, Error>
        if case .success = result, relay?.isCancelled == true { finalResult = .failure(CancellationError()) }
        else { finalResult = result }
        continuation?.resume(returning: finalResult)
    }
}

struct WAVProcessRunner: Sendable {
    let process: ManagedWAVProcess
    init(executableURL: URL, driver: any WAVProcessDriver = FoundationWAVProcessDriver(), grace: Duration = .milliseconds(250)) {
        process = ManagedWAVProcess(executableURL: executableURL, driver: driver, grace: grace)
    }
    func run(_ command: WAVConversionCommand, deadline: Duration) async throws {
        do { try await process.run(arguments: ["-y", "-i", command.inputURL.path, "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", command.outputURL.path], deadline: deadline) }
        catch {
            if case WAVAudioError.processCancellationUnacknowledged = error { await process.quarantine(command.outputURL) }
            throw error
        }
    }
    func isQuarantined(_ url: URL) async -> Bool { await process.isQuarantined(url) }
    func quarantine(_ url: URL) async { await process.quarantine(url) }
}

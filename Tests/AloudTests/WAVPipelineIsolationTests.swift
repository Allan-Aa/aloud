import Foundation
import XCTest
@testable import Aloud

final class WAVPipelineIsolationTests: XCTestCase {
    func testCancellationAtPrelaunchBarrierNeverReturnsSuccessAndNextRunWorks() async throws {
        for _ in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let driver = BarrierWAVDriver()
            let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver, grace: .milliseconds(1))
            let output = directory.url.appendingPathComponent("output.wav")
            let task = Task { try await runner.run(.init(id: UUID(), inputURL: URL(fileURLWithPath: "/input"), inputFormat: .encoded(container: "mp3", codec: "mp3"), outputURL: output), deadline: .seconds(1)) }
            await driver.waitUntilLaunchEntered()
            task.cancel()
            driver.releaseLaunch()
            await XCTAssertThrowsErrorAsync(try await task.value)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            try await runner.run(.init(id: UUID(), inputURL: URL(fileURLWithPath: "/input"), inputFormat: .encoded(container: "mp3", codec: "mp3"), outputURL: directory.url.appendingPathComponent("next.wav")), deadline: .seconds(1))
        }
    }

    func testZeroStatusAndCancellationRaceNeverReturnsSuccessArtifact() async throws {
        for _ in 0..<20 {
            let directory = try TemporaryDirectory(); defer { try? directory.remove() }
            let driver = BarrierWAVDriver()
            let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver, grace: .milliseconds(1))
            let output = directory.url.appendingPathComponent("output.wav")
            let task = Task { try await runner.run(.init(id: UUID(), inputURL: URL(fileURLWithPath: "/input"), inputFormat: .encoded(container: "mp3", codec: "mp3"), outputURL: output), deadline: .seconds(1)) }
            await driver.waitUntilLaunchEntered()
            task.cancel()
            driver.completeZero()
            await XCTAssertThrowsErrorAsync(try await task.value)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testExitedChildWithDelayedTerminationHandlerCompletesBoundedlyOnce() async throws {
        let driver = DelayedHandlerWAVDriver()
        let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver, grace: .milliseconds(2))
        let task = Task { try await runner.run(.init(id: UUID(), inputURL: URL(fileURLWithPath: "/input"), inputFormat: .encoded(container: "mp3", codec: "mp3"), outputURL: URL(fileURLWithPath: "/output")), deadline: .seconds(1)) }
        await driver.waitUntilLaunched()
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(driver.killCount, 1)
        driver.deliverDelayedHandler()
        XCTAssertEqual(driver.terminateCount, 1)
    }

    func testCancelledBeforeRunnerLaunchDoesNotStartChild() async throws {
        let driver = ScriptedWAVDriver(mode: .ignoreTerminate)
        let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver)
        let task = Task { try await runner.run(.init(id: UUID(), inputURL: URL(fileURLWithPath: "/input"), inputFormat: .encoded(container: "mp3", codec: "mp3"), outputURL: URL(fileURLWithPath: "/output")), deadline: .seconds(1)) }
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(driver.launchCount, 0)
        XCTAssertEqual(driver.terminateCount, 0)
        XCTAssertEqual(driver.killCount, 0)
    }

    func testNonPositiveDeadlineRejectsBeforeDriverLaunch() async throws {
        let driver = ScriptedWAVDriver(mode: .ignoreTerminate)
        let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver)
        await XCTAssertThrowsErrorAsync(try await runner.run(.init(id: UUID(), inputURL: URL(fileURLWithPath: "/input"), inputFormat: .encoded(container: "mp3", codec: "mp3"), outputURL: URL(fileURLWithPath: "/output")), deadline: .zero))
        XCTAssertEqual(driver.launchCount, 0)
    }

    func testSynchronousTerminationCallbackBeforeLaunchReturnsCompletesExactlyOnce() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let driver = ScriptedWAVDriver(mode: .succeed)
        let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver)
        try await runner.run(.init(id: UUID(), inputURL: URL(fileURLWithPath: "/input"), inputFormat: .encoded(container: "mp3", codec: "mp3"), outputURL: directory.url.appendingPathComponent("output.wav")), deadline: .seconds(1))
        XCTAssertEqual(driver.launchCount, 1)
        XCTAssertEqual(driver.terminateCount, 0)
        XCTAssertEqual(driver.killCount, 0)
    }

    func testCancellationWaitsForSIGKILLAcknowledgementBeforeTempCleanup() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let raw = directory.url.appendingPathComponent("raw.pcm")
        try Data(repeating: 0, count: 640).write(to: raw)
        let driver = ScriptedWAVDriver(mode: .ignoreTerminate)
        let canonicalizer = WAVCanonicalizer(runner: WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver, grace: .milliseconds(5)), deadline: .seconds(5))
        let task = Task { try await canonicalizer.canonicalize(NativeAudioArtifact(url: raw, format: .pcm(sampleRate: 32_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview), destinationDirectory: directory.url) }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(driver.terminateCount, 1)
        XCTAssertEqual(driver.killCount, 1)
        let residual = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).filter { $0.hasPrefix("aloud-canonical-") }
        XCTAssertEqual(residual.count, 0, "\(residual)")
    }

    func testDoubleCancellationHasOneTerminationAndOneCompletion() async throws {
        let driver = ScriptedWAVDriver(mode: .ignoreTerminate)
        let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver, grace: .milliseconds(1))
        let task = Task { try await runner.run(.init(id: UUID(), inputURL: URL(fileURLWithPath: "/input"), inputFormat: .encoded(container: "mp3", codec: "mp3"), outputURL: URL(fileURLWithPath: "/output")), deadline: .seconds(3)) }
        try await Task.sleep(for: .milliseconds(10)); task.cancel(); task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(driver.terminateCount, 1); XCTAssertEqual(driver.killCount, 1)
    }

    func testLateWriterAfterTerminationCannotLeaveCanonicalTempBehind() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let raw = directory.url.appendingPathComponent("raw.pcm"); try Data(repeating: 0, count: 640).write(to: raw)
        let driver = ScriptedWAVDriver(mode: .lateWriteAfterKill)
        let canonicalizer = WAVCanonicalizer(runner: WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver, grace: .milliseconds(20)), deadline: .seconds(4))
        let task = Task { try await canonicalizer.canonicalize(NativeAudioArtifact(url: raw, format: .pcm(sampleRate: 32_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview), destinationDirectory: directory.url) }
        try await Task.sleep(for: .milliseconds(10)); task.cancel(); await XCTAssertThrowsErrorAsync(try await task.value)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).filter { $0.hasPrefix("aloud-canonical-") }.count, 0)
    }

    func testKillFailureWithoutTerminationAcknowledgementReturnsBoundedAndQuarantinesOutput() async throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let raw = directory.url.appendingPathComponent("raw.pcm"); try Data(repeating: 0, count: 640).write(to: raw)
        let driver = ScriptedWAVDriver(mode: .killThrowsNoAck)
        let runner = WAVProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/true"), driver: driver, grace: .milliseconds(5))
        let canonicalizer = WAVCanonicalizer(runner: runner, deadline: .seconds(2))
        let task = Task { try await canonicalizer.canonicalize(NativeAudioArtifact(url: raw, format: .pcm(sampleRate: 32_000, channels: 1, bitDepth: 16, littleEndian: true), purpose: .preview), destinationDirectory: directory.url) }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value)
        let leftovers = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("aloud-canonical-") }
        XCTAssertEqual(leftovers.count, 1)
        // A retained unique canonical temp is the quarantine boundary: it is not
        // returned as an artifact, published, or eligible for cache reuse.
    }

    func testFoundationDriverCanonicalizesRealGeneratedMP3() async throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("ffmpeg is unavailable") }
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let input = directory.url.appendingPathComponent("input.mp3")
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5", "-ar", "32000", "-ac", "1", "-b:a", "128k", input.path]
        generator.standardOutput = FileHandle.nullDevice
        generator.standardError = FileHandle.nullDevice
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)

        let artifact = try await WAVCanonicalizer(
            runner: WAVProcessRunner(executableURL: ffmpeg)
        ).canonicalize(
            NativeAudioArtifact(url: input, format: .encoded(container: "mp3", codec: "mp3"), purpose: .preview),
            destinationDirectory: directory.url
        )

        XCTAssertGreaterThan(artifact.duration, 0)
        XCTAssertTrue(artifact.isCanonical)
    }

    func testLegacyMP3CacheFailsClosedWithContentFreeRecoveryMessageBeforePlayerOrConcat() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let legacy = directory.url.appendingPathComponent("old-cache.mp3")
        let joined = directory.url.appendingPathComponent("joined.wav")
        try Data("ID3 legacy bytes".utf8).write(to: legacy)
        XCTAssertThrowsError(try LegacyAudioIsolation.requireCanonical(legacy)) { XCTAssertEqual($0.localizedDescription, "Audio must be regenerated in the current WAV format.") }
        XCTAssertThrowsError(try AudioJoin.concat([legacy], to: joined, ffmpeg: "/not-used"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: joined.path))
    }
}

private final class BarrierWAVDriver: WAVProcessDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Int32) -> Void)?; private var launchCount = 0; private var waiter: CheckedContinuation<Void, Never>?
    func launch(executableURL: URL, arguments: [String], terminated: @escaping @Sendable (Int32) -> Void) throws -> any WAVChildProcess {
        _ = executableURL; _ = arguments
        let next = lock.withLock { () -> Int in launchCount += 1; return launchCount }
        if next > 1 { terminated(0); return BarrierWAVChild(parent: self) }
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in callback = terminated; return self.waiter }
        waiter?.resume()
        return BarrierWAVChild(parent: self)
    }
    func waitUntilLaunchEntered() async {
        if lock.withLock({ callback != nil }) { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if callback != nil { return true }; waiter = continuation; return false
            }
            if shouldResume { continuation.resume() }
        }
    }
    func releaseLaunch() {}
    func completeZero() { lock.withLock { callback }?(0) }
}

private final class BarrierWAVChild: WAVChildProcess, @unchecked Sendable {
    private let parent: BarrierWAVDriver
    init(parent: BarrierWAVDriver) { self.parent = parent }
    var isRunning: Bool { true }
    func terminate() { parent.releaseLaunch() }
    func kill() throws {}
    func waitForTermination(for deadline: Duration) async -> Bool { _ = deadline; return true }
}

private final class DelayedHandlerWAVDriver: WAVProcessDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Int32) -> Void)?; private var terminations = 0; private var kills = 0; private var waiter: CheckedContinuation<Void, Never>?
    var killCount: Int { lock.withLock { kills } }; var terminateCount: Int { lock.withLock { terminations } }
    func launch(executableURL: URL, arguments: [String], terminated: @escaping @Sendable (Int32) -> Void) throws -> any WAVChildProcess {
        _ = executableURL; _ = arguments
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in callback = terminated; return self.waiter }
        waiter?.resume()
        return DelayedHandlerWAVChild(parent: self)
    }
    func waitUntilLaunched() async {
        if lock.withLock({ callback != nil }) { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if callback != nil { return true }; waiter = continuation; return false
            }
            if shouldResume { continuation.resume() }
        }
    }
    func didTerminate() { lock.withLock { terminations += 1 } }
    func didKill() { lock.withLock { kills += 1 } }
    func deliverDelayedHandler() { lock.withLock { callback }?(0) }
}

private final class DelayedHandlerWAVChild: WAVChildProcess, @unchecked Sendable {
    private let parent: DelayedHandlerWAVDriver
    init(parent: DelayedHandlerWAVDriver) { self.parent = parent }
    var isRunning: Bool { false }
    func terminate() { parent.didTerminate() }
    func kill() throws { parent.didKill() }
    func waitForTermination(for deadline: Duration) async -> Bool { _ = deadline; return true }
}

final class ScriptedWAVDriver: WAVProcessDriver, @unchecked Sendable {
    enum Mode { case succeed, ignoreTerminate, lateWriteAfterKill, killThrowsNoAck }
    private let lock = NSLock(); private let mode: Mode
    private var terminateCalls = 0; private var killCalls = 0; private var launches = 0; private var capturedInput: Data?
    var terminateCount: Int { lock.withLock { terminateCalls } }
    var killCount: Int { lock.withLock { killCalls } }
    var launchCount: Int { lock.withLock { launches } }
    var capturedInputData: Data? { lock.withLock { capturedInput } }
    init(mode: Mode) { self.mode = mode }
    func launch(executableURL: URL, arguments: [String], terminated: @escaping @Sendable (Int32) -> Void) throws -> any WAVChildProcess {
        _ = executableURL
        lock.withLock {
            launches += 1
            if let index = arguments.firstIndex(of: "-i"), arguments.indices.contains(index + 1) {
                capturedInput = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            }
        }
        if mode == .succeed { try WAVTestFixture.wav(samples: 480).write(to: URL(fileURLWithPath: arguments.last!)); terminated(0) }
        return ScriptedWAVChild(parent: self, terminated: terminated, ignoreTerminate: mode != .succeed, lateWriter: (mode == .lateWriteAfterKill || mode == .killThrowsNoAck) ? URL(fileURLWithPath: arguments.last!) : nil, killThrows: mode == .killThrowsNoAck)
    }
    func didTerminate() { lock.withLock { terminateCalls += 1 } }
    func didKill() { lock.withLock { killCalls += 1 } }
}

private final class ScriptedWAVChild: WAVChildProcess, @unchecked Sendable {
    private let parent: ScriptedWAVDriver; private let terminated: @Sendable (Int32) -> Void; private let ignoreTerminate: Bool; private let lateWriter: URL?; private let killThrows: Bool
    private var running = true; private let lock = NSLock()
    init(parent: ScriptedWAVDriver, terminated: @escaping @Sendable (Int32) -> Void, ignoreTerminate: Bool, lateWriter: URL?, killThrows: Bool = false) { self.parent = parent; self.terminated = terminated; self.ignoreTerminate = ignoreTerminate; self.lateWriter = lateWriter; self.killThrows = killThrows }
    var isRunning: Bool { lock.withLock { running } }
    func terminate() { parent.didTerminate(); if let lateWriter { try? Data("late writer".utf8).write(to: lateWriter) }; if !ignoreTerminate { exit(-15) } }
    func kill() throws { parent.didKill(); if killThrows { throw POSIXError(.EPERM) }; exit(-9) }
    func waitForTermination(for deadline: Duration) async -> Bool { if killThrows { try? await Task.sleep(for: deadline); return false }; return !isRunning }
    private func exit(_ status: Int32) { let should = lock.withLock { if !running { return false }; running = false; return true }; if should { terminated(status) } }
}

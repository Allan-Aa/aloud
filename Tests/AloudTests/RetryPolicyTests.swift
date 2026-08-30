import XCTest
@testable import Aloud

final class RetryPolicyTests: XCTestCase {
    func testPureDecisionTableCoversSendStateHTTPIdempotencyAndMaximum() {
        let guaranteed = contract(.guaranteed, attempts: 3, statuses: [500, 502, 503], backoffs: [10, 20])
        let unknown = contract(.notGuaranteed, attempts: 3, statuses: [500, 502, 503], backoffs: [10, 20])
        XCTAssertEqual(RetryDecision.decide(.failureBeforeSend, contract: guaranteed, attempt: 1), .retry(afterMilliseconds: 10))
        XCTAssertEqual(RetryDecision.decide(.resultUnknownAfterSend, contract: guaranteed, attempt: 2), .retry(afterMilliseconds: 20))
        for status in [500, 502, 503] {
            XCTAssertEqual(RetryDecision.decide(.http(status), contract: guaranteed, attempt: 1), .retry(afterMilliseconds: 10))
            XCTAssertEqual(RetryDecision.decide(.http(status), contract: unknown, attempt: 1), .stop)
        }
        XCTAssertEqual(RetryDecision.decide(.http(501), contract: guaranteed, attempt: 1), .stop)
        XCTAssertEqual(RetryDecision.decide(.resultUnknownAfterSend, contract: unknown, attempt: 1), .stop)
        XCTAssertEqual(RetryDecision.decide(.failureBeforeSend, contract: unknown, attempt: 1), .stop)
        XCTAssertEqual(RetryDecision.decide(.http(503), contract: guaranteed, attempt: 3), .stop)
        let malformed = RetryContract(idempotency: .guaranteed, retryableHTTPStatuses: [500], maximumAttempts: 2, backoffMilliseconds: [])
        XCTAssertEqual(RetryDecision.decide(.http(500), contract: malformed, attempt: 1), .stop)
        for outcome in [AttemptOutcome.validAudio, .canonicalFailure, .decodeFailure, .playbackFailure] {
            XCTAssertEqual(RetryDecision.decide(outcome, contract: guaranteed, attempt: 1), .stop)
        }
    }

    func testExecuteHasExactAttemptAndBackoffCounts() async throws {
        let calls = RetryCallSpy(outcomes: [.failure(.http(500)), .failure(.http(502)), .success("audio")])
        let sleeps = IntSpy()
        let value = try await RetryPolicy.execute(
            contract: contract(.guaranteed, attempts: 3, statuses: [500, 502, 503], backoffs: [11, 22]),
            sleep: { await sleeps.record($0) },
            attempt: { try await calls.next($0) }
        )
        XCTAssertEqual(value, "audio")
        let attempts = await calls.attempts
        let values = await sleeps.values
        XCTAssertEqual(attempts, [1, 2, 3])
        XCTAssertEqual(values, [11, 22])
    }

    func testUnknownPostSendRetriesOnlyWhenContractGuaranteesIdempotency() async throws {
        for idempotency in [RetryIdempotency.guaranteed, .notGuaranteed] {
            let calls = RetryCallSpy(outcomes: [.failure(.resultUnknownAfterSend), .success("audio")])
            do {
                _ = try await RetryPolicy.execute(
                    contract: contract(idempotency, attempts: 2, statuses: [], backoffs: [0]),
                    sleep: { _ in }, attempt: { try await calls.next($0) }
                )
                XCTAssertEqual(idempotency, .guaranteed)
            } catch let failure as RetryFailure {
                XCTAssertEqual(idempotency, .notGuaranteed)
                XCTAssertEqual(failure, RetryFailure(outcome: .resultUnknownAfterSend, attempts: 1))
            } catch { XCTFail("unexpected \(error)") }
            let attemptCount = await calls.attempts.count
            XCTAssertEqual(attemptCount, idempotency == .guaranteed ? 2 : 1)
        }
    }

    func testMaximumAttemptsStopsWithLiteralFailureAndNoExtraSleep() async {
        let calls = RetryCallSpy(outcomes: [.failure(.http(503)), .failure(.http(503)), .failure(.http(503))])
        let sleeps = IntSpy()
        do {
            _ = try await RetryPolicy.execute(
                contract: contract(.guaranteed, attempts: 3, statuses: [503], backoffs: [5, 7]),
                sleep: { await sleeps.record($0) }, attempt: { try await calls.next($0) }
            ) as String
            XCTFail("expected failure")
        } catch let failure as RetryFailure {
            XCTAssertEqual(failure, RetryFailure(outcome: .http(503), attempts: 3))
        } catch { XCTFail("unexpected \(error)") }
        let attempts = await calls.attempts
        let values = await sleeps.values
        XCTAssertEqual(attempts, [1, 2, 3])
        XCTAssertEqual(values, [5, 7])
    }

    func testCancellationDuringBackoffPreventsAnotherAttempt() async {
        let calls = RetryCallSpy(outcomes: [.failure(.http(500)), .success("must not happen")])
        let gate = RetrySleepGate()
        let task = Task {
            try await RetryPolicy.execute(
                contract: contract(.guaranteed, attempts: 2, statuses: [500], backoffs: [1]),
                sleep: { _ in await gate.enterAndWait() }, attempt: { try await calls.next($0) }
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        let attempts = await calls.attempts
        XCTAssertEqual(attempts, [1])
    }

    func testValidAudioThenCanonicalDecodeOrPlaybackFailureNeverResynthesizes() async throws {
        for downstream in [AttemptOutcome.canonicalFailure, .decodeFailure, .playbackFailure] {
            let calls = RetryCallSpy(outcomes: [.success("valid native audio")])
            let audio = try await RetryPolicy.execute(
                contract: contract(.guaranteed, attempts: 3, statuses: [500], backoffs: [0, 0]),
                attempt: { try await calls.next($0) }
            )
            XCTAssertEqual(audio, "valid native audio")
            do { throw RetryFailure(outcome: downstream, attempts: 1) }
            catch {
                let attempts = await calls.attempts
                XCTAssertEqual(attempts, [1])
            }
        }
    }

    func testCoordinatorCancellationDuringRetryBackoffHasNoRetryOrEffect() async throws {
        let coordinator = SpeechCoordinator()
        let gate = RetrySleepGate()
        let calls = RetryCallSpy(outcomes: [.failure(.http(500)), .success("must not happen")])
        let effects = await MainActor.run { RetryEffectBox() }
        _ = await coordinator.start(
            .reading(text: "fixture", origin: .speak, providerID: .minimax),
            work: { token in
                _ = try await coordinator.synthesizeWithRetry(
                    token: token,
                    contract: contract(.guaranteed, attempts: 2, statuses: [500], backoffs: [1]),
                    sleep: { _ in await gate.enterAndWait() },
                    attempt: { try await calls.next($0) }
                )
                try await token.performCurrent { effects.count += 1 }
            }
        )
        await gate.waitUntilEntered()
        // `requestStop` issues the invalidating ticket synchronously. Releasing
        // the cancellation-ignoring sleep afterward therefore proves the
        // stop-wins order instead of relying on Task scheduling.
        _ = coordinator.requestStop(reason: .userStopped)
        await gate.release()
        await coordinator.stop()
        let attempts = await calls.attempts
        let effectCount = await MainActor.run { effects.count }
        XCTAssertEqual(attempts, [1])
        XCTAssertEqual(effectCount, 0)
    }
}

private func contract(_ idempotency: RetryIdempotency, attempts: Int, statuses: Set<Int>, backoffs: [Int]) -> RetryContract {
    RetryContract(idempotency: idempotency, retryableHTTPStatuses: statuses, maximumAttempts: attempts, backoffMilliseconds: backoffs)
}

private actor RetryCallSpy {
    private var outcomes: [RetryAttempt<String>]
    private(set) var attempts: [Int] = []
    init(outcomes: [RetryAttempt<String>]) { self.outcomes = outcomes }
    func next(_ attempt: Int) throws -> RetryAttempt<String> {
        attempts.append(attempt)
        guard !outcomes.isEmpty else { throw RetryFailure(outcome: .failureBeforeSend, attempts: attempt) }
        return outcomes.removeFirst()
    }
}

private actor IntSpy {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}

private actor RetrySleepGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func enterAndWait() async {
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

@MainActor
private final class RetryEffectBox { var count = 0 }

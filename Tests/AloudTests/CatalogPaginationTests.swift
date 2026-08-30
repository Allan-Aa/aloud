import XCTest
@testable import Aloud

final class CatalogPaginationTests: XCTestCase {
    private let scope = try! RelationshipScope(providerID: ProviderID(rawValue: "test-provider"), credentialRevision: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, contractVersion: ContractVersion(rawValue: "contract-v1"), parentModelID: ModelID(rawValue: "m1"), controlsSchema: "controls-v1", queryParameters: [:])
    private let refreshA = CatalogRefreshID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
    private let refreshB = CatalogRefreshID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
    private func pager(_ pages: Int = 3, _ items: Int = 3, _ timeout: TimeInterval = 5) -> CatalogPager { CatalogPager(initialSnapshot: .empty, limits: CatalogPaginationLimits(maxPages: pages, maxItems: items, timeout: timeout)) }
    private func terminal<T: Codable & Hashable & Sendable>(_ values: [T], scope: RelationshipScope? = nil, refresh: CatalogRefreshID? = nil, coverage: EvidenceCoverage = .authoritativeComplete, complete: Bool = true) -> CatalogPage<T> { CatalogPage(scope: scope ?? self.scope, refreshID: refresh ?? refreshA, coverage: coverage, paginationComplete: complete, values: values, nextToken: nil) }
    private func partial<T: Codable & Hashable & Sendable>(_ values: [T], token: String, scope: RelationshipScope? = nil, refresh: CatalogRefreshID? = nil) -> CatalogPage<T> { CatalogPage(scope: scope ?? self.scope, refreshID: refresh ?? refreshA, coverage: .partial, paginationComplete: false, values: values, nextToken: token) }

    func testTerminalPagesPublishOnlyAfterExplicitAuthority() async {
        let pager = pager(), tuple = Self.tuple("v1"), gate = RefreshGate()
        let task = Task {
            await pager.refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { token in
                if token == nil {
                    return self.partial([tuple], token: "next")
                }
                await gate.started()
                await gate.wait()
                return self.terminal([])
            })
        }
        await gate.waitStarted()
        let snapshot = await pager.currentSnapshot()
        XCTAssertNil(snapshot.relationshipEvidence[scope])
        await gate.release()
        let completed = await task.value
        XCTAssertEqual(completed.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
        XCTAssertEqual(completed.relationshipEvidence[scope]?.values, [tuple])
    }

    func testWrongPageIdentityPartialTerminalAndEmptyTokenNeverPublish() async {
        let other = try! RelationshipScope(providerID: ProviderID(rawValue: "other"), credentialRevision: scope.credentialRevision, contractVersion: scope.contractVersion, parentModelID: scope.parentModelID, controlsSchema: scope.controlsSchema, queryParameters: scope.queryParameters)
        let cases: [CatalogPage<AccountRelationshipTuple>] = [terminal([], scope: other), terminal([], refresh: refreshB), terminal([], coverage: .partial, complete: false), CatalogPage(scope: scope, refreshID: refreshA, coverage: .partial, paginationComplete: false, values: [], nextToken: "")]
        for page in cases { let snapshot = await pager().refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { _ in page }); XCTAssertNotEqual(snapshot.relationshipEvidence[scope]?.coverage, .authoritativeComplete) }
    }

    func testNonAdjacentTokenLoopAndExactLimits() async {
        let loop = await pager().refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { token in token == nil ? self.partial([], token: "a") : token == "a" ? self.partial([], token: "b") : self.partial([], token: "a") })
        XCTAssertNotEqual(loop.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
        let exact = await pager(2, 2).refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { token in token == nil ? self.partial([Self.tuple("v1")], token: "next") : self.terminal([Self.tuple("v2")]) })
        XCTAssertEqual(exact.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
        let tooMany = await pager(2, 2).refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { _ in self.terminal([Self.tuple("v1"), Self.tuple("v2"), Self.tuple("v3")]) })
        XCTAssertNotEqual(tooMany.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
        let pageOverflow = await pager(2, 3).refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { token in token == nil ? self.partial([], token: "a") : self.partial([], token: "b") })
        XCTAssertNotEqual(pageOverflow.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
    }

    func testPerRefreshDeadlineAndCancellationRetainStale() async {
        let longLived = pager(3, 3, 0.001)
        _ = await longLived.refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { _ in self.terminal([] as [AccountRelationshipTuple]) })
        let later = await longLived.refreshRelationships(scope: scope, refreshID: refreshB, authoritySource: "test", fetchPage: { _ in self.terminal([] as [AccountRelationshipTuple], refresh: self.refreshB) })
        XCTAssertEqual(later.relationshipEvidence[scope]?.refreshID, refreshB)
        let gate = RefreshGate(), pending = Task { await self.pager().refreshRelationships(scope: self.scope, refreshID: self.refreshA, authoritySource: "test", fetchPage: { _ in await gate.started(); await gate.wait(); return self.terminal([] as [AccountRelationshipTuple]) }) }
        await gate.waitStarted(); pending.cancel(); await gate.release(); let cancelled = await pending.value
        XCTAssertNotEqual(cancelled.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
        let forever = RefreshGate(), timed = await pager(3, 3, 0.001).refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { _ in await forever.started(); await forever.wait(); return self.terminal([] as [AccountRelationshipTuple]) })
        await forever.release()
        XCTAssertNotEqual(timed.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
    }

    func testParentCancellationReturnsBeforeIgnoringFetchAndLateFetchCannotOverwriteNewRefresh() async {
        let initialEvidence = AccountRelationshipEvidence(
            scope: scope,
            scopeRevision: scope.credentialRevision,
            contractVersion: scope.contractVersion,
            fetchedAt: Date(),
            refreshID: refreshA,
            authoritySource: "fixture",
            coverage: .authoritativeComplete,
            paginationComplete: true,
            values: [Self.tuple("initial")],
            rejections: []
        )
        let pager = CatalogPager(
            initialSnapshot: AccountCatalogSnapshot(relationshipEvidence: [scope: initialEvidence]),
            limits: CatalogPaginationLimits(maxPages: 2, maxItems: 2, timeout: 5)
        )
        let oldFetch = RefreshGate()
        let completion = CompletionProbe()
        let oldRefresh = Task {
            let snapshot = await pager.refreshRelationships(scope: self.scope, refreshID: self.refreshB, authoritySource: "old", fetchPage: { _ in
                await oldFetch.started()
                await oldFetch.wait()
                await oldFetch.ended()
                return self.terminal([Self.tuple("old")], refresh: self.refreshB)
            })
            await completion.finish()
            return snapshot
        }

        await oldFetch.waitStarted()
        oldRefresh.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        let returnedBeforeRelease = await completion.isFinished
        if !returnedBeforeRelease {
            await oldFetch.release()
        }
        let cancelled = await oldRefresh.value
        XCTAssertTrue(returnedBeforeRelease, "parent cancellation waited for a fetch that ignored cancellation")
        XCTAssertEqual(cancelled.relationshipEvidence[scope]?.coverage, .unknown)
        XCTAssertEqual(cancelled.relationshipEvidence[scope]?.refreshID, refreshA)

        let current = await pager.refreshRelationships(scope: scope, refreshID: refreshB, authoritySource: "current", fetchPage: { _ in
            self.terminal([Self.tuple("current")], refresh: self.refreshB)
        })
        XCTAssertEqual(current.relationshipEvidence[scope]?.values, [Self.tuple("current")])

        await oldFetch.release()
        await oldFetch.waitEnded()
        try? await Task.sleep(for: .milliseconds(20))
        let afterLateReturn = await pager.currentSnapshot()
        XCTAssertEqual(afterLateReturn.relationshipEvidence[scope]?.values, [Self.tuple("current")])
    }

    func testSameRefreshIDOldOperationCannotClearNewOperation() async {
        let pager = pager(), gate = RefreshGate()
        let old = Task { await pager.refreshRelationships(scope: self.scope, refreshID: self.refreshA, authoritySource: "test", fetchPage: { _ in await gate.started(); await gate.wait(); return self.terminal([Self.tuple("old")]) }) }
        await gate.waitStarted()
        let current = await pager.refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { _ in self.terminal([Self.tuple("current")]) })
        await gate.release(); let result = await old.value
        XCTAssertEqual(current.relationshipEvidence[scope]?.values, [Self.tuple("current")])
        XCTAssertEqual(result.relationshipEvidence[scope]?.values, [Self.tuple("current")])
        let next = await pager.refreshRelationships(scope: scope, refreshID: refreshB, authoritySource: "test", fetchPage: { _ in self.terminal([] as [AccountRelationshipTuple], refresh: self.refreshB) })
        XCTAssertEqual(next.relationshipEvidence[scope]?.refreshID, refreshB)
    }

    func testResourceStaggeredSuccessFailureAndDimensionsStaySeparate() async {
        let pager = pager(), root = scope.withoutParentModel()
        let models = await pager.refreshModels(scope: root, refreshID: refreshA, authoritySource: "test", fetchPage: { _ in CatalogPage(scope: root, refreshID: self.refreshA, coverage: .authoritativeComplete, paginationComplete: true, values: [ModelID(rawValue: "m1")], nextToken: nil) })
        let stale = await pager.refreshModels(scope: root, refreshID: refreshB, authoritySource: "test", fetchPage: { _ in throw CancellationError() })
        let voices = await pager.refreshVoices(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { _ in CatalogPage(scope: self.scope, refreshID: self.refreshA, coverage: .authoritativeComplete, paginationComplete: true, values: [VoiceID(rawValue: "v1")], nextToken: nil) })
        XCTAssertEqual(models.modelEvidence[root]?[AccountResourceKey(dimension: .model, parentModelID: nil)]?.coverage, .authoritativeComplete)
        XCTAssertEqual(stale.modelEvidence[root]?[AccountResourceKey(dimension: .model, parentModelID: nil)]?.coverage, .unknown)
        XCTAssertEqual(voices.voiceEvidence[scope]?[AccountResourceKey(dimension: .voice, parentModelID: scope.parentModelID)]?.coverage, .authoritativeComplete)
    }

    func testConcurrentModelSuccessAndVoiceFailureRemainIndependent() async {
        let root = scope.withoutParentModel()
        let voiceKey = AccountResourceKey(dimension: .voice, parentModelID: scope.parentModelID)
        let existingVoice = AccountResourceEvidence(
            scopeRevision: scope.credentialRevision,
            contractVersion: scope.contractVersion,
            fetchedAt: Date(),
            refreshID: refreshA,
            authoritySource: "fixture",
            coverage: .authoritativeComplete,
            values: [VoiceID(rawValue: "existing")]
        )
        let pager = CatalogPager(
            initialSnapshot: AccountCatalogSnapshot(voiceEvidence: [scope: [voiceKey: existingVoice]]),
            limits: CatalogPaginationLimits(maxPages: 2, maxItems: 2, timeout: 5)
        )
        let modelGate = RefreshGate()
        let voiceGate = RefreshGate()
        let models = Task {
            await pager.refreshModels(scope: root, refreshID: refreshA, authoritySource: "models", fetchPage: { _ in
                await modelGate.started()
                await modelGate.wait()
                return CatalogPage(scope: root, refreshID: self.refreshA, coverage: .authoritativeComplete, paginationComplete: true, values: [ModelID(rawValue: "m1")], nextToken: nil)
            })
        }
        let voices = Task {
            await pager.refreshVoices(scope: self.scope, refreshID: self.refreshB, authoritySource: "voices", fetchPage: { _ in
                await voiceGate.started()
                await voiceGate.wait()
                throw CatalogTestError.expectedFailure
            })
        }

        await modelGate.waitStarted()
        await voiceGate.waitStarted()
        await modelGate.release()
        let modelResult = await models.value
        XCTAssertEqual(modelResult.modelEvidence[root]?[AccountResourceKey(dimension: .model, parentModelID: nil)]?.coverage, .authoritativeComplete)
        XCTAssertEqual(modelResult.voiceEvidence[scope]?[voiceKey]?.coverage, .authoritativeComplete)

        await voiceGate.release()
        _ = await voices.value
        let final = await pager.currentSnapshot()
        XCTAssertEqual(final.modelEvidence[root]?[AccountResourceKey(dimension: .model, parentModelID: nil)]?.values, [ModelID(rawValue: "m1")])
        XCTAssertEqual(final.voiceEvidence[scope]?[voiceKey]?.coverage, .unknown)
        XCTAssertEqual(final.voiceEvidence[scope]?[voiceKey]?.values, [VoiceID(rawValue: "existing")])
    }

    func testAllPagesShareOneAbsoluteDeadline() async {
        let pager = pager(3, 3, 0.30)
        let clock = ContinuousClock()
        let started = clock.now
        let result = await pager.refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "test", fetchPage: { token in
            if token == nil {
                try await Task.sleep(for: .milliseconds(240))
                return self.partial([Self.tuple("v1")], token: "next")
            }
            try await Task.sleep(for: .seconds(5))
            return self.terminal([])
        })
        let elapsed = started.duration(to: clock.now)

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200))
        XCTAssertLessThan(elapsed, .milliseconds(480), "a second per-page timeout replaced the single refresh deadline")
        XCTAssertNotEqual(result.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
    }

    func testFastFetchCancelsDeadlineAndTimeoutCancelsFetch() async {
        let fastRecorder = RaceRecorder()
        let fastPager = CatalogPager(
            initialSnapshot: .empty,
            limits: CatalogPaginationLimits(maxPages: 2, maxItems: 2, timeout: 5),
            raceObserver: { fastRecorder.record($0) }
        )
        _ = await fastPager.refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "fast", fetchPage: { _ in
            self.terminal([] as [AccountRelationshipTuple])
        })
        XCTAssertEqual(fastRecorder.count(.fetchWon), 1)
        XCTAssertEqual(fastRecorder.count(.deadlineCancelled), 1)

        let timeoutRecorder = RaceRecorder()
        let cancellationProbe = CancellationProbe()
        let blockedFetch = RefreshGate()
        let timeoutPager = CatalogPager(
            initialSnapshot: .empty,
            limits: CatalogPaginationLimits(maxPages: 2, maxItems: 2, timeout: 0.03),
            raceObserver: { timeoutRecorder.record($0) }
        )
        let timed = await timeoutPager.refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "timeout", fetchPage: { _ in
            await blockedFetch.started()
            return await withTaskCancellationHandler(operation: {
                await blockedFetch.wait()
                await blockedFetch.ended()
                return self.terminal([] as [AccountRelationshipTuple])
            }, onCancel: {
                cancellationProbe.recordCancellation()
            })
        })
        XCTAssertNotEqual(timed.relationshipEvidence[scope]?.coverage, .authoritativeComplete)
        XCTAssertEqual(timeoutRecorder.count(.timeoutWon), 1)
        XCTAssertEqual(timeoutRecorder.count(.fetchCancelled), 1)
        XCTAssertTrue(cancellationProbe.wasCancelled)
        await blockedFetch.release()
        await blockedFetch.waitEnded()
    }

    func testTwentyNearRacesCompleteExactlyOnceWithoutDeadlock() async {
        let recorder = RaceRecorder()
        for round in 0..<20 {
            let before = recorder.winnerCount
            let timeout = round.isMultiple(of: 3) ? 0.018 : 0.015
            let racePager = CatalogPager(
                initialSnapshot: .empty,
                limits: CatalogPaginationLimits(maxPages: 1, maxItems: 1, timeout: timeout),
                raceObserver: { recorder.record($0) }
            )
            if round % 3 == 1 {
                let refresh = Task {
                    await racePager.refreshRelationships(scope: self.scope, refreshID: self.refreshA, authoritySource: "cancel", fetchPage: { _ in
                        try await Task.sleep(for: .milliseconds(18))
                        return self.terminal([] as [AccountRelationshipTuple])
                    })
                }
                try? await Task.sleep(for: .milliseconds(13))
                refresh.cancel()
                _ = await refresh.value
            } else {
                _ = await racePager.refreshRelationships(scope: scope, refreshID: refreshA, authoritySource: "return-or-timeout", fetchPage: { _ in
                    try await Task.sleep(for: .milliseconds(16))
                    return self.terminal([] as [AccountRelationshipTuple])
                })
            }
            XCTAssertEqual(recorder.winnerCount, before + 1, "round \(round) resolved more or less than once")
        }
        XCTAssertEqual(recorder.winnerCount, 20)
    }

    func testSuccessfulCatalogRefreshRetainsCurrentStructuredRejection() async {
        let tuple = Self.tuple("v1"), rejection = StructuredSynthesisRejection(scopeRevision: scope.credentialRevision, tuple: tuple, sessionGeneration: SessionGeneration(rawValue: 7), reason: "real-structured-rejection")
        let initialEvidence = AccountRelationshipEvidence(scope: scope, scopeRevision: scope.credentialRevision, contractVersion: scope.contractVersion, fetchedAt: Date(), refreshID: refreshA, authoritySource: "fixture", coverage: .unknown, paginationComplete: false, values: [], rejections: [rejection])
        let pager = CatalogPager(initialSnapshot: AccountCatalogSnapshot(relationshipEvidence: [scope: initialEvidence]), limits: CatalogPaginationLimits(maxPages: 2, maxItems: 2, timeout: 5))
        let snapshot = await pager.refreshRelationships(scope: scope, refreshID: refreshB, authoritySource: "test", fetchPage: { _ in self.terminal([], refresh: self.refreshB) as CatalogPage<AccountRelationshipTuple> })
        XCTAssertEqual(AccountSelectionValidator.validate(model: tuple.modelID, voice: tuple.voiceID, in: snapshot, scope: scope, currentRevision: scope.credentialRevision, currentRefreshID: refreshB, currentSessionGeneration: SessionGeneration(rawValue: 7), contractOwned: .none), .invalid)
    }

    private static func tuple(_ voice: String) -> AccountRelationshipTuple { AccountRelationshipTuple(modelID: ModelID(rawValue: "m1"), voiceID: VoiceID(rawValue: voice), controlsID: nil, controlsVersion: nil) }
}

private actor RefreshGate {
    private var didStart = false, didRelease = false, didEnd = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var endWaiter: CheckedContinuation<Void, Never>?
    func started() { didStart = true; startWaiter?.resume(); startWaiter = nil }
    func waitStarted() async { if !didStart { await withCheckedContinuation { startWaiter = $0 } } }
    func wait() async { if !didRelease { await withCheckedContinuation { releaseWaiter = $0 } } }
    func release() { didRelease = true; releaseWaiter?.resume(); releaseWaiter = nil }
    func ended() { didEnd = true; endWaiter?.resume(); endWaiter = nil }
    func waitEnded() async { if !didEnd { await withCheckedContinuation { endWaiter = $0 } } }
}

private actor CompletionProbe {
    private var finished = false
    var isFinished: Bool { finished }
    func finish() { finished = true }
}

private enum CatalogTestError: Error {
    case expectedFailure
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func recordCancellation() {
        lock.withLock { cancelled = true }
    }
}

private final class RaceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CatalogPagerRaceEvent] = []

    var winnerCount: Int {
        lock.withLock { events.filter(\.isWinner).count }
    }

    func count(_ event: CatalogPagerRaceEvent) -> Int {
        lock.withLock { events.filter { $0 == event }.count }
    }

    func record(_ event: CatalogPagerRaceEvent) {
        lock.withLock { events.append(event) }
    }
}

private extension CatalogPagerRaceEvent {
    var isWinner: Bool {
        switch self {
        case .fetchWon, .timeoutWon, .parentCancellationWon:
            return true
        case .deadlineCancelled, .fetchCancelled:
            return false
        }
    }
}

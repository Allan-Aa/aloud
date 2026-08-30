import Foundation

enum CancellationReason: String, Sendable {
    case replaced
    case userStopped
    case selectionChanged
    case defaultProviderChanged
    case credentialChanged
    case shutdown
}

enum SpeechCommand: Hashable, Sendable {
    case reading(text: String, origin: ReadingOrigin, providerID: ProviderID, credentiallessScopeRevision: UUID? = nil)
    case preview(providerID: ProviderID, phraseID: String, credentiallessScopeRevision: UUID? = nil)

    var providerID: ProviderID {
        switch self {
        case .reading(_, _, let providerID, _), .preview(let providerID, _, _): return providerID
        }
    }

    var purpose: SpeechPurpose {
        switch self {
        case .reading(_, let origin, _, _): return .reading(origin)
        case .preview: return .preview
        }
    }

    var credentiallessScopeRevision: UUID? {
        switch self {
        case .reading(_, _, _, let revision), .preview(_, _, let revision): return revision
        }
    }
}

struct SpeechSession: Sendable {
    let sessionID: SpeechRequestID
    let generation: SessionGeneration
    let purpose: SpeechPurpose
    let providerID: ProviderID
    /// One complete snapshot is captured before validation. Work receives this
    /// value and has no credential-store callback with which to reread it.
    let envelope: CredentialEnvelope?
    let scopeRevision: UUID?
}

enum AttemptOutcome: Equatable, Sendable {
    case failureBeforeSend
    case resultUnknownAfterSend
    case http(Int)
    case validAudio
    case canonicalFailure
    case decodeFailure
    case playbackFailure
}

enum RetryDecision: Equatable, Sendable {
    case retry(afterMilliseconds: Int)
    case stop

    static func decide(_ outcome: AttemptOutcome, contract: RetryContract, attempt: Int) -> RetryDecision {
        guard attempt >= 1,
              attempt < contract.maximumAttempts,
              contract.idempotency == .guaranteed else { return .stop }

        let retryable: Bool
        switch outcome {
        case .failureBeforeSend, .resultUnknownAfterSend:
            retryable = true
        case .http(let status):
            retryable = contract.retryableHTTPStatuses.contains(status)
        case .validAudio, .canonicalFailure, .decodeFailure, .playbackFailure:
            retryable = false
        }
        guard retryable else { return .stop }
        guard contract.backoffMilliseconds.indices.contains(attempt - 1) else { return .stop }
        return .retry(afterMilliseconds: contract.backoffMilliseconds[attempt - 1])
    }
}

enum RetryAttempt<Output: Sendable>: Sendable {
    case success(Output)
    case failure(AttemptOutcome)
}

struct RetryFailure: Error, Equatable, Sendable {
    let outcome: AttemptOutcome
    let attempts: Int
}

enum RetryPolicy {
    static func execute<Output: Sendable>(
        contract: RetryContract,
        sleep: @escaping @Sendable (Int) async throws -> Void = { milliseconds in
            guard milliseconds > 0 else { try Task.checkCancellation(); return }
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        },
        attempt: @escaping @Sendable (Int) async throws -> RetryAttempt<Output>
    ) async throws -> Output {
        var number = 1
        while true {
            try Task.checkCancellation()
            switch try await attempt(number) {
            case .success(let output):
                return output
            case .failure(let outcome):
                switch RetryDecision.decide(outcome, contract: contract, attempt: number) {
                case .stop:
                    throw RetryFailure(outcome: outcome, attempts: number)
                case .retry(let milliseconds):
                    try Task.checkCancellation()
                    try await sleep(milliseconds)
                    try Task.checkCancellation()
                    number += 1
                }
            }
        }
    }
}

private final class SessionCancellationRelay: @unchecked Sendable {
    // Side effects are MainActor-isolated and may synchronously submit a newer
    // command. Recursive locking gives that command a linearization point: the
    // current effect finishes, then every later effect from the old token fails.
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var cleanups: [UUID: @Sendable () -> Void] = [:]

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            let values = Array(cleanups.values)
            cleanups.removeAll()
            return values
        }
        pending.forEach { $0() }
    }

    func cleanupUnpublished() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            let values = Array(cleanups.values)
            cleanups.removeAll()
            return values
        }
        pending.forEach { $0() }
    }

    func registerCleanup(_ cleanup: @escaping @Sendable () -> Void) -> UUID? {
        lock.withLock {
            guard !cancelled else { return nil }
            let id = UUID()
            cleanups[id] = cleanup
            return id
        }
    }

    func disarmCleanup(_ id: UUID) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            cleanups[id] = nil
        }
    }

    func withPermission<Output>(_ body: () throws -> Output) throws -> Output {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            return try body()
        }
    }
}

private final class PendingStartLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if lock.withLock({ released }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if released { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            let pending = waiter
            waiter = nil
            return pending
        }
        continuation?.resume()
    }
}

private final class CoordinatorCommandSequencer: @unchecked Sendable {
    private struct Pending { let providerID: ProviderID?; let task: Task<Void, Never> }
    private struct ActiveWork { let ticket: UInt64; let providerID: ProviderID; let relay: SessionCancellationRelay; let task: Task<Void, Never> }
    private let lock = NSRecursiveLock()
    private var value: UInt64 = 0
    private var providerID: ProviderID?
    private var pending: [UInt64: Pending] = [:]
    private var retired: [UInt64: Pending] = [:]
    private var activeWork: ActiveWork?

    /// Issues a ticket, registers its task, and only then lets the operation
    /// run. Stop and submission therefore have one total order under this lock:
    /// Stop either sees and drains this pending task, or precedes a genuinely
    /// newer user submission.
    func submitPending(
        providerID: ProviderID?,
        operation: @escaping @Sendable (UInt64) async -> Void
    ) -> UInt64 {
        let submitted: (
            ticket: UInt64, latch: PendingStartLatch,
            priorActive: ActiveWork?, priorTasks: [Task<Void, Never>]
        ) = lock.withLock {
            let priorActive = activeWork
            var priorTasks: [Task<Void, Never>] = []
            for (ticket, work) in pending {
                retired[ticket] = work
                priorTasks.append(work.task)
            }
            pending.removeAll()
            value &+= 1
            self.providerID = providerID
            let ticket = value
            let latch = PendingStartLatch()
            let task = Task { [weak self] in
                await latch.wait()
                await operation(ticket)
                self?.completePending(ticket: ticket)
            }
            pending[ticket] = Pending(providerID: providerID, task: task)
            return (ticket, latch, priorActive, priorTasks)
        }
        submitted.priorActive?.relay.cancel()
        submitted.priorActive?.task.cancel()
        submitted.priorTasks.forEach { $0.cancel() }
        submitted.latch.release()
        return submitted.ticket
    }

    private func issueRecord(providerID: ProviderID?) -> (ticket: UInt64, affectedProviders: Set<ProviderID>, active: ActiveWork?, tasks: [Task<Void, Never>]) {
        lock.withLock {
            let priorActive = activeWork
            var pendingTasks: [Task<Void, Never>] = []
            var affectedProviders = Set(pending.values.compactMap(\.providerID))
            affectedProviders.formUnion(retired.values.compactMap(\.providerID))
            if let currentProviderID = self.providerID { affectedProviders.insert(currentProviderID) }
            if let priorActive { affectedProviders.insert(priorActive.providerID) }
            for (ticket, work) in pending {
                retired[ticket] = work
                pendingTasks.append(work.task)
            }
            pending.removeAll()
            value &+= 1
            self.providerID = providerID
            return (value, affectedProviders, priorActive, pendingTasks)
        }
    }

    func issue(providerID: ProviderID?) -> UInt64 {
        let issued = issueRecord(providerID: providerID)
        issued.active?.relay.cancel()
        issued.active?.task.cancel()
        issued.tasks.forEach { $0.cancel() }
        return issued.ticket
    }

    func issueWithAffectedProviders(providerID: ProviderID?) -> (ticket: UInt64, affectedProviders: Set<ProviderID>) {
        let issued = issueRecord(providerID: providerID)
        issued.active?.relay.cancel()
        issued.active?.task.cancel()
        issued.tasks.forEach { $0.cancel() }
        return (issued.ticket, issued.affectedProviders)
    }

    func completePending(ticket: UInt64) { lock.withLock { pending[ticket] = nil; retired[ticket] = nil } }

    func pendingLedgerCount() -> Int { lock.withLock { pending.count + retired.count } }

    func installActive(ticket: UInt64, providerID: ProviderID, relay: SessionCancellationRelay, task: Task<Void, Never>) {
        let cancel = lock.withLock {
            guard value == ticket else { return true }
            activeWork = ActiveWork(ticket: ticket, providerID: providerID, relay: relay, task: task)
            return false
        }
        if cancel { relay.cancel(); task.cancel() }
    }

    func completeActive(ticket: UInt64) {
        lock.withLock { if activeWork?.ticket == ticket { activeWork = nil } }
    }

    func takeRetired(providerID: ProviderID? = nil) -> [Task<Void, Never>] {
        lock.withLock {
            let matches = retired.filter { providerID == nil || $0.value.providerID == providerID }
            for ticket in matches.keys { retired[ticket] = nil }
            return matches.values.map(\.task)
        }
    }

    func hasWork(providerID: ProviderID) -> Bool {
        lock.withLock {
            self.providerID == providerID
                || pending.values.contains(where: { $0.providerID == providerID })
                || retired.values.contains(where: { $0.providerID == providerID })
                || activeWork?.providerID == providerID
        }
    }

    func providerIDsWithWork() -> Set<ProviderID> {
        lock.withLock {
            var providers = Set(pending.values.compactMap(\.providerID))
            providers.formUnion(retired.values.compactMap(\.providerID))
            if let providerID { providers.insert(providerID) }
            if let activeWork { providers.insert(activeWork.providerID) }
            return providers
        }
    }

    /// Cancels only the requested provider. This is used when an older retired
    /// provider is changing credentials while a newer provider stays current.
    func cancelProviderTasks(_ providerID: ProviderID) {
        let cancelled: (ActiveWork?, [Task<Void, Never>]) = lock.withLock {
            let active = activeWork?.providerID == providerID ? activeWork : nil
            let matches = pending.filter { $0.value.providerID == providerID }
            for (ticket, work) in matches {
                retired[ticket] = work
                pending[ticket] = nil
            }
            let tasks = retired.values.filter { $0.providerID == providerID }.map(\.task)
            return (active, tasks)
        }
        cancelled.0?.relay.cancel()
        cancelled.0?.task.cancel()
        cancelled.1.forEach { $0.cancel() }
    }

    func isLatest(_ ticket: UInt64) -> Bool { lock.withLock { value == ticket } }
    func latestProviderIs(_ providerID: ProviderID) -> Bool { lock.withLock { self.providerID == providerID } }
    func latestTicket() -> UInt64 { lock.withLock { value } }

    func withLatestPermission<Output>(_ ticket: UInt64, _ body: () throws -> Output) throws -> Output {
        try lock.withLock {
            guard value == ticket else { throw CancellationError() }
            return try body()
        }
    }
}

/// Linearizes player/UI effects with a queued start/stop command. A command
/// submitted later invalidates this token synchronously, even before either
/// command reaches the coordinator actor.
struct CoordinatorControlToken: Sendable {
    fileprivate let ticket: UInt64
    fileprivate let sequencer: CoordinatorCommandSequencer

    func performCurrent<Output: Sendable>(_ body: @MainActor @Sendable () throws -> Output) async throws -> Output {
        try await MainActor.run { try sequencer.withLatestPermission(ticket, body) }
    }

    @MainActor
    func performCurrentSync<Output>(_ body: () throws -> Output) throws -> Output {
        try sequencer.withLatestPermission(ticket, body)
    }
}

/// Work can only mutate generation-scoped state through this token. The
/// synchronous relay closes the actor-hop race immediately before a MainActor
/// side effect, while `requireCurrent` verifies identity and envelope revision.
struct SessionCurrentToken: Sendable {
    let session: SpeechSession
    private let relay: SessionCancellationRelay
    private let coordinator: SpeechCoordinator
    private let ticket: UInt64
    private let sequencer: CoordinatorCommandSequencer

    fileprivate init(session: SpeechSession, relay: SessionCancellationRelay, coordinator: SpeechCoordinator, ticket: UInt64, sequencer: CoordinatorCommandSequencer) {
        self.session = session
        self.relay = relay
        self.coordinator = coordinator
        self.ticket = ticket
        self.sequencer = sequencer
    }

    var envelope: CredentialEnvelope? { session.envelope }
    var generation: SessionGeneration { session.generation }
    var scopeRevision: UUID? { session.scopeRevision }

    func requireCurrent() async throws {
        try Task.checkCancellation()
        guard sequencer.isLatest(ticket), !relay.isCancelled else { throw CancellationError() }
        try await coordinator.requireCurrent(session)
    }

    func performCurrent<Output: Sendable>(_ body: @MainActor @Sendable () throws -> Output) async throws -> Output {
        try await requireCurrent()
        return try await MainActor.run {
            try sequencer.withLatestPermission(ticket) { try relay.withPermission(body) }
        }
    }

    /// Grants a synchronous, non-suspending commit boundary to an actor-owned
    /// state transition. The command sequencer is always acquired before the
    /// session relay, matching `performCurrent`; callers must not await or call
    /// arbitrary external code from `body`.
    func withCurrentCommitPermission<Output>(_ body: () throws -> Output) throws -> Output {
        try sequencer.withLatestPermission(ticket) {
            try relay.withPermission(body)
        }
    }

    /// Unpublished native/canonical temps are removed synchronously when the
    /// session is cancelled. Publishing code disarms the cleanup only after a
    /// successful commit.
    func registerUnpublishedCleanup(_ cleanup: @escaping @Sendable () -> Void) throws -> UUID {
        try sequencer.withLatestPermission(ticket) {
            guard let id = relay.registerCleanup(cleanup) else { throw CancellationError() }
            return id
        }
    }

    func disarmUnpublishedCleanup(_ id: UUID) throws {
        try sequencer.withLatestPermission(ticket) { try relay.disarmCleanup(id) }
    }

    /// Transfers an artifact to the next pipeline stage and disarms this
    /// session's cleanup in one cancellation linearization point. A later Stop
    /// therefore observes either the session-owned artifact or the transferred
    /// artifact, never a gap between the two states.
    func transferUnpublishedArtifact(
        _ artifact: OwnedAudioArtifact,
        cleanupID: UUID
    ) throws -> UnpublishedArtifact {
        try sequencer.withLatestPermission(ticket) {
            try relay.withPermission {
                let unpublished = try artifact.transferToUnpublished()
                try relay.disarmCleanup(cleanupID)
                return unpublished
            }
        }
    }
}

actor SpeechCoordinator {
    typealias CaptureEnvelope = @Sendable (ProviderID) async throws -> CredentialEnvelope?
    typealias StopPlayer = @Sendable (CoordinatorControlToken) async -> Void
    typealias AdvanceCacheScope = @Sendable (ProviderID, UUID, SessionGeneration) async -> Void
    typealias Work = @Sendable (SessionCurrentToken) async throws -> Void
    typealias Failure = @Sendable (SessionCurrentToken, Error) async -> Void
    typealias StartFailure = @Sendable (CoordinatorControlToken, Error) async -> Void

    struct PreparedSubmission: Sendable {
        let command: SpeechCommand
        let captureEnvelope: CaptureEnvelope
        let stopPlayer: StopPlayer
        let advanceCacheScope: AdvanceCacheScope
        let work: Work
        let onFailure: Failure
        let onStartFailure: StartFailure

        init(
            command: SpeechCommand,
            captureEnvelope: @escaping CaptureEnvelope = { _ in nil },
            stopPlayer: @escaping StopPlayer = { _ in },
            advanceCacheScope: @escaping AdvanceCacheScope = { _, _, _ in },
            work: @escaping Work,
            onFailure: @escaping Failure = { _, _ in },
            onStartFailure: @escaping StartFailure = { _, _ in }
        ) {
            self.command = command
            self.captureEnvelope = captureEnvelope
            self.stopPlayer = stopPlayer
            self.advanceCacheScope = advanceCacheScope
            self.work = work
            self.onFailure = onFailure
            self.onStartFailure = onStartFailure
        }
    }

    private struct Active {
        let session: SpeechSession
        let relay: SessionCancellationRelay
        let stopPlayer: StopPlayer
        var task: Task<Void, Never>?
    }

    private struct Draining {
        let providerID: ProviderID
        let task: Task<Void, Never>
    }

    private struct CacheScopeRegistration {
        let ticket: UInt64
        let sessionGeneration: SessionGeneration?
        let advance: AdvanceCacheScope
    }

    nonisolated private let sequencer = CoordinatorCommandSequencer()
    nonisolated private let pendingStartGate: @Sendable () async -> Void
    private var generation: UInt64 = 0
    private var active: Active?
    private var draining: [SpeechRequestID: Draining] = [:]
    private var cacheScopeRegistrations: [ProviderID: CacheScopeRegistration] = [:]

    init(pendingStartGate: @escaping @Sendable () async -> Void = {}) {
        self.pendingStartGate = pendingStartGate
    }

    nonisolated func pendingLedgerCount() -> Int { sequencer.pendingLedgerCount() }

    /// Synchronous façade used by Engine. The only spawned speech-work task is
    /// installed in `active` below; Engine owns no task or generation counter.
    nonisolated func submit(
        _ command: SpeechCommand,
        captureEnvelope: @escaping CaptureEnvelope = { _ in nil },
        stopPlayer: @escaping StopPlayer = { _ in },
        advanceCacheScope: @escaping AdvanceCacheScope = { _, _, _ in },
        work: @escaping Work,
        onFailure: @escaping Failure = { _, _ in },
        onStartFailure: @escaping StartFailure = { _, _ in }
    ) {
        submit(PreparedSubmission(
            command: command, captureEnvelope: captureEnvelope, stopPlayer: stopPlayer,
            advanceCacheScope: advanceCacheScope, work: work,
            onFailure: onFailure, onStartFailure: onStartFailure
        ))
    }

    nonisolated func submit(_ submission: PreparedSubmission) {
        let command = submission.command
        let pendingStartGate = self.pendingStartGate
        _ = sequencer.submitPending(providerID: command.providerID) { [weak self] ticket in
            await pendingStartGate()
            _ = await self?.startSubmitted(ticket: ticket, submission: submission)
        }
    }

    /// Tracks asynchronous input acquisition in the same provider-addressable
    /// ledger as credential capture and synthesis. A late preparation may finish
    /// for cleanup, but its ticket can never start or mutate a newer session.
    nonisolated func submitInput(
        providerID: ProviderID,
        stopPlayer: @escaping StopPlayer = { _ in },
        advanceCacheScope: @escaping AdvanceCacheScope = { _, _, _ in },
        prepare: @escaping @Sendable (CoordinatorControlToken) async throws -> PreparedSubmission?,
        onPreparationFailure: @escaping StartFailure = { _, _ in }
    ) {
        let pendingStartGate = self.pendingStartGate
        _ = sequencer.submitPending(providerID: providerID) { [weak self] ticket in
            guard let self else { return }
            await pendingStartGate()
            let control = CoordinatorControlToken(ticket: ticket, sequencer: self.sequencer)
            do {
                try await self.prepareInputSubmitted(
                    control: control, providerID: providerID,
                    stopPlayer: stopPlayer, advanceCacheScope: advanceCacheScope
                )
                guard let submission = try await prepare(control) else {
                    return
                }
                try Task.checkCancellation()
                guard submission.command.providerID == providerID, self.sequencer.isLatest(ticket) else {
                    throw CancellationError()
                }
                let trackedSubmission = PreparedSubmission(
                    command: submission.command,
                    captureEnvelope: submission.captureEnvelope,
                    stopPlayer: submission.stopPlayer,
                    advanceCacheScope: advanceCacheScope,
                    work: submission.work,
                    onFailure: submission.onFailure,
                    onStartFailure: submission.onStartFailure
                )
                // `prepareInputSubmitted` already retired the prior active work
                // under this same ticket. The prepared submission is a handoff,
                // not a second start command, so it must not acquire a second
                // player-cleanup lease before installing the session.
                _ = await self.startSubmitted(
                    ticket: ticket, submission: trackedSubmission,
                    cancelActiveBeforeStart: false
                )
            } catch is CancellationError {
                // Scope-affecting commands own cancellation and draining.
            } catch {
                guard self.sequencer.isLatest(ticket) else { return }
                await onPreparationFailure(control, error)
            }
        }
    }

    private func prepareInputSubmitted(
        control: CoordinatorControlToken,
        providerID: ProviderID,
        stopPlayer: @escaping StopPlayer,
        advanceCacheScope: @escaping AdvanceCacheScope
    ) async throws {
        try sequencer.withLatestPermission(control.ticket) {
            registerCacheScope(providerID: providerID, ticket: control.ticket, generation: nil, advance: advanceCacheScope)
        }
        await cancelActive(stopPlayer: stopPlayer, control: control, waitForTasks: false)
        guard sequencer.isLatest(control.ticket) else { throw CancellationError() }
    }

    @discardableResult
    func start(
        _ command: SpeechCommand,
        captureEnvelope: @escaping CaptureEnvelope = { _ in nil },
        stopPlayer: @escaping StopPlayer = { _ in },
        advanceCacheScope: @escaping AdvanceCacheScope = { _, _, _ in },
        work: @escaping Work,
        onFailure: @escaping Failure = { _, _ in },
        onStartFailure: @escaping StartFailure = { _, _ in }
    ) async -> SpeechSession? {
        return await withCheckedContinuation { continuation in
            let pendingStartGate = self.pendingStartGate
            _ = sequencer.submitPending(providerID: command.providerID) { [weak self] ticket in
                guard let self else { continuation.resume(returning: nil); return }
                await pendingStartGate()
                let session = await self.startSubmitted(ticket: ticket, submission: PreparedSubmission(
                    command: command, captureEnvelope: captureEnvelope, stopPlayer: stopPlayer,
                    advanceCacheScope: advanceCacheScope, work: work,
                    onFailure: onFailure, onStartFailure: onStartFailure
                ))
                continuation.resume(returning: session)
            }
        }
    }

    private func startSubmitted(
        ticket: UInt64,
        submission: PreparedSubmission,
        cancelActiveBeforeStart: Bool = true
    ) async -> SpeechSession? {
        let command = submission.command
        do {
            try sequencer.withLatestPermission(ticket) {
                registerCacheScope(providerID: command.providerID, ticket: ticket, generation: nil, advance: submission.advanceCacheScope)
            }
        } catch {
            return nil
        }
        let control = CoordinatorControlToken(ticket: ticket, sequencer: sequencer)
        if cancelActiveBeforeStart {
            await cancelActive(stopPlayer: submission.stopPlayer, control: control, waitForTasks: false)
        }
        guard sequencer.isLatest(ticket) else { return nil }

        let envelope: CredentialEnvelope?
        do {
            envelope = try await submission.captureEnvelope(command.providerID)
            try Task.checkCancellation()
            guard sequencer.isLatest(ticket), envelope?.providerID == command.providerID || envelope == nil else {
                throw CancellationError()
            }
        } catch is CancellationError {
            return nil
        } catch {
            guard sequencer.isLatest(ticket) else { return nil }
            await submission.onStartFailure(control, error)
            return nil
        }

        generation &+= 1
        let session = SpeechSession(
            sessionID: SpeechRequestID(rawValue: UUID()),
            generation: SessionGeneration(rawValue: generation),
            purpose: command.purpose,
            providerID: command.providerID,
            envelope: envelope,
            scopeRevision: envelope?.revision ?? command.credentiallessScopeRevision
        )
        let relay = SessionCancellationRelay()
        do {
            try sequencer.withLatestPermission(ticket) {
                active = Active(session: session, relay: relay, stopPlayer: submission.stopPlayer, task: nil)
                registerCacheScope(
                    providerID: session.providerID, ticket: ticket,
                    generation: session.generation, advance: submission.advanceCacheScope
                )
            }
        } catch {
            relay.cancel()
            return nil
        }
        let token = SessionCurrentToken(session: session, relay: relay, coordinator: self, ticket: ticket, sequencer: sequencer)

        if let revision = session.scopeRevision {
            await submission.advanceCacheScope(session.providerID, revision, session.generation)
            guard (try? await token.requireCurrent()) != nil else { return nil }
        }

        let task = Task { [weak self] in
            do {
                try await token.requireCurrent()
                try await submission.work(token)
                relay.cleanupUnpublished()
            } catch is CancellationError {
                // Cancellation is intentionally silent. `cancelActive` owns the
                // player stop and waits for this task to become quiescent.
                relay.cancel()
            } catch {
                relay.cleanupUnpublished()
                guard (try? await token.requireCurrent()) != nil else {
                    await self?.finish(session)
                    self?.sequencer.completeActive(ticket: ticket)
                    return
                }
                await submission.onFailure(token, error)
            }
            await self?.finish(session)
            self?.sequencer.completeActive(ticket: ticket)
        }
        guard var current = active,
              current.session.sessionID == session.sessionID,
              current.session.generation == session.generation else {
            relay.cancel()
            task.cancel()
            return nil
        }
        current.task = task
        active = current
        sequencer.installActive(ticket: ticket, providerID: session.providerID, relay: relay, task: task)
        return session
    }

    private func registerCacheScope(
        providerID: ProviderID,
        ticket: UInt64,
        generation: SessionGeneration?,
        advance: @escaping AdvanceCacheScope
    ) {
        if let existing = cacheScopeRegistrations[providerID] {
            guard ticket >= existing.ticket else { return }
            if ticket == existing.ticket, generation == nil, existing.sessionGeneration != nil { return }
        }
        cacheScopeRegistrations[providerID] = CacheScopeRegistration(
            ticket: ticket, sessionGeneration: generation, advance: advance
        )
    }

    private func invalidateCacheScopes(_ providerIDs: Set<ProviderID>) async {
        for providerID in providerIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let registration = cacheScopeRegistrations[providerID] else { continue }
            let registeredGeneration = registration.sessionGeneration?.rawValue ?? 0
            generation = max(generation, registeredGeneration) &+ 1
            let invalidationGeneration = SessionGeneration(rawValue: generation)
            await registration.advance(providerID, UUID(), invalidationGeneration)
            if cacheScopeRegistrations[providerID]?.ticket == registration.ticket {
                cacheScopeRegistrations[providerID] = CacheScopeRegistration(
                    ticket: registration.ticket,
                    sessionGeneration: invalidationGeneration,
                    advance: registration.advance
                )
            }
        }
    }

    private func finish(_ session: SpeechSession) {
        draining[session.sessionID] = nil
        guard var current = active,
              current.session.sessionID == session.sessionID,
              current.session.generation == session.generation else { return }
        current.task = nil
        active = current
    }

    private func cancelActive(stopPlayer: @escaping StopPlayer, control: CoordinatorControlToken, waitForTasks: Bool) async {
        let old = active
        active = nil
        old?.relay.cancel()
        old?.task?.cancel()
        if !waitForTasks, let old, let task = old.task {
            draining[old.session.sessionID] = Draining(providerID: old.session.providerID, task: task)
        }
        var invalidated = Set(old.map { [$0.session.providerID] } ?? [])
        if waitForTasks { invalidated.formUnion(draining.values.map(\.providerID)) }
        await invalidateCacheScopes(invalidated)
        await (old?.stopPlayer ?? stopPlayer)(control)
        if waitForTasks {
            var tasks = Array(draining.values.map(\.task))
            draining.removeAll()
            if let task = old?.task { tasks.append(task) }
            for task in tasks { await task.value }
        }
    }

    private func stopSubmitted(ticket: UInt64, affectedProviders: Set<ProviderID>, stopPlayer: @escaping StopPlayer) async {
        guard sequencer.isLatest(ticket) else { return }
        var activeProviders = Set(draining.values.map(\.providerID))
        if let providerID = active?.session.providerID { activeProviders.insert(providerID) }
        await cancelActive(stopPlayer: stopPlayer, control: CoordinatorControlToken(ticket: ticket, sequencer: sequencer), waitForTasks: true)
        await invalidateCacheScopes(affectedProviders.subtracting(activeProviders))
        for task in sequencer.takeRetired() { await task.value }
    }

    @discardableResult
    nonisolated func requestStop(reason: CancellationReason, stopPlayer: @escaping StopPlayer = { _ in }) -> CoordinatorControlToken {
        _ = reason
        let issued = sequencer.issueWithAffectedProviders(providerID: nil)
        Task { await self.stopSubmitted(ticket: issued.ticket, affectedProviders: issued.affectedProviders, stopPlayer: stopPlayer) }
        return CoordinatorControlToken(ticket: issued.ticket, sequencer: sequencer)
    }

    func stop(reason: CancellationReason = .userStopped, stopPlayer: @escaping StopPlayer = { _ in }) async {
        _ = reason
        let issued = sequencer.issueWithAffectedProviders(providerID: nil)
        await stopSubmitted(ticket: issued.ticket, affectedProviders: issued.affectedProviders, stopPlayer: stopPlayer)
    }

    func selectionDidChange(providerID: ProviderID? = nil, stopPlayer: @escaping StopPlayer = { _ in }) async {
        if let providerID, !sequencer.latestProviderIs(providerID), active?.session.providerID != providerID { return }
        let issued = sequencer.issueWithAffectedProviders(providerID: nil)
        let affectedProviders = providerID.map { issued.affectedProviders.union([$0]) } ?? issued.affectedProviders
        await stopSubmitted(ticket: issued.ticket, affectedProviders: affectedProviders, stopPlayer: stopPlayer)
    }

    nonisolated func requestSelectionChange(providerID: ProviderID? = nil, stopPlayer: @escaping StopPlayer = { _ in }) {
        let issued = sequencer.issueWithAffectedProviders(providerID: nil)
        let affectedProviders = providerID.map { issued.affectedProviders.union([$0]) } ?? issued.affectedProviders
        Task { await self.stopSubmitted(ticket: issued.ticket, affectedProviders: affectedProviders, stopPlayer: stopPlayer) }
    }

    func defaultProviderDidChange(stopPlayer: @escaping StopPlayer = { _ in }) async {
        let issued = sequencer.issueWithAffectedProviders(providerID: nil)
        await stopSubmitted(ticket: issued.ticket, affectedProviders: issued.affectedProviders, stopPlayer: stopPlayer)
    }

    func credentialWillChange(providerID: ProviderID, stopPlayer: @escaping StopPlayer = { _ in }) async {
        guard sequencer.hasWork(providerID: providerID) || active?.session.providerID == providerID
                || draining.values.contains(where: { $0.providerID == providerID }) else { return }
        let invalidatesLatest = sequencer.latestProviderIs(providerID)
        let control: CoordinatorControlToken
        var matchingActiveTask: Task<Void, Never>?
        if invalidatesLatest {
            let ticket = sequencer.issue(providerID: nil)
            guard sequencer.isLatest(ticket) else { return }
            control = CoordinatorControlToken(ticket: ticket, sequencer: sequencer)
        } else {
            // A newer provider remains current. Cancel and drain only the older
            // provider's pending/retired work without advancing the global ticket.
            sequencer.cancelProviderTasks(providerID)
            control = CoordinatorControlToken(ticket: sequencer.latestTicket(), sequencer: sequencer)
        }
        if let current = active, current.session.providerID == providerID {
            active = nil
            current.relay.cancel()
            current.task?.cancel()
            matchingActiveTask = current.task
        }
        await invalidateCacheScopes([providerID])
        if invalidatesLatest || matchingActiveTask != nil { await stopPlayer(control) }
        if let matchingActiveTask { await matchingActiveTask.value }

        let matching = draining.filter { $0.value.providerID == providerID }
        for id in matching.keys { draining[id] = nil }
        for value in matching.values { await value.task.value }
        for task in sequencer.takeRetired(providerID: providerID) { await task.value }
    }

    func shutdown(stopPlayer: @escaping StopPlayer = { _ in }) async {
        let issued = sequencer.issueWithAffectedProviders(providerID: nil)
        await stopSubmitted(ticket: issued.ticket, affectedProviders: issued.affectedProviders, stopPlayer: stopPlayer)
    }

    func isCurrent(_ session: SpeechSession) -> Bool {
        guard let current = active?.session else { return false }
        return current.sessionID == session.sessionID && current.generation == session.generation
            && current.envelope?.revision == session.envelope?.revision
    }

    func requireCurrent(_ session: SpeechSession) throws {
        try Task.checkCancellation()
        guard isCurrent(session) else { throw CancellationError() }
    }

    /// Task 16 adapters use this helper so retry encloses only provider
    /// synthesis. Canonicalization, decoding and playback necessarily happen
    /// after it returns and can never trigger another synthesis attempt.
    func synthesizeWithRetry<Output: Sendable>(
        token: SessionCurrentToken,
        contract: RetryContract,
        sleep: @escaping @Sendable (Int) async throws -> Void = { milliseconds in
            guard milliseconds > 0 else { try Task.checkCancellation(); return }
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        },
        attempt: @escaping @Sendable (Int) async throws -> RetryAttempt<Output>
    ) async throws -> Output {
        try await RetryPolicy.execute(contract: contract, sleep: { milliseconds in
            try await token.requireCurrent()
            try await sleep(milliseconds)
            try await token.requireCurrent()
        }, attempt: { number in
            try await token.requireCurrent()
            let result = try await attempt(number)
            try await token.requireCurrent()
            return result
        })
    }
}

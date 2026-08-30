import Foundation

private struct CatalogPagerTimeout: Error {}
enum CatalogPagerRaceEvent: Equatable, Sendable {
    case fetchWon
    case timeoutWon
    case parentCancellationWon
    case deadlineCancelled
    case fetchCancelled
}

private enum PagerRaceWinner {
    case fetch
    case timeout
    case parentCancellation
}

private final class PagerRaceState<Value>: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Value, Error>

    private let lock = NSLock()
    private let observer: (@Sendable (CatalogPagerRaceEvent) -> Void)?
    private var continuation: Continuation?
    private var pendingResult: Result<Value, Error>?
    private var winner: PagerRaceWinner?
    private var fetchTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(observer: (@Sendable (CatalogPagerRaceEvent) -> Void)?) {
        self.observer = observer
    }

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return winner != nil
    }

    func installContinuation(_ continuation: Continuation) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func installFetchTask(_ task: Task<Void, Never>) {
        lock.lock()
        if winner == nil {
            fetchTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    func installDeadlineTask(_ task: Task<Void, Never>) {
        lock.lock()
        if winner == nil {
            deadlineTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    func resolve(_ result: Result<Value, Error>, winner newWinner: PagerRaceWinner) {
        let continuation: Continuation?
        let fetchTask: Task<Void, Never>?
        let deadlineTask: Task<Void, Never>?

        lock.lock()
        guard winner == nil else {
            lock.unlock()
            return
        }
        winner = newWinner
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        fetchTask = self.fetchTask
        deadlineTask = self.deadlineTask
        self.fetchTask = nil
        self.deadlineTask = nil
        lock.unlock()

        switch newWinner {
        case .fetch:
            observer?(.fetchWon)
            observer?(.deadlineCancelled)
            deadlineTask?.cancel()
        case .timeout:
            observer?(.timeoutWon)
            observer?(.fetchCancelled)
            fetchTask?.cancel()
        case .parentCancellation:
            observer?(.parentCancellationWon)
            observer?(.fetchCancelled)
            observer?(.deadlineCancelled)
            fetchTask?.cancel()
            deadlineTask?.cancel()
        }
        continuation?.resume(with: result)
    }
}

enum CatalogDimension: String, Codable, Hashable, Sendable { case model, voice, controls }
enum EvidenceCoverage: String, Codable, Hashable, Sendable { case authoritativeComplete, partial, unknown }

struct AccountResourceKey: Codable, Hashable, Sendable { let dimension: CatalogDimension; let parentModelID: ModelID? }

struct AccountResourceEvidence<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    let scopeRevision: UUID; let contractVersion: ContractVersion; let fetchedAt: Date; let refreshID: CatalogRefreshID; let authoritySource: String; let coverage: EvidenceCoverage; let values: Set<Value>
    func stale() -> Self { Self(scopeRevision: scopeRevision, contractVersion: contractVersion, fetchedAt: fetchedAt, refreshID: refreshID, authoritySource: authoritySource, coverage: .unknown, values: values) }
}

struct CatalogControlsID: RawRepresentable, Codable, Hashable, Sendable { let rawValue: String }
struct CatalogControlsVersion: RawRepresentable, Codable, Hashable, Sendable { let rawValue: String }

enum RelationshipScopeError: Error, Equatable, Sendable { case emptyControlsSchema, emptyQueryKey, duplicateQueryKey }

struct RelationshipScope: Codable, Hashable, Sendable {
    let providerID: ProviderID; let credentialRevision: UUID; let contractVersion: ContractVersion; let parentModelID: ModelID?; let controlsSchema: String; let queryParameters: [String: String]

    init(providerID: ProviderID, credentialRevision: UUID, contractVersion: ContractVersion, parentModelID: ModelID?, controlsSchema: String, queryParameters: [String: String]) throws {
        let schema = controlsSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !schema.isEmpty else { throw RelationshipScopeError.emptyControlsSchema }
        var canonical: [String: String] = [:]
        for (key, value) in queryParameters {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty else { throw RelationshipScopeError.emptyQueryKey }
            guard canonical[normalizedKey] == nil else { throw RelationshipScopeError.duplicateQueryKey }
            canonical[normalizedKey] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.providerID = providerID; self.credentialRevision = credentialRevision; self.contractVersion = contractVersion; self.parentModelID = parentModelID; self.controlsSchema = schema; self.queryParameters = canonical
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(providerID: c.decode(ProviderID.self, forKey: .providerID), credentialRevision: c.decode(UUID.self, forKey: .credentialRevision), contractVersion: c.decode(ContractVersion.self, forKey: .contractVersion), parentModelID: c.decodeIfPresent(ModelID.self, forKey: .parentModelID), controlsSchema: c.decode(String.self, forKey: .controlsSchema), queryParameters: c.decode([String: String].self, forKey: .queryParameters))
    }

    func withoutParentModel() -> RelationshipScope { try! RelationshipScope(providerID: providerID, credentialRevision: credentialRevision, contractVersion: contractVersion, parentModelID: nil, controlsSchema: controlsSchema, queryParameters: queryParameters) }
}

struct AccountRelationshipTuple: Codable, Hashable, Sendable { let modelID: ModelID; let voiceID: VoiceID; let controlsID: CatalogControlsID?; let controlsVersion: CatalogControlsVersion? }
struct StructuredSynthesisRejection: Codable, Hashable, Sendable { let scopeRevision: UUID; let tuple: AccountRelationshipTuple; let sessionGeneration: SessionGeneration; let reason: String }

struct AccountRelationshipEvidence: Codable, Hashable, Sendable {
    let scope: RelationshipScope; let scopeRevision: UUID; let contractVersion: ContractVersion; let fetchedAt: Date; let refreshID: CatalogRefreshID; let authoritySource: String; let coverage: EvidenceCoverage; let paginationComplete: Bool; let values: Set<AccountRelationshipTuple>; let rejections: Set<StructuredSynthesisRejection>
    func stale() -> Self { Self(scope: scope, scopeRevision: scopeRevision, contractVersion: contractVersion, fetchedAt: fetchedAt, refreshID: refreshID, authoritySource: authoritySource, coverage: .unknown, paginationComplete: false, values: values, rejections: rejections) }
}

struct ContractOwnedResources: Codable, Hashable, Sendable {
    let builtInVoices: Set<VoiceID>; let builtInControls: Set<CatalogControlsID>
    static let none = Self(builtInVoices: [], builtInControls: [])
}

struct AccountCatalogSnapshot: Codable, Hashable, Sendable {
    let modelEvidence: [RelationshipScope: [AccountResourceKey: AccountResourceEvidence<ModelID>]]; let voiceEvidence: [RelationshipScope: [AccountResourceKey: AccountResourceEvidence<VoiceID>]]; let controlsEvidence: [RelationshipScope: [AccountResourceKey: AccountResourceEvidence<CatalogControlsID>]]; let relationshipEvidence: [RelationshipScope: AccountRelationshipEvidence]; let synthesisRejections: [RelationshipScope: Set<StructuredSynthesisRejection>]
    init(modelEvidence: [RelationshipScope: [AccountResourceKey: AccountResourceEvidence<ModelID>]] = [:], voiceEvidence: [RelationshipScope: [AccountResourceKey: AccountResourceEvidence<VoiceID>]] = [:], controlsEvidence: [RelationshipScope: [AccountResourceKey: AccountResourceEvidence<CatalogControlsID>]] = [:], relationshipEvidence: [RelationshipScope: AccountRelationshipEvidence] = [:], synthesisRejections: [RelationshipScope: Set<StructuredSynthesisRejection>] = [:]) { self.modelEvidence = modelEvidence; self.voiceEvidence = voiceEvidence; self.controlsEvidence = controlsEvidence; self.relationshipEvidence = relationshipEvidence; self.synthesisRejections = synthesisRejections }
    static let empty = AccountCatalogSnapshot()
}

struct CatalogPage<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    let scope: RelationshipScope; let refreshID: CatalogRefreshID; let coverage: EvidenceCoverage; let paginationComplete: Bool; let values: Set<Value>; let nextToken: String?
    init<S: Sequence>(scope: RelationshipScope, refreshID: CatalogRefreshID, coverage: EvidenceCoverage, paginationComplete: Bool, values: S, nextToken: String?) where S.Element == Value { self.scope = scope; self.refreshID = refreshID; self.coverage = coverage; self.paginationComplete = paginationComplete; self.values = Set(values); self.nextToken = nextToken }
}

struct CatalogPaginationLimits: Codable, Hashable, Sendable { let maxPages: Int; let maxItems: Int; let timeout: TimeInterval }

actor CatalogPager {
    private enum RefreshTarget: Hashable { case models(RelationshipScope), voices(RelationshipScope), controls(RelationshipScope), relationships(RelationshipScope) }
    private struct Operation: Hashable { let refreshID: CatalogRefreshID; let nonce = UUID() }
    private var snapshot: AccountCatalogSnapshot; private let limits: CatalogPaginationLimits; private let raceObserver: (@Sendable (CatalogPagerRaceEvent) -> Void)?; private var active: [RefreshTarget: Operation] = [:]
    init(initialSnapshot: AccountCatalogSnapshot, limits: CatalogPaginationLimits, raceObserver: (@Sendable (CatalogPagerRaceEvent) -> Void)? = nil) { self.snapshot = initialSnapshot; self.limits = limits; self.raceObserver = raceObserver }
    func currentSnapshot() -> AccountCatalogSnapshot { snapshot }

    func refreshModels(scope: RelationshipScope, refreshID: CatalogRefreshID, authoritySource: String, fetchPage: @escaping @Sendable (String?) async throws -> CatalogPage<ModelID>) async -> AccountCatalogSnapshot { await refreshResources(scope: scope, refreshID: refreshID, authoritySource: authoritySource, dimension: .model, target: .models(scope), fetchPage: fetchPage) }
    func refreshVoices(scope: RelationshipScope, refreshID: CatalogRefreshID, authoritySource: String, fetchPage: @escaping @Sendable (String?) async throws -> CatalogPage<VoiceID>) async -> AccountCatalogSnapshot { await refreshResources(scope: scope, refreshID: refreshID, authoritySource: authoritySource, dimension: .voice, target: .voices(scope), fetchPage: fetchPage) }
    func refreshControls(scope: RelationshipScope, refreshID: CatalogRefreshID, authoritySource: String, fetchPage: @escaping @Sendable (String?) async throws -> CatalogPage<CatalogControlsID>) async -> AccountCatalogSnapshot { await refreshResources(scope: scope, refreshID: refreshID, authoritySource: authoritySource, dimension: .controls, target: .controls(scope), fetchPage: fetchPage) }

    func refreshRelationships(scope: RelationshipScope, refreshID: CatalogRefreshID, authoritySource: String, fetchPage: @escaping @Sendable (String?) async throws -> CatalogPage<AccountRelationshipTuple>) async -> AccountCatalogSnapshot {
        let target = RefreshTarget.relationships(scope), operation = begin(target: target, refreshID: refreshID); defer { finish(target: target, operation: operation) }
        var values = Set<AccountRelationshipTuple>(), tokens = Set<String>(), token: String?, pages = 0
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(limits.timeout))
        while true {
            guard current(target, operation), !Task.isCancelled, clock.now <= deadline, pages < limits.maxPages else { return staleRelationship(scope, target, operation) }
            do {
                let page = try await fetchWithDeadline(token, deadline: deadline, clock: clock, fetchPage)
                guard current(target, operation), !Task.isCancelled, clock.now <= deadline, valid(page, scope, refreshID) else { return staleRelationship(scope, target, operation) }
                pages += 1; values.formUnion(page.values); guard values.count <= limits.maxItems else { return staleRelationship(scope, target, operation) }
                if page.nextToken == nil { guard page.coverage == .authoritativeComplete, page.paginationComplete else { return staleRelationship(scope, target, operation) }; return publishRelationship(scope, refreshID, authoritySource, values, target, operation) }
                guard page.coverage == .partial, !page.paginationComplete, let next = page.nextToken, !next.isEmpty, next != token, tokens.insert(next).inserted else { return staleRelationship(scope, target, operation) }; token = next
            } catch { return staleRelationship(scope, target, operation) }
        }
    }

    private func refreshResources<Value: Codable & Hashable & Sendable>(scope: RelationshipScope, refreshID: CatalogRefreshID, authoritySource: String, dimension: CatalogDimension, target: RefreshTarget, fetchPage: @escaping @Sendable (String?) async throws -> CatalogPage<Value>) async -> AccountCatalogSnapshot {
        let operation = begin(target: target, refreshID: refreshID); defer { finish(target: target, operation: operation) }
        var values = Set<Value>(), tokens = Set<String>(), token: String?, pages = 0
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(limits.timeout))
        while true {
            guard current(target, operation), !Task.isCancelled, clock.now <= deadline, pages < limits.maxPages else { return staleResource(scope, dimension, target, operation, Value.self) }
            do {
                let page = try await fetchWithDeadline(token, deadline: deadline, clock: clock, fetchPage)
                guard current(target, operation), !Task.isCancelled, clock.now <= deadline, valid(page, scope, refreshID) else { return staleResource(scope, dimension, target, operation, Value.self) }
                pages += 1; values.formUnion(page.values); guard values.count <= limits.maxItems else { return staleResource(scope, dimension, target, operation, Value.self) }
                if page.nextToken == nil { guard page.coverage == .authoritativeComplete, page.paginationComplete else { return staleResource(scope, dimension, target, operation, Value.self) }; return publishResource(scope, refreshID, authoritySource, dimension, target, operation, values) }
                guard page.coverage == .partial, !page.paginationComplete, let next = page.nextToken, !next.isEmpty, next != token, tokens.insert(next).inserted else { return staleResource(scope, dimension, target, operation, Value.self) }; token = next
            } catch { return staleResource(scope, dimension, target, operation, Value.self) }
        }
    }

    private func begin(target: RefreshTarget, refreshID: CatalogRefreshID) -> Operation { let op = Operation(refreshID: refreshID); active[target] = op; return op }
    private func current(_ target: RefreshTarget, _ operation: Operation) -> Bool { active[target] == operation }
    private func finish(target: RefreshTarget, operation: Operation) { guard active[target] == operation else { return }; active[target] = nil }
    private func fetchWithDeadline<Value>(_ token: String?, deadline: ContinuousClock.Instant, clock: ContinuousClock, _ fetch: @escaping @Sendable (String?) async throws -> CatalogPage<Value>) async throws -> CatalogPage<Value> where Value: Codable & Hashable & Sendable {
        let remaining = deadline - clock.now
        guard remaining > .zero else {
            raceObserver?(.timeoutWon)
            throw CatalogPagerTimeout()
        }

        let state = PagerRaceState<CatalogPage<Value>>(observer: raceObserver)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.installContinuation(continuation)
                guard !state.isResolved else { return }

                let fetchTask = Task.detached {
                    do {
                        state.resolve(.success(try await fetch(token)), winner: .fetch)
                    } catch {
                        state.resolve(.failure(error), winner: .fetch)
                    }
                }
                state.installFetchTask(fetchTask)
                guard !state.isResolved else { return }

                let deadlineTask = Task.detached {
                    do {
                        try await clock.sleep(until: deadline)
                        state.resolve(.failure(CatalogPagerTimeout()), winner: .timeout)
                    } catch {
                        // Cancellation means fetch or parent cancellation already won.
                    }
                }
                state.installDeadlineTask(deadlineTask)
            }
        }, onCancel: {
            state.resolve(.failure(CancellationError()), winner: .parentCancellation)
        })
    }
    private func valid<Value>(_ page: CatalogPage<Value>, _ scope: RelationshipScope, _ refreshID: CatalogRefreshID) -> Bool { page.scope == scope && page.refreshID == refreshID && page.coverage != .unknown }

    private func publishRelationship(_ scope: RelationshipScope, _ refreshID: CatalogRefreshID, _ source: String, _ values: Set<AccountRelationshipTuple>, _ target: RefreshTarget, _ operation: Operation) -> AccountCatalogSnapshot {
        guard current(target, operation) else { return snapshot }; var relationships = snapshot.relationshipEvidence; let retained = snapshot.synthesisRejections[scope] ?? relationships[scope]?.rejections ?? []
        relationships[scope] = AccountRelationshipEvidence(scope: scope, scopeRevision: scope.credentialRevision, contractVersion: scope.contractVersion, fetchedAt: Date(), refreshID: refreshID, authoritySource: source, coverage: .authoritativeComplete, paginationComplete: true, values: values, rejections: retained)
        snapshot = AccountCatalogSnapshot(modelEvidence: snapshot.modelEvidence, voiceEvidence: snapshot.voiceEvidence, controlsEvidence: snapshot.controlsEvidence, relationshipEvidence: relationships, synthesisRejections: snapshot.synthesisRejections); return snapshot
    }
    private func staleRelationship(_ scope: RelationshipScope, _ target: RefreshTarget, _ operation: Operation) -> AccountCatalogSnapshot { guard current(target, operation), let previous = snapshot.relationshipEvidence[scope] else { return snapshot }; var relationships = snapshot.relationshipEvidence; relationships[scope] = previous.stale(); snapshot = AccountCatalogSnapshot(modelEvidence: snapshot.modelEvidence, voiceEvidence: snapshot.voiceEvidence, controlsEvidence: snapshot.controlsEvidence, relationshipEvidence: relationships, synthesisRejections: snapshot.synthesisRejections); return snapshot }
    private func publishResource<Value: Codable & Hashable & Sendable>(_ scope: RelationshipScope, _ refreshID: CatalogRefreshID, _ source: String, _ dimension: CatalogDimension, _ target: RefreshTarget, _ operation: Operation, _ values: Set<Value>) -> AccountCatalogSnapshot {
        guard current(target, operation) else { return snapshot }; let key = AccountResourceKey(dimension: dimension, parentModelID: scope.parentModelID); let evidence = AccountResourceEvidence(scopeRevision: scope.credentialRevision, contractVersion: scope.contractVersion, fetchedAt: Date(), refreshID: refreshID, authoritySource: source, coverage: .authoritativeComplete, values: values)
        if let v = evidence as? AccountResourceEvidence<ModelID> { var all = snapshot.modelEvidence, one = all[scope] ?? [:]; one[key] = v; all[scope] = one; snapshot = AccountCatalogSnapshot(modelEvidence: all, voiceEvidence: snapshot.voiceEvidence, controlsEvidence: snapshot.controlsEvidence, relationshipEvidence: snapshot.relationshipEvidence, synthesisRejections: snapshot.synthesisRejections) }
        else if let v = evidence as? AccountResourceEvidence<VoiceID> { var all = snapshot.voiceEvidence, one = all[scope] ?? [:]; one[key] = v; all[scope] = one; snapshot = AccountCatalogSnapshot(modelEvidence: snapshot.modelEvidence, voiceEvidence: all, controlsEvidence: snapshot.controlsEvidence, relationshipEvidence: snapshot.relationshipEvidence, synthesisRejections: snapshot.synthesisRejections) }
        else if let v = evidence as? AccountResourceEvidence<CatalogControlsID> { var all = snapshot.controlsEvidence, one = all[scope] ?? [:]; one[key] = v; all[scope] = one; snapshot = AccountCatalogSnapshot(modelEvidence: snapshot.modelEvidence, voiceEvidence: snapshot.voiceEvidence, controlsEvidence: all, relationshipEvidence: snapshot.relationshipEvidence, synthesisRejections: snapshot.synthesisRejections) }; return snapshot
    }
    private func staleResource<Value>(_ scope: RelationshipScope, _ dimension: CatalogDimension, _ target: RefreshTarget, _ operation: Operation, _ type: Value.Type) -> AccountCatalogSnapshot { guard current(target, operation) else { return snapshot }; let key = AccountResourceKey(dimension: dimension, parentModelID: scope.parentModelID)
        if Value.self == ModelID.self, let old = snapshot.modelEvidence[scope]?[key] { var all = snapshot.modelEvidence, one = all[scope] ?? [:]; one[key] = old.stale(); all[scope] = one; snapshot = AccountCatalogSnapshot(modelEvidence: all, voiceEvidence: snapshot.voiceEvidence, controlsEvidence: snapshot.controlsEvidence, relationshipEvidence: snapshot.relationshipEvidence, synthesisRejections: snapshot.synthesisRejections) }
        else if Value.self == VoiceID.self, let old = snapshot.voiceEvidence[scope]?[key] { var all = snapshot.voiceEvidence, one = all[scope] ?? [:]; one[key] = old.stale(); all[scope] = one; snapshot = AccountCatalogSnapshot(modelEvidence: snapshot.modelEvidence, voiceEvidence: all, controlsEvidence: snapshot.controlsEvidence, relationshipEvidence: snapshot.relationshipEvidence, synthesisRejections: snapshot.synthesisRejections) }
        else if Value.self == CatalogControlsID.self, let old = snapshot.controlsEvidence[scope]?[key] { var all = snapshot.controlsEvidence, one = all[scope] ?? [:]; one[key] = old.stale(); all[scope] = one; snapshot = AccountCatalogSnapshot(modelEvidence: snapshot.modelEvidence, voiceEvidence: snapshot.voiceEvidence, controlsEvidence: all, relationshipEvidence: snapshot.relationshipEvidence, synthesisRejections: snapshot.synthesisRejections) }; return snapshot }
}

enum AccountSelectionValidator {
    static func validateModel(_ model: ModelID, in snapshot: AccountCatalogSnapshot, scope: RelationshipScope, currentRevision: UUID, currentRefreshID: CatalogRefreshID) -> SelectionValidation { resource(model, snapshot.modelEvidence[scope]?[AccountResourceKey(dimension: .model, parentModelID: scope.parentModelID)], scope, currentRevision, currentRefreshID) }
    static func validateVoice(_ voice: VoiceID, in snapshot: AccountCatalogSnapshot, scope: RelationshipScope, currentRevision: UUID, currentRefreshID: CatalogRefreshID, contractOwned: ContractOwnedResources) -> SelectionValidation { contractOwned.builtInVoices.contains(voice) ? .unknown : resource(voice, snapshot.voiceEvidence[scope]?[AccountResourceKey(dimension: .voice, parentModelID: scope.parentModelID)], scope, currentRevision, currentRefreshID) }
    static func validate(model: ModelID, voice: VoiceID, in snapshot: AccountCatalogSnapshot, scope: RelationshipScope, currentRevision: UUID, currentRefreshID: CatalogRefreshID, currentSessionGeneration: SessionGeneration? = nil, controlsID: CatalogControlsID? = nil, controlsVersion: CatalogControlsVersion? = nil, contractOwned: ContractOwnedResources) -> SelectionValidation {
        let tuple = AccountRelationshipTuple(modelID: model, voiceID: voice, controlsID: controlsID, controlsVersion: controlsVersion)
        guard scope.credentialRevision == currentRevision else { return .unknown }
        if let generation = currentSessionGeneration, snapshot.synthesisRejections[scope]?.contains(where: { $0.scopeRevision == currentRevision && $0.tuple == tuple && $0.sessionGeneration == generation }) == true { return .invalid }
        guard scope.credentialRevision == currentRevision, let evidence = snapshot.relationshipEvidence[scope], evidence.scope == scope, evidence.scopeRevision == currentRevision, evidence.contractVersion == scope.contractVersion else { return .unknown }
        let rejections = (snapshot.synthesisRejections[scope] ?? []).union(evidence.rejections)
        if let g = currentSessionGeneration, rejections.contains(where: { $0.scopeRevision == currentRevision && $0.tuple == tuple && $0.sessionGeneration == g }) { return .invalid }
        if contractOwned.builtInVoices.contains(voice) || (controlsID.map(contractOwned.builtInControls.contains) ?? false) { return .unknown }
        guard evidence.refreshID == currentRefreshID, evidence.coverage == .authoritativeComplete, evidence.paginationComplete else { return .unknown }; return evidence.values.contains(tuple) ? .valid : .invalid
    }
    private static func resource<Value: Hashable & Sendable>(_ value: Value, _ evidence: AccountResourceEvidence<Value>?, _ scope: RelationshipScope, _ revision: UUID, _ refresh: CatalogRefreshID) -> SelectionValidation { guard scope.credentialRevision == revision, let evidence, evidence.scopeRevision == revision, evidence.contractVersion == scope.contractVersion, evidence.refreshID == refresh, evidence.coverage == .authoritativeComplete else { return .unknown }; return evidence.values.contains(value) ? .valid : .invalid }
}

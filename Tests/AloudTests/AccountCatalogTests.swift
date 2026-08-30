import XCTest
@testable import Aloud

final class AccountCatalogTests: XCTestCase {
    private let provider = ProviderID(rawValue: "test-provider")
    private let revisionA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let revisionB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let contract = ContractVersion(rawValue: "contract-v1")
    private let refreshA = CatalogRefreshID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
    private let refreshB = CatalogRefreshID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
    private let generationA = SessionGeneration(rawValue: 4)

    func testSeparateCompleteDimensionsDoNotProveRelationshipInvalid() {
        let scope = makeScope(revision: revisionA, parent: "m1")
        let snapshot = AccountCatalogFixture.snapshot(
            scope: scope,
            models: .complete(["m1"], refreshID: refreshA),
            voices: .complete(["v1"], refreshID: refreshA)
        )

        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
    }

    func testCurrentCompleteRelationshipAbsenceIsInvalid() {
        let scope = makeScope(revision: revisionA, parent: "m1")
        let snapshot = AccountCatalogFixture.completeRelationships(values: [], scope: scope, refreshID: refreshA)

        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .invalid)
    }

    func testModelsOnlyAndVoicesOnlyCompleteCanOnlyInvalidateTheirOwnMember() {
        let scope = makeScope(revision: revisionA, parent: nil)
        let models = AccountCatalogFixture.snapshot(scope: scope, models: .complete(["m1"], refreshID: refreshA))
        let voices = AccountCatalogFixture.snapshot(scope: scope, voices: .complete(["v1"], refreshID: refreshA))

        XCTAssertEqual(AccountSelectionValidator.validateModel(ModelID(rawValue: "missing"), in: models, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA), .invalid)
        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: models, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
        XCTAssertEqual(AccountSelectionValidator.validateVoice(VoiceID(rawValue: "missing"), in: voices, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .invalid)
    }

    func testBuiltInControlsAndInactiveCloneDoNotCreateAccountInvalidation() {
        let scope = makeScope(revision: revisionA, parent: "m1")
        let snapshot = AccountCatalogFixture.snapshot(scope: scope)

        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "built-in"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "clone-inactive"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
    }

    func testEmptyNonEnumeratingResponseIsUnknownRatherThanInvalid() {
        let scope = makeScope(revision: revisionA, parent: "m1")
        let snapshot = AccountCatalogFixture.snapshot(scope: scope, relationships: .unknown([], refreshID: refreshA, paginationComplete: false, rejections: []))

        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
    }

    func testPartialStaleAndCredentialMismatchEvidenceIsUnknown() {
        let scopeA = makeScope(revision: revisionA, parent: "m1")
        let partial = AccountCatalogFixture.snapshot(scope: scopeA, relationships: .partial([], refreshID: refreshA))
        let stale = AccountCatalogFixture.snapshot(scope: scopeA, relationships: .unknown([], refreshID: refreshA, paginationComplete: false, rejections: []))

        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: partial, scope: scopeA, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: stale, scope: scopeA, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: AccountCatalogFixture.completeRelationships(values: [], scope: scopeA, refreshID: refreshA), scope: makeScope(revision: revisionB, parent: "m1"), currentRevision: revisionB, currentRefreshID: refreshA, contractOwned: .none), .unknown)
    }

    func testParentScopeAndOldRefreshCannotInvalidate() {
        let parentM1 = makeScope(revision: revisionA, parent: "m1")
        let parentM2 = makeScope(revision: revisionA, parent: "m2")
        let snapshot = AccountCatalogFixture.completeRelationships(values: [], scope: parentM1, refreshID: refreshA)

        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m2"), voice: VoiceID(rawValue: "v1"), in: snapshot, scope: parentM2, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: snapshot, scope: parentM1, currentRevision: revisionA, currentRefreshID: refreshB, contractOwned: .none), .unknown)
    }

    func testCurrentStructuredSynthesisRejectionInvalidatesOnlyMatchingResponseIdentity() {
        let scope = makeScope(revision: revisionA, parent: "m1")
        let tuple = AccountRelationshipTuple(modelID: ModelID(rawValue: "m1"), voiceID: VoiceID(rawValue: "v1"), controlsID: nil, controlsVersion: nil)
        let rejection = StructuredSynthesisRejection(scopeRevision: revisionA, tuple: tuple, sessionGeneration: generationA, reason: "voice_not_supported")
        let snapshot = AccountCatalogFixture.snapshot(scope: scope, relationships: .unknown([], refreshID: refreshA, paginationComplete: false, rejections: [rejection]))

        XCTAssertEqual(AccountSelectionValidator.validate(model: tuple.modelID, voice: tuple.voiceID, in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshB, currentSessionGeneration: generationA, contractOwned: .none), .invalid)
        XCTAssertEqual(AccountSelectionValidator.validate(model: tuple.modelID, voice: tuple.voiceID, in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshB, currentSessionGeneration: SessionGeneration(rawValue: 5), contractOwned: .none), .unknown)
        XCTAssertEqual(AccountSelectionValidator.validate(model: tuple.modelID, voice: tuple.voiceID, in: snapshot, scope: makeScope(revision: revisionB, parent: "m1"), currentRevision: revisionB, currentRefreshID: refreshB, currentSessionGeneration: generationA, contractOwned: .none), .unknown)
    }

    func testBuiltInContractVoiceCannotBecomeInvalidFromCompleteAccountAbsence() {
        let scope = makeScope(revision: revisionA, parent: "m1")
        let snapshot = AccountCatalogFixture.completeRelationships(values: [], scope: scope, refreshID: refreshA)
        let owned = ContractOwnedResources(builtInVoices: [VoiceID(rawValue: "built-in")], builtInControls: [])

        XCTAssertNotEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "built-in"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: owned), .invalid)
        XCTAssertNotEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, controlsID: CatalogControlsID(rawValue: "built-in-control"), contractOwned: ContractOwnedResources(builtInVoices: [], builtInControls: [CatalogControlsID(rawValue: "built-in-control")])), .invalid)
    }

    func testEvidenceScopeMustExactlyMatchProviderParentControlsAndQuery() {
        let scope = makeScope(revision: revisionA, parent: "m1")
        let changed = try! RelationshipScope(providerID: ProviderID(rawValue: "other-provider"), credentialRevision: revisionA, contractVersion: contract, parentModelID: ModelID(rawValue: "m2"), controlsSchema: "other-controls", queryParameters: ["locale": "fr-FR"])
        let evidence = AccountRelationshipEvidence(scope: changed, scopeRevision: revisionA, contractVersion: contract, fetchedAt: Date(), refreshID: refreshA, authoritySource: "fixture", coverage: .authoritativeComplete, paginationComplete: true, values: [], rejections: [])
        let snapshot = AccountCatalogSnapshot(relationshipEvidence: [scope: evidence])
        XCTAssertEqual(AccountSelectionValidator.validate(model: ModelID(rawValue: "m1"), voice: VoiceID(rawValue: "v1"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, contractOwned: .none), .unknown)
    }

    func testIndependentSynthesisRejectionDoesNotNeedCatalogEvidence() {
        let scope = makeScope(revision: revisionA, parent: "m1"), tuple = AccountRelationshipTuple(modelID: ModelID(rawValue: "m1"), voiceID: VoiceID(rawValue: "v1"), controlsID: nil, controlsVersion: nil)
        let rejection = StructuredSynthesisRejection(scopeRevision: revisionA, tuple: tuple, sessionGeneration: generationA, reason: "structured")
        let snapshot = AccountCatalogSnapshot(synthesisRejections: [scope: [rejection]])
        XCTAssertEqual(AccountSelectionValidator.validate(model: tuple.modelID, voice: tuple.voiceID, in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, currentSessionGeneration: generationA, contractOwned: .none), .invalid)
        XCTAssertEqual(AccountSelectionValidator.validate(model: tuple.modelID, voice: VoiceID(rawValue: "wrong"), in: snapshot, scope: scope, currentRevision: revisionA, currentRefreshID: refreshA, currentSessionGeneration: generationA, contractOwned: .none), .unknown)
    }

    func testScopeCanonicalizationRejectsInvalidConstructionAndDecoding() throws {
        XCTAssertThrowsError(try RelationshipScope(providerID: provider, credentialRevision: revisionA, contractVersion: contract, parentModelID: nil, controlsSchema: "  ", queryParameters: [:]))
        XCTAssertThrowsError(try RelationshipScope(providerID: provider, credentialRevision: revisionA, contractVersion: contract, parentModelID: nil, controlsSchema: "controls", queryParameters: [" ": "value"]))
        XCTAssertThrowsError(try RelationshipScope(providerID: provider, credentialRevision: revisionA, contractVersion: contract, parentModelID: nil, controlsSchema: "controls", queryParameters: [" locale ": "a", "locale": "b"]))

        let encoded = Data("{\"providerID\":{\"rawValue\":\"test-provider\"},\"credentialRevision\":\"00000000-0000-0000-0000-000000000001\",\"contractVersion\":{\"rawValue\":\"contract-v1\"},\"controlsSchema\":\" \",\"queryParameters\":{}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RelationshipScope.self, from: encoded))
        let duplicate = Data("{\"providerID\":{\"rawValue\":\"test-provider\"},\"credentialRevision\":\"00000000-0000-0000-0000-000000000001\",\"contractVersion\":{\"rawValue\":\"contract-v1\"},\"controlsSchema\":\"controls\",\"queryParameters\":{\" locale \":\"a\",\"locale\":\"b\"}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RelationshipScope.self, from: duplicate))
    }

    private func makeScope(revision: UUID, parent: String?) -> RelationshipScope {
        try! RelationshipScope(providerID: provider, credentialRevision: revision, contractVersion: contract, parentModelID: parent.map(ModelID.init(rawValue:)), controlsSchema: "controls-v1", queryParameters: ["locale": "en-US"])
    }
}

private enum AccountCatalogFixture {
    enum Resource {
        case complete([String], refreshID: CatalogRefreshID)
    }

    enum Relationships {
        case authoritativeComplete([AccountRelationshipTuple], refreshID: CatalogRefreshID, paginationComplete: Bool, rejections: Set<StructuredSynthesisRejection>)
        case partial([AccountRelationshipTuple], refreshID: CatalogRefreshID)
        case unknown([AccountRelationshipTuple], refreshID: CatalogRefreshID, paginationComplete: Bool, rejections: Set<StructuredSynthesisRejection>)
    }

    static func snapshot(scope: RelationshipScope, models: Resource? = nil, voices: Resource? = nil, relationships: Relationships? = nil) -> AccountCatalogSnapshot {
        let modelEvidence = models.map { [scope: [AccountResourceKey(dimension: .model, parentModelID: scope.parentModelID): makeEvidence(values: $0.models.map(ModelID.init(rawValue:)), scope: scope, refreshID: $0.refreshID)]] } ?? [:]
        let voiceEvidence = voices.map { [scope: [AccountResourceKey(dimension: .voice, parentModelID: scope.parentModelID): makeEvidence(values: $0.models.map(VoiceID.init(rawValue:)), scope: scope, refreshID: $0.refreshID)]] } ?? [:]
        let relationshipEvidence = relationships.map { [scope: makeRelationshipEvidence($0, scope: scope)] } ?? [:]
        return AccountCatalogSnapshot(modelEvidence: modelEvidence, voiceEvidence: voiceEvidence, relationshipEvidence: relationshipEvidence)
    }

    static func completeRelationships(values: [AccountRelationshipTuple], scope: RelationshipScope, refreshID: CatalogRefreshID) -> AccountCatalogSnapshot {
        snapshot(scope: scope, relationships: .authoritativeComplete(values, refreshID: refreshID, paginationComplete: true, rejections: []))
    }

    private static func makeEvidence<Value: Codable & Hashable & Sendable>(values: [Value], scope: RelationshipScope, refreshID: CatalogRefreshID) -> AccountResourceEvidence<Value> {
        AccountResourceEvidence(scopeRevision: scope.credentialRevision, contractVersion: scope.contractVersion, fetchedAt: Date(timeIntervalSince1970: 0), refreshID: refreshID, authoritySource: "fixture", coverage: .authoritativeComplete, values: Set(values))
    }

    private static func makeRelationshipEvidence(_ fixture: Relationships, scope: RelationshipScope) -> AccountRelationshipEvidence {
        switch fixture {
        case let .authoritativeComplete(values, refreshID, paginationComplete, rejections):
            return AccountRelationshipEvidence(scope: scope, scopeRevision: scope.credentialRevision, contractVersion: scope.contractVersion, fetchedAt: Date(timeIntervalSince1970: 0), refreshID: refreshID, authoritySource: "fixture", coverage: .authoritativeComplete, paginationComplete: paginationComplete, values: Set(values), rejections: rejections)
        case let .partial(values, refreshID):
            return AccountRelationshipEvidence(scope: scope, scopeRevision: scope.credentialRevision, contractVersion: scope.contractVersion, fetchedAt: Date(timeIntervalSince1970: 0), refreshID: refreshID, authoritySource: "fixture", coverage: .partial, paginationComplete: false, values: Set(values), rejections: [])
        case let .unknown(values, refreshID, paginationComplete, rejections):
            return AccountRelationshipEvidence(scope: scope, scopeRevision: scope.credentialRevision, contractVersion: scope.contractVersion, fetchedAt: Date(timeIntervalSince1970: 0), refreshID: refreshID, authoritySource: "fixture", coverage: .unknown, paginationComplete: paginationComplete, values: Set(values), rejections: rejections)
        }
    }
}

private extension AccountCatalogFixture.Resource {
    var models: [String] {
        switch self {
        case let .complete(values, _): values
        }
    }

    var refreshID: CatalogRefreshID {
        switch self {
        case let .complete(_, refreshID): refreshID
        }
    }
}

import CryptoKit
import Foundation

struct ContractEvidence: Codable, Hashable, Sendable {
    let sourceURL: URL
    let retrievedAt: Date
    let evidenceDigest: String
    let contractVersion: ContractVersion
    private enum CodingKeys: String, CodingKey { case sourceURL, retrievedAt, evidenceDigest, contractVersion }
    init(sourceURL: URL, retrievedAt: Date, evidenceDigest: String, contractVersion: ContractVersion) { self.sourceURL = sourceURL; self.retrievedAt = retrievedAt; self.evidenceDigest = evidenceDigest; self.contractVersion = contractVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); sourceURL = try c.decode(URL.self, forKey: .sourceURL); evidenceDigest = try c.decode(String.self, forKey: .evidenceDigest); contractVersion = try c.decode(ContractVersion.self, forKey: .contractVersion)
        let timestamp = try c.decode(String.self, forKey: .retrievedAt)
        guard let value = ISO8601DateFormatter().date(from: timestamp) else { throw DecodingError.dataCorruptedError(forKey: .retrievedAt, in: c, debugDescription: "Expected ISO-8601 evidence time.") }; retrievedAt = value
    }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(sourceURL, forKey: .sourceURL); try c.encode(ISO8601DateFormatter().string(from: retrievedAt), forKey: .retrievedAt); try c.encode(evidenceDigest, forKey: .evidenceDigest); try c.encode(contractVersion, forKey: .contractVersion) }
}

/// A catalog record that has passed strict wire, subject, and snapshot-digest validation.
/// The initializer is file-private so release gates cannot accept caller-assembled evidence.
struct CatalogValidatedEvidence: Hashable, Sendable {
    let evidenceID: String
    let providerID: ProviderID
    let modelID: ModelID?
    let kind: EvidenceKind
    let snapshot: String
    let evidence: ContractEvidence

    fileprivate init(record: EvidenceRecord) {
        evidenceID = record.id
        providerID = record.providerID
        modelID = record.modelID
        kind = record.kind
        snapshot = record.snapshot
        evidence = record.evidence
    }
}

enum EvidenceKind: String, Codable, Hashable, Sendable { case provider, model }
struct EvidenceRecord: Codable, Hashable, Sendable { let id: String; let providerID: ProviderID; let modelID: ModelID?; let kind: EvidenceKind; let snapshot: String; let evidence: ContractEvidence }
struct ModelAvailability: Codable, Hashable, Sendable { let kind: ProviderAvailabilityKind; let reason: ProviderAvailabilityReason?; let contractVersion: ContractVersion; let evidenceID: String? }
struct ModelContract: Codable, Hashable, Sendable { let modelID: ModelID; let availability: ModelAvailability }
struct NativeAudioContract: Codable, Hashable, Sendable { let container: String; let codec: String; let sampleRate: Int?; let channels: Int?; let bitDepth: Int?; let mappingVersion: String }
enum RetryIdempotency: String, Codable, Hashable, Sendable { case guaranteed, notGuaranteed }
struct RetryContract: Codable, Hashable, Sendable { let idempotency: RetryIdempotency; let retryableHTTPStatuses: Set<Int>; let maximumAttempts: Int; let backoffMilliseconds: [Int] }

struct ProviderContract: Codable, Hashable, Sendable {
    let providerID: ProviderID; let availability: ProviderAvailability; let models: [ModelID: ModelContract]; let nativeAudio: NativeAudioContract; let retryContract: RetryContract
    private enum CodingKeys: String, CodingKey { case providerID, availability, models, nativeAudio, retryContract }
    init(providerID: ProviderID, availability: ProviderAvailability, models: [ModelID: ModelContract], nativeAudio: NativeAudioContract, retryContract: RetryContract) { self.providerID = providerID; self.availability = availability; self.models = models; self.nativeAudio = nativeAudio; self.retryContract = retryContract }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); providerID = try c.decode(ProviderID.self, forKey: .providerID); availability = try c.decode(ProviderAvailability.self, forKey: .availability)
        var indexed: [ModelID: ModelContract] = [:]
        for model in try c.decode([ModelContract].self, forKey: .models) { guard indexed[model.modelID] == nil else { throw DecodingError.dataCorruptedError(forKey: .models, in: c, debugDescription: "Duplicate model ID.") }; indexed[model.modelID] = model }
        models = indexed; nativeAudio = try c.decode(NativeAudioContract.self, forKey: .nativeAudio); retryContract = try c.decode(RetryContract.self, forKey: .retryContract)
    }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(providerID, forKey: .providerID); try c.encode(availability, forKey: .availability); try c.encode(models.values.sorted { $0.modelID.rawValue < $1.modelID.rawValue }, forKey: .models); try c.encode(nativeAudio, forKey: .nativeAudio); try c.encode(retryContract, forKey: .retryContract) }
}

struct CatalogDocument: Codable, Hashable, Sendable {
    let schemaVersion: Int; let contractVersion: ContractVersion; let evidenceRecords: [EvidenceRecord]; let contracts: [ProviderContract]
    init(schemaVersion: Int, contractVersion: ContractVersion = ContractVersion(rawValue: "provider-contracts-v1"), evidenceRecords: [EvidenceRecord] = [], contracts: [ProviderContract]) { self.schemaVersion = schemaVersion; self.contractVersion = contractVersion; self.evidenceRecords = evidenceRecords; self.contracts = contracts }
}

enum ProviderContractCatalogError: Error, Equatable, Sendable { case resourceMissing, invalidSchema, invalidWireNumber, invalidDocument }

struct ProviderContractCatalog: Sendable {
    static let schemaVersion = 1
    private let contracts: [ProviderID: ProviderContract]; let evidenceRecords: [EvidenceRecord]; private let trusted: Bool
    init(data: Data) throws {
        try StrictContractWire.validate(data)
        let document = try JSONDecoder().decode(CatalogDocument.self, from: data)
        try Self.validate(document)
        contracts = Dictionary(uniqueKeysWithValues: document.contracts.map { ($0.providerID, $0) }); evidenceRecords = document.evidenceRecords; trusted = true
    }
    private init(failClosed: Void) { contracts = [:]; evidenceRecords = []; trusted = false }
    static func loading(data: Data) -> ProviderContractCatalog { (try? ProviderContractCatalog(data: data)) ?? ProviderContractCatalog(failClosed: ()) }
    static func bundledResourceData() throws -> Data { guard let url = Bundle.module.url(forResource: "provider-contracts-v1", withExtension: "json") else { throw ProviderContractCatalogError.resourceMissing }; return try Data(contentsOf: url) }
    static func bundled() throws -> ProviderContractCatalog { try ProviderContractCatalog(data: bundledResourceData()) }
    func contract(for providerID: ProviderID) -> ProviderContract? { contracts[providerID] }
    func validatedEvidence(providerID: ProviderID, modelID: ModelID?) -> CatalogValidatedEvidence? {
        guard trusted, let contract = contracts[providerID] else { return nil }
        let evidenceID: String?
        if let modelID {
            evidenceID = contract.models[modelID]?.availability.evidenceID
        } else {
            evidenceID = contract.availability.evidenceID
        }
        guard
            let evidenceID,
            let record = evidenceRecords.first(where: { $0.id == evidenceID }),
            record.providerID == providerID,
            record.modelID == modelID,
            record.kind == (modelID == nil ? .provider : .model)
        else { return nil }
        return CatalogValidatedEvidence(record: record)
    }
    func providerAvailability(for providerID: ProviderID) -> ProviderAvailability {
        guard trusted, let contract = contracts[providerID] else { return Self.unknownProvider }
        let declared = contract.availability
        guard declared.kind == .available else { return declared }
        guard contract.models.values.contains(where: { $0.availability.kind == .available }) else { return ProviderAvailability(kind: .disabled, reason: .noQualifiedModel, maturity: declared.maturity, featureFlagName: declared.featureFlagName, featureFlagEnabled: declared.featureFlagEnabled, providerContractVersion: declared.providerContractVersion, evidenceID: declared.evidenceID) }
        return declared
    }
    func modelAvailability(providerID: ProviderID, modelID: ModelID) -> ModelAvailability { guard trusted, let value = contracts[providerID]?.models[modelID]?.availability else { return Self.unknownModel }; return value }
    private static func validate(_ d: CatalogDocument) throws {
        guard d.schemaVersion == schemaVersion, !d.contractVersion.rawValue.isEmpty else { throw ProviderContractCatalogError.invalidSchema }
        let ids = d.evidenceRecords.map(\.id); guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { throw ProviderContractCatalogError.invalidDocument }
        let evidence = Dictionary(uniqueKeysWithValues: d.evidenceRecords.map { ($0.id, $0) })
        guard d.evidenceRecords.allSatisfy({ !$0.providerID.rawValue.isEmpty && !$0.snapshot.isEmpty && validDigest($0.evidence.evidenceDigest) && $0.evidence.contractVersion == d.contractVersion && EvidenceRecordDigestV1.matches($0) && (($0.kind == .provider && $0.modelID == nil) || ($0.kind == .model && $0.modelID != nil)) }) else { throw ProviderContractCatalogError.invalidDocument }
        let providerIDs = d.contracts.map(\.providerID); let allowed: Set<ProviderID> = [.minimax, .openAI, .macOS, .gemini]
        guard providerIDs.allSatisfy({ allowed.contains($0) }), Set(providerIDs).count == providerIDs.count else { throw ProviderContractCatalogError.invalidDocument }
        for c in d.contracts {
            guard !c.providerID.rawValue.isEmpty, !c.availability.providerContractVersion.rawValue.isEmpty, c.availability.providerContractVersion == d.contractVersion, let providerEvidence = c.availability.evidenceID, let record = evidence[providerEvidence], record.kind == .provider, record.providerID == c.providerID, record.modelID == nil else { throw ProviderContractCatalogError.invalidDocument }
            guard !c.nativeAudio.mappingVersion.isEmpty, validAudio(c.nativeAudio), validRetry(c.retryContract) else { throw ProviderContractCatalogError.invalidDocument }
            let models = c.models.values; guard Set(models.map(\.modelID)).count == models.count else { throw ProviderContractCatalogError.invalidDocument }
            for m in models { guard !m.modelID.rawValue.isEmpty, !m.availability.contractVersion.rawValue.isEmpty, m.availability.contractVersion == d.contractVersion, let id = m.availability.evidenceID, let record = evidence[id], record.kind == .model, record.providerID == c.providerID, record.modelID == m.modelID else { throw ProviderContractCatalogError.invalidDocument } }
            if c.availability.kind == .experimental || models.contains(where: { $0.availability.kind == .experimental }) { guard c.availability.featureFlagName == "geminiExperimentalEnabled" else { throw ProviderContractCatalogError.invalidDocument } }
        }
    }
    private static func validDigest(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    private static func validAudio(_ value: NativeAudioContract) -> Bool {
        if value.container == "unknown" || value.codec == "unknown" { return value.container == "unknown" && value.codec == "unknown" && value.sampleRate == nil && value.channels == nil && value.bitDepth == nil }
        return !value.container.isEmpty && !value.codec.isEmpty && (value.sampleRate ?? 0) > 0 && (value.channels ?? 0) > 0 && (value.bitDepth ?? 0) > 0
    }
    private static func validRetry(_ value: RetryContract) -> Bool { value.maximumAttempts >= 1 && value.retryableHTTPStatuses.allSatisfy { (100...599).contains($0) } && value.backoffMilliseconds.allSatisfy { $0 >= 0 } && value.backoffMilliseconds.count == value.maximumAttempts - 1 }
    private static let unknownProvider = ProviderAvailability(kind: .unknown, reason: .wireContractUnverified, maturity: .stable, featureFlagName: nil, featureFlagEnabled: nil, providerContractVersion: ContractVersion(rawValue: "unknown"), evidenceID: nil)
    private static let unknownModel = ModelAvailability(kind: .unknown, reason: .wireContractUnverified, contractVersion: ContractVersion(rawValue: "unknown"), evidenceID: nil)
}

private enum EvidenceRecordDigestV1 {
    static func matches(_ record: EvidenceRecord) -> Bool {
        let bytes = Data(record.snapshot.utf8)
        return Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined() == record.evidence.evidenceDigest
    }
}

private enum StrictContractWire {
    static func validate(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderContractCatalogError.invalidDocument }
        try integer(root["schemaVersion"]); for contract in try objects(root["contracts"]) { try retry(contract["retryContract"]); try audio(contract["nativeAudio"]) }
    }
    private static func objects(_ value: Any?) throws -> [[String: Any]] { guard let array = value as? [[String: Any]] else { throw ProviderContractCatalogError.invalidDocument }; return array }
    private static func integer(_ value: Any?) throws { guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: n.objCType)) else { throw ProviderContractCatalogError.invalidWireNumber } }
    private static func retry(_ value: Any?) throws { guard let r = value as? [String: Any] else { throw ProviderContractCatalogError.invalidDocument }; try integer(r["maximumAttempts"]); guard let statuses = r["retryableHTTPStatuses"] as? [Any], let backoff = r["backoffMilliseconds"] as? [Any] else { throw ProviderContractCatalogError.invalidDocument }; try statuses.forEach(integer); try backoff.forEach(integer); let codes = statuses.compactMap { ($0 as? NSNumber)?.intValue }; guard codes.count == statuses.count, Set(codes).count == codes.count else { throw ProviderContractCatalogError.invalidDocument } }
    private static func audio(_ value: Any?) throws { guard let a = value as? [String: Any] else { throw ProviderContractCatalogError.invalidDocument }; for key in ["sampleRate", "channels", "bitDepth"] where a[key] != nil && !(a[key] is NSNull) { try integer(a[key]) } }
}

enum CredentialGateState: Equatable, Sendable { case noneRequired, missing, configured(health: ProviderHealth), blocked(CredentialBlockReason) }
enum SynthesisBlockReason: Equatable, Sendable { case credentialRejected, credentialMissing, credentialBlocked, providerDisabled, providerDeprecated, contractUnknown, noQualifiedModel, modelDisabled, modelDeprecated, modelUnknown, experimentalFeatureDisabled, experimentalReleaseApprovalRequired, experimentalEvidenceMissing, contractEvidenceMissing, accountInvalid, experimentalContractFlagMismatch }
enum SynthesisGate: Equatable, Sendable { case allowed, blocked(SynthesisBlockReason) }
enum SelectionGate {
    static func evaluate(credential: CredentialGateState, provider: ProviderAvailability, model: ModelAvailability, account: SelectionValidation, featureFlag: Bool, releaseApproved: Bool) -> SynthesisGate {
        switch credential { case .configured(health: .explicitRejected): return .blocked(.credentialRejected); case .missing: return .blocked(.credentialMissing); case .blocked: return .blocked(.credentialBlocked); case .noneRequired, .configured: break }
        switch provider.kind { case .disabled: return .blocked(provider.reason == .noQualifiedModel ? .noQualifiedModel : .providerDisabled); case .deprecated: return .blocked(.providerDeprecated); case .unknown: return .blocked(.contractUnknown); case .available, .experimental: break }
        switch model.kind { case .disabled: return .blocked(.modelDisabled); case .deprecated: return .blocked(.modelDeprecated); case .unknown: return .blocked(.modelUnknown); case .available, .experimental: break }
        if provider.kind == .experimental || model.kind == .experimental { guard provider.featureFlagName == "geminiExperimentalEnabled" else { return .blocked(.experimentalContractFlagMismatch) }; guard featureFlag else { return .blocked(.experimentalFeatureDisabled) }; guard releaseApproved else { return .blocked(.experimentalReleaseApprovalRequired) } }
        guard provider.evidenceID != nil, model.evidenceID != nil else { return .blocked(provider.kind == .experimental || model.kind == .experimental ? .experimentalEvidenceMissing : .contractEvidenceMissing) }
        return account == .invalid ? .blocked(.accountInvalid) : .allowed
    }
}

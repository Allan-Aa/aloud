import CryptoKit
import Foundation

protocol VoiceProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }
    func measureInput(_ text: String, requestOverhead: RequestOverhead) async throws -> InputMeasurement
    func split(_ text: String, selection: ProviderSelection) async throws -> [ValidatedSpeechChunk]
    func loadCatalog(using credential: ProviderCredential) async throws -> AccountCatalogSnapshot
    func synthesize(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact
}

enum InputValidationError: Error, Equatable {
    case invalidLimit, emptyLimits, mixedContracts, emptyChunk, exceeded(InputLimit), missingProof(InputLimit), incorrectProof(InputLimit), invalidFingerprintFields, lengthPrefixTooLarge
}

/// Centralized checked conversion for every u32 length prefix. `maximum` is an
/// internal test seam so boundary behavior can be proven without allocating 4GB.
enum LengthPrefix {
    static func checked(_ count: Int, maximum: UInt32 = .max) throws -> UInt32 {
        guard count >= 0, count <= Int(maximum), count <= Int(UInt32.max) else { throw InputValidationError.lengthPrefixTooLarge }
        return UInt32(count)
    }
}

struct InputLimit: Codable, Hashable, Sendable {
    enum Unit: String, Codable, Sendable { case utf8Bytes, unicodeScalars, graphemes, conservativeTokens }
    let endpoint: String
    let unit: Unit
    let maximum: Int
    let safetyMargin: Int
    let contractVersion: ContractVersion

    init(endpoint: String, unit: Unit, maximum: Int, safetyMargin: Int, contractVersion: ContractVersion) throws {
        guard !endpoint.isEmpty, maximum > 0, safetyMargin >= 0, !contractVersion.rawValue.isEmpty else { throw InputValidationError.invalidLimit }
        // A byte-per-token upper bound plus a positive margin never claims tokenizer precision.
        guard unit != .conservativeTokens || safetyMargin > 0 else { throw InputValidationError.invalidLimit }
        guard unit == .conservativeTokens || safetyMargin == 0 else { throw InputValidationError.invalidLimit }
        self.endpoint = endpoint; self.unit = unit; self.maximum = maximum; self.safetyMargin = safetyMargin; self.contractVersion = contractVersion
    }
    private enum CodingKeys: String, CodingKey { case endpoint, unit, maximum, safetyMargin, contractVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), unit: c.decode(Unit.self, forKey: .unit), maximum: c.decode(Int.self, forKey: .maximum), safetyMargin: c.decode(Int.self, forKey: .safetyMargin), contractVersion: c.decode(ContractVersion.self, forKey: .contractVersion))
    }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(endpoint, forKey: .endpoint); try c.encode(unit, forKey: .unit); try c.encode(maximum, forKey: .maximum); try c.encode(safetyMargin, forKey: .safetyMargin); try c.encode(contractVersion, forKey: .contractVersion) }
}

struct RequestOverhead: Codable, Hashable, Sendable {
    let instruction: String; let style: String; let rate: String
    init(instruction: String = "", style: String = "", rate: String = "") { self.instruction = instruction; self.style = style; self.rate = rate }
    /// This is the provider request-side measurement contract.  Each role has a
    /// tag and byte length, so `("ab", "c", "")` can never be confused with
    /// `("a", "bc", "")`.  Providers must render their endpoint request from
    /// this same three-field contract before using a byte/token limit.
    func encoded(maximumLength: UInt32 = .max) throws -> Data {
        var output = Data("ALOVHD01".utf8)
        for (tag, value) in [("instruction", instruction), ("style", style), ("rate", rate)] {
            let tagBytes = Data(tag.utf8)
            let valueBytes = Data(value.utf8)
            output.appendUInt32(try LengthPrefix.checked(tagBytes.count, maximum: maximumLength)); output.append(tagBytes)
            output.appendUInt32(try LengthPrefix.checked(valueBytes.count, maximum: maximumLength)); output.append(valueBytes)
        }
        return output
    }
    /// A scalar/grapheme-safe presentation of the same length-prefixed fields.
    /// Separators are framing, never implicit concatenation boundaries.
    var typedText: String {
        [("instruction", instruction), ("style", style), ("rate", rate)].map { tag, value in
            "\u{001E}\(tag.utf8.count):\(tag)\u{001F}\(value.utf8.count):\(value)"
        }.joined()
    }
    func measurementBytes(for text: String, maximumTextLength: UInt32 = .max, maximumOverheadFieldLength: UInt32 = .max) throws -> Data {
        var output = Data("ALMEAS01".utf8)
        let textBytes = Data(text.utf8)
        output.appendUInt32(try LengthPrefix.checked(textBytes.count, maximum: maximumTextLength)); output.append(textBytes)
        output.append(try encoded(maximumLength: maximumOverheadFieldLength))
        return output
    }
}

struct InputMeasurement: Hashable, Sendable {
    let values: [InputLimit: Int]
    let contractVersion: ContractVersion
    let safetyMarginDescription: String?
    private init(values: [InputLimit: Int], contractVersion: ContractVersion, safetyMarginDescription: String?) { self.values = values; self.contractVersion = contractVersion; self.safetyMarginDescription = safetyMarginDescription }

    static func measure(_ text: String, limits: Set<InputLimit>, requestOverhead: RequestOverhead) async throws -> InputMeasurement {
        guard !limits.isEmpty else { throw InputValidationError.emptyLimits }
        let versions = Set(limits.map(\.contractVersion))
        guard versions.count == 1, let version = versions.first else { throw InputValidationError.mixedContracts }
        let bytes = try requestOverhead.measurementBytes(for: text)
        let typedContent = text + requestOverhead.typedText
        var values: [InputLimit: Int] = [:]
        for limit in limits {
            let raw: Int
            switch limit.unit {
            case .utf8Bytes: raw = bytes.count
            case .unicodeScalars: raw = typedContent.unicodeScalars.count
            case .graphemes: raw = typedContent.count
            case .conservativeTokens:
                // UTF-8 byte count is a deliberately safe upper bound for byte-tokenizable input.
                raw = bytes.count + limit.safetyMargin
            }
            values[limit] = raw
        }
        let descriptions = limits.filter { $0.unit == .conservativeTokens }.map { "\($0.safetyMargin) conservative-token safety margin" }
        return InputMeasurement(values: values, contractVersion: version, safetyMarginDescription: descriptions.isEmpty ? nil : descriptions.sorted().joined(separator: ", "))
    }

    /// Measures only the provider field named by the limits. OpenAI's speech
    /// endpoint publishes its maximum for `input`, not for the JSON envelope,
    /// so request framing must not reduce that documented allowance.
    static func measureTextOnly(_ text: String, limits: Set<InputLimit>) throws -> InputMeasurement {
        guard !limits.isEmpty else { throw InputValidationError.emptyLimits }
        let versions = Set(limits.map(\.contractVersion))
        guard versions.count == 1, let version = versions.first else {
            throw InputValidationError.mixedContracts
        }
        let bytes = Data(text.utf8)
        var values: [InputLimit: Int] = [:]
        for limit in limits {
            switch limit.unit {
            case .utf8Bytes: values[limit] = bytes.count
            case .unicodeScalars: values[limit] = text.unicodeScalars.count
            case .graphemes: values[limit] = text.count
            case .conservativeTokens: values[limit] = bytes.count + limit.safetyMargin
            }
        }
        let descriptions = limits
            .filter { $0.unit == .conservativeTokens }
            .map { "\($0.safetyMargin) conservative-token safety margin" }
        return InputMeasurement(
            values: values,
            contractVersion: version,
            safetyMarginDescription: descriptions.isEmpty ? nil : descriptions.sorted().joined(separator: ", ")
        )
    }
}

struct ValidatedSpeechChunk: Hashable, Sendable {
    let text: String
    let measurements: InputMeasurement
    private init(text: String, measurements: InputMeasurement) { self.text = text; self.measurements = measurements }

    fileprivate static func make(text: String, proof: InputMeasurement, capabilities: ProviderCapabilities) throws -> ValidatedSpeechChunk {
        guard !text.isEmpty else { throw InputValidationError.emptyChunk }
        try capabilities.validate(proof)
        return ValidatedSpeechChunk(text: text, measurements: proof)
    }
}

enum NativeAudioFormat: Codable, Hashable, Sendable { case encoded(container: String, codec: String); case pcm(sampleRate: Int, channels: Int, bitDepth: Int, littleEndian: Bool) }

struct ProviderCapabilities: Hashable, Sendable {
    let inputLimits: Set<InputLimit>; let outputFormat: NativeAudioFormat; let contractVersion: ContractVersion; let requestOverhead: RequestOverhead
    init(inputLimits: Set<InputLimit>, outputFormat: NativeAudioFormat, contractVersion: ContractVersion, requestOverhead: RequestOverhead = RequestOverhead()) throws {
        guard !inputLimits.isEmpty else { throw InputValidationError.emptyLimits }
        guard inputLimits.allSatisfy({ $0.contractVersion == contractVersion }) else { throw InputValidationError.mixedContracts }
        self.inputLimits = inputLimits; self.outputFormat = outputFormat; self.contractVersion = contractVersion; self.requestOverhead = requestOverhead
    }
    func validate(_ proof: InputMeasurement) throws {
        guard proof.contractVersion == contractVersion else { throw InputValidationError.mixedContracts }
        guard Set(proof.values.keys) == inputLimits else {
            if let missing = inputLimits.first(where: { proof.values[$0] == nil }) { throw InputValidationError.missingProof(missing) }
            throw InputValidationError.invalidLimit
        }
        for limit in inputLimits { guard let value = proof.values[limit], value <= limit.maximum else { throw InputValidationError.exceeded(limit) } }
    }
}

/// Provider-owned splitter. It uses the exact aggregate measurement contract used for chunk proof.
struct ProviderInputSplitter: Sendable {
    let capabilities: ProviderCapabilities
    let measure: @Sendable (String, RequestOverhead) async throws -> InputMeasurement
    init(capabilities: ProviderCapabilities) { self.capabilities = capabilities; self.measure = { text, overhead in try await InputMeasurement.measure(text, limits: capabilities.inputLimits, requestOverhead: overhead) } }
    init(capabilities: ProviderCapabilities, measure: @escaping @Sendable (String, RequestOverhead) async throws -> InputMeasurement) { self.capabilities = capabilities; self.measure = measure }
    func split(_ text: String) async throws -> [ValidatedSpeechChunk] {
        guard !text.isEmpty else { return [] }
        var chunks: [ValidatedSpeechChunk] = []; var current = ""
        for grapheme in text {
            let candidate = current + String(grapheme)
            if try await fits(candidate) { current = candidate; continue }
            guard !current.isEmpty else { throw InputValidationError.exceeded(try await firstExceeded(candidate)) }
            chunks.append(try await make(current))
            guard try await fits(String(grapheme)) else { throw InputValidationError.exceeded(try await firstExceeded(String(grapheme))) }
            current = String(grapheme)
        }
        if !current.isEmpty { chunks.append(try await make(current)) }
        return chunks
    }
    private func fits(_ text: String) async throws -> Bool {
        let proof = try await measure(text, capabilities.requestOverhead)
        return proof.values.allSatisfy { $0.value <= $0.key.maximum }
    }
    private func firstExceeded(_ text: String) async throws -> InputLimit {
        let proof = try await measure(text, capabilities.requestOverhead)
        guard let limit = proof.values.first(where: { $0.value > $0.key.maximum })?.key else { throw InputValidationError.invalidLimit }; return limit
    }
    private func make(_ text: String) async throws -> ValidatedSpeechChunk { try ValidatedSpeechChunk.make(text: text, proof: try await measure(text, capabilities.requestOverhead), capabilities: capabilities) }
}

struct SynthesisControlField: Codable, Hashable, Sendable { let name: String; let value: String }
struct SynthesisControls: Codable, Hashable, Sendable {
    /// `renderedFields` are a canonical map, serialized in strict ASCII-name
    /// order. Field order therefore cannot change cache identity by accident.
    let renderedFields: [SynthesisControlField]; let mappingVersion: String; let templateVersion: String?
    init(renderedFields: [SynthesisControlField], mappingVersion: String, templateVersion: String?) throws {
        let names = renderedFields.map(\.name)
        guard !mappingVersion.isEmpty,
              templateVersion?.isEmpty != true,
              renderedFields.allSatisfy({ Self.isLegalName($0.name) && !$0.value.isEmpty }),
              Set(names).count == names.count,
              names == names.sorted() else { throw InputValidationError.invalidFingerprintFields }
        self.renderedFields = renderedFields; self.mappingVersion = mappingVersion; self.templateVersion = templateVersion
    }
    private static func isLegalName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95 }
    }
    private enum CodingKeys: String, CodingKey { case renderedFields, mappingVersion, templateVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(renderedFields: c.decode([SynthesisControlField].self, forKey: .renderedFields), mappingVersion: c.decode(String.self, forKey: .mappingVersion), templateVersion: c.decodeIfPresent(String.self, forKey: .templateVersion))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(renderedFields, forKey: .renderedFields); try c.encode(mappingVersion, forKey: .mappingVersion); try c.encodeIfPresent(templateVersion, forKey: .templateVersion)
    }
    func encoded() throws -> Data { var out = Data("ALCTRL01".utf8); for field in renderedFields { for value in [Data(field.name.utf8), Data(field.value.utf8)] { out.appendUInt32(try LengthPrefix.checked(value.count)); out.append(value) } }; return out }
}
struct RateMapping: Sendable {
    let mappingVersion: String; let templateVersion: String?; private let render: @Sendable (NormalizedRate) throws -> SynthesisControls
    init(mappingVersion: String, templateVersion: String?, render: @escaping @Sendable (NormalizedRate) throws -> SynthesisControls) { self.mappingVersion = mappingVersion; self.templateVersion = templateVersion; self.render = render }
    func controls(for rate: NormalizedRate) throws -> SynthesisControls {
        guard rate.version == mappingVersion else { throw InputValidationError.invalidLimit }
        let controls = try render(rate); guard controls.mappingVersion == mappingVersion, controls.templateVersion == templateVersion else { throw InputValidationError.invalidLimit }; return controls
    }
}

struct RequestFingerprint: RawRepresentable, Codable, Hashable, Sendable { let rawValue: Data; init?(rawValue: Data) { guard rawValue.count == 32 else { return nil }; self.rawValue = rawValue }; init(from decoder: Decoder) throws { guard let value = Self(rawValue: try Data(from: decoder)) else { throw InputValidationError.invalidFingerprintFields }; self = value }; func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) } }
struct RequestFingerprintFields: Sendable {
    let providerID: Data; let scopeRevision: Data; let contractVersion: Data; let modelID: Data; let voiceID: Data?; let normalizedTextDigest: Data; let controls: Data; let mappingVersion: Data; let templateVersion: Data?; let outputFormat: Data; let canonicalizerVersion: Data
    init(providerID: Data, scopeRevision: Data, contractVersion: Data, modelID: Data, voiceID: Data?, normalizedTextDigest: Data, controls: Data, mappingVersion: Data, templateVersion: Data?, outputFormat: Data, canonicalizerVersion: Data) throws {
        let required = [providerID, scopeRevision, contractVersion, modelID, normalizedTextDigest, controls, mappingVersion, outputFormat, canonicalizerVersion]
        guard required.allSatisfy({ !$0.isEmpty && $0.count <= Int(UInt32.max) }), voiceID?.count ?? 0 <= Int(UInt32.max), templateVersion?.count ?? 0 <= Int(UInt32.max), scopeRevision.count == 16, normalizedTextDigest.count == 32 else { throw InputValidationError.invalidFingerprintFields }
        self.providerID = providerID; self.scopeRevision = scopeRevision; self.contractVersion = contractVersion; self.modelID = modelID; self.voiceID = voiceID; self.normalizedTextDigest = normalizedTextDigest; self.controls = controls; self.mappingVersion = mappingVersion; self.templateVersion = templateVersion; self.outputFormat = outputFormat; self.canonicalizerVersion = canonicalizerVersion
    }
    var ordered: [Data?] { [providerID, scopeRevision, contractVersion, modelID, voiceID, normalizedTextDigest, controls, mappingVersion, templateVersion, outputFormat, canonicalizerVersion] }
}
enum RequestFingerprintCodec {
    static func encode(fields: RequestFingerprintFields) throws -> Data {
        var body = Data("ALRFP001".utf8); body.append(contentsOf: [0, 1])
        for field in fields.ordered { guard let field else { body.append(contentsOf: [255, 255, 255, 255]); continue }; body.appendUInt32(try LengthPrefix.checked(field.count)); body.append(field) }
        return body
    }
    static func fingerprint(fields: RequestFingerprintFields) throws -> RequestFingerprint { guard let value = RequestFingerprint(rawValue: Data(SHA256.hash(data: try encode(fields: fields)))) else { throw InputValidationError.invalidFingerprintFields }; return value }
}

struct SpeechRequest: Hashable, Sendable {
    let id: SpeechRequestID; let selection: ProviderSelection; let chunk: ValidatedSpeechChunk; let controls: SynthesisControls; let credentialScopeRevision: UUID; let outputFormatID: String; let canonicalizerVersion: String; let requestFingerprint: RequestFingerprint
    private init(id: SpeechRequestID, selection: ProviderSelection, chunk: ValidatedSpeechChunk, controls: SynthesisControls, credentialScopeRevision: UUID, outputFormatID: String, canonicalizerVersion: String, requestFingerprint: RequestFingerprint) { self.id = id; self.selection = selection; self.chunk = chunk; self.controls = controls; self.credentialScopeRevision = credentialScopeRevision; self.outputFormatID = outputFormatID; self.canonicalizerVersion = canonicalizerVersion; self.requestFingerprint = requestFingerprint }
    static func make(id: SpeechRequestID, selection: ProviderSelection, chunk: ValidatedSpeechChunk, controls: SynthesisControls, credentialScopeRevision: UUID, capabilities: ProviderCapabilities, outputFormatID: String, canonicalizerVersion: String) throws -> SpeechRequest {
        try capabilities.validate(chunk.measurements)
        guard chunk.measurements.contractVersion == capabilities.contractVersion, !chunk.text.isEmpty else { throw InputValidationError.emptyChunk }
        let controlsBytes = try controls.encoded()
        let scope = credentialScopeRevision.uuidString.replacingOccurrences(of: "-", with: "").hexData
        let digest = Data(SHA256.hash(data: Data(chunk.text.precomposedStringWithCanonicalMapping.utf8)))
        let fields = try RequestFingerprintFields(providerID: Data(selection.providerID.rawValue.utf8), scopeRevision: scope, contractVersion: Data(capabilities.contractVersion.rawValue.utf8), modelID: Data(selection.modelID.rawValue.utf8), voiceID: selection.voiceID.map { Data($0.rawValue.utf8) }, normalizedTextDigest: digest, controls: controlsBytes, mappingVersion: Data(controls.mappingVersion.utf8), templateVersion: controls.templateVersion.map { Data($0.utf8) }, outputFormat: Data(outputFormatID.utf8), canonicalizerVersion: Data(("nfc-utf8-v1|" + canonicalizerVersion).utf8))
        return SpeechRequest(id: id, selection: selection, chunk: chunk, controls: controls, credentialScopeRevision: credentialScopeRevision, outputFormatID: outputFormatID, canonicalizerVersion: canonicalizerVersion, requestFingerprint: try RequestFingerprintCodec.fingerprint(fields: fields))
    }
    func recomputedFingerprint(capabilities: ProviderCapabilities) throws -> RequestFingerprint { try Self.make(id: id, selection: selection, chunk: chunk, controls: controls, credentialScopeRevision: credentialScopeRevision, capabilities: capabilities, outputFormatID: outputFormatID, canonicalizerVersion: canonicalizerVersion).requestFingerprint }
    /// Test-only corruption seam. Production code has no public mutable request
    /// construction path; this lets the synthesis gate prove it rejects every
    /// identity mismatch before provider synthesis.
    static func unsafeFixtureForTesting(copying request: SpeechRequest, chunk: ValidatedSpeechChunk? = nil, controls: SynthesisControls? = nil, fingerprint: RequestFingerprint? = nil) -> SpeechRequest {
        SpeechRequest(id: request.id, selection: request.selection, chunk: chunk ?? request.chunk, controls: controls ?? request.controls, credentialScopeRevision: request.credentialScopeRevision, outputFormatID: request.outputFormatID, canonicalizerVersion: request.canonicalizerVersion, requestFingerprint: fingerprint ?? request.requestFingerprint)
    }
}
/// The only coordinator seam for providers: re-measures with the provider before synthesis.
struct ProviderSynthesisGate: Sendable {
    let provider: any VoiceProvider
    func synthesize(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact {
        guard request.selection.providerID == provider.id else { throw InputValidationError.invalidLimit }
        let proof = try await provider.measureInput(request.chunk.text, requestOverhead: provider.capabilities.requestOverhead)
        try provider.capabilities.validate(proof)
        guard proof == request.chunk.measurements else { throw InputValidationError.incorrectProof(provider.capabilities.inputLimits.first!) }
        guard try request.recomputedFingerprint(capabilities: provider.capabilities) == request.requestFingerprint else { throw InputValidationError.invalidFingerprintFields }
        return try await provider.synthesize(request, credential: credential)
    }
}
private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }
}
private extension String { var hexData: Data { Data(stride(from: 0, to: count, by: 2).map { Data(UInt8(self[index(startIndex, offsetBy: $0)...index(startIndex, offsetBy: $0 + 1)], radix: 16).map { [$0] } ?? []) }.flatMap { $0 }) } }
struct NativeAudioArtifact: Hashable, Sendable { let url: URL; let format: NativeAudioFormat; let purpose: SpeechPurpose }

enum TemporaryArtifactOwnershipError: Error, Equatable, Sendable { case noLongerOwned }

/// Explicit, synchronous cleanup ownership for a unique temporary artifact.
/// Correctness never depends on `deinit`: every owner is either cleaned by a
/// lexical `defer` or explicitly transferred to the next pipeline stage.
final class TemporaryArtifactOwnership: @unchecked Sendable {
    private enum State { case owned, transferred, cleaned }
    private let lock = NSLock()
    private var state: State = .owned
    private let cleanupAction: @Sendable () -> Void

    init(cleanup: @escaping @Sendable () -> Void) { cleanupAction = cleanup }

    func cleanupIfOwned() {
        let shouldClean = lock.withLock {
            guard case .owned = state else { return false }
            state = .cleaned
            return true
        }
        if shouldClean { cleanupAction() }
    }

    func transfer() throws {
        let transferred = lock.withLock {
            guard case .owned = state else { return false }
            state = .transferred
            return true
        }
        guard transferred else { throw TemporaryArtifactOwnershipError.noLongerOwned }
    }
}

struct OwnedNativeAudioArtifact: Sendable {
    let artifact: NativeAudioArtifact
    private let ownership: TemporaryArtifactOwnership

    init(artifact: NativeAudioArtifact, cleanup: (@Sendable () -> Void)? = nil) {
        self.artifact = artifact
        let url = artifact.url
        self.ownership = TemporaryArtifactOwnership(cleanup: cleanup ?? {
            try? FileManager.default.removeItem(at: url)
        })
    }

    var url: URL { artifact.url }
    var format: NativeAudioFormat { artifact.format }
    var purpose: SpeechPurpose { artifact.purpose }
    func cleanupIfOwned() { ownership.cleanupIfOwned() }
}

struct OwnedAudioArtifact: Sendable {
    let artifact: AudioArtifact
    private let ownership: TemporaryArtifactOwnership

    init(artifact: AudioArtifact, cleanup: (@Sendable () -> Void)? = nil) {
        self.artifact = artifact
        let url = artifact.url
        self.ownership = TemporaryArtifactOwnership(cleanup: cleanup ?? {
            try? FileManager.default.removeItem(at: url)
        })
    }

    var url: URL { artifact.url }
    func cleanupIfOwned() { ownership.cleanupIfOwned() }

    /// Transfers the only cleanup responsibility to CacheFlight. From this
    /// point CacheFlight/PublishCommitGate owns deletion or publication.
    func transferToUnpublished() throws -> UnpublishedArtifact {
        try ownership.transfer()
        return UnpublishedArtifact(artifact: artifact)
    }
}

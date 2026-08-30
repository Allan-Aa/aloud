import Foundation

struct ProviderID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

extension ProviderID {
    static let minimax = ProviderID(rawValue: "minimax")
    static let openAI = ProviderID(rawValue: "openai")
    static let gemini = ProviderID(rawValue: "gemini")
    static let macOS = ProviderID(rawValue: "macos")
}

struct ModelID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

struct VoiceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

struct ContractVersion: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

struct CatalogRefreshID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID
}

struct SpeechRequestID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID
}

struct SessionGeneration: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: SessionGeneration, rhs: SessionGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct NormalizedRate: Codable, Hashable, Sendable {
    let version: String
    let value: Int

    init?(version: String, value: Int) {
        guard Self.isValid(value) else { return nil }
        self.version = version
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
        let value = try container.decode(Int.self, forKey: .value)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Normalized rate must be within -100...100."
            )
        }
        self.version = version
        self.value = value
    }

    private static func isValid(_ value: Int) -> Bool {
        (-100...100).contains(value)
    }
}

struct ProviderSelection: Codable, Hashable, Sendable {
    let providerID: ProviderID
    let modelID: ModelID
    let voiceID: VoiceID?
    let rate: NormalizedRate
}

struct CredentialEnvelope: Equatable, Sendable {
    let providerID: ProviderID
    let revision: UUID
    let secret: Data
}

enum ProviderCredential: Sendable {
    case apiKey(providerID: ProviderID, envelope: CredentialEnvelope)
    case none
}

enum ReadingOrigin: String, Codable, Hashable, Sendable {
    case speak
    case replay
}

enum SpeechPurpose: Hashable, Sendable {
    case reading(ReadingOrigin)
    case preview
}

enum ProviderAvailabilityKind: String, Codable, Hashable, Sendable {
    case available
    case experimental
    case disabled
    case deprecated
    case unknown
}

enum ProviderAvailabilityReason: String, Codable, Hashable, Sendable {
    case noQualifiedModel
    case wireContractUnverified
    case featureFlagDisabled
    case releaseApprovalRequired
    case evidenceMissing
    case explicitlyDisabled
    case deprecated
    case noEligibleLocalVoice
}

enum ProviderMaturity: String, Codable, Hashable, Sendable {
    case stable
    case preview
    case experimental
}

struct ProviderAvailability: Codable, Hashable, Sendable {
    let kind: ProviderAvailabilityKind
    let reason: ProviderAvailabilityReason?
    let maturity: ProviderMaturity
    let featureFlagName: String?
    let featureFlagEnabled: Bool?
    let providerContractVersion: ContractVersion
    let evidenceID: String?
}

enum ProviderConfiguration: String, Codable, Hashable, Sendable {
    case unconfigured
    case configured
    case invalidSelection
}

enum ProviderHealth: String, Codable, Hashable, Sendable {
    case unknown
    case verifying
    case recentSuccess
    case recoverableFailure
    case explicitRejected
}

enum SelectionValidation: String, Codable, Hashable, Sendable {
    case valid
    case invalid
    case unknown
}

struct OpenAIDisclosureAck: Codable, Hashable, Sendable {
    let policyVersion: Int
    let modelID: ModelID
    let voiceID: VoiceID

    func matches(policyVersion: Int, modelID: ModelID, voiceID: VoiceID) -> Bool {
        self.policyVersion == policyVersion && self.modelID == modelID && self.voiceID == voiceID
    }
}

struct FeatureFlags: Codable, Hashable, Sendable {
    var geminiExperimentalEnabled: Bool

    static let defaults = FeatureFlags(geminiExperimentalEnabled: false)
}

struct PrefsV1: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var defaultProviderID: ProviderID
    var selections: [ProviderID: ProviderSelection]
    var openAIDisclosureAck: OpenAIDisclosureAck?
    var featureFlags: FeatureFlags
    var playbackSpeed: Double
    var stripMarkdown: Bool
    var skipCode: Bool
    var mpvBin: String
    var ffmpegBin: String
    var cacheLimitMB: Int
    var cacheDays: Int
    var launchAtLogin: Bool
    var menuBarOnly: Bool
    var hotkeyChime: Bool
    var hkReadSelection: HotkeySpec
    var hkReadClipboard: HotkeySpec
    var hkTogglePause: HotkeySpec

    static let defaults = PrefsV1(
        schemaVersion: 1,
        defaultProviderID: .minimax,
        selections: [
            .minimax: ProviderSelection(
                providerID: .minimax,
                modelID: ModelID(rawValue: "speech-2.8-hd"),
                voiceID: VoiceID(rawValue: "Chinese (Mandarin)_Radio_Host|default"),
                rate: NormalizedRate(version: "rate-v1", value: 50)!
            )
        ],
        openAIDisclosureAck: nil,
        featureFlags: .defaults,
        playbackSpeed: 1.0,
        stripMarkdown: true,
        skipCode: true,
        mpvBin: "/opt/homebrew/bin/mpv",
        ffmpegBin: "/opt/homebrew/bin/ffmpeg",
        cacheLimitMB: 512,
        cacheDays: 14,
        launchAtLogin: false,
        menuBarOnly: false,
        hotkeyChime: true,
        hkReadSelection: .readSelection,
        hkReadClipboard: .readClipboard,
        hkTogglePause: .togglePause
    )
}

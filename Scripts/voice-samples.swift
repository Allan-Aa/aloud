#!/usr/bin/env swift
import CryptoKit
@preconcurrency import Foundation

private struct CatalogVoice: Codable {
    let number: Int
    let language: String
    let wireVoiceID: String
    let displayName: String
    let stableVoiceID: String
    let languageTag: String
    let phrase: String
}

private struct Catalog: Codable {
    let schemaVersion: Int
    let sourceURL: String
    let accountSourceURL: String?
    let retrievedAt: String
    let modelID: String
    let voices: [CatalogVoice]
}

private struct Manifest: Codable {
    struct Encoding: Codable { let container: String; let codec: String; let bitrateKbps: Int; let channels: Int }
    struct Entry: Codable {
        let providerID: String
        let modelID: String
        let generatedModelID: String
        let stableVoiceID: String
        let wireVoiceID: String
        let languageTag: String
        let fileName: String
    }
    let schemaVersion: Int
    let phraseVersion: String
    let encoding: Encoding
    let entries: [Entry]
}

private enum ScriptError: Error, CustomStringConvertible {
    case usage, invalidCatalog, changedApprovalBoundary(Int, Int), missingAPIKey
    case requestFailed(Int, String), invalidResponse, commandFailed(String)
    case billingCheckpointRequired, approvedSpendExceeded(Int)
    var description: String {
        switch self {
        case .usage: return "usage: voice-samples.swift prepare-catalog <markdown> | reconcile-account-catalog <json> | estimate | generate | validate"
        case .invalidCatalog: return "official voice catalog is malformed"
        case .changedApprovalBoundary(let voices, let characters): return "approval boundary changed: voices=\(voices) characters=\(characters)"
        case .missingAPIKey: return "MINIMAX_API_KEY is required; do not pass it as a command-line argument"
        case .requestFailed(let code, _): return "MiniMax request failed with HTTP \(code)"
        case .invalidResponse: return "MiniMax returned an invalid audio response"
        case .commandFailed(let command): return "command failed: \(command)"
        case .billingCheckpointRequired: return "partial assets require a trusted billing checkpoint"
        case .approvedSpendExceeded(let characters): return "approved spend boundary would be exceeded at \(characters) billed characters"
        }
    }
}

private let sourceURL = "https://platform.minimax.io/docs/faq/system-voice-id"
private let modelID = "speech-2.8-hd"
private let expectedVoices = 332
private let approvedCharacters = 3_995
private let approvedBilledCharacters = 14_100
private let pricePerMillionCharacters = 100.0
private let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
private let repository = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private let resourceDirectory = repository.appendingPathComponent("Sources/Aloud/Resources/VoiceSamples", isDirectory: true)
private let catalogURL = resourceDirectory.appendingPathComponent("catalog-v1.json")
private let manifestURL = resourceDirectory.appendingPathComponent("manifest.json")
private let generationStateURL = resourceDirectory.appendingPathComponent(".generation-state.json")

private struct GenerationState: Codable {
    var billedCharacters: Int
    var completedFileNames: Set<String>
}

private func stableID(wireID: String) -> String {
    switch wireID {
    case "Chinese (Mandarin)_Radio_Host": return "minimax.radio-host.default"
    case "Chinese (Mandarin)_Laid_BackGirl": return "minimax.laid-back-girl.default"
    default:
        let digest = SHA256.hash(data: Data("system\u{0}\(wireID)".utf8)).map { String(format: "%02x", $0) }.joined()
        return "minimax.dynamic.\(digest)"
    }
}

private func languageTag(_ language: String) -> String {
    [
        "English": "en-US", "Chinese (Mandarin)": "zh-CN", "Cantonese": "yue-HK",
        "Japanese": "ja-JP", "Korean": "ko-KR", "Spanish": "es-ES",
        "Portuguese": "pt-PT", "French": "fr-FR", "Indonesian": "id-ID",
        "German": "de-DE", "Russian": "ru-RU", "Italian": "it-IT",
        "Dutch": "nl-NL", "Vietnamese": "vi-VN", "Arabic": "ar-SA",
        "Turkish": "tr-TR", "Ukrainian": "uk-UA", "Thai": "th-TH",
        "Polish": "pl-PL", "Romanian": "ro-RO", "Greek": "el-GR",
        "Czech": "cs-CZ", "Finnish": "fi-FI", "Hindi": "hi-IN",
    ][language] ?? "zh-CN"
}

private func phrase(_ tag: String) -> String {
    switch tag.split(separator: "-").first.map(String.init) {
    case "ja": return "音声サンプルです。"
    case "ko": return "음성 샘플입니다."
    case "es": return "Muestra de voz."
    case "fr": return "Exemple de voix."
    case "de": return "Stimmprobe."
    case "pt": return "Amostra de voz."
    case "it": return "Esempio di voce."
    case "ru": return "Образец голоса."
    case "ar": return "عينة صوتية."
    case "tr": return "Ses örneği."
    case "vi": return "Mẫu giọng nói."
    case "id": return "Contoh suara."
    case "th": return "ตัวอย่างเสียง"
    case "nl": return "Stemvoorbeeld."
    case "uk": return "Зразок голосу."
    case "pl": return "Próbka głosu."
    case "ro": return "Mostră de voce."
    case "el": return "Δείγμα φωνής."
    case "cs": return "Ukázka hlasu."
    case "fi": return "Ääninäyte."
    case "hi": return "आवाज़ का नमूना।"
    case "yue": return "聲音樣本。"
    case "en": return "Voice sample."
    default: return "声音样本。"
    }
}

private func prepareCatalog(markdownURL: URL) throws {
    let text = try String(contentsOf: markdownURL, encoding: .utf8)
    var voices: [CatalogVoice] = []
    for line in text.split(separator: "\n").map(String.init) where line.range(of: #"^\|\s*\d+\s*\|"#, options: .regularExpression) != nil {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\_", with: "_")
        }
        guard fields.count >= 6, let number = Int(fields[1]) else { throw ScriptError.invalidCatalog }
        let tag = languageTag(fields[2])
        voices.append(CatalogVoice(
            number: number, language: fields[2], wireVoiceID: fields[3], displayName: fields[4],
            stableVoiceID: stableID(wireID: fields[3]), languageTag: tag, phrase: phrase(tag)
        ))
    }
    guard voices.count == expectedVoices, Set(voices.map(\.wireVoiceID)).count == voices.count else { throw ScriptError.invalidCatalog }
    let catalog = Catalog(
        schemaVersion: 1, sourceURL: sourceURL, accountSourceURL: nil,
        retrievedAt: ISO8601DateFormatter().string(from: Date()), modelID: modelID, voices: voices
    )
    try writeJSON(catalog, to: catalogURL)
}

private func reconcileAccountCatalog(responseURL: URL) throws {
    struct Response: Decodable {
        struct Voice: Decodable {
            let voiceID: String
            let voiceName: String?
            private enum CodingKeys: String, CodingKey { case voiceID = "voice_id"; case voiceName = "voice_name" }
        }
        struct Base: Decodable {
            let statusCode: Int
            private enum CodingKeys: String, CodingKey { case statusCode = "status_code" }
        }
        let systemVoices: [Voice]
        let base: Base
        private enum CodingKeys: String, CodingKey { case systemVoices = "system_voice"; case base = "base_resp" }
    }
    let catalog = try loadCatalog()
    let response = try JSONDecoder().decode(Response.self, from: Data(contentsOf: responseURL))
    guard response.base.statusCode == 0, response.systemVoices.count == expectedVoices else { throw ScriptError.invalidCatalog }
    func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: " (", with: "(")
    }
    let keyed = Dictionary(grouping: response.systemVoices, by: { normalized($0.voiceID) })
    guard keyed.values.allSatisfy({ $0.count == 1 }) else { throw ScriptError.invalidCatalog }
    let voices = try catalog.voices.map { voice -> CatalogVoice in
        guard let current = keyed[normalized(voice.wireVoiceID)]?.first else { throw ScriptError.invalidCatalog }
        let name = current.voiceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CatalogVoice(
            number: voice.number, language: voice.language, wireVoiceID: current.voiceID,
            displayName: name?.isEmpty == false ? name! : voice.displayName,
            stableVoiceID: stableID(wireID: current.voiceID), languageTag: voice.languageTag, phrase: voice.phrase
        )
    }
    try writeJSON(Catalog(
        schemaVersion: catalog.schemaVersion, sourceURL: catalog.sourceURL,
        accountSourceURL: "https://api.minimax.io/v1/get_voice",
        retrievedAt: ISO8601DateFormatter().string(from: Date()), modelID: catalog.modelID, voices: voices
    ), to: catalogURL)
}

private func loadCatalog() throws -> Catalog {
    try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
}

private func verifyBoundary(_ catalog: Catalog) throws -> Int {
    let characters = catalog.voices.reduce(0) { $0 + $1.phrase.count }
    guard catalog.voices.count == expectedVoices, characters == approvedCharacters else {
        throw ScriptError.changedApprovalBoundary(catalog.voices.count, characters)
    }
    return characters
}

private func estimate(_ catalog: Catalog) throws {
    let characters = try verifyBoundary(catalog)
    let dollars = Double(characters) * pricePerMillionCharacters / 1_000_000
    print("voices=\(catalog.voices.count) characters=\(characters) paygo_usd=\(String(format: "%.4f", dollars))")
}

private func generate(_ catalog: Catalog) async throws {
    _ = try verifyBoundary(catalog)
    guard let apiKey = ProcessInfo.processInfo.environment["MINIMAX_API_KEY"], !apiKey.isEmpty else { throw ScriptError.missingAPIKey }
    let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw ScriptError.commandFailed("ffmpeg") }
    try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
    let existingNames = Set(catalog.voices.compactMap { voice -> String? in
        let name = sampleFileName(voice.stableVoiceID)
        return isNonempty(resourceDirectory.appendingPathComponent(name)) ? name : nil
    })
    let allAssetsAlreadyExist = existingNames.count == catalog.voices.count
    var state: GenerationState
    if let data = try? Data(contentsOf: generationStateURL), let saved = try? JSONDecoder().decode(GenerationState.self, from: data) {
        state = saved
    } else if allAssetsAlreadyExist {
        state = GenerationState(billedCharacters: 0, completedFileNames: existingNames)
    } else if existingNames.isEmpty {
        state = GenerationState(billedCharacters: 0, completedFileNames: [])
    } else {
        throw ScriptError.billingCheckpointRequired
    }
    guard state.completedFileNames.isSubset(of: existingNames) else { throw ScriptError.invalidCatalog }
    var entries: [Manifest.Entry] = []
    for (index, voice) in catalog.voices.enumerated() {
        let name = sampleFileName(voice.stableVoiceID)
        let destination = resourceDirectory.appendingPathComponent(name)
        let generationModelID = modelID
        entries.append(.init(
            providerID: "minimax", modelID: modelID, generatedModelID: generationModelID, stableVoiceID: voice.stableVoiceID,
            wireVoiceID: voice.wireVoiceID, languageTag: voice.languageTag, fileName: name
        ))
        if isNonempty(destination) {
            guard state.completedFileNames.contains(name) || allAssetsAlreadyExist else { throw ScriptError.billingCheckpointRequired }
            continue
        }
        let projectedUpper = state.billedCharacters + voice.phrase.utf8.count
        guard projectedUpper <= approvedBilledCharacters else { throw ScriptError.approvedSpendExceeded(projectedUpper) }
        print("request=\(index + 1)/\(catalog.voices.count) billed_before=\(state.billedCharacters) call_upper=\(projectedUpper) approved=\(approvedBilledCharacters) projected_usd=\(String(format: "%.4f", Double(projectedUpper) * pricePerMillionCharacters / 1_000_000))")
        let mp3 = resourceDirectory.appendingPathComponent(".voice-sample-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: mp3) }
        let used = try await requestAudio(voice: voice, modelID: generationModelID, apiKey: apiKey, destination: mp3)
        state.billedCharacters += used
        try writeJSON(state, to: generationStateURL)
        try transcode(ffmpeg: ffmpeg, source: mp3, destination: destination)
        state.completedFileNames.insert(name)
        try writeJSON(state, to: generationStateURL)
    }
    let manifest = Manifest(
        schemaVersion: 1, phraseVersion: "bundled-system-voice-sample-v1",
        encoding: .init(container: "m4a", codec: "aac-lc", bitrateKbps: 64, channels: 1),
        entries: entries
    )
    try writeJSON(manifest, to: manifestURL)
    try validateAssets(catalog: catalog, manifest: manifest)
    try? FileManager.default.removeItem(at: generationStateURL)
}

private func requestAudio(voice: CatalogVoice, modelID: String, apiKey: String, destination: URL) async throws -> Int {
    let payload: [String: Any] = [
        "model": modelID, "text": voice.phrase, "stream": false, "output_format": "hex",
        "language_boost": voice.languageTag.hasPrefix("yue-") ? "Chinese,Yue" : "auto",
        "voice_setting": ["voice_id": voice.wireVoiceID, "speed": 1, "vol": 1, "pitch": 0],
        "audio_setting": ["sample_rate": 32_000, "bitrate": 64_000, "format": "mp3", "channel": 1],
    ]
    var request = URLRequest(url: URL(string: "https://api.minimax.io/v1/t2a_v2")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw ScriptError.requestFailed(status, "content-free") }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let base = object["base_resp"] as? [String: Any] else { throw ScriptError.invalidResponse }
    let serviceCode = (base["status_code"] as? NSNumber)?.intValue ?? -1
    guard serviceCode == 0 else { throw ScriptError.requestFailed(serviceCode, "content-free") }
    guard let audio = (object["data"] as? [String: Any])?["audio"] as? String,
          let bytes = Data(hex: audio), !bytes.isEmpty else { throw ScriptError.invalidResponse }
    try bytes.write(to: destination, options: .atomic)
    let usage = (object["extra_info"] as? [String: Any])?["usage_characters"] as? Int
    return usage ?? voice.phrase.count
}

private func sampleFileName(_ stableVoiceID: String) -> String {
    SHA256.hash(data: Data(stableVoiceID.utf8)).map { String(format: "%02x", $0) }.joined() + ".m4a"
}

private func transcode(ffmpeg: URL, source: URL, destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".sample-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-t", "4", "-vn", "-ac", "1", "-c:a", "aac", "-b:a", "64k", temporary.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0, isNonempty(temporary) else { throw ScriptError.commandFailed("ffmpeg") }
    try FileManager.default.moveItem(at: temporary, to: destination)
}

private func validateAssets(catalog: Catalog, manifest: Manifest) throws {
    guard manifest.entries.count == catalog.voices.count,
          Set(manifest.entries.map(\.stableVoiceID)).count == catalog.voices.count,
          manifest.entries.allSatisfy({ isNonempty(resourceDirectory.appendingPathComponent($0.fileName)) }) else {
        throw ScriptError.invalidCatalog
    }
}

private func validate() throws {
    let catalog = try loadCatalog()
    _ = try verifyBoundary(catalog)
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    try validateAssets(catalog: catalog, manifest: manifest)
    print("voice samples validated: voices=\(manifest.entries.count)")
}

private func isNonempty(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).map { $0.isRegularFile == true && ($0.fileSize ?? 0) > 0 } ?? false
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(); data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte); index = next
        }
        self = data
    }
}

do {
    guard CommandLine.arguments.count >= 2 else { throw ScriptError.usage }
    switch CommandLine.arguments[1] {
    case "prepare-catalog":
        guard CommandLine.arguments.count == 3 else { throw ScriptError.usage }
        try prepareCatalog(markdownURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        try estimate(loadCatalog())
    case "reconcile-account-catalog":
        guard CommandLine.arguments.count == 3 else { throw ScriptError.usage }
        try reconcileAccountCatalog(responseURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        try estimate(loadCatalog())
    case "estimate": try estimate(loadCatalog())
    case "generate": try await generate(loadCatalog())
    case "validate": try validate()
    default: throw ScriptError.usage
    }
} catch {
    FileHandle.standardError.write(Data("voice samples: \(error)\n".utf8))
    exit(1)
}

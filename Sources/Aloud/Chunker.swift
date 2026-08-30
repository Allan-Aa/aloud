import Foundation

/// Legacy bridge for the live MiniMax adapter. New providers own splitting through `VoiceProvider.split`.
enum Chunker {
    /// Kept only until Task 15 replaces the live adapter. It uses grapheme count rather than language weights.
    static func split(_ text: String, target: Int = 120) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard target > 0 else { return [trimmed] }
        var result: [String] = [], current = ""
        for grapheme in trimmed {
            if current.count == target { result.append(current); current = "" }
            current.append(grapheme)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Legacy adapter retained until Task 15 removes the live MiniMax path. New
/// audio is canonical WAV and never concatenated as encoded MP3.
enum AudioJoin {
    static func concat(_ parts: [URL], to dest: URL, ffmpeg: String) throws {
        _ = ffmpeg
        _ = try WAVConcatenator.concatenate(parts, to: dest, purpose: .reading(.speak))
    }
}

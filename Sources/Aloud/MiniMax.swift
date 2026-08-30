import Foundation

struct VoiceOption: Identifiable, Hashable {
    var id: String { value }
    let value: String          // minimax:<voice_id>|<emotion>
    let zh: String
    let en: String
    func label(_ l: Lang) -> String { l == .zh ? zh : en }
}

enum Voices {
    static let all: [VoiceOption] = [
        .init(value: "minimax:Chinese (Mandarin)_Radio_Host|default",
              zh: "电台主持", en: "Radio Host"),
        .init(value: "minimax:Chinese (Mandarin)_Laid_BackGirl|default",
              zh: "松弛女孩", en: "Laid-back Girl"),
    ]

    /// Kept only so existing prefs/history can still be identified and shown
    /// with a useful disabled-selection message. These entries are not exposed
    /// by Settings and cannot reach provider transport.
    private static let migrationOnly: [VoiceOption] = [
        .init(value: "minimax:Chinese (Mandarin)_Radio_Host|fluent",
              zh: "电台主持 · 流畅", en: "Radio Host · fluent"),
        .init(value: "minimax:Chinese (Mandarin)_Laid_BackGirl|fluent",
              zh: "松弛女孩 · 流畅", en: "Laid-back Girl · fluent"),
    ]

    static func label(_ value: String, _ l: Lang) -> String {
        (all + migrationOnly).first { $0.value == value }?.label(l) ?? value
    }

    /// "minimax:<id>|<emotion>" → (id, emotion?)。裸值当作 edge-tts 音色。
    static func parse(_ value: String) -> (id: String, emotion: String?)? {
        guard value.hasPrefix("minimax:") else { return nil }
        let body = String(value.dropFirst("minimax:".count))
        let parts = body.split(separator: "|", maxSplits: 1).map(String.init)
        let emotion = parts.count > 1 && parts[1] != "default" ? parts[1] : nil
        return (parts[0], emotion)
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }
}

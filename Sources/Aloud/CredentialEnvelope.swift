import CryptoKit
import Foundation

enum CredentialEnvelopeError: Error, Equatable, Sendable { case malformed, digestMismatch, providerMismatch, empty }

enum CredentialEnvelopeCodec {
    private static let magic = Data("ALOUDAK1".utf8)
    static func encode(_ value: CredentialEnvelope) throws -> Data {
        guard !value.secret.isEmpty, value.secret.count <= 4096 else { throw CredentialEnvelopeError.malformed }
        let provider = Data(value.providerID.rawValue.utf8); guard !provider.isEmpty, provider.count <= Int(UInt16.max) else { throw CredentialEnvelopeError.malformed }
        var body = magic; body += u16(1); body += u16(provider.count); body += u16(16); body += u16(value.secret.count); body += provider
        var uuid = value.revision.uuid; withUnsafeBytes(of: &uuid) { body += Data($0) }; body += value.secret
        return body + Data(SHA256.hash(data: body))
    }
    static func decode(_ data: Data, expectedProviderID: ProviderID) throws -> CredentialEnvelope {
        guard data.count >= 8 + 8 + 32 else { throw CredentialEnvelopeError.malformed }
        let body = data.dropLast(32), digest = data.suffix(32); guard Data(SHA256.hash(data: body)) == digest else { throw CredentialEnvelopeError.digestMismatch }
        var i = 0; func take(_ n: Int) throws -> Data { guard n >= 0, i + n <= body.count else { throw CredentialEnvelopeError.malformed }; defer { i += n }; return Data(body[body.index(body.startIndex, offsetBy: i)..<body.index(body.startIndex, offsetBy: i + n)]) }
        guard try take(8) == magic, try read16(&i, body) == 1 else { throw CredentialEnvelopeError.malformed }
        let pLen = Int(try read16(&i, body)), rLen = Int(try read16(&i, body)), sLen = Int(try read16(&i, body))
        let expectedProvider = Data(expectedProviderID.rawValue.utf8)
        guard !expectedProvider.isEmpty, pLen > 0, rLen == 16, sLen > 0, sLen <= 4096 else { throw CredentialEnvelopeError.malformed }
        let p = try take(pLen)
        guard p == expectedProvider else { throw CredentialEnvelopeError.providerMismatch }
        let raw = try take(16); guard raw.count == 16 else { throw CredentialEnvelopeError.malformed }; let bytes = [UInt8](raw); let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        let secret = try take(sLen); guard i == body.count else { throw CredentialEnvelopeError.malformed }
        return CredentialEnvelope(providerID: expectedProviderID, revision: id, secret: secret)
    }
    private static func u16(_ n: Int) -> Data { Data([UInt8((n >> 8) & 255), UInt8(n & 255)]) }
    private static func read16(_ i: inout Int, _ data: Data.SubSequence) throws -> UInt16 { guard i + 2 <= data.count else { throw CredentialEnvelopeError.malformed }; let a = data[data.index(data.startIndex, offsetBy: i)], b = data[data.index(data.startIndex, offsetBy: i + 1)]; i += 2; return UInt16(a) << 8 | UInt16(b) }
}

enum SecretIngressV1 {
    static func normalize(_ input: String) throws -> Data {
        let allowed: Set<UnicodeScalar> = [" ", "\t", "\n", "\r", "\u{00A0}", "\u{202F}", "\u{3000}"]
        let values = Array(input.unicodeScalars); var start = 0, end = values.count
        while start < end && allowed.contains(values[start]) { start += 1 }; while end > start && allowed.contains(values[end - 1]) { end -= 1 }
        let result = String(String.UnicodeScalarView(values[start..<end])); guard !result.isEmpty else { throw CredentialEnvelopeError.empty }; return Data(result.utf8)
    }
}

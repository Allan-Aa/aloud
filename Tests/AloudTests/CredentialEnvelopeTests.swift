import CryptoKit
import XCTest
@testable import Aloud

final class CredentialEnvelopeTests: XCTestCase {
    func testEnvelopeVectorMatchesAppendixA() throws {
        let e = CredentialEnvelope(providerID: .openAI, revision: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!, secret: Data("abc".utf8))
        XCTAssertEqual(try CredentialEnvelopeCodec.encode(e).map { String(format: "%02x", $0) }.joined(), "414c4f5544414b3100010006001000036f70656e616900112233445566778899aabbccddeeff61626347288b01f599be25b09ee0039d0434a7cc28a1f05fde92d85bb14e41180b6c08")
    }
    func testEveryTruncatedPrefixIsRejected() throws {
        let data = try CredentialEnvelopeCodec.encode(CredentialEnvelope(providerID: .openAI, revision: UUID(), secret: Data("abc".utf8)))
        for n in 0..<data.count { XCTAssertThrowsError(try CredentialEnvelopeCodec.decode(Data(data.prefix(n)), expectedProviderID: .openAI)) }
    }
    func testTamperAndProviderMismatchAreRejected() throws {
        let data = try CredentialEnvelopeCodec.encode(CredentialEnvelope(providerID: .openAI, revision: UUID(), secret: Data("abc".utf8)))
        for index in [0, 8, 10, 12, 20, data.count - 1] { var copy = data; copy[index] ^= 1; XCTAssertThrowsError(try CredentialEnvelopeCodec.decode(copy, expectedProviderID: .openAI)) }
        XCTAssertThrowsError(try CredentialEnvelopeCodec.decode(data, expectedProviderID: .gemini))
        XCTAssertThrowsError(try CredentialEnvelopeCodec.decode(Data("{\"key\":\"old\"}".utf8), expectedProviderID: .openAI))
    }

    func testEveryEnvelopeByteMutationIsRejectedByDigest() throws {
        let data = try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: UUID(), secret: Data("abc".utf8)))
        for index in data.indices {
            var copy = data
            copy[index] ^= 0x01
            XCTAssertThrowsError(try CredentialEnvelopeCodec.decode(copy, expectedProviderID: .openAI), "byte \\(index)")
        }
    }

    func testRecomputedDigestStillRejectsMalformedStructureHeaders() throws {
        let valid = try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: UUID(), secret: Data("abc".utf8)))
        let body = Data(valid.dropLast(32))
        let cases: [(Data, ProviderID)] = [
            (replacing(body, at: 8, with: [0, 2]), .openAI), // unknown version
            (replacing(body, at: 10, with: [0, 0]), .openAI), // empty provider
            (replacing(body, at: 12, with: [0, 15]), .openAI), // revision length
            (replacing(body, at: 14, with: [0, 0]), .openAI), // empty secret
            (replacing(body, at: 14, with: [0x10, 0x01]), .openAI), // secret 4097
            (replacing(body, at: 16, with: [0xff]), .openAI), // invalid provider UTF-8
            (body + Data([0]), .openAI), // trailing body byte
        ]
        for (malformedBody, provider) in cases {
            XCTAssertThrowsError(try CredentialEnvelopeCodec.decode(envelope(withDigestFor: malformedBody), expectedProviderID: provider))
        }
    }

    func testProviderLengthThatDiffersFromExpectedIsProviderMismatchWhenBytesArePresent() throws {
        let valid = try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: UUID(), secret: Data("abc".utf8)))
        let malformed = envelope(withDigestFor: replacing(Data(valid.dropLast(32)), at: 10, with: [0, 5]))
        XCTAssertEqual(thrownEnvelopeError { _ = try CredentialEnvelopeCodec.decode(malformed, expectedProviderID: .openAI) }, .providerMismatch)
    }

    func testErrorsRemainClosedAndNeverIncludeSecretMaterial() {
        let canary = "secret-canary-should-not-appear"
        for error in [CredentialEnvelopeError.malformed, .digestMismatch, .providerMismatch, .empty] {
            XCTAssertFalse(String(describing: error).contains(canary))
        }
    }

    func testRecomputedDigestRejectsProviderMismatchAndNonEnvelopeInputs() throws {
        let data = try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: UUID(), secret: Data("abc".utf8)))
        XCTAssertThrowsError(try CredentialEnvelopeCodec.decode(data, expectedProviderID: .gemini))
        for raw in [Data("{\"key\":\"old\"}".utf8), Data("sk-raw-old-key".utf8), Data([0, 1, 2, 3])] {
            XCTAssertThrowsError(try CredentialEnvelopeCodec.decode(raw, expectedProviderID: .openAI))
        }
    }
    func testRepeatedDecodePreservesNetworkOrderRevision() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!, data = try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: id, secret: Data("abc".utf8)))
        XCTAssertEqual(try CredentialEnvelopeCodec.decode(data, expectedProviderID: .openAI).revision, id)
    }
    func testDifferentLengthProviderIDsAreProviderMismatchWhenStructureIsValid() throws {
        let minimax = try CredentialEnvelopeCodec.encode(.init(providerID: .minimax, revision: UUID(), secret: Data("abc".utf8)))
        XCTAssertEqual(thrownEnvelopeError { _ = try CredentialEnvelopeCodec.decode(minimax, expectedProviderID: .openAI) }, .providerMismatch)
        XCTAssertEqual(thrownEnvelopeError { _ = try CredentialEnvelopeCodec.decode(minimax, expectedProviderID: .gemini) }, .providerMismatch)
    }
    func testEmptyProviderAndSecretBoundsAreRejectedWhileMaximumSecretRoundTrips() throws {
        XCTAssertThrowsError(try CredentialEnvelopeCodec.encode(.init(providerID: ProviderID(rawValue: ""), revision: UUID(), secret: Data("x".utf8))))
        XCTAssertThrowsError(try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: UUID(), secret: Data())))
        XCTAssertThrowsError(try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: UUID(), secret: Data(repeating: 1, count: 4097))))
        let max = Data(repeating: 2, count: 4096), encoded = try CredentialEnvelopeCodec.encode(.init(providerID: .openAI, revision: UUID(), secret: max))
        XCTAssertEqual(try CredentialEnvelopeCodec.decode(encoded, expectedProviderID: .openAI).secret, max)
    }
}

private func replacing(_ data: Data, at offset: Int, with bytes: [UInt8]) -> Data {
    var result = data
    result.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    return result
}

private func envelope(withDigestFor body: Data) -> Data {
    body + Data(SHA256.hash(data: body))
}

private func thrownEnvelopeError(_ operation: () throws -> Void) -> CredentialEnvelopeError? {
    do { try operation(); return nil }
    catch let error as CredentialEnvelopeError { return error }
    catch { return nil }
}

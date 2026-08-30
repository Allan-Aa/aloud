import XCTest
@testable import Aloud

final class SecretIngressTests: XCTestCase {
    func testTrimsOnlyAllowedBoundaryScalarsAndPreservesInterior() throws {
        XCTAssertEqual(try SecretIngressV1.normalize(" \t\n\r\u{00A0}\u{202F}\u{3000}a b\u{3000}").utf8String, "a b")
    }
    func testRejectsEmptyAndDoesNotTrimZeroWidthBomOrNul() {
        XCTAssertThrowsError(try SecretIngressV1.normalize(" \n\t\r\u{00A0}\u{202F}\u{3000}"))
        XCTAssertEqual(try? SecretIngressV1.normalize("\u{200B}x\u{FEFF}\0").utf8String, "\u{200B}x\u{FEFF}\0")
    }

    func testAppendixATrimVectorsAreByteExact() throws {
        let vectors: [(String, String?)] = [
            ("2061626320", "616263"), ("0961626309", "616263"),
            ("0d6162630d", "616263"), ("0a6162630a", "616263"),
            ("0d0a6162630d0a", "616263"), ("c2a0616263c2a0", "616263"),
            ("e280af616263e280af", "616263"), ("e38080616263e38080", "616263"),
            ("20090d0a0d0ac2a0e280afe38080616263e38080e280afc2a00d0a0920", "616263"),
            ("2009c2a0e280afe38080", nil),
            ("61c2a062e280af63e3808064", "61c2a062e280af63e3808064"),
            ("e2808b616263e2808b", "e2808b616263e2808b"),
            ("efbbbf616263efbbbf", "efbbbf616263efbbbf"),
            ("0061626300", "0061626300"),
        ]
        for (inputHex, outputHex) in vectors {
            let input = try XCTUnwrap(Data(hex: inputHex))
            let string = String(decoding: input, as: UTF8.self)
            if let outputHex {
                XCTAssertEqual(try SecretIngressV1.normalize(string), Data(hex: outputHex), inputHex)
            } else {
                XCTAssertThrowsError(try SecretIngressV1.normalize(string))
            }
        }
    }
}
private extension Data { var utf8String: String { String(decoding: self, as: UTF8.self) } }

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        self.init(bytes)
    }
}

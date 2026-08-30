import Foundation
import XCTest
@testable import Aloud

final class TestHarnessTests: XCTestCase {
    func testFixtureLoaderReadsLegacyPrefs() throws {
        let data = try Fixture.data(named: "legacy-prefs-v0.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["rate"] as? Int, 50)
        XCTAssertEqual(object["menuBarOnly"] as? Bool, true)
    }
}

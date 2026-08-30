import XCTest
@testable import Aloud

final class PrefsMigrationTests: XCTestCase {
    func testLegacyMigrationPreservesEveryIndependentlyDecodableField() throws {
        let source = try Fixture.data(named: "legacy-prefs-v0.json")
        let expected = try PrefsDecoder.decodeByVersion(source)

        let corruptions: [(String, Any)] = [
            ("voice", 7), ("rate", "fast"), ("playbackSpeed", "fast"), ("stripMarkdown", 7),
            ("skipCode", "no"), ("mpvBin", 7), ("ffmpegBin", 7), ("cacheLimitMB", "many"),
            ("cacheDays", "forever"), ("launchAtLogin", 1), ("menuBarOnly", "yes"),
            ("hotkeyChime", 1), ("hkReadSelection", "bad"), ("hkReadClipboard", "bad"),
            ("hkTogglePause", "bad")
        ]

        for (field, corruptValue) in corruptions {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
            object[field] = corruptValue
            let migrated = try PrefsDecoder.decodeByVersion(JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(migrated.value(for: field), PrefsV1.defaults.value(for: field), "\(field) defaults")
            for preservedField in PrefsV1.legacyFieldNames where preservedField != field {
                XCTAssertEqual(migrated.value(for: preservedField), expected.value(for: preservedField), "\(field) must not discard \(preservedField)")
            }
        }

        for field in PrefsV1.legacyFieldNames {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
            object.removeValue(forKey: field)
            let migrated = try PrefsDecoder.decodeByVersion(JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(migrated.value(for: field), PrefsV1.defaults.value(for: field), "\(field) deletion defaults")
            for preservedField in PrefsV1.legacyFieldNames where preservedField != field {
                XCTAssertEqual(migrated.value(for: preservedField), expected.value(for: preservedField), "deleting \(field) must not discard \(preservedField)")
            }
        }
    }

    func testLegacyMigrationCreatesStableMiniMaxIdentityAndRateVersion() throws {
        let prefs = try PrefsDecoder.decodeByVersion(Fixture.data(named: "legacy-prefs-v0.json"))
        let selection = try XCTUnwrap(prefs.selections[.minimax])

        XCTAssertEqual(prefs.schemaVersion, 1)
        XCTAssertEqual(prefs.defaultProviderID, .minimax)
        XCTAssertEqual(selection.modelID, ModelID(rawValue: "speech-2.8-hd"))
        XCTAssertEqual(selection.voiceID, VoiceID(rawValue: "Chinese (Mandarin)_Radio_Host|fluent"))
        XCTAssertEqual(selection.rate, NormalizedRate(version: "legacy-minimax-rate-v1", value: 50))
    }

    func testUnknownSchemaIsRejected() {
        XCTAssertThrowsError(try PrefsDecoder.decodeByVersion(Data(#"{"schemaVersion":99}"#.utf8)))
    }

    func testSchemaVersionAcceptsOnlyJSONIntegerOne() throws {
        let valid = try JSONEncoder().encode(PrefsV1.defaults)
        XCTAssertNoThrow(try PrefsDecoder.decodeByVersion(valid))

        for value in ["true", "false", "1.0", "1.5", "\"1\"", "null", "99"] {
            let data = Data("{\"schemaVersion\":\(value)}".utf8)
            XCTAssertThrowsError(try PrefsDecoder.decodeByVersion(data), "schemaVersion=\(value)")
        }
    }
}

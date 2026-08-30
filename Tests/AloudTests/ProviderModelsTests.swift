import XCTest
@testable import Aloud

private func assertSendable<T: Sendable>(_ value: T) {}

final class ProviderModelsTests: XCTestCase {
    func testPrefsV1DefaultsToMiniMaxWithoutLosingLegacyControls() throws {
        let prefs = PrefsV1.defaults

        XCTAssertEqual(prefs.schemaVersion, 1)
        XCTAssertEqual(prefs.defaultProviderID, .minimax)
        XCTAssertEqual(prefs.selections[.minimax]?.modelID, ModelID(rawValue: "speech-2.8-hd"))
        XCTAssertEqual(prefs.playbackSpeed, 1.0)
        XCTAssertEqual(prefs.cacheLimitMB, 512)
        XCTAssertEqual(prefs.cacheDays, 14)
        XCTAssertTrue(prefs.stripMarkdown)
        XCTAssertTrue(prefs.skipCode)
        XCTAssertEqual(prefs.mpvBin, "/opt/homebrew/bin/mpv")
        XCTAssertEqual(prefs.ffmpegBin, "/opt/homebrew/bin/ffmpeg")
        XCTAssertEqual(prefs.hkReadSelection, .readSelection)
        XCTAssertEqual(prefs.hkReadClipboard, .readClipboard)
        XCTAssertEqual(prefs.hkTogglePause, .togglePause)
    }

    func testDisclosureAckMatchesExactPolicyModelVoiceTuple() {
        let ack = OpenAIDisclosureAck(
            policyVersion: 1,
            modelID: ModelID(rawValue: "gpt-4o-mini-tts"),
            voiceID: VoiceID(rawValue: "alloy")
        )

        XCTAssertTrue(ack.matches(
            policyVersion: 1,
            modelID: ModelID(rawValue: "gpt-4o-mini-tts"),
            voiceID: VoiceID(rawValue: "alloy")
        ))
        XCTAssertFalse(ack.matches(
            policyVersion: 2,
            modelID: ModelID(rawValue: "gpt-4o-mini-tts"),
            voiceID: VoiceID(rawValue: "alloy")
        ))
    }

    func testNormalizedRateV1AcceptsOnlyInclusiveRange() {
        let cases: [(Int, Bool)] = [(-101, false), (-100, true), (0, true), (100, true), (101, false)]

        for (value, shouldSucceed) in cases {
            XCTAssertEqual(
                NormalizedRate(version: "rate-v1", value: value) != nil,
                shouldSucceed,
                "rate \(value)"
            )
        }
    }

    func testNormalizedRateDecodingRejectsOutOfRangeValues() throws {
        let cases: [(Int, Bool)] = [(-101, false), (-100, true), (100, true), (101, false)]

        for (value, shouldDecode) in cases {
            let data = Data(#"{"version":"rate-v1","value":\#(value)}"#.utf8)
            if shouldDecode {
                XCTAssertEqual(try JSONDecoder().decode(NormalizedRate.self, from: data).value, value)
            } else {
                XCTAssertThrowsError(try JSONDecoder().decode(NormalizedRate.self, from: data)) { error in
                    guard case DecodingError.dataCorrupted = error else {
                        return XCTFail("Expected dataCorrupted, got \(error)")
                    }
                }
            }
        }
    }

    func testPrefsDecodingRejectsNestedOutOfRangeRate() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PrefsV1.defaults)) as? [String: Any])
        var selections = try XCTUnwrap(object["selections"] as? [Any])
        var minimax = try XCTUnwrap(selections[1] as? [String: Any])
        minimax["rate"] = ["version": "rate-v1", "value": 101]
        selections[1] = minimax
        object["selections"] = selections

        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(PrefsV1.self, from: data)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testPrefsV1IsSendable() {
        assertSendable(PrefsV1.defaults)
    }

    func testPrefsEncodingContainsOnlyAllowedConfigurationKeys() throws {
        let ack = OpenAIDisclosureAck(
            policyVersion: 1,
            modelID: ModelID(rawValue: "gpt-4o-mini-tts"),
            voiceID: VoiceID(rawValue: "alloy")
        )
        var prefs = PrefsV1.defaults
        prefs.openAIDisclosureAck = ack

        let data = try JSONEncoder().encode(prefs)
        let object = try JSONSerialization.jsonObject(with: data)
        let keys = recursiveKeys(in: object)
        let allowed: Set<String> = [
            "schemaVersion", "defaultProviderID", "selections", "minimax", "providerID", "modelID", "voiceID",
            "rate", "version", "value", "featureFlags", "geminiExperimentalEnabled", "playbackSpeed", "stripMarkdown",
            "skipCode", "mpvBin", "ffmpegBin", "cacheLimitMB", "cacheDays", "launchAtLogin", "menuBarOnly",
            "hotkeyChime", "hkReadSelection", "hkReadClipboard", "hkTogglePause", "keyCode", "modifiers",
            "openAIDisclosureAck", "policyVersion"
        ]
        let forbidden: Set<String> = ["apiKey", "authorization", "health", "preview", "rawResponse", "header", "secret"]

        XCTAssertTrue(keys.isSubset(of: allowed), "Unexpected encoded keys: \(keys.subtracting(allowed))")
        XCTAssertTrue(keys.isDisjoint(with: forbidden), "Forbidden encoded keys: \(keys.intersection(forbidden))")
        XCTAssertTrue(keys.isSuperset(of: ["openAIDisclosureAck", "policyVersion", "modelID", "voiceID"]))
        XCTAssertEqual(try JSONDecoder().decode(PrefsV1.self, from: data).openAIDisclosureAck, ack)
    }

    private func recursiveKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { keys, pair in
                keys.formUnion(recursiveKeys(in: pair.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { keys, item in
                keys.formUnion(recursiveKeys(in: item))
            }
        }
        return []
    }
}

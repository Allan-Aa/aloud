import XCTest
@testable import Aloud

final class OpenAIDisclosureTests: XCTestCase {
    func testUnmatchedPolicyModelOrVoiceBlocksUntilExplicitConfirmation() {
        let model = ModelID(rawValue: "tts-1")
        let voice = VoiceID(rawValue: "openai.alloy")
        let exact = OpenAIDisclosureAck(policyVersion: OpenAIDisclosurePolicy.version, modelID: model, voiceID: voice)
        let mismatches: [OpenAIDisclosureAck?] = [
            nil,
            OpenAIDisclosureAck(policyVersion: OpenAIDisclosurePolicy.version + 1, modelID: model, voiceID: voice),
            OpenAIDisclosureAck(policyVersion: OpenAIDisclosurePolicy.version, modelID: ModelID(rawValue: "tts-1-hd"), voiceID: voice),
            OpenAIDisclosureAck(policyVersion: OpenAIDisclosurePolicy.version, modelID: model, voiceID: VoiceID(rawValue: "openai.nova")),
        ]
        for ack in mismatches {
            XCTAssertTrue(OpenAIDisclosureGate.evaluate(modelID: model, voiceID: voice, ack: ack, purpose: .reading(.speak)).blocksSynthesis)
        }
        XCTAssertFalse(OpenAIDisclosureGate.evaluate(modelID: model, voiceID: voice, ack: exact, purpose: .reading(.speak)).blocksSynthesis)
        XCTAssertNil(OpenAIDisclosureGate.confirm(modelID: model, voiceID: voice, explicitlyAccepted: false))
        XCTAssertEqual(OpenAIDisclosureGate.confirm(modelID: model, voiceID: voice, explicitlyAccepted: true), exact)
    }

    func testPreviewAlwaysDisplaysDisclosureEvenWhenExactTupleIsAcknowledged() {
        let model = ModelID(rawValue: "tts-1")
        let voice = VoiceID(rawValue: "openai.alloy")
        let ack = OpenAIDisclosureAck(policyVersion: OpenAIDisclosurePolicy.version, modelID: model, voiceID: voice)
        let evaluation = OpenAIDisclosureGate.evaluate(modelID: model, voiceID: voice, ack: ack, purpose: .preview)
        XCTAssertFalse(evaluation.blocksSynthesis)
        XCTAssertTrue(evaluation.disclosureVisible)
        XCTAssertEqual(evaluation.disclosureText, "此声音由 AI 生成，并非真人声音。")
    }

    func testPersistedAcknowledgementContainsOnlyExactNonSecretIdentity() throws {
        let ack = OpenAIDisclosureAck(
            policyVersion: OpenAIDisclosurePolicy.version,
            modelID: ModelID(rawValue: "tts-1"), voiceID: VoiceID(rawValue: "openai.alloy")
        )
        let data = try JSONEncoder().encode(ack)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["policyVersion", "modelID", "voiceID"])
        XCTAssertNil(object["secret"])
        XCTAssertNil(object["authorization"])
        XCTAssertEqual(try JSONDecoder().decode(OpenAIDisclosureAck.self, from: data), ack)
    }

    func testCoordinatorBlocksSpeakAndPreviewThenPersistsOnlyExplicitConfirmation() async throws {
        let url = URL(fileURLWithPath: "/test/openai-disclosure-prefs.json")
        let files = RecordingAtomicFileStore(initial: [
            url: try JSONEncoder().encode(PrefsV1.defaults)
        ])
        let store = ProviderSettingsStore.open(url: url, files: files)
        let coordinator = OpenAIDisclosureCoordinator(store: store)
        let model = ModelID(rawValue: "tts-1")
        let voice = VoiceID(rawValue: "openai.alloy")
        let effects = OpenAIDisclosureEffectCounter()

        for purpose in [SpeechPurpose.reading(.speak), .preview] {
            await XCTAssertThrowsErrorAsync(
                try await coordinator.performIfAuthorized(
                    modelID: model, voiceID: voice, purpose: purpose
                ) { await effects.record() }
            )
        }
        let blockedCount = await effects.currentCount()
        XCTAssertEqual(blockedCount, 0)
        let rejectedConfirmation = try await coordinator.confirm(
            modelID: model, voiceID: voice, explicitlyAccepted: false
        )
        XCTAssertNil(rejectedConfirmation)
        let prefsBeforeConfirmation = await store.prefsSnapshot()
        XCTAssertNil(prefsBeforeConfirmation.openAIDisclosureAck)

        let ack = try await coordinator.confirm(
            modelID: model, voiceID: voice, explicitlyAccepted: true
        )
        XCTAssertEqual(
            ack,
            OpenAIDisclosureAck(
                policyVersion: OpenAIDisclosurePolicy.version,
                modelID: model,
                voiceID: voice
            )
        )
        try await coordinator.performIfAuthorized(
            modelID: model, voiceID: voice, purpose: SpeechPurpose.reading(.speak)
        ) { await effects.record() }
        let authorizedCount = await effects.currentCount()
        XCTAssertEqual(authorizedCount, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(PrefsV1.self, from: try XCTUnwrap(files.data(at: url))).openAIDisclosureAck,
            ack
        )
    }

    func testRecoveryAndAtomicWriteFailureNeverReturnOrPublishAcknowledgement() async throws {
        let model = ModelID(rawValue: "tts-1")
        let voice = VoiceID(rawValue: "openai.alloy")
        for fixture in OpenAIDisclosurePersistenceFailureFixture.allCases {
            let url = URL(fileURLWithPath: "/test/openai-disclosure-\(fixture).json")
            let files: RecordingAtomicFileStore
            switch fixture {
            case .recovery:
                files = RecordingAtomicFileStore(initial: [url: Data("[]".utf8)])
            case .writeFailure:
                files = RecordingAtomicFileStore(initial: [
                    url: try JSONEncoder().encode(PrefsV1.defaults)
                ])
            }
            let store = ProviderSettingsStore.open(url: url, files: files)
            let expectedMode: ProviderSettingsStore.Mode = fixture == .recovery ? .readOnlyRecovery : .ready
            let modeBeforeConfirmation = await store.currentMode()
            XCTAssertEqual(modeBeforeConfirmation, expectedMode)
            let persistedBeforeFailure = try XCTUnwrap(files.data(at: url))
            if fixture == .writeFailure {
                files.failWrites = true
            }
            let coordinator = OpenAIDisclosureCoordinator(store: store)
            await XCTAssertThrowsErrorAsync(
                try await coordinator.confirm(
                    modelID: model, voiceID: voice, explicitlyAccepted: true
                )
            )
            let prefsAfterFailure = await store.prefsSnapshot()
            XCTAssertNil(prefsAfterFailure.openAIDisclosureAck)
            XCTAssertEqual(files.data(at: url), persistedBeforeFailure)
            await XCTAssertThrowsErrorAsync(
                try await coordinator.performIfAuthorized(
                    modelID: model, voiceID: voice, purpose: .reading(.speak)
                ) { XCTFail("failed persistence cannot authorize"); return () }
            )
        }
    }

}

private enum OpenAIDisclosurePersistenceFailureFixture: String, CaseIterable {
    case recovery, writeFailure
}

private actor OpenAIDisclosureEffectCounter {
    private var count = 0
    func record() { count += 1 }
    func currentCount() -> Int { count }
}

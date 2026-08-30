import XCTest
@testable import Aloud

final class PrefsMutationControllerTests: XCTestCase {
    func testStartupMutationUsesHydratedPrefsInsteadOfBeingOverwritten() async throws {
        var stored = PrefsV1.defaults
        stored.menuBarOnly = true
        let url = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(stored)])
        let store = ProviderSettingsStore.open(url: url, files: files)
        let controller = PrefsMutationController(store: store)

        let visible = try await controller.mutate { $0.cacheDays = 30 }

        XCTAssertTrue(visible.menuBarOnly)
        XCTAssertEqual(visible.cacheDays, 30)
    }

    func testRapidMutationsAreSerializedWithoutLosingTheFirstChange() async throws {
        let url = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let controller = PrefsMutationController(store: ProviderSettingsStore.open(url: url, files: files))

        _ = try await controller.mutate { $0.cacheDays = 30 }
        let visible = try await controller.mutate { $0.menuBarOnly = true }

        XCTAssertEqual(visible.cacheDays, 30)
        XCTAssertTrue(visible.menuBarOnly)
    }

    func testLegacyMutationPreservesProviderSelectionSavedAfterHydration() async throws {
        let url = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let store = ProviderSettingsStore.open(url: url, files: files)
        let controller = PrefsMutationController(store: store)
        _ = try await controller.hydrate()

        let dynamicVoice = VoiceID(rawValue: "minimax.dynamic.professional-host")
        try await store.updateInMemory { prefs in
            let current = prefs.selections[.minimax]!
            prefs.selections[.minimax] = ProviderSelection(
                providerID: .minimax,
                modelID: current.modelID,
                voiceID: dynamicVoice,
                rate: current.rate
            )
        }

        let visible = try await controller.mutate { $0.rate = 16 }
        let persisted = await store.prefsSnapshot()

        XCTAssertEqual(persisted.selections[.minimax]?.voiceID, dynamicVoice)
        XCTAssertEqual(visible.voice, "minimax:\(dynamicVoice.rawValue)")
        XCTAssertEqual(visible.rate, 16)
    }

    func testWriteFailureDoesNotPublishCandidate() async throws {
        let url = URL(fileURLWithPath: "/test/prefs.json")
        let files = RecordingAtomicFileStore(initial: [url: try JSONEncoder().encode(PrefsV1.defaults)])
        let controller = PrefsMutationController(store: ProviderSettingsStore.open(url: url, files: files))
        _ = try await controller.hydrate()
        files.failWrites = true

        await XCTAssertThrowsErrorAsync(try await controller.mutate { $0.menuBarOnly = true })
        let visible = await controller.visiblePrefs()
        XCTAssertFalse(visible.menuBarOnly)
    }

    func testRecoveryMutationStaysInMemoryAndDoesNotWrite() async throws {
        let url = URL(fileURLWithPath: "/test/prefs.json")
        let original = Data("[]".utf8)
        let files = RecordingAtomicFileStore(initial: [url: original])
        let controller = PrefsMutationController(store: ProviderSettingsStore.open(url: url, files: files))

        let visible = try await controller.mutate { $0.menuBarOnly = true }

        XCTAssertTrue(visible.menuBarOnly)
        XCTAssertEqual(files.data(at: url), original)
    }
}

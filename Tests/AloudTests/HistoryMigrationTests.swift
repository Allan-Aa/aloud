import XCTest
@testable import Aloud

final class HistoryMigrationTests: XCTestCase {
    private final class MigrationScriptStore: @unchecked Sendable, AtomicFileStore {
        enum Script { case partialWriteThrow, corruptReadback, differentReadback, restoreWriteFail, restoreReadbackWrong }
        private let lock = NSLock(); private var files: [URL: Data]; private let script: Script; private var writes = 0; private var readsAfterWrite = 0
        init(url: URL, source: Data, script: Script) { files = [url: source]; self.script = script }
        func read(_ url: URL) throws -> Data { try lock.withLock {
            guard let value = files[url] else { throw AtomicFileStoreError.notFound }
            if writes > 0 { readsAfterWrite += 1
                if readsAfterWrite == 1 { if script == .corruptReadback || script == .restoreWriteFail || script == .restoreReadbackWrong { return Data("bad".utf8) }; if script == .differentReadback { return Data("[]".utf8) } }
                if script == .restoreReadbackWrong && readsAfterWrite == 2 { return Data("wrong".utf8) }
            }
            return value
        }}
        func atomicWrite(_ data: Data, to url: URL) throws { try lock.withLock {
            writes += 1; files[url] = data
            if script == .partialWriteThrow && writes == 1 { throw HistoryMutationError.persistenceFailed }
            if script == .restoreWriteFail && writes == 2 { throw HistoryMutationError.restorationFailed }
        }}
        func atomicCopy(from source: URL, to destination: URL) throws { try lock.withLock { guard let data = files[source] else { throw AtomicFileStoreError.notFound }; files[destination] = data } }
        func atomicCopyIfAbsent(from source: URL, to destination: URL) throws { try lock.withLock { guard files[destination] == nil else { throw AtomicFileStoreError.destinationExists }; guard let data = files[source] else { throw AtomicFileStoreError.notFound }; files[destination] = data } }
        func bytes(_ url: URL) -> Data? { lock.withLock { files[url] } }
    }

    private func assertMigrationFailure(_ script: MigrationScriptStore.Script, reason: HistoryDiagnosticReason, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = URL(fileURLWithPath: "/history.json"), source = try Fixture.data(named: "legacy-history-v0.json")
        let store = MigrationScriptStore(url: url, source: source, script: script), diagnostics = HistoryDiagnosticsRecorder()
        let repository = HistoryRepository.open(url: url, files: store, diagnostics: diagnostics)
        XCTAssertEqual(repository.entries.count, 4, file: file, line: line)
        XCTAssertEqual(store.bytes(url), source, file: file, line: line)
        XCTAssertEqual(diagnostics.events, [.init(failureCount: 1, indexes: [], reason: reason)], file: file, line: line)
        XCTAssertFalse(diagnostics.rendered.contains("为什么用"), file: file, line: line)
    }
    func testAllKnownLegacyVoiceLabelsMapToStableMiniMaxSelections() throws {
        let expected: [String: VoiceID] = [
            "电台主持": VoiceID(rawValue: "minimax.radio-host.default"),
            "Radio Host": VoiceID(rawValue: "minimax.radio-host.default"),
            "电台主持 · 流畅": VoiceID(rawValue: "minimax.radio-host.fluent"),
            "Radio Host · fluent": VoiceID(rawValue: "minimax.radio-host.fluent"),
            "松弛女孩": VoiceID(rawValue: "minimax.laid-back-girl.default"),
            "Laid-back Girl": VoiceID(rawValue: "minimax.laid-back-girl.default"),
            "松弛女孩 · 流畅": VoiceID(rawValue: "minimax.laid-back-girl.fluent"),
            "Laid-back Girl · fluent": VoiceID(rawValue: "minimax.laid-back-girl.fluent")
        ]

        for (label, voiceID) in expected {
            let entry = try XCTUnwrap(HistoryRepository.decodeLegacyRow(Data("{\"text\":\"safe\",\"seconds\":1,\"voice\":\"\(label)\",\"rate\":50}".utf8)).entry)
            XCTAssertEqual(entry.providerID, .minimax, label)
            XCTAssertEqual(entry.modelID, ModelID(rawValue: "speech-2.8-hd"), label)
            XCTAssertEqual(entry.voiceID, voiceID, label)
            XCTAssertEqual(entry.rate, NormalizedRate(version: "legacy-minimax-rate-v1", value: 50), label)
            XCTAssertEqual(entry.selectionResolution, .resolved, label)
            XCTAssertNotNil(entry.id.uuidString)
        }
    }

    func testUnknownLegacyVoiceKeepsContentButIsUnresolved() throws {
        let result = HistoryRepository.decodeLegacyRow(Data(#"{"text":"safe text","seconds":3,"voice":"removed voice","rate":15,"ago":"昨天"}"#.utf8))
        let entry = try XCTUnwrap(result.entry)
        XCTAssertEqual(entry.text, "safe text")
        XCTAssertEqual(entry.voiceID, nil)
        XCTAssertEqual(entry.providerID, .minimax)
        XCTAssertEqual(entry.modelID, ModelID(rawValue: "speech-2.8-hd"))
        XCTAssertEqual(entry.rate, NormalizedRate(version: "legacy-minimax-rate-v1", value: 15))
        XCTAssertEqual(entry.selectionResolution, .unresolvedLegacyVoice)
        XCTAssertEqual(entry.legacyAgoSnapshot, "昨天")
    }

    func testNilDateRetainsLegacyAgoWithoutInventingTimestamp() throws {
        let row = Data(#"{"text":"safe","seconds":3,"voice":"电台主持","rate":15,"ago":"2 天前","date":null}"#.utf8)
        let entry = try XCTUnwrap(HistoryRepository.decodeLegacyRow(row).entry)
        XCTAssertNil(entry.date)
        XCTAssertEqual(entry.legacyAgoSnapshot, "2 天前")
    }

    func testLegacyJSONEncoderReferenceDateNumberMigrates() throws {
        let secondsSinceReferenceDate = 807_321_600.0
        let row = Data("{\"text\":\"safe\",\"seconds\":3,\"voice\":\"电台主持\",\"rate\":15,\"date\":\(secondsSinceReferenceDate)}".utf8)
        let entry = try XCTUnwrap(HistoryRepository.decodeLegacyRow(row).entry)

        XCTAssertEqual(entry.date, Date(timeIntervalSinceReferenceDate: secondsSinceReferenceDate))
    }

    func testValidLegacyUUIDIsPreserved() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let row = Data("{\"id\":\"\(id.uuidString)\",\"text\":\"safe\",\"seconds\":3,\"voice\":\"电台主持\",\"rate\":15}".utf8)
        XCTAssertEqual(HistoryRepository.decodeLegacyRow(row).entry?.id, id)
    }

    func testMalformedRowIsSkippedWithoutDiscardingSiblingRowsOrLeakingText() throws {
        let url = URL(fileURLWithPath: "/history.json")
        let source = Data(#"[{"text":"first safe","seconds":1,"voice":"电台主持","rate":1},{"text":"secret malformed","seconds":"bad","voice":"电台主持","rate":1},{"text":"last safe","seconds":2,"voice":"松弛女孩","rate":2}]"#.utf8)
        let store = RecordingAtomicFileStore(initial: [url: source])
        let diagnostics = HistoryDiagnosticsRecorder()
        let repository = HistoryRepository.open(url: url, files: store, diagnostics: diagnostics)

        XCTAssertEqual(repository.entries.count, 3)
        XCTAssertEqual(repository.entries.compactMap(\.text), ["first safe", "last safe"])
        XCTAssertEqual(repository.entries[1].contentResolution, .skipped)
        XCTAssertNil(repository.entries[1].text)
        XCTAssertEqual(store.data(at: url), source)
        XCTAssertEqual(diagnostics.events, [.init(failureCount: 1, indexes: [1], reason: .malformedRow)])
        XCTAssertFalse(diagnostics.rendered.contains("secret malformed"))
    }

    func testMissingTextIsRepresentedAsMissing() throws {
        let entry = try XCTUnwrap(HistoryRepository.decodeLegacyRow(Data(#"{"seconds":3,"voice":"电台主持","rate":15}"#.utf8)).entry)
        XCTAssertNil(entry.text)
        XCTAssertEqual(entry.contentResolution, .missing)
    }

    func testRepositoryWritesMigrationOnlyAfterBackupAndReplacementVerification() throws {
        let url = URL(fileURLWithPath: "/history.json")
        let source = try Fixture.data(named: "legacy-history-v0.json")
        let store = RecordingAtomicFileStore(initial: [url: source])
        let repository = HistoryRepository.open(url: url, files: store)

        XCTAssertEqual(repository.entries.count, 4)
        XCTAssertNotEqual(store.data(at: url), source)
        let backup = url.deletingLastPathComponent().appendingPathComponent("history.json.backup-history-v1")
        XCTAssertEqual(store.data(at: backup), source)
        XCTAssertNoThrow(try JSONDecoder().decode([HistoryEntry].self, from: try XCTUnwrap(store.data(at: url))))
    }

    func testBackupFailurePreservesSourceFile() throws {
        let url = URL(fileURLWithPath: "/history.json")
        let source = try Fixture.data(named: "legacy-history-v0.json")
        let store = RecordingAtomicFileStore(initial: [url: source], failCopies: true)
        _ = HistoryRepository.open(url: url, files: store)
        XCTAssertEqual(store.data(at: url), source)
    }

    func testLegacyNumbersRejectBooleanAndNonIntegerNSNumberValues() {
        for field in ["seconds", "rate"] {
            for value in ["true", "1.0", "1.5"] {
                let seconds = field == "seconds" ? value : "1"
                let rate = field == "rate" ? value : "1"
                let row = Data("{\"text\":\"safe\",\"seconds\":\(seconds),\"voice\":\"电台主持\",\"rate\":\(rate)}".utf8)
                XCTAssertNil(HistoryRepository.decodeLegacyRow(row).entry, "\(field)=\(value)")
            }
        }
    }

    func testSemanticallyCorruptV1RowIsSkippedAndPreventsMigrationWrite() throws {
        let url = URL(fileURLWithPath: "/history.json")
        let source = Data(#"[{"id":"00112233-4455-6677-8899-AABBCCDDEEFF","version":1,"text":"bad","contentResolution":"missing","seconds":1,"providerID":{"rawValue":"minimax"},"modelID":{"rawValue":"speech-2.8-hd"},"voiceID":{"rawValue":"x"},"rate":{"version":"rate-v1","value":1},"displayLabelSnapshot":"x","selectionResolution":"resolved","date":null,"legacyAgoSnapshot":null},{"text":"safe","seconds":1,"voice":"电台主持","rate":1}]"#.utf8)
        let store = RecordingAtomicFileStore(initial: [url: source])
        let repository = HistoryRepository.open(url: url, files: store)
        XCTAssertEqual(repository.entries[0].contentResolution, .skipped)
        XCTAssertEqual(repository.entries[1].text, "safe")
        XCTAssertEqual(store.data(at: url), source)
    }

    func testExistingBackupIsNotOverwritten() throws {
        let url = URL(fileURLWithPath: "/history.json")
        let source = try Fixture.data(named: "legacy-history-v0.json")
        let firstBackup = url.deletingLastPathComponent().appendingPathComponent("history.json.backup-history-v1")
        let originalBackup = Data("old backup".utf8)
        let store = RecordingAtomicFileStore(initial: [url: source, firstBackup: originalBackup])
        _ = HistoryRepository.open(url: url, files: store)
        XCTAssertEqual(store.data(at: firstBackup), originalBackup)
        XCTAssertEqual(store.data(at: url.deletingLastPathComponent().appendingPathComponent("history.json.backup-history-v1-2")), source)
    }

    func testMigrationPartialReplacementWriteRestoresSource() throws { try assertMigrationFailure(.partialWriteThrow, reason: .replacementVerificationFailed) }
    func testMigrationCorruptReplacementReadbackRestoresSource() throws { try assertMigrationFailure(.corruptReadback, reason: .replacementVerificationFailed) }
    func testMigrationDifferentValidReplacementReadbackRestoresSource() throws { try assertMigrationFailure(.differentReadback, reason: .replacementVerificationFailed) }
    func testMigrationRestoreWriteFailureReportsOnlyRestorationFailure() throws { try assertMigrationFailure(.restoreWriteFail, reason: .restorationFailed) }
    func testMigrationRestoreReadbackMismatchReportsOnlyRestorationFailure() throws { try assertMigrationFailure(.restoreReadbackWrong, reason: .restorationFailed) }
}

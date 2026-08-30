import XCTest
@testable import Aloud

final class ProviderContractCatalogTests: XCTestCase {
    func testBundledCatalogLocksOnlyKnownProviderModelPairs() throws {
        let catalog = try ProviderContractCatalog.bundled()

        XCTAssertEqual(catalog.providerAvailability(for: .minimax).kind, .available)
        XCTAssertEqual(catalog.modelAvailability(providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd")).kind, .available)
        XCTAssertEqual(catalog.modelAvailability(providerID: .openAI, modelID: ModelID(rawValue: "gpt-4o-mini-tts")).kind, .deprecated)
        XCTAssertEqual(catalog.modelAvailability(providerID: .openAI, modelID: ModelID(rawValue: "tts-1")).kind, .available)
        XCTAssertEqual(catalog.providerAvailability(for: .macOS).kind, .available)
        XCTAssertEqual(catalog.providerAvailability(for: .gemini).kind, .experimental)
        XCTAssertEqual(catalog.modelAvailability(providerID: .gemini, modelID: ModelID(rawValue: "gemini-2.5-pro-preview-tts")).kind, .experimental)
        XCTAssertEqual(catalog.modelAvailability(providerID: .openAI, modelID: ModelID(rawValue: "not-in-contract")).kind, .unknown)
    }

    func testAvailableProviderWithoutAvailableModelFailsClosed() throws {
        var object = try fixtureObject(); var contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]]); contracts[0]["models"] = []; object["contracts"] = contracts
        let catalog = ProviderContractCatalog.loading(data: try JSONSerialization.data(withJSONObject: object))
        let availability = catalog.providerAvailability(for: .minimax)

        XCTAssertEqual(availability.kind, .disabled)
        XCTAssertEqual(availability.reason, .noQualifiedModel)
    }

    func testCorruptOrUnknownCatalogVersionReturnsUnknownRatherThanDefaults() throws {
        let corrupt = ProviderContractCatalog.loading(data: Data("not-json".utf8))
        XCTAssertEqual(corrupt.providerAvailability(for: .minimax).kind, .unknown)
        XCTAssertEqual(corrupt.modelAvailability(providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd")).kind, .unknown)

        let unknownVersion = try JSONEncoder().encode(CatalogDocument(schemaVersion: 999, contracts: []))
        let versioned = ProviderContractCatalog.loading(data: unknownVersion)
        XCTAssertEqual(versioned.providerAvailability(for: .openAI).kind, .unknown)
    }

    func testMissingContractEvidenceFailsClosedAsUnknown() throws {
        var object = try fixtureObject(); var contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]]); var availability = try XCTUnwrap(contracts[1]["availability"] as? [String: Any]); availability["evidenceID"] = "claimed-but-absent"; contracts[1]["availability"] = availability; object["contracts"] = contracts
        let catalog = ProviderContractCatalog.loading(data: try JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(catalog.providerAvailability(for: .openAI).kind, .unknown)
        XCTAssertEqual(catalog.modelAvailability(providerID: .openAI, modelID: ModelID(rawValue: "gpt-4o-mini-tts")).kind, .unknown)
    }

    func testEvidenceAndResourceContainNoSecretsOrAccountSnapshots() throws {
        let data = try ProviderContractCatalog.bundledResourceData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = recursiveKeys(in: object)

        XCTAssertTrue(keys.isDisjoint(with: ["apiKey", "secret", "authorization", "accountSnapshot", "credentialRevision"]))
        let wire = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["secret", "account", "credential", "task9-canary-value"] { XCTAssertFalse(wire.contains(forbidden)) }
        XCTAssertFalse((try ProviderContractCatalog.bundled().evidenceRecords).isEmpty)
    }

    func testEvidenceRecordsAreUniqueAndEveryReferenceIsConcrete() throws {
        let catalog = try ProviderContractCatalog.bundled()
        let records = catalog.evidenceRecords
        XCTAssertEqual(Set(records.map(\.id)).count, records.count)
        XCTAssertTrue(records.allSatisfy { $0.id.isEmpty == false && $0.evidence.evidenceDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil })
        for provider in [ProviderID.minimax, .openAI, .macOS, .gemini] {
            let contract = try XCTUnwrap(catalog.contract(for: provider))
            XCTAssertNotNil(contract.availability.evidenceID.flatMap { id in records.first(where: { $0.id == id }) })
            for model in contract.models.values { XCTAssertNotNil(model.availability.evidenceID.flatMap { id in records.first(where: { $0.id == id }) }) }
        }
    }

    func testDanglingDuplicateEmptyOrMalformedEvidenceFailsClosed() throws {
        for mutation in ["danglingEvidence", "duplicateEvidence", "emptyEvidence", "badDigest"] {
            var object = try fixtureObject()
            var records = try XCTUnwrap(object["evidenceRecords"] as? [[String: Any]])
            switch mutation {
            case "danglingEvidence":
                var contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]])
                var availability = try XCTUnwrap(contracts[0]["availability"] as? [String: Any]); availability["evidenceID"] = "not-present"; contracts[0]["availability"] = availability; object["contracts"] = contracts
            case "duplicateEvidence": records.append(records[0])
            case "emptyEvidence": records[0]["id"] = ""
            default: var evidence = try XCTUnwrap(records[0]["evidence"] as? [String: Any]); evidence["evidenceDigest"] = "not-a-sha"; records[0]["evidence"] = evidence
            }
            object["evidenceRecords"] = records
            XCTAssertEqual(ProviderContractCatalog.loading(data: try JSONSerialization.data(withJSONObject: object)).providerAvailability(for: .minimax).kind, .unknown, mutation)
        }
    }

    func testAllContractVersionsMustMatchDocumentVersion() throws {
        for path in ["provider", "model", "evidence"] {
            var object = try fixtureObject()
            if path == "provider" {
                var contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]]); var availability = try XCTUnwrap(contracts[0]["availability"] as? [String: Any]); availability["providerContractVersion"] = "wrong"; contracts[0]["availability"] = availability; object["contracts"] = contracts
            } else if path == "model" {
                var contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]]); var models = try XCTUnwrap(contracts[0]["models"] as? [[String: Any]]); var availability = try XCTUnwrap(models[0]["availability"] as? [String: Any]); availability["contractVersion"] = "wrong"; models[0]["availability"] = availability; contracts[0]["models"] = models; object["contracts"] = contracts
            } else {
                var records = try XCTUnwrap(object["evidenceRecords"] as? [[String: Any]]); var evidence = try XCTUnwrap(records[0]["evidence"] as? [String: Any]); evidence["contractVersion"] = "wrong"; records[0]["evidence"] = evidence; object["evidenceRecords"] = records
            }
            XCTAssertEqual(ProviderContractCatalog.loading(data: try JSONSerialization.data(withJSONObject: object)).providerAvailability(for: .openAI).kind, .unknown, path)
        }
    }

    func testWireNumbersRejectFloatsFractionsAndBooleans() throws {
        for mutation in ["schemaFloat", "attemptBoolean", "statusFraction", "backoffFloat", "sampleRateFloat"] {
            let original = String(decoding: try ProviderContractCatalog.bundledResourceData(), as: UTF8.self)
            let wire: String
            switch mutation {
            case "schemaFloat": wire = original.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1.0")
            case "attemptBoolean": wire = original.replacingOccurrences(of: "\"maximumAttempts\": 1", with: "\"maximumAttempts\": true")
            case "statusFraction": wire = original.replacingOccurrences(of: "\"retryableHTTPStatuses\": []", with: "\"retryableHTTPStatuses\": [200.5]")
            case "backoffFloat": wire = original.replacingOccurrences(of: "\"maximumAttempts\": 1, \"backoffMilliseconds\": []", with: "\"maximumAttempts\": 2, \"backoffMilliseconds\": [1.0]")
            default: wire = original.replacingOccurrences(of: "\"container\": \"unknown\", \"codec\": \"unknown\", \"mappingVersion\": \"minimax-native-v1\"", with: "\"container\": \"wav\", \"codec\": \"pcm\", \"sampleRate\": 48000.0, \"channels\": 1, \"bitDepth\": 16, \"mappingVersion\": \"minimax-native-v1\"")
            }
            XCTAssertEqual(ProviderContractCatalog.loading(data: Data(wire.utf8)).providerAvailability(for: .minimax).kind, .unknown, mutation)
        }
    }

    func testDuplicateRetryStatusAndInvalidAudioSemanticsFailClosed() throws {
        let original = String(decoding: try ProviderContractCatalog.bundledResourceData(), as: UTF8.self)
        let duplicateStatus = original.replacingOccurrences(of: "\"retryableHTTPStatuses\": []", with: "\"retryableHTTPStatuses\": [500, 500]")
        XCTAssertEqual(ProviderContractCatalog.loading(data: Data(duplicateStatus.utf8)).providerAvailability(for: .minimax).kind, .unknown)
        let partialConcreteAudio = original.replacingOccurrences(of: "\"container\": \"unknown\", \"codec\": \"unknown\", \"mappingVersion\": \"minimax-native-v1\"", with: "\"container\": \"wav\", \"codec\": \"pcm\", \"sampleRate\": 48000, \"mappingVersion\": \"minimax-native-v1\"")
        XCTAssertEqual(ProviderContractCatalog.loading(data: Data(partialConcreteAudio.utf8)).providerAvailability(for: .minimax).kind, .unknown)
    }

    func testKnownProviderMayBeAbsentButLookupIsUnknownAndDuplicatesFailClosed() throws {
        var object = try fixtureObject(); var contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]]); contracts.removeAll { $0["providerID"] as? String == "gemini" }; object["contracts"] = contracts
        XCTAssertEqual(ProviderContractCatalog.loading(data: try JSONSerialization.data(withJSONObject: object)).providerAvailability(for: .gemini).kind, .unknown)
        contracts.append(contracts[0]); object["contracts"] = contracts
        XCTAssertEqual(ProviderContractCatalog.loading(data: try JSONSerialization.data(withJSONObject: object)).providerAvailability(for: .minimax).kind, .unknown)
    }

    func testEvidenceSubjectAndKindMustBindTheReferencingProviderAndModel() throws {
        for mutation in ["crossProvider", "providerUsedForModel", "wrongModel"] {
            var object = try fixtureObject(); var records = try XCTUnwrap(object["evidenceRecords"] as? [[String: Any]])
            switch mutation {
            case "crossProvider": records[0]["providerID"] = "openai"
            case "providerUsedForModel":
                var contracts = try XCTUnwrap(object["contracts"] as? [[String: Any]]); var models = try XCTUnwrap(contracts[0]["models"] as? [[String: Any]]); var availability = try XCTUnwrap(models[0]["availability"] as? [String: Any]); availability["evidenceID"] = "minimax-provider"; models[0]["availability"] = availability; contracts[0]["models"] = models; object["contracts"] = contracts
            default: records[1]["modelID"] = "other-model"
            }
            object["evidenceRecords"] = records
            XCTAssertEqual(ProviderContractCatalog.loading(data: try JSONSerialization.data(withJSONObject: object)).providerAvailability(for: .minimax).kind, .unknown, mutation)
        }
    }

    func testEvidenceSnapshotAndDigestCannotBeReplacedByLocatorMetadata() throws {
        var object = try fixtureObject(); var records = try XCTUnwrap(object["evidenceRecords"] as? [[String: Any]])
        records[0]["snapshot"] = "changed approved fact"
        object["evidenceRecords"] = records
        XCTAssertEqual(ProviderContractCatalog.loading(data: try JSONSerialization.data(withJSONObject: object)).providerAvailability(for: .minimax).kind, .unknown)

        let original = String(decoding: try ProviderContractCatalog.bundledResourceData(), as: UTF8.self)
        let alteredURL = original.replacingOccurrences(of: "https://platform.minimax.io/docs", with: "https://invalid.example/changed").replacingOccurrences(of: "c79326c855304383ba63eae7b3843c87eb6e17fca05738888bc3ea12dd12b4b4", with: "1059203dabb25b6352a744e56b3725fbb13843944955e9a54aa2dcf9599fc1a7")
        XCTAssertEqual(ProviderContractCatalog.loading(data: Data(alteredURL.utf8)).providerAvailability(for: .minimax).kind, .unknown)
    }

    private func recursiveKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { $0.formUnion(recursiveKeys(in: $1.value)) }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(recursiveKeys(in: $1)) }
        }
        return []
    }

    private func fixtureObject() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: ProviderContractCatalog.bundledResourceData()) as? [String: Any]) }
}

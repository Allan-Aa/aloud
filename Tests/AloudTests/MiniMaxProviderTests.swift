import XCTest
@testable import Aloud

final class MiniMaxProviderTests: XCTestCase {
    func testProductionHTTPClientUsesEphemeralNoCacheSessionAndRequestPolicy() async throws {
        let production = URLSessionMiniMaxHTTPClient()
        let productionConfiguration = production.session.configuration
        XCTAssertNil(productionConfiguration.urlCache)
        XCTAssertNil(productionConfiguration.httpCookieStorage)
        XCTAssertNil(productionConfiguration.urlCredentialStorage)
        XCTAssertEqual(
            productionConfiguration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData
        )

        MiniMaxNoCacheURLProtocol.reset()
        let interceptedConfiguration = URLSessionConfiguration.ephemeral
        interceptedConfiguration.protocolClasses = [MiniMaxNoCacheURLProtocol.self]
        let client = URLSessionMiniMaxHTTPClient(configuration: interceptedConfiguration)
        var request = URLRequest(url: MiniMaxVoiceManagementContractV1.endpoint)
        request.cachePolicy = .returnCacheDataElseLoad

        let response = try await client.send(request)
        let captured = try XCTUnwrap(MiniMaxNoCacheURLProtocol.capturedRequest())

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(captured.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testLoadVoiceCatalogUsesExactOfficialRequestAndParsesAllThreeKinds() async throws {
        let directory = try MiniMaxTestDirectory()
        let client = RecordingMiniMaxHTTPClient(results: [
            .success(.init(statusCode: 200, body: voiceCatalogJSON))
        ])
        let voiceDirectory = MiniMaxVoiceDirectory()
        let provider = MiniMaxProvider(
            httpClient: client, nativeDirectory: directory.url, voiceDirectory: voiceDirectory
        )
        let revision = UUID()

        let result = try await provider.loadVoiceCatalog(using: .apiKey(
            providerID: .minimax,
            envelope: .init(
                providerID: .minimax, revision: revision, secret: Data("fixture-bearer".utf8)
            )
        ))

        let recordedRequests = await client.requests
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.url, URL(string: "https://api.minimax.io/v1/get_voice"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bearer")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.httpBody), encoding: .utf8),
            #"{"voice_type":"all"}"#
        )
        XCTAssertEqual(Set(result.voices.map(\.kind)), [.system, .cloned, .generated])
        XCTAssertEqual(result.voices.first { $0.wireID == "system-1" }?.displayName, "System One")
        XCTAssertEqual(result.voices.first { $0.wireID == "clone-1" }?.displayName, "Clone One")
        XCTAssertEqual(result.voices.first { $0.wireID == "generated-1" }?.displayName, "Generated One")

        let scope = try XCTUnwrap(result.snapshot.relationshipEvidence.keys.first)
        XCTAssertEqual(scope.providerID, .minimax)
        XCTAssertEqual(scope.credentialRevision, revision)
        XCTAssertEqual(scope.contractVersion, MiniMaxWireContractV1.version)
        XCTAssertEqual(scope.parentModelID, MiniMaxWireContractV1.modelID)
        let voiceEvidence = try XCTUnwrap(
            result.snapshot.voiceEvidence[scope]?[.init(dimension: .voice, parentModelID: MiniMaxWireContractV1.modelID)]
        )
        let accountVoiceIDs = Set(result.voices.map(\.stableID)).subtracting(
            MiniMaxVoiceCatalogV1.contractOwnedResources.builtInVoices
        )
        XCTAssertEqual(voiceEvidence.coverage, .authoritativeComplete)
        XCTAssertEqual(voiceEvidence.values, accountVoiceIDs)
        let relationship = try XCTUnwrap(result.snapshot.relationshipEvidence[scope])
        XCTAssertEqual(relationship.coverage, .authoritativeComplete)
        XCTAssertTrue(relationship.paginationComplete)
        XCTAssertEqual(relationship.values, Set(accountVoiceIDs.map {
            AccountRelationshipTuple(
                modelID: MiniMaxWireContractV1.modelID,
                voiceID: $0,
                controlsID: nil,
                controlsVersion: nil
            )
        }))
        let dynamicVoice = try XCTUnwrap(
            result.voices.first { !MiniMaxVoiceCatalogV1.contractOwnedResources.builtInVoices.contains($0.stableID) }
        )
        XCTAssertEqual(
            AccountSelectionValidator.validate(
                model: MiniMaxWireContractV1.modelID,
                voice: dynamicVoice.stableID,
                in: result.snapshot,
                scope: scope,
                currentRevision: revision,
                currentRefreshID: relationship.refreshID,
                contractOwned: MiniMaxVoiceCatalogV1.contractOwnedResources
            ),
            .valid
        )
    }

    func testLoadVoiceCatalogMapsHTTPServiceAndMalformedResponsesWithoutLeakingContent() async throws {
        let oversized = Data(repeating: 0x78, count: 2_000_001)
        let cases: [(MiniMaxHTTPResponse, MiniMaxProviderError)] = [
            (.init(statusCode: 401, body: Data("raw-response-canary".utf8)), .credentialRejected),
            (.init(statusCode: 403, body: Data("raw-response-canary".utf8)), .credentialRejected),
            (.init(statusCode: 503, body: Data("raw-response-canary".utf8)), .httpStatus(503)),
            (.init(statusCode: 200, body: Data(#"{"base_resp":{"status_code":1004,"status_msg":"raw-response-canary"}}"#.utf8)), .credentialRejected),
            (.init(statusCode: 200, body: Data(#"{"base_resp":{"status_code":2049,"status_msg":"raw-response-canary"}}"#.utf8)), .credentialRejected),
            (.init(statusCode: 200, body: Data(#"{"base_resp":{"status_code":7,"status_msg":"raw-response-canary"}}"#.utf8)), .service(7)),
            (.init(statusCode: 200, body: Data("raw-response-canary".utf8)), .invalidResponse),
            (.init(statusCode: 200, body: oversized), .invalidResponse),
        ]

        for (response, expected) in cases {
            let client = RecordingMiniMaxHTTPClient(results: [.success(response)])
            let provider = MiniMaxProvider(
                httpClient: client, nativeDirectory: try MiniMaxTestDirectory().url,
                voiceDirectory: MiniMaxVoiceDirectory()
            )
            do {
                _ = try await provider.loadVoiceCatalog(using: miniMaxCredential(revision: UUID()))
                XCTFail("expected catalog failure")
            } catch let error as MiniMaxProviderError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("raw-response-canary"))
                XCTAssertFalse(error.localizedDescription.contains("fixture-catalog-key"))
            }
        }
    }

    func testLoadVoiceCatalogMapsTransportAndValidatesCredentialBeforeTransport() async throws {
        let transport = RecordingMiniMaxHTTPClient(results: [.failure(MiniMaxCatalogFixtureError())])
        let transportProvider = MiniMaxProvider(
            httpClient: transport, nativeDirectory: try MiniMaxTestDirectory().url,
            voiceDirectory: MiniMaxVoiceDirectory()
        )
        do {
            _ = try await transportProvider.loadVoiceCatalog(using: miniMaxCredential(revision: UUID()))
            XCTFail("expected transport failure")
        } catch let error as MiniMaxProviderError {
            XCTAssertEqual(error, .transport)
        }

        let never = RecordingMiniMaxHTTPClient(results: [])
        let provider = MiniMaxProvider(
            httpClient: never, nativeDirectory: try MiniMaxTestDirectory().url,
            voiceDirectory: MiniMaxVoiceDirectory()
        )
        for credential in [
            ProviderCredential.none,
            .apiKey(
                providerID: .openAI,
                envelope: .init(providerID: .openAI, revision: UUID(), secret: Data("x".utf8))
            ),
            .apiKey(
                providerID: .minimax,
                envelope: .init(providerID: .minimax, revision: UUID(), secret: Data())
            ),
        ] {
            await XCTAssertThrowsErrorAsync(try await provider.loadVoiceCatalog(using: credential))
        }
        let requestCount = await never.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testLoadVoiceCatalogFallsBackForEmptyNamesAndDeduplicatesWireIDsByKindPriority() async throws {
        let emptyNames = Data(#"{"base_resp":{"status_code":0},"system_voice":[],"voice_cloning":[{"voice_id":"clone-empty","voice_name":""}],"voice_generation":[{"voice_id":"generated-empty"}]}"#.utf8)
        let provider = MiniMaxProvider(
            httpClient: RecordingMiniMaxHTTPClient(results: [.success(.init(statusCode: 200, body: emptyNames))]),
            nativeDirectory: try MiniMaxTestDirectory().url,
            voiceDirectory: MiniMaxVoiceDirectory()
        )
        let loaded = try await provider.loadVoiceCatalog(using: miniMaxCredential(revision: UUID()))
        XCTAssertEqual(loaded.voices.first { $0.wireID == "clone-empty" }?.displayName, "clone-empty")
        XCTAssertEqual(loaded.voices.first { $0.wireID == "generated-empty" }?.displayName, "generated-empty")

        let duplicate = Data(#"{"base_resp":{"status_code":0},"system_voice":[{"voice_id":"duplicate","voice_name":"System"}],"voice_cloning":[{"voice_id":"duplicate","voice_name":"Clone"}],"voice_generation":[]}"#.utf8)
        let duplicateProvider = MiniMaxProvider(
            httpClient: RecordingMiniMaxHTTPClient(results: [.success(.init(statusCode: 200, body: duplicate))]),
            nativeDirectory: try MiniMaxTestDirectory().url,
            voiceDirectory: MiniMaxVoiceDirectory()
        )
        let deduplicated = try await duplicateProvider.loadVoiceCatalog(
            using: miniMaxCredential(revision: UUID())
        )
        XCTAssertEqual(deduplicated.voices.filter { $0.wireID == "duplicate" }.count, 1)
        XCTAssertEqual(deduplicated.voices.first { $0.wireID == "duplicate" }?.kind, .system)
        XCTAssertEqual(deduplicated.voices.first { $0.wireID == "duplicate" }?.displayName, "System")
    }

    func testEmptyOfficialCatalogKeepsFallbackUIWithoutClaimingAccountEvidence() async throws {
        let empty = Data(#"{"base_resp":{"status_code":0},"system_voice":[],"voice_cloning":[],"voice_generation":[]}"#.utf8)
        let provider = MiniMaxProvider(
            httpClient: RecordingMiniMaxHTTPClient(results: [.success(.init(statusCode: 200, body: empty))]),
            nativeDirectory: try MiniMaxTestDirectory().url,
            voiceDirectory: MiniMaxVoiceDirectory()
        )

        let loaded = try await provider.loadVoiceCatalog(using: miniMaxCredential(revision: UUID()))
        XCTAssertEqual(
            Set(loaded.voices.map(\.stableID)),
            MiniMaxVoiceCatalogV1.contractOwnedResources.builtInVoices
        )
        let scope = try XCTUnwrap(loaded.snapshot.relationshipEvidence.keys.first)
        let voiceEvidence = try XCTUnwrap(
            loaded.snapshot.voiceEvidence[scope]?[.init(
                dimension: .voice, parentModelID: MiniMaxWireContractV1.modelID
            )]
        )
        XCTAssertTrue(voiceEvidence.values.isEmpty)
        XCTAssertTrue(try XCTUnwrap(loaded.snapshot.relationshipEvidence[scope]).values.isEmpty)
    }

    func testLoadVoiceCatalogCancellationAfterHTTPReturnDoesNotPublish() async throws {
        let revision = UUID()
        let voiceDirectory = MiniMaxVoiceDirectory()
        let barrier = MiniMaxOwnershipBarrier()
        let provider = MiniMaxProvider(
            httpClient: RecordingMiniMaxHTTPClient(results: [
                .success(MiniMaxHTTPResponse(statusCode: 200, body: voiceCatalogJSON))
            ]),
            nativeDirectory: try MiniMaxTestDirectory().url,
            voiceDirectory: voiceDirectory,
            beforeVoiceCatalogCommit: { await barrier.suspend() }
        )
        let task = Task {
            try await provider.loadVoiceCatalog(using: miniMaxCredential(revision: revision))
        }

        await barrier.waitUntilEntered()
        task.cancel()
        await barrier.release()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        let voices = await provider.voiceDescriptors(revision: revision)
        XCTAssertFalse(voices.contains { $0.wireID == "clone-1" })
    }

    func testLateOldCatalogResponseCannotCommitAfterNewRevisionBegins() async throws {
        let oldRevision = UUID()
        let newRevision = UUID()
        let client = InterleavedMiniMaxCatalogHTTPClient(
            oldResponse: .init(statusCode: 200, body: miniMaxCatalogJSON(wireID: "old")),
            newResponse: .init(statusCode: 200, body: miniMaxCatalogJSON(wireID: "new"))
        )
        let provider = MiniMaxProvider(
            httpClient: client,
            nativeDirectory: try MiniMaxTestDirectory().url,
            voiceDirectory: MiniMaxVoiceDirectory()
        )
        let oldTask = Task {
            try await provider.loadVoiceCatalog(using: miniMaxCredential(revision: oldRevision))
        }
        await client.waitUntilOldRequestEntered()

        let newLoad = try await provider.loadVoiceCatalog(
            using: miniMaxCredential(revision: newRevision)
        )
        XCTAssertTrue(newLoad.voices.contains { $0.wireID == "new" })
        await client.releaseOldResponse()
        do { _ = try await oldTask.value; XCTFail("expected superseded operation") }
        catch is CancellationError {} catch { XCTFail("unexpected \(error)") }

        let oldDescriptors = await provider.voiceDescriptors(revision: oldRevision)
        let newDescriptors = await provider.voiceDescriptors(revision: newRevision)
        XCTAssertFalse(oldDescriptors.contains { $0.wireID == "old" })
        XCTAssertTrue(newDescriptors.contains { $0.wireID == "new" })
    }

    func testDynamicStableVoiceResolvesToExactWireIDForMatchingRevisionOnly() async throws {
        let directory = try MiniMaxTestDirectory()
        let client = RecordingMiniMaxHTTPClient(results: [
            .success(.init(statusCode: 200, body: voiceCatalogJSON)),
            .success(okAudio),
        ])
        let provider = MiniMaxProvider(
            httpClient: client, nativeDirectory: directory.url,
            voiceDirectory: MiniMaxVoiceDirectory()
        )
        let revision = UUID()
        let loaded = try await provider.loadVoiceCatalog(using: miniMaxCredential(revision: revision))
        let stableVoice = try XCTUnwrap(loaded.voices.first { $0.wireID == "clone-1" }?.stableID)
        let request = try await makeMiniMaxRequest(
            provider: provider, revision: revision, text: "dynamic", rate: 0, voiceID: stableVoice
        )
        let artifact = try await provider.synthesize(request, credential: miniMaxCredential(revision: revision))
        defer { artifact.cleanupIfOwned() }

        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        let synthesisBody = try XCTUnwrap(String(
            data: try XCTUnwrap(requests.last?.httpBody), encoding: .utf8
        ))
        XCTAssertTrue(synthesisBody.contains(#""voice_id":"clone-1""#))

        let otherRevision = UUID()
        let otherRequest = try await makeMiniMaxRequest(
            provider: provider, revision: otherRevision, text: "wrong revision", rate: 0,
            voiceID: stableVoice
        )
        do {
            _ = try await provider.synthesize(
                otherRequest, credential: miniMaxCredential(revision: otherRevision)
            )
            XCTFail("expected revision-exact rejection")
        } catch let error as MiniMaxProviderError {
            XCTAssertEqual(error, .unsupportedSelection)
        }
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testSynthesizeSendsExactEndpointHeaderAndTypedBodyThenDecodesHexToNativeTemp() async throws {
        let directory = try MiniMaxTestDirectory()
        let client = RecordingMiniMaxHTTPClient(results: [
            .success(.init(statusCode: 200, body: Data(#"{"base_resp":{"status_code":0,"status_msg":"success"},"data":{"audio":"49443304"}}"#.utf8)))
        ])
        let provider = MiniMaxProvider(httpClient: client, nativeDirectory: directory.url)
        let revision = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        let request = try await makeMiniMaxRequest(provider: provider, revision: revision, text: "validated chunk only", rate: 0)
        let envelope = CredentialEnvelope(providerID: .minimax, revision: revision, secret: Data("fixture-bearer".utf8))

        let artifact = try await ProviderSynthesisGate(provider: provider).synthesize(
            request, credential: .apiKey(providerID: .minimax, envelope: envelope)
        )
        defer { artifact.cleanupIfOwned() }

        let recorded = await client.requests
        let sent = try XCTUnwrap(recorded.first)
        XCTAssertEqual(sent.url, MiniMaxWireContractV1.endpoint)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bearer")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(data: try XCTUnwrap(sent.httpBody), encoding: .utf8), #"{"audio_setting":{"bitrate":128000,"format":"mp3","sample_rate":32000},"language_boost":"Chinese","model":"speech-2.8-hd","output_format":"hex","stream":false,"text":"validated chunk only","voice_setting":{"pitch":0,"speed":1,"voice_id":"Chinese (Mandarin)_Radio_Host","vol":1}}"#)
        XCTAssertEqual(artifact.format, .encoded(container: "mp3", codec: "mp3"))
        XCTAssertEqual(artifact.purpose, .reading(.speak))
        XCTAssertEqual(try Data(contentsOf: artifact.url), Data([0x49, 0x44, 0x33, 0x04]))
        XCTAssertEqual(artifact.url.deletingLastPathComponent(), directory.url)
    }

    func testFluentStableVoiceIDsAreMigrationOnlyAndNeverReachTransport() async throws {
        for voiceID in MiniMaxVoiceCatalogV1.disabledReasons.keys {
            let client = RecordingMiniMaxHTTPClient(results: [.success(okAudio)])
            let provider = MiniMaxProvider(httpClient: client, nativeDirectory: try MiniMaxTestDirectory().url)
            let selection = ProviderSelection(
                providerID: .minimax, modelID: MiniMaxWireContractV1.modelID,
                voiceID: voiceID,
                rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 0)!
            )
            do {
                _ = try await provider.split("x", selection: selection)
                XCTFail("fluent selection must be disabled")
            } catch let error as MiniMaxProviderError {
                XCTAssertEqual(error, .disabledSelection(.fluentNotVerifiedForSpeech28HD))
                XCTAssertTrue(error.localizedDescription.contains("speech-2.8-hd"))
            }
            let requestCount = await client.requestCount()
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testCredentialEnvelopeSnapshotMustMatchProviderAndRequestRevisionBeforeTransport() async throws {
        let client = RecordingMiniMaxHTTPClient(results: [.success(okAudio)])
        let provider = MiniMaxProvider(httpClient: client, nativeDirectory: try MiniMaxTestDirectory().url)
        let revision = UUID()
        let request = try await makeMiniMaxRequest(provider: provider, revision: revision, text: "x", rate: 0)
        for credential in [
            ProviderCredential.none,
            .apiKey(providerID: .openAI, envelope: .init(providerID: .openAI, revision: revision, secret: Data("x".utf8))),
            .apiKey(providerID: .minimax, envelope: .init(providerID: .minimax, revision: UUID(), secret: Data("x".utf8))),
        ] {
            await XCTAssertThrowsErrorAsync(try await provider.synthesize(request, credential: credential))
        }
        let requestCount = await client.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testStatus1004And2049AreExplicitCredentialRejectionsAndRawMessageSecretAndTextDoNotEscapeError() async throws {
        let secret = "fixture-secret-canary"
        let text = "fixture-text-canary"
        for code in [1004, 2049] {
            let response = MiniMaxHTTPResponse(
                statusCode: 200,
                body: Data("{\"base_resp\":{\"status_code\":\(code),\"status_msg\":\"fixture-secret-canary fixture-text-canary\"}}".utf8)
            )
            let client = RecordingMiniMaxHTTPClient(results: [.success(response)])
            let provider = MiniMaxProvider(httpClient: client, nativeDirectory: try MiniMaxTestDirectory().url)
            let revision = UUID()
            let request = try await makeMiniMaxRequest(provider: provider, revision: revision, text: text, rate: 0)
            do {
                _ = try await provider.synthesize(request, credential: .apiKey(
                    providerID: .minimax,
                    envelope: CredentialEnvelope(providerID: .minimax, revision: revision, secret: Data(secret.utf8))
                ))
                XCTFail("expected credential rejection")
            } catch let error as MiniMaxProviderError {
                XCTAssertEqual(error, .credentialRejected)
                let visible = error.localizedDescription
                XCTAssertFalse(visible.contains(secret))
                XCTAssertFalse(visible.contains(text))
            }
            let requestCount = await client.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testHTTPAndMalformedResponsesAreContentFreeAndNeverMutateCredential() async throws {
        for response in [
            MiniMaxHTTPResponse(statusCode: 503, body: Data("fixture response canary".utf8)),
            MiniMaxHTTPResponse(statusCode: 200, body: Data(#"{"base_resp":{"status_code":7,"status_msg":"fixture response canary"}}"#.utf8)),
            MiniMaxHTTPResponse(statusCode: 200, body: Data(#"{"base_resp":{"status_code":0},"data":{"audio":"not-hex"}}"#.utf8)),
        ] {
            let client = RecordingMiniMaxHTTPClient(results: [.success(response)])
            let provider = MiniMaxProvider(httpClient: client, nativeDirectory: try MiniMaxTestDirectory().url)
            let revision = UUID()
            let request = try await makeMiniMaxRequest(provider: provider, revision: revision, text: "fixture request canary", rate: 0)
            let envelope = CredentialEnvelope(providerID: .minimax, revision: revision, secret: Data("fixture key canary".utf8))
            do { _ = try await provider.synthesize(request, credential: .apiKey(providerID: .minimax, envelope: envelope)); XCTFail("expected failure") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
                XCTAssertEqual(envelope.revision, revision)
                XCTAssertEqual(envelope.secret, Data("fixture key canary".utf8))
            }
        }
    }

    func testCancellationAfterTransportReturnsLeavesNoNativeTemp() async throws {
        let directory = try MiniMaxTestDirectory()
        let barrier = MiniMaxTransportBarrier(response: okAudio)
        let provider = MiniMaxProvider(httpClient: barrier, nativeDirectory: directory.url)
        let revision = UUID()
        let request = try await makeMiniMaxRequest(provider: provider, revision: revision, text: "cancel", rate: 0)
        let task = Task {
            try await provider.synthesize(request, credential: .apiKey(
                providerID: .minimax,
                envelope: CredentialEnvelope(providerID: .minimax, revision: revision, secret: Data("k".utf8))
            ))
        }
        await barrier.waitUntilEntered()
        task.cancel()
        await barrier.release()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError {} catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [])
    }

    func testNonIdempotentAdapterContractMakesRetryPolicyAttemptExactlyOnce() async throws {
        let client = RecordingMiniMaxHTTPClient(results: [.success(.init(statusCode: 503, body: Data()))])
        let provider = MiniMaxProvider(httpClient: client, nativeDirectory: try MiniMaxTestDirectory().url)
        let revision = UUID()
        let request = try await makeMiniMaxRequest(provider: provider, revision: revision, text: "retry", rate: 0)
        let envelope = CredentialEnvelope(providerID: .minimax, revision: revision, secret: Data("k".utf8))
        do {
            _ = try await RetryPolicy.execute(contract: MiniMaxWireContractV1.retryContract) { _ in
                do { return .success(try await provider.synthesize(request, credential: .apiKey(providerID: .minimax, envelope: envelope))) }
                catch MiniMaxProviderError.httpStatus(let status) { return .failure(.http(status)) }
                catch { return .failure(.resultUnknownAfterSend) }
            }
            XCTFail("expected retry stop")
        } catch let failure as RetryFailure {
            XCTAssertEqual(failure.attempts, 1)
        }
        let requestCount = await client.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testEngineFacadeRunsAdapterThroughCanonicalResolverBeforePlaybackAndHistory() async throws {
        let directory = try MiniMaxTestDirectory()
        let client = RecordingMiniMaxHTTPClient(results: [.success(okAudio)])
        let provider = MiniMaxProvider(httpClient: client, nativeDirectory: directory.url)
        let cache = CanonicalChunkCacheCoordinator(cache: CanonicalAudioCache(directory: directory.url.appendingPathComponent("cache")))
        let revision = UUID()
        let envelope = CredentialEnvelope(providerID: .minimax, revision: revision, secret: Data("engine-fixture".utf8))
        let credentialCapture = MiniMaxCredentialCaptureSpy(envelope: envelope)
        let health = MiniMaxHealthSpy()
        let player = MiniMaxEnginePlayback()
        let history = HistoryMutationController(url: directory.url.appendingPathComponent("history.json"))
        let operations = Store.Operations(
            dir: directory.url, cacheDir: directory.url.appendingPathComponent("legacy-cache"), runtimeDir: directory.url,
            read: { _ in nil }, write: { _, _ in }
        )
        let engine = Store.withOperations(operations) {
            Engine(
                player: player,
                speech: EngineSpeechDependencies(
                    cachePath: { _, _, _ in directory.url.appendingPathComponent("legacy.wav") },
                    cacheHit: { _ in false },
                    synthesize: { _, _, _, _ in XCTFail("legacy synth must be unreachable") },
                    concat: { _, _, _ in },
                    provider: provider,
                    canonicalizeNative: { native, purpose, _ in
                        XCTAssertEqual(native.format, .encoded(container: "mp3", codec: "mp3"))
                        let output = directory.url.appendingPathComponent("canonical-\(UUID().uuidString).wav")
                        try WAVTestFixture.wav(samples: 480).write(to: output)
                        return OwnedAudioArtifact(artifact: try WAVValidator.validate(output, purpose: purpose))
                    },
                    captureCredential: { providerID in try await credentialCapture.capture(providerID) },
                    advanceCanonicalScope: { providerID, scope, generation in
                        await cache.advance(providerID: providerID, revision: scope, generation: generation)
                    },
                    canonicalChunkResolver: { key, generation, purpose, producer in
                        try await cache.resolve(key: key, generation: generation, purpose: purpose, produce: producer)
                    },
                    verifyPlayback: {
                        PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
                    },
                    prepareSessionArtifact: { urls, purpose in
                        try WAVConcatenator.concatenate(urls, to: directory.url.appendingPathComponent("session.wav"), purpose: purpose)
                    },
                    providerDidSucceed: { token in await health.record(token) }
                ),
                credentialRegistry: CredentialScopeRegistry(), historyController: history,
                installCredentialHook: false, lastAudioStore: LastAudioArtifactStore()
            )
        }
        await engine.installCredentialCancellationHook()
        try await Task.sleep(for: .milliseconds(30))
        var providerState = try ProviderSettingsState.fixture(defaultProviderID: .minimax)
        let providerIndex = providerState.cards.firstIndex { $0.id == .minimax }!
        providerState.cards[providerIndex].selection = ProviderSelection(
            providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"),
            voiceID: VoiceID(rawValue: "minimax.radio-host.default"),
            rate: NormalizedRate(version: MiniMaxRateMappingV1.version, value: 0)!
        )
        engine.providerSettingsState = providerState
        engine.text = "Engine adapter integration"
        engine.speak()
        for _ in 0..<400 where engine.history.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

        let engineRequestCount = await client.requests.count
        let captureCount = await credentialCapture.count
        let healthCount = await health.count
        XCTAssertEqual(engineRequestCount, 1)
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(healthCount, 1)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(player.playedExtensions, ["wav"])
        XCTAssertEqual(engine.history.map(\.text), ["Engine adapter integration"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("legacy.wav").path))
    }

    @MainActor
    func testBlockedNonV1CredentialStopsAtCoordinatorCaptureWithNoDownstreamEffects() async throws {
        let directory = try MiniMaxTestDirectory()
        let client = RecordingMiniMaxHTTPClient(results: [.success(okAudio)])
        let provider = MiniMaxProvider(httpClient: client, nativeDirectory: directory.url)
        let player = MiniMaxEnginePlayback()
        let history = HistoryMutationController(url: directory.url.appendingPathComponent("history.json"))
        let downstream = LockedInvocationCount()
        let engine = Store.withOperations(.init(
            dir: directory.url, cacheDir: directory.url.appendingPathComponent("cache"), runtimeDir: directory.url,
            read: { _ in nil }, write: { _, _ in }
        )) {
            Engine(
                player: player,
                speech: EngineSpeechDependencies(
                    cachePath: { _, _, _ in directory.url.appendingPathComponent("unused.wav") },
                    cacheHit: { _ in false }, synthesize: { _, _, _, _ in }, concat: { _, _, _ in },
                    provider: provider,
                    canonicalizeNative: { _, _, _ in downstream.increment(); throw WAVAudioError.invalidContainer },
                    captureCredential: { providerID in
                        try MiniMaxCredentialCapture.envelope(
                            from: .blocked(.nonV1Item), providerID: providerID
                        )
                    },
                    canonicalChunkResolver: { _, _, _, _ in
                        downstream.increment(); throw CacheFlightError.noReadyArtifact
                    },
                    prepareSessionArtifact: { _, _ in downstream.increment(); return nil }
                ),
                credentialRegistry: CredentialScopeRegistry(), historyController: history,
                installCredentialHook: false, lastAudioStore: LastAudioArtifactStore()
            )
        }
        await engine.installCredentialCancellationHook()
        engine.text = "blocked non-v1"
        engine.speak()
        for _ in 0..<400 where engine.toast == nil { try await Task.sleep(for: .milliseconds(1)) }

        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(downstream.value, 0)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertTrue(engine.history.isEmpty)
        XCTAssertTrue(engine.toast?.contains("重新") == true)
    }

    @MainActor
    func testCancellationAfterNativeReturnBeforeTokenCheckCleansNativeExactlyOnce() async throws {
        try await assertCancellationOwnership(window: .afterNative)
    }

    @MainActor
    func testCancellationAfterCanonicalReturnBeforeCacheTransferCleansBothExactlyOnce() async throws {
        try await assertCancellationOwnership(window: .afterCanonical)
    }

    @MainActor
    private func assertCancellationOwnership(window: MiniMaxOwnershipWindow) async throws {
        let directory = try MiniMaxTestDirectory()
        let nativeCleanup = LockedInvocationCount()
        let canonicalCleanup = LockedInvocationCount()
        let publication = LockedInvocationCount()
        let barrier = MiniMaxOwnershipBarrier()
        let provider = OwnedArtifactMiniMaxProvider(directory: directory.url, cleanup: nativeCleanup)
        let player = MiniMaxEnginePlayback()
        let history = HistoryMutationController(url: directory.url.appendingPathComponent("history.json"))
        let revision = UUID()
        let engine = Store.withOperations(.init(
            dir: directory.url, cacheDir: directory.url.appendingPathComponent("cache"), runtimeDir: directory.url,
            read: { _ in nil }, write: { _, _ in }
        )) {
            Engine(
                player: player,
                speech: EngineSpeechDependencies(
                    cachePath: { _, _, _ in directory.url.appendingPathComponent("unused.wav") },
                    cacheHit: { _ in false }, synthesize: { _, _, _, _ in }, concat: { _, _, _ in },
                    provider: provider,
                    canonicalizeNative: { _, purpose, _ in
                        let url = directory.url.appendingPathComponent("canonical-(UUID().uuidString).wav")
                        try WAVTestFixture.wav(samples: 480).write(to: url)
                        let artifact = try WAVValidator.validate(url, purpose: purpose)
                        return OwnedAudioArtifact(artifact: artifact, cleanup: {
                            canonicalCleanup.increment()
                            try? FileManager.default.removeItem(at: url)
                        })
                    },
                    captureCredential: { _ in
                        CredentialEnvelope(providerID: .minimax, revision: revision, secret: Data("fixture".utf8))
                    },
                    canonicalChunkResolver: { _, _, _, producer in
                        let artifact = try await producer()
                        publication.increment()
                        return artifact.artifact
                    },
                    afterNativeSynthesis: {
                        if window == .afterNative { await barrier.suspend() }
                    },
                    afterCanonicalization: {
                        if window == .afterCanonical { await barrier.suspend() }
                    }
                ),
                credentialRegistry: CredentialScopeRegistry(), historyController: history,
                installCredentialHook: false, lastAudioStore: LastAudioArtifactStore()
            )
        }
        await engine.installCredentialCancellationHook()
        engine.text = "ownership cancellation"
        engine.speak()
        await barrier.waitUntilEntered()
        engine.stop()
        for _ in 0..<400 where nativeCleanup.value == 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(nativeCleanup.value, 1, "Stop must synchronously own cleanup while the stage remains suspended")
        XCTAssertEqual(canonicalCleanup.value, window == .afterCanonical ? 1 : 0)
        await barrier.release()
        for _ in 0..<400 where nativeCleanup.value == 0 { try await Task.sleep(for: .milliseconds(1)) }

        XCTAssertEqual(nativeCleanup.value, 1)
        XCTAssertEqual(canonicalCleanup.value, window == .afterCanonical ? 1 : 0)
        XCTAssertEqual(publication.value, 0)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertTrue(engine.history.isEmpty)
    }
}

private let okAudio = MiniMaxHTTPResponse(
    statusCode: 200,
    body: Data(#"{"base_resp":{"status_code":0},"data":{"audio":"494433"}}"#.utf8)
)

private let voiceCatalogJSON = Data(#"{"base_resp":{"status_code":0,"status_msg":"success"},"system_voice":[{"voice_id":"system-1","voice_name":"System One"}],"voice_cloning":[{"voice_id":"clone-1","voice_name":"Clone One"}],"voice_generation":[{"voice_id":"generated-1","voice_name":"Generated One"}]}"#.utf8)

private func miniMaxCatalogJSON(wireID: String) -> Data {
    Data(#"{"base_resp":{"status_code":0},"system_voice":[],"voice_cloning":[{"voice_id":"\#(wireID)","voice_name":"\#(wireID)"}],"voice_generation":[]}"#.utf8)
}

private struct MiniMaxCatalogFixtureError: Error {}

private func miniMaxCredential(revision: UUID) -> ProviderCredential {
    .apiKey(
        providerID: .minimax,
        envelope: CredentialEnvelope(
            providerID: .minimax, revision: revision, secret: Data("fixture-catalog-key".utf8)
        )
    )
}

private func makeMiniMaxRequest(
    provider: MiniMaxProvider, revision: UUID, text: String, rate: Int, voiceID: VoiceID = VoiceID(rawValue: "minimax.radio-host.default")
) async throws -> SpeechRequest {
    let selection = ProviderSelection(
        providerID: .minimax, modelID: MiniMaxWireContractV1.modelID, voiceID: voiceID,
        rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: rate)!
    )
    let chunks = try await provider.split(text, selection: selection)
    let chunk = try XCTUnwrap(chunks.first)
    return try SpeechRequest.make(
        id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: chunk,
        controls: MiniMaxRateMappingV1.controls(for: selection.rate), credentialScopeRevision: revision,
        capabilities: provider.capabilities, outputFormatID: MiniMaxWireContractV1.outputFormatID,
        canonicalizerVersion: "canonical-wav-v1"
    )
}

private actor RecordingMiniMaxHTTPClient: MiniMaxHTTPClient {
    private var results: [Result<MiniMaxHTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []
    init(results: [Result<MiniMaxHTTPResponse, Error>]) { self.results = results }
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        requests.append(request)
        guard !results.isEmpty else { throw MiniMaxProviderError.transport }
        return try results.removeFirst().get()
    }
    func requestCount() -> Int { requests.count }
}

private final class MiniMaxNoCacheURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var captured: URLRequest?
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        captured = nil
        lock.unlock()
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured = request
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor InterleavedMiniMaxCatalogHTTPClient: MiniMaxHTTPClient {
    private let oldResponse: MiniMaxHTTPResponse
    private let newResponse: MiniMaxHTTPResponse
    private var requestCount = 0
    private var oldRequestEntered = false
    private var oldRequestEnteredWaiter: CheckedContinuation<Void, Never>?
    private var oldResponseWaiter: CheckedContinuation<Void, Never>?

    init(oldResponse: MiniMaxHTTPResponse, newResponse: MiniMaxHTTPResponse) {
        self.oldResponse = oldResponse
        self.newResponse = newResponse
    }

    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        requestCount += 1
        guard requestCount == 1 else { return newResponse }
        oldRequestEntered = true
        oldRequestEnteredWaiter?.resume()
        oldRequestEnteredWaiter = nil
        await withCheckedContinuation { oldResponseWaiter = $0 }
        return oldResponse
    }

    func waitUntilOldRequestEntered() async {
        if oldRequestEntered { return }
        await withCheckedContinuation { oldRequestEnteredWaiter = $0 }
    }

    func releaseOldResponse() {
        oldResponseWaiter?.resume()
        oldResponseWaiter = nil
    }
}

private actor MiniMaxTransportBarrier: MiniMaxHTTPClient {
    private let response: MiniMaxHTTPResponse
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(response: MiniMaxHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return response
    }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { enteredWaiter = $0 } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private final class MiniMaxTestDirectory {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aloud-minimax-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private enum MiniMaxOwnershipWindow: Sendable { case afterNative, afterCanonical }

private final class LockedInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor MiniMaxOwnershipBarrier {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() {
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}

private final class OwnedArtifactMiniMaxProvider: VoiceProvider, @unchecked Sendable {
    let id = ProviderID.minimax
    let capabilities = MiniMaxWireContractV1.capabilities
    private let directory: URL
    private let cleanup: LockedInvocationCount
    init(directory: URL, cleanup: LockedInvocationCount) { self.directory = directory; self.cleanup = cleanup }
    func measureInput(_ text: String, requestOverhead: RequestOverhead) async throws -> InputMeasurement {
        try await InputMeasurement.measure(text, limits: capabilities.inputLimits, requestOverhead: requestOverhead)
    }
    func split(_ text: String, selection: ProviderSelection) async throws -> [ValidatedSpeechChunk] {
        try await ProviderInputSplitter(capabilities: capabilities).split(text)
    }
    func loadCatalog(using credential: ProviderCredential) async throws -> AccountCatalogSnapshot { .empty }
    func synthesize(_ request: SpeechRequest, credential: ProviderCredential) async throws -> OwnedNativeAudioArtifact {
        let url = directory.appendingPathComponent("owned-native-(UUID().uuidString).mp3")
        try Data([0x49, 0x44, 0x33]).write(to: url)
        return OwnedNativeAudioArtifact(
            artifact: NativeAudioArtifact(url: url, format: capabilities.outputFormat, purpose: .reading(.speak)),
            cleanup: { [cleanup] in
                cleanup.increment()
                try? FileManager.default.removeItem(at: url)
            }
        )
    }
}

private actor MiniMaxHealthSpy {
    private(set) var count = 0
    func record(_ token: SessionCurrentToken) { count += 1 }
}

private actor MiniMaxCredentialCaptureSpy {
    private let envelope: CredentialEnvelope
    private(set) var count = 0
    init(envelope: CredentialEnvelope) { self.envelope = envelope }
    func capture(_ providerID: ProviderID) throws -> CredentialEnvelope? {
        count += 1
        guard providerID == envelope.providerID else { return nil }
        return envelope
    }
}

@MainActor
private final class MiniMaxEnginePlayback: EnginePlayback {
    var alive = false
    var paused = false
    var position = 0.2
    var duration = 0.01
    private(set) var playCount = 0
    private(set) var playedExtensions: [String] = []
    func play(file: URL, prefs: Prefs, streaming: Bool) throws {
        playCount += 1; playedExtensions.append(file.pathExtension); alive = true
    }
    func append(file: URL) throws { playedExtensions.append(file.pathExtension) }
    func finishStream(prefs: Prefs) {}
    func stop() { alive = false }
    func togglePause() { paused.toggle() }
    func seek(relative: Double) {}
    func setSpeed(_ speed: Double) {}
}

import XCTest
import Darwin
@testable import Aloud

@MainActor
final class PlaybackEvidenceTests: XCTestCase {
    func testOnlyTwoStrictlyIncreasingUnpausedPositionsProduceEvidence() throws {
        let observedAt = Date(timeIntervalSince1970: 123)
        var verifier = PlaybackVerifier()
        XCTAssertNil(try verifier.consume(.duration(10), observedAt: observedAt))
        XCTAssertNil(try verifier.consume(.paused(false), observedAt: observedAt))
        XCTAssertNil(try verifier.consume(.timePosition(0.25), observedAt: observedAt))
        let evidence = try verifier.consume(.timePosition(0.50), observedAt: observedAt)
        XCTAssertEqual(evidence, PlaybackEvidence(firstTimePosition: 0.25, secondTimePosition: 0.50, observedAt: observedAt))
    }

    func testDurationOneAdvanceEqualOrDecreasingPositionsAreInsufficient() throws {
        for events: [MPVEvent] in [
            [.duration(10)],
            [.timePosition(0.25)],
            [.timePosition(0.25), .timePosition(0.25)],
            [.timePosition(0.50), .timePosition(0.25)],
        ] {
            var verifier = PlaybackVerifier()
            var evidence: PlaybackEvidence?
            for event in events { evidence = try verifier.consume(event, observedAt: Date()) ?? evidence }
            XCTAssertNil(evidence, "events=\(events)")
        }
    }

    func testPausedAndEveryTerminalPlaybackErrorRejectEvidence() {
        for terminal in [MPVEvent.paused(true), .decodeError, .audioOutputError, .endFile(error: true)] {
            var verifier = PlaybackVerifier()
            XCTAssertNoThrow(try verifier.consume(.timePosition(0.10), observedAt: Date()))
            XCTAssertThrowsError(try verifier.consume(terminal, observedAt: Date()))
            XCTAssertThrowsError(try verifier.consume(.timePosition(0.20), observedAt: Date()))
        }
    }

    func testPausedFalseDoesNotCountAsProgress() throws {
        var verifier = PlaybackVerifier()
        XCTAssertNil(try verifier.consume(.paused(false), observedAt: Date()))
        XCTAssertNil(try verifier.consume(.timePosition(1), observedAt: Date()))
        XCTAssertNotNil(try verifier.consume(.timePosition(2), observedAt: Date()))
    }

    func testStructuredMPVErrorEventsEnterPlaybackVerifierAsTerminalFailures() throws {
        let cases: [(String, PlaybackVerificationError)] = [
            (#"{"event":"log-message","level":"error","prefix":"ffmpeg/audio","text":"Error decoding audio frame"}"#, .decode),
            (#"{"event":"log-message","level":"error","prefix":"ao/coreaudio","text":"Failed to initialize audio output"}"#, .audioOutput),
            (#"{"event":"end-file","reason":"error","file_error":"unrecognized file format"}"#, .endFile),
        ]

        for (line, expected) in cases {
            let event = try XCTUnwrap(MPVStructuredEventParser.parse(line))
            var verifier = PlaybackVerifier()
            XCTAssertNil(try verifier.consume(.timePosition(0.1), observedAt: Date()))
            XCTAssertThrowsError(try verifier.consume(event, observedAt: Date())) { error in
                XCTAssertEqual(error as? PlaybackVerificationError, expected)
            }
        }
    }

    func testStructuredMPVPropertyEventsProduceEvidenceOnlyAfterUnpausedProgress() throws {
        let lines = [
            #"{"event":"property-change","name":"pause","data":false}"#,
            #"{"event":"property-change","name":"duration","data":10.0}"#,
            #"{"event":"property-change","name":"time-pos","data":0.25}"#,
            #"{"event":"property-change","name":"time-pos","data":0.50}"#,
        ]
        var verifier = PlaybackVerifier()
        var evidence: PlaybackEvidence?
        for line in lines {
            let event = try XCTUnwrap(MPVStructuredEventParser.parse(line))
            evidence = try verifier.consume(event, observedAt: Date()) ?? evidence
        }
        XCTAssertEqual(evidence?.firstTimePosition, 0.25)
        XCTAssertEqual(evidence?.secondTimePosition, 0.50)
    }

    func testWireParserSeparatesAcknowledgementsFromEvents() throws {
        XCTAssertEqual(
            MPVStructuredMessageParser.parse(#"{"request_id":41,"error":"success"}"#),
            .acknowledgement(requestID: 41, error: "success")
        )
        XCTAssertEqual(
            MPVStructuredMessageParser.parse(#"{"event":"property-change","name":"pause","data":false}"#),
            .event(.paused(false))
        )
    }

    func testObserverReplaysInterleavedPreAcknowledgementEventsInOriginalOrder() async throws {
        let requestIDs: [Int64] = [101, 102, 103, 104]
        let wire = [
            "{\"event\":\"property-change\",\"name\":\"pause\",\"data\":false}\n{\"request_id\":101,\"error\":\"suc",
            "cess\"}\n{\"event\":\"property-change\",\"name\":\"time-pos\",\"data\":0.1}\n{\"request_id\":102,\"error\":\"success\"}\n",
            "{\"request_id\":103,\"error\":\"success\"}\n{\"request_id\":104,\"error\":\"success\"}\n{\"event\":\"property-change\",\"name\":\"time-pos\",\"data\":0.2}\n",
        ].map { Data($0.utf8) }
        let connection = MPVConnectionFake(reads: wire.map(MPVConnectionFake.Read.data) + [.peerClosed])
        let connector = MPVConnectorFake(connection: connection)
        let events = MPVEventRecorder()
        let observer = MPVStructuredEventObserver(
            path: "/private/ipc.sock", connector: connector,
            requestIDs: requestIDs, handshakeTimeout: .seconds(1),
            receive: { events.record($0) }
        )

        observer.start()
        await events.waitForCount(3)
        observer.cancelAndWait()

        XCTAssertEqual(events.values.prefix(3), [.paused(false), .timePosition(0.1), .timePosition(0.2)])
        var verifier = PlaybackVerifier()
        var evidence: PlaybackEvidence?
        for event in events.values.prefix(3) {
            evidence = try verifier.consume(event, observedAt: Date()) ?? evidence
        }
        XCTAssertEqual(evidence?.firstTimePosition, 0.1)
        XCTAssertEqual(evidence?.secondTimePosition, 0.2)
        XCTAssertEqual(connection.writtenRequestIDs, requestIDs)
    }

    func testObserverAcknowledgementFailureDropsAllBufferedEvents() async throws {
        let connection = MPVConnectionFake(reads: [
            .data(Data("{\"event\":\"property-change\",\"name\":\"pause\",\"data\":false}\n{\"event\":\"property-change\",\"name\":\"time-pos\",\"data\":0.1}\n{\"request_id\":1,\"error\":\"property unavailable\"}\n".utf8)),
        ])
        let events = MPVEventRecorder()
        let observer = MPVStructuredEventObserver(
            path: "/private/ipc.sock", connector: MPVConnectorFake(connection: connection),
            requestIDs: [1, 2, 3, 4], receive: { events.record($0) }
        )
        observer.start()
        await events.waitForCount(1)
        observer.cancelAndWait()
        XCTAssertEqual(events.values, [.ipcFailure(.handshakeRejected)])
    }

    func testObserverBoundsPreAcknowledgementEventBuffer() async throws {
        let early = (0..<3).map {
            "{\"event\":\"property-change\",\"name\":\"time-pos\",\"data\":\($0)}\n"
        }.joined()
        let connection = MPVConnectionFake(reads: [.data(Data(early.utf8))])
        let events = MPVEventRecorder()
        let observer = MPVStructuredEventObserver(
            path: "/private/ipc.sock", connector: MPVConnectorFake(connection: connection),
            requestIDs: [1, 2, 3, 4], maximumPreHandshakeEvents: 2,
            receive: { events.record($0) }
        )
        observer.start()
        await events.waitForCount(1)
        observer.cancelAndWait()
        XCTAssertEqual(events.values, [.ipcFailure(.protocolViolation)])
    }

    func testObserverAndOneShotCommandRejectFramesBeyondSharedLimit() async throws {
        let oversized = Data(repeating: 0x78, count: MPVJSONLineFramer.productionMaximumFrameBytes + 1)
        let observerConnection = MPVConnectionFake(reads: [.data(oversized)])
        let events = MPVEventRecorder()
        let observer = MPVStructuredEventObserver(
            path: "/private/ipc.sock",
            connector: MPVConnectorFake(connection: observerConnection),
            requestIDs: [1, 2, 3, 4], receive: { events.record($0) }
        )
        observer.start()
        await events.waitForCount(1)
        observer.cancelAndWait()
        XCTAssertEqual(events.values, [.ipcFailure(.protocolViolation)])

        let commandConnection = MPVConnectionFake(reads: [.data(oversized)])
        let socket = MPVSocket(
            path: "/private/ipc.sock", expectedProcessID: 123,
            connector: MPVConnectorFake(connection: commandConnection)
        )
        XCTAssertNil(socket.send(["get_property", "pause"], retries: 1))
    }

    func testObserverAckFailureMissingAckAndPeerCloseFailVerification() async throws {
        let cases: [([MPVConnectionFake.Read], MPVIPCFailure)] = [
            ([.data(Data("{\"request_id\":1,\"error\":\"property unavailable\"}\n".utf8))], .handshakeRejected),
            ([.data(Data("{\"request_id\":1,\"error\":\"success\"}\n".utf8)), .timeout], .handshakeTimeout),
            ([.peerClosed], .peerClosed),
        ]
        for (reads, expected) in cases {
            let connection = MPVConnectionFake(reads: reads)
            let events = MPVEventRecorder()
            let observer = MPVStructuredEventObserver(
                path: "/private/ipc.sock", connector: MPVConnectorFake(connection: connection),
                requestIDs: [1, 2, 3, 4], handshakeTimeout: .milliseconds(1),
                receive: { events.record($0) }
            )
            observer.start()
            await events.waitForCount(1)
            observer.cancelAndWait()
            let failure = try XCTUnwrap(events.values.first)
            XCTAssertEqual(failure, .ipcFailure(expected))
            var verifier = PlaybackVerifier()
            XCTAssertThrowsError(try verifier.consume(failure, observedAt: Date())) { error in
                XCTAssertEqual(error as? PlaybackVerificationError, .ipc(expected))
            }
        }
    }

    func testSafeWritePumpHandlesInterruptAndPartialWritesAndTypesPeerClose() throws {
        var attempts: [MPVSocketWriteAttempt] = [.interrupted, .written(2), .written(3)]
        try MPVSocketWritePump.writeAll(byteCount: 5) { _, _ in attempts.removeFirst() }
        XCTAssertTrue(attempts.isEmpty)

        XCTAssertThrowsError(
            try MPVSocketWritePump.writeAll(byteCount: 5) { _, _ in .failed(EPIPE) }
        ) { error in
            XCTAssertEqual(error as? MPVSocketError, .peerClosed)
        }
    }

    func testSharedJSONFramerHandlesFragmentsAndMultipleLinesAndRejectsOversizeFrame() throws {
        var framer = MPVJSONLineFramer(maximumFrameBytes: 16)
        XCTAssertEqual(try framer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(
            try framer.append(Data("1}\n{\"b\":2}\n".utf8)),
            [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)]
        )
        XCTAssertThrowsError(try framer.append(Data(String(repeating: "x", count: 17).utf8))) { error in
            XCTAssertEqual(error as? MPVSocketError, .frameTooLarge)
        }
    }

    func testTwentyInterruptedPollsCannotExtendAbsoluteDeadline() throws {
        var now: UInt64 = 0
        var attempts = 0
        XCTAssertThrowsError(
            try MPVMonotonicPoll.wait(
                timeoutNanoseconds: 20,
                now: { now },
                attempt: { _ in
                    attempts += 1
                    now += 1
                    return .interrupted
                }
            )
        ) { error in
            XCTAssertEqual(error as? MPVSocketError, .timeout)
        }
        XCTAssertEqual(attempts, 20)
        XCTAssertEqual(now, 20)
    }

    func testSameUIDPeerWithWrongPIDIsRejected() throws {
        XCTAssertNoThrow(try MPVPeerIdentity.validate(
            endpointOwnerUID: 501, peerUID: 501, peerPID: 700,
            expectedPID: 700, currentUID: 501
        ))
        XCTAssertThrowsError(try MPVPeerIdentity.validate(
            endpointOwnerUID: 501, peerUID: 501, peerPID: 701,
            expectedPID: 700, currentUID: 501
        )) { error in
            XCTAssertEqual(error as? MPVSocketError, .unsafeEndpoint)
        }
    }

    func testDescriptorPreparationRequiresNoSIGPIPE() throws {
        var calls = 0
        XCTAssertNoThrow(try MPVSocketDescriptorPreparer.requireNoSIGPIPE {
            calls += 1
            return 0
        })
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try MPVSocketDescriptorPreparer.requireNoSIGPIPE { -1 })
    }

    func testPrivateIPCDirectoriesAreUniqueMode0700AndRejectExistingOrSymlink() throws {
        let root = try ShortPrivateTemporaryDirectory(); defer { try? root.remove() }
        let firstNonce = UUID()
        let first = try PrivateMPVIPCDirectory.create(in: root.url, processID: 42, nonce: firstNonce)
        let second = try PrivateMPVIPCDirectory.create(in: root.url, processID: 42, nonce: UUID())
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertTrue(first.directory.lastPathComponent.hasPrefix("aloud-mpv-42-"))
        XCTAssertEqual(first.socket.lastPathComponent, "ipc.sock")
        let attributes = try FileManager.default.attributesOfItem(atPath: first.directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        XCTAssertThrowsError(
            try PrivateMPVIPCDirectory.create(
                in: root.url, processID: 42, nonce: firstNonce
            )
        )
        let link = root.url.appendingPathComponent("aloud-mpv-42-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first.directory)
        XCTAssertThrowsError(try PrivateMPVIPCDirectory.validatePrivateDirectory(link))

        first.cleanup()
        second.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.directory.path))
    }

    func testPlaybackEventQueueIgnoresLateOldObserverEventAfterRestart() async throws {
        let queue = PlaybackEventQueue()
        let oldSession = queue.reset()
        let newSession = queue.reset()
        queue.push(.timePosition(99), session: oldSession)
        queue.push(.paused(false), session: newSession)
        let received = try await queue.next()
        XCTAssertEqual(received, .paused(false))
    }

    func testPlayerCreatesUniquePrivateIPCForEachPlaybackAndCleansOnlyItsOwnDirectory() async throws {
        let root = try ShortPrivateTemporaryDirectory(); defer { try? root.remove() }
        let audio = root.url.appendingPathComponent("playback.wav")
        try WAVTestFixture.wav(samples: 480).write(to: audio)
        let launcher = MPVProcessLauncherFake()
        let connector = MPVSequenceConnectorFake()
        let player = Player(processLauncher: launcher, socketConnector: connector, ipcRoot: root.url)
        var prefs = Prefs()
        prefs.mpvBin = "/fake/mpv"

        try player.play(file: audio, prefs: prefs)
        let firstPath = try XCTUnwrap(launcher.socketPaths.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: firstPath).deletingLastPathComponent().path))
        await connector.waitForConnection(count: 1)
        await player.stopAndWait()
        try player.play(file: audio, prefs: prefs)
        let secondPath = try XCTUnwrap(launcher.socketPaths.last)

        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertTrue(firstPath.contains("aloud-mpv-"))
        XCTAssertTrue(secondPath.contains("aloud-mpv-"))
        XCTAssertTrue(connector.connections.first?.closed == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: firstPath).deletingLastPathComponent().path))

        player.stop()
        await player.stopAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: secondPath).deletingLastPathComponent().path))
        XCTAssertEqual(launcher.handles.filter(\.terminated).count, 2)
    }

    func testPlayerUpmixesCanonicalMonoWAVForCoreAudioCompatibility() async throws {
        let root = try ShortPrivateTemporaryDirectory(); defer { try? root.remove() }
        let audio = root.url.appendingPathComponent("playback.wav")
        try WAVTestFixture.wav(samples: 480).write(to: audio)
        let launcher = MPVProcessLauncherFake()
        let player = Player(
            processLauncher: launcher,
            socketConnector: MPVSequenceConnectorFake(),
            ipcRoot: root.url
        )
        var prefs = Prefs(); prefs.mpvBin = "/fake/mpv"

        try player.play(file: audio, prefs: prefs)

        XCTAssertTrue(try XCTUnwrap(launcher.launchArguments.first).contains("--audio-channels=stereo"))
        await player.stopAndWait()
    }

    func testSeparatePlayerInstancesCannotShareIPCPathAndLaunchFailureCleansDirectory() async throws {
        let root = try ShortPrivateTemporaryDirectory(); defer { try? root.remove() }
        let audio = root.url.appendingPathComponent("playback.wav")
        try WAVTestFixture.wav(samples: 480).write(to: audio)
        var prefs = Prefs(); prefs.mpvBin = "/fake/mpv"
        let firstLauncher = MPVProcessLauncherFake()
        let secondLauncher = MPVProcessLauncherFake()
        let first = Player(processLauncher: firstLauncher, socketConnector: MPVSequenceConnectorFake(), ipcRoot: root.url)
        let second = Player(processLauncher: secondLauncher, socketConnector: MPVSequenceConnectorFake(), ipcRoot: root.url)
        try first.play(file: audio, prefs: prefs)
        try second.play(file: audio, prefs: prefs)
        XCTAssertNotEqual(firstLauncher.socketPaths.first, secondLauncher.socketPaths.first)
        first.stop(); second.stop()
        await first.stopAndWait(); await second.stopAndWait()

        let failedLauncher = MPVProcessLauncherFake(failLaunch: true)
        let failed = Player(processLauncher: failedLauncher, socketConnector: MPVSequenceConnectorFake(), ipcRoot: root.url)
        do {
            try failed.play(file: audio, prefs: prefs)
            XCTFail("launch must fail")
        } catch MPVProcessLauncherFake.Failure.launch {}
        let residues = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
            .filter { $0.hasPrefix("aloud-mpv-") }
        XCTAssertTrue(residues.isEmpty)
    }

    func testReplacementWaitsForForcedTerminationAcknowledgementAndRepeatedStopSharesDrain() async throws {
        let root = try ShortPrivateTemporaryDirectory(); defer { try? root.remove() }
        let audio = root.url.appendingPathComponent("playback.wav")
        try WAVTestFixture.wav(samples: 480).write(to: audio)
        var prefs = Prefs(); prefs.mpvBin = "/fake/mpv"
        let launcher = MPVProcessLauncherFake(firstProcessIgnoresTermination: true)
        let player = Player(
            processLauncher: launcher, socketConnector: MPVSequenceConnectorFake(),
            ipcRoot: root.url,
            terminationTiming: MPVTerminationTiming(grace: .zero, poll: .milliseconds(1))
        )

        try player.play(file: audio, prefs: prefs)
        let old = try XCTUnwrap(launcher.handles.first)
        player.stop()
        player.stop()
        let firstWaiter = Task { await player.stopAndWait() }
        let replacement = Task { @MainActor in
            await player.stopAndWait()
            try player.play(file: audio, prefs: prefs)
        }
        await old.waitForForceTermination()

        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(old.terminateCount, 1)
        XCTAssertEqual(old.forceTerminateCount, 1)
        old.acknowledgeExit()
        await firstWaiter.value
        try await replacement.value
        XCTAssertEqual(launcher.launchCount, 2)
        await player.stopAndWait()
    }

    func testTimeoutStopsClientAndRunsCleanupExactlyOnce() async {
        let client = PlaybackClientFake(events: [.duration(10), .timePosition(0.1)])
        let cleanups = PlaybackCounter()
        do {
            _ = try await PlaybackVerifier.verify(
                client: client, timeout: .milliseconds(1),
                cleanup: { await cleanups.increment() }
            )
            XCTFail("duration plus one position must time out")
        } catch PlaybackVerificationError.timeout {}
        catch { XCTFail("unexpected \(error)") }
        let stopCount = await client.stopCount
        let cleanupCount = await cleanups.value
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(cleanupCount, 1)
    }

    func testChunkDurationUsesValidatedWAVSumNotPlayerMetadata() throws {
        let directory = try TemporaryDirectory(); defer { try? directory.remove() }
        let first = directory.url.appendingPathComponent("first.wav")
        let second = directory.url.appendingPathComponent("second.wav")
        try WAVTestFixture.wav(samples: 480).write(to: first)
        try WAVTestFixture.wav(samples: 960).write(to: second)
        XCTAssertEqual(try PlaybackDuration.validatedSum([first, second], purpose: .reading(.speak)), 0.03, accuracy: 0.000_001)
    }

    func testPlaybackFailureKeepsProviderSuccessButWritesNoHistoryOrLastAudioAndDoesNotResynthesize() async throws {
        let fixture = try makeEngineFixture(playbackResult: .failure(PlaybackVerificationError.decode))
        fixture.engine.text = "one provider request"
        fixture.engine.speak()
        await fixture.waitForSynthesisCount(1)
        for _ in 0..<100 where fixture.engine.phase != .idle { try await Task.sleep(for: .milliseconds(1)) }
        let syntheses = await fixture.synthesis.count
        let successes = await fixture.health.count
        let retained = await fixture.lastAudio.currentArtifact()
        XCTAssertEqual(syntheses, 1)
        XCTAssertEqual(successes, 1)
        XCTAssertTrue(fixture.engine.history.isEmpty)
        XCTAssertNil(retained)
    }

    func testCanonicalFailureDoesNotResynthesizeOrMarkProviderSuccess() async throws {
        let fixture = try makeEngineFixture(playbackResult: .success(evidence()), corruptSynthesis: true)
        fixture.engine.text = "canonical failure"
        fixture.engine.speak()
        await fixture.waitForSynthesisCount(1)
        for _ in 0..<100 where fixture.engine.phase != .idle { try await Task.sleep(for: .milliseconds(1)) }
        let syntheses = await fixture.synthesis.count
        let successes = await fixture.health.count
        XCTAssertEqual(syntheses, 1)
        XCTAssertEqual(successes, 0)
        XCTAssertTrue(fixture.engine.history.isEmpty)
    }

    func testPlayerLaunchFailureDoesNotResynthesizeAndRetainsProviderSuccess() async throws {
        let fixture = try makeEngineFixture(playbackResult: .success(evidence()), playerThrows: true)
        fixture.engine.text = "player failure"
        fixture.engine.speak()
        await fixture.waitForSynthesisCount(1)
        for _ in 0..<100 where fixture.engine.phase != .idle { try await Task.sleep(for: .milliseconds(1)) }
        let syntheses = await fixture.synthesis.count
        let successes = await fixture.health.count
        XCTAssertEqual(syntheses, 1)
        XCTAssertEqual(successes, 1)
        XCTAssertTrue(fixture.engine.history.isEmpty)
    }

    func testVerifiedMultiChunkReadingRecordsAndPromotesExactlyOnceUsingWAVDurationSum() async throws {
        let fixture = try makeEngineFixture(playbackResult: .success(evidence()), durationSamples: [48_000, 96_000])
        fixture.engine.text = String(repeating: "字", count: 121)
        fixture.engine.speak()
        for _ in 0..<300 where fixture.engine.history.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let syntheses = await fixture.synthesis.count
        let successes = await fixture.health.count
        let retained = await fixture.lastAudio.currentHandle()
        XCTAssertEqual(syntheses, 2)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(fixture.engine.history.count, 1)
        XCTAssertEqual(fixture.engine.history.first?.seconds, 3)
        XCTAssertEqual(try XCTUnwrap(retained?.artifact.duration), 3, accuracy: 0.000_001)
        XCTAssertEqual(retained?.purpose, .reading(.speak))
    }

    func testVerifiedReplayRecordsAndPromotesExactlyOnceAsReplay() async throws {
        let fixture = try makeEngineFixture(playbackResult: .success(evidence()))
        let replay = HistoryEntry(
            id: UUID(), version: 1, text: "replay text", contentResolution: .valid,
            seconds: 1, providerID: .minimax, modelID: ModelID(rawValue: "speech-2.8-hd"),
            voiceID: VoiceID(rawValue: "voice-fixture"),
            rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 0)!,
            displayLabelSnapshot: "fixture", selectionResolution: .resolved,
            date: Date(), legacyAgoSnapshot: nil
        )
        fixture.engine.replay(replay)
        for _ in 0..<200 where fixture.engine.history.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let retained = await fixture.lastAudio.currentHandle()
        XCTAssertEqual(fixture.engine.history.count, 1)
        XCTAssertEqual(retained?.purpose, .reading(.replay))
    }

    private func evidence() -> PlaybackEvidence {
        PlaybackEvidence(firstTimePosition: 0.1, secondTimePosition: 0.2, observedAt: Date())
    }

    private func makeEngineFixture(
        playbackResult: Result<PlaybackEvidence, Error>,
        corruptSynthesis: Bool = false,
        playerThrows: Bool = false,
        durationSamples: [Int] = [48_000]
    ) throws -> PlaybackEngineFixture {
        let directory = try TemporaryDirectory()
        let player = PlaybackEngineFake(throwsOnPlay: playerThrows)
        let health = PlaybackHealthSpy()
        let synthesis = PlaybackSynthesisSpy(samples: durationSamples, corrupt: corruptSynthesis)
        let lastAudio = LastAudioArtifactStore()
        let history = HistoryMutationController(url: directory.url.appendingPathComponent("history.json"))
        let speech = EngineSpeechDependencies(
            cachePath: { text, _, _ in directory.url.appendingPathComponent("\(text.hashValue).wav") },
            cacheHit: { _ in false },
            synthesize: { _, _, _, url in try await synthesis.write(to: url) },
            concat: { _, _, _ in },
            captureCredential: { providerID in
                CredentialEnvelope(providerID: providerID, revision: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, secret: Data("fake".utf8))
            },
            verifyPlayback: { try playbackResult.get() },
            prepareSessionArtifact: { urls, purpose in
                try WAVConcatenator.concatenate(
                    urls,
                    to: directory.url.appendingPathComponent("session-\(UUID().uuidString).wav"),
                    purpose: purpose
                )
            },
            providerDidSucceed: { token in await health.record(token: token) }
        )
        let engine = Engine(
            player: player, speech: speech, credentialRegistry: CredentialScopeRegistry(),
            historyController: history, installCredentialHook: false, lastAudioStore: lastAudio
        )
        Task { await engine.installCredentialCancellationHook() }
        return PlaybackEngineFixture(
            directory: directory, engine: engine, synthesis: synthesis,
            health: health, lastAudio: lastAudio
        )
    }
}

@MainActor
private struct PlaybackEngineFixture {
    let directory: TemporaryDirectory
    let engine: Engine
    let synthesis: PlaybackSynthesisSpy
    let health: PlaybackHealthSpy
    let lastAudio: LastAudioArtifactStore
    func waitForSynthesisCount(_ expected: Int) async {
        for _ in 0..<200 {
            if await synthesis.count >= expected { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class PlaybackEngineFake: EnginePlayback {
    enum Failure: Error { case launch }
    var alive = false
    var paused = false
    var position = 0.0
    var duration = 999.0
    let throwsOnPlay: Bool
    init(throwsOnPlay: Bool) { self.throwsOnPlay = throwsOnPlay }
    func play(file: URL, prefs: Prefs, streaming: Bool) throws {
        if throwsOnPlay { throw Failure.launch }
        alive = true
    }
    func append(file: URL) throws {}
    func finishStream(prefs: Prefs) {}
    func stop() { alive = false }
    func stopAndWait() async {}
    func togglePause() { paused.toggle() }
    func seek(relative: Double) {}
    func setSpeed(_ speed: Double) {}
}

private actor PlaybackSynthesisSpy {
    private(set) var count = 0
    let samples: [Int]
    let corrupt: Bool
    init(samples: [Int], corrupt: Bool) { self.samples = samples; self.corrupt = corrupt }
    func write(to url: URL) throws {
        let index = count
        count += 1
        if corrupt { try Data("corrupt".utf8).write(to: url); return }
        try WAVTestFixture.wav(samples: samples[min(index, samples.count - 1)]).write(to: url)
    }
}

private actor PlaybackHealthSpy {
    private(set) var count = 0
    func record(token: SessionCurrentToken) {
        try? token.withCurrentCommitPermission { count += 1 }
    }
}

private actor PlaybackClientFake: PlayerClient {
    private var events: [MPVEvent]
    private(set) var stopCount = 0
    init(events: [MPVEvent]) { self.events = events }
    func nextEvent() async throws -> MPVEvent? {
        guard !events.isEmpty else { try await Task.sleep(for: .seconds(1)); return nil }
        return events.removeFirst()
    }
    func stopAndWait() async { stopCount += 1 }
}

private actor PlaybackCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct ShortPrivateTemporaryDirectory {
    let url: URL

    init() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        url = URL(fileURLWithPath: "/tmp/aloud-t-\(suffix)", isDirectory: true)
        guard Darwin.mkdir(url.path, S_IRWXU) == 0 else {
            throw MPVSocketError.systemCall(operation: "mkdir", code: errno)
        }
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}

private final class MPVConnectionFake: @unchecked Sendable, MPVUnixSocketConnection {
    enum Read { case data(Data), timeout, peerClosed }
    private let lock = NSLock()
    private var reads: [Read]
    private var writes: [Data] = []
    private(set) var closed = false

    init(reads: [Read]) { self.reads = reads }

    func write(_ data: Data) throws { lock.withLock { writes.append(data) } }
    func read(timeout: Duration) throws -> Data? {
        _ = timeout
        return try lock.withLock {
            guard !reads.isEmpty else { throw MPVSocketError.timeout }
            switch reads.removeFirst() {
            case .data(let data): return data
            case .timeout: throw MPVSocketError.timeout
            case .peerClosed: return nil
            }
        }
    }
    func close() { lock.withLock { closed = true } }

    var writtenRequestIDs: [Int64] {
        lock.withLock {
            writes.compactMap { data in
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                return (object["request_id"] as? NSNumber)?.int64Value
            }
        }
    }
}

private struct MPVConnectorFake: MPVUnixSocketConnecting {
    let connection: MPVConnectionFake
    func connect(to path: String, expectedProcessID: pid_t) throws -> any MPVUnixSocketConnection {
        _ = (path, expectedProcessID)
        return connection
    }
}

private final class MPVEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MPVEvent] = []
    var values: [MPVEvent] { lock.withLock { events } }
    func record(_ event: MPVEvent) { lock.withLock { events.append(event) } }
    func waitForCount(_ count: Int) async {
        for _ in 0..<500 {
            if values.count >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class MPVProcessHandleFake: @unchecked Sendable, MPVProcessHandle {
    private let lock = NSLock()
    private var running = true
    private var terminateCalls = 0
    private var forceTerminateCalls = 0
    private let onExit: @Sendable (Int32) -> Void
    private let ignoresTermination: Bool
    let processIdentifier: Int32 = 999_999
    var terminated: Bool { lock.withLock { terminateCalls > 0 } }
    var terminateCount: Int { lock.withLock { terminateCalls } }
    var forceTerminateCount: Int { lock.withLock { forceTerminateCalls } }
    var isRunning: Bool { lock.withLock { running } }
    var terminationStatus: Int32 { 0 }
    init(
        ignoresTermination: Bool = false,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.ignoresTermination = ignoresTermination
        self.onExit = onExit
    }
    func terminate() {
        let shouldExit = lock.withLock {
            terminateCalls += 1
            guard running, !ignoresTermination else { return false }
            running = false
            return true
        }
        if shouldExit { onExit(0) }
    }
    func forceTerminate() {
        lock.withLock { forceTerminateCalls += 1 }
    }
    func acknowledgeExit() {
        let shouldExit = lock.withLock {
            guard running else { return false }
            running = false
            return true
        }
        if shouldExit { onExit(0) }
    }
    func waitForExit() async throws {
        while isRunning {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func waitForForceTermination() async {
        for _ in 0..<500 {
            if forceTerminateCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class MPVProcessLauncherFake: @unchecked Sendable, MPVProcessLaunching {
    enum Failure: Error { case launch }
    private let lock = NSLock()
    private let failLaunch: Bool
    private let firstProcessIgnoresTermination: Bool
    private(set) var socketPaths: [String] = []
    private(set) var launchArguments: [[String]] = []
    private(set) var handles: [MPVProcessHandleFake] = []
    var launchCount: Int { lock.withLock { handles.count } }
    init(failLaunch: Bool = false, firstProcessIgnoresTermination: Bool = false) {
        self.failLaunch = failLaunch
        self.firstProcessIgnoresTermination = firstProcessIgnoresTermination
    }
    func launch(
        executable: URL,
        arguments: [String],
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any MPVProcessHandle {
        _ = executable
        let socket = try XCTUnwrap(
            arguments.first(where: { $0.hasPrefix("--input-ipc-server=") })?
                .replacingOccurrences(of: "--input-ipc-server=", with: "")
        )
        if failLaunch { throw Failure.launch }
        let ignoresTermination = lock.withLock {
            firstProcessIgnoresTermination && handles.isEmpty
        }
        let handle = MPVProcessHandleFake(
            ignoresTermination: ignoresTermination, onExit: onExit
        )
        lock.withLock {
            socketPaths.append(socket)
            launchArguments.append(arguments)
            handles.append(handle)
        }
        return handle
    }
}

private final class MPVSequenceConnectorFake: @unchecked Sendable, MPVUnixSocketConnecting {
    private let lock = NSLock()
    private var storedConnections: [MPVConnectionFake] = []
    var connections: [MPVConnectionFake] { lock.withLock { storedConnections } }
    func connect(to path: String, expectedProcessID: pid_t) throws -> any MPVUnixSocketConnection {
        _ = (path, expectedProcessID)
        let ids: [Int64] = [1, 2, 3, 4]
        let acknowledgements = ids.map { "{\"request_id\":\($0),\"error\":\"success\"}\n" }.joined()
        let connection = MPVConnectionFake(reads: [.data(Data(acknowledgements.utf8)), .timeout])
        lock.withLock { storedConnections.append(connection) }
        return connection
    }
    func waitForConnection(count: Int) async {
        for _ in 0..<1_000 {
            if connections.count >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

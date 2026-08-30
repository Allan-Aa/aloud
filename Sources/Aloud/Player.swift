import Darwin
import Foundation

struct PlaybackEvidence: Equatable, Sendable {
    let firstTimePosition: Double
    let secondTimePosition: Double
    let observedAt: Date
}

enum MPVEvent: Equatable, Sendable {
    case timePosition(Double)
    case duration(Double)
    case paused(Bool)
    case decodeError
    case audioOutputError
    case endFile(error: Bool)
    case ipcFailure(MPVIPCFailure)
}

enum MPVIPCFailure: Error, Equatable, Sendable {
    case handshakeRejected
    case handshakeTimeout
    case peerClosed
    case connectionFailed
    case unsafeEndpoint
    case protocolViolation
}

enum PlaybackVerificationError: Error, Equatable {
    case paused
    case decode
    case audioOutput
    case endFile
    case streamEnded
    case timeout
    case ipc(MPVIPCFailure)
}

protocol PlayerClient: Sendable {
    func nextEvent() async throws -> MPVEvent?
    func stopAndWait() async
}

struct PlaybackVerifier: Sendable {
    private var firstPosition: Double?
    private var explicitlyUnpaused = false
    private var terminalError: PlaybackVerificationError?

    mutating func consume(_ event: MPVEvent, observedAt: Date) throws -> PlaybackEvidence? {
        if let terminalError { throw terminalError }
        switch event {
        case .duration:
            return nil
        case .paused(let paused):
            guard !paused else { return try fail(.paused) }
            explicitlyUnpaused = true
            return nil
        case .decodeError:
            return try fail(.decode)
        case .audioOutputError:
            return try fail(.audioOutput)
        case .endFile(let error):
            guard !error else { return try fail(.endFile) }
            return try fail(.streamEnded)
        case .ipcFailure(let failure):
            return try fail(.ipc(failure))
        case .timePosition(let value):
            guard explicitlyUnpaused else { return nil }
            guard value.isFinite, value >= 0 else { return nil }
            guard let firstPosition else {
                self.firstPosition = value
                return nil
            }
            guard value > firstPosition else {
                if value < firstPosition { self.firstPosition = value }
                return nil
            }
            return PlaybackEvidence(
                firstTimePosition: firstPosition,
                secondTimePosition: value,
                observedAt: observedAt
            )
        }
    }

    static func verify(
        client: PlayerClient,
        timeout: Duration,
        cleanup: @escaping @Sendable () async -> Void
    ) async throws -> PlaybackEvidence {
        do {
            return try await withThrowingTaskGroup(of: PlaybackEvidence.self) { group in
                group.addTask {
                    var verifier = PlaybackVerifier()
                    while let event = try await client.nextEvent() {
                        if let evidence = try verifier.consume(event, observedAt: Date()) { return evidence }
                    }
                    throw PlaybackVerificationError.streamEnded
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw PlaybackVerificationError.timeout
                }
                guard let evidence = try await group.next() else {
                    throw PlaybackVerificationError.streamEnded
                }
                group.cancelAll()
                return evidence
            }
        } catch {
            await client.stopAndWait()
            await cleanup()
            throw error
        }
    }

    private mutating func fail(_ error: PlaybackVerificationError) throws -> PlaybackEvidence? {
        terminalError = error
        throw error
    }
}

/// Converts mpv's documented JSON IPC events into the playback-verification
/// vocabulary. Playback success and failures use this structured channel;
/// stderr wording is intentionally not treated as evidence.
enum MPVWireMessage: Equatable, Sendable {
    case acknowledgement(requestID: Int64, error: String)
    case event(MPVEvent)
}

enum MPVStructuredMessageParser {
    static func parse(_ line: String) -> MPVWireMessage? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let requestID = (object["request_id"] as? NSNumber)?.int64Value,
           let error = object["error"] as? String {
            return .acknowledgement(requestID: requestID, error: error)
        }
        return parseEvent(object).map(MPVWireMessage.event)
    }

    fileprivate static func parseEvent(_ object: [String: Any]) -> MPVEvent? {
        guard let event = object["event"] as? String else { return nil }
        switch event {
        case "property-change":
            guard let name = object["name"] as? String else { return nil }
            switch name {
            case "pause": return (object["data"] as? Bool).map(MPVEvent.paused)
            case "time-pos": return number(object["data"]).map(MPVEvent.timePosition)
            case "duration": return number(object["data"]).map(MPVEvent.duration)
            default: return nil
            }
        case "end-file":
            let reason = (object["reason"] as? String)?.lowercased()
            return .endFile(error: reason == "error" || object["file_error"] != nil)
        case "log-message":
            let level = ((object["level"] as? String) ?? "").lowercased()
            guard level == "error" || level == "fatal" else { return nil }
            let prefix = ((object["prefix"] as? String) ?? "").lowercased()
            let text = ((object["text"] as? String) ?? "").lowercased()
            let failure = text.contains("error") || text.contains("failed") || text.contains("failure")
            let decoder = prefix == "ad" || prefix.contains("ffmpeg") || prefix.contains("decoder")
                || text.contains("decode") || text.contains("codec")
            if failure && decoder { return .decodeError }
            let audioOutput = prefix == "ao" || prefix.hasPrefix("ao/")
                || text.contains("audio output") || text.contains("coreaudio")
            if failure && audioOutput { return .audioOutputError }
            return nil
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }
}

enum MPVStructuredEventParser {
    static func parse(_ line: String) -> MPVEvent? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return MPVStructuredMessageParser.parseEvent(object)
    }
}

enum PlaybackDuration {
    static func validatedSum(_ urls: [URL], purpose: SpeechPurpose) throws -> TimeInterval {
        guard !urls.isEmpty else { throw WAVAudioError.invalidDuration }
        return try urls.reduce(0) { partial, url in
            partial + (try WAVValidator.validate(url, purpose: purpose)).duration
        }
    }
}

final class PlaybackEventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MPVEvent] = []
    private var waiters: [UUID: CheckedContinuation<MPVEvent?, Error>] = [:]
    private var waiterOrder: [UUID] = []
    private var cancelled: Set<UUID> = []
    private var sessionID = UUID()

    func next() async throws -> MPVEvent? {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Result {
                    case event(MPVEvent)
                    case cancelled
                    case pending
                }
                let result: Result = lock.withLock {
                    if Task.isCancelled || cancelled.remove(id) != nil { return .cancelled }
                    if !events.isEmpty { return .event(events.removeFirst()) }
                    waiters[id] = continuation
                    waiterOrder.append(id)
                    return .pending
                }
                switch result {
                case .event(let event): continuation.resume(returning: event)
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .pending: break
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<MPVEvent?, Error>? = self.lock.withLock {
                if let continuation = self.waiters.removeValue(forKey: id) {
                    self.waiterOrder.removeAll { $0 == id }
                    return continuation
                }
                self.cancelled.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func push(_ event: MPVEvent, session: UUID) {
        let continuation: CheckedContinuation<MPVEvent?, Error>? = lock.withLock {
            guard session == sessionID else { return nil }
            while let id = waiterOrder.first {
                waiterOrder.removeFirst()
                if let continuation = waiters.removeValue(forKey: id) { return continuation }
            }
            events.append(event)
            return nil
        }
        continuation?.resume(returning: event)
    }

    @discardableResult
    func reset() -> UUID {
        let continuations: [CheckedContinuation<MPVEvent?, Error>] = lock.withLock {
            sessionID = UUID()
            let values = Array(waiters.values)
            events.removeAll()
            waiters.removeAll()
            waiterOrder.removeAll()
            cancelled.removeAll()
            return values
        }
        continuations.forEach { $0.resume(throwing: CancellationError()) }
        return lock.withLock { sessionID }
    }
}

enum MPVSocketError: Error, Equatable, Sendable {
    case endpointNotReady
    case unsafeEndpoint
    case invalidPath
    case systemCall(operation: String, code: Int32)
    case peerClosed
    case timeout
    case invalidResponse
    case frameTooLarge
    case processDrainRequired
}

struct MPVJSONLineFramer: Sendable {
    static let productionMaximumFrameBytes = 64 * 1_024
    private var pending = Data()
    private let maximumFrameBytes: Int

    init(maximumFrameBytes: Int = productionMaximumFrameBytes) {
        precondition(maximumFrameBytes > 0)
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            guard line.count <= maximumFrameBytes else { throw MPVSocketError.frameTooLarge }
            pending.removeSubrange(...newline)
            lines.append(line)
        }
        guard pending.count <= maximumFrameBytes else { throw MPVSocketError.frameTooLarge }
        return lines
    }
}

enum MPVPollAttempt: Equatable, Sendable {
    case ready
    case interrupted
    case failed(Int32)
}

enum MPVMonotonicPoll {
    static func wait(
        timeoutNanoseconds: UInt64,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        attempt: (UInt64) -> MPVPollAttempt
    ) throws {
        let start = now()
        let deadline = start.addingReportingOverflow(timeoutNanoseconds)
        let end = deadline.overflow ? UInt64.max : deadline.partialValue
        try wait(untilNanoseconds: end, now: now, attempt: attempt)
    }

    static func wait(
        untilNanoseconds deadline: UInt64,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        attempt: (UInt64) -> MPVPollAttempt
    ) throws {
        while true {
            let current = now()
            guard current < deadline else { throw MPVSocketError.timeout }
            switch attempt(deadline - current) {
            case .ready: return
            case .interrupted: continue
            case .failed(let code):
                throw MPVSocketError.systemCall(operation: "poll", code: code)
            }
        }
    }
}

enum MPVPeerIdentity {
    static func validate(
        endpointOwnerUID: uid_t,
        peerUID: uid_t,
        peerPID: pid_t,
        expectedPID: pid_t,
        currentUID: uid_t = geteuid()
    ) throws {
        guard endpointOwnerUID == currentUID,
              peerUID == currentUID,
              peerPID == expectedPID else { throw MPVSocketError.unsafeEndpoint }
    }
}

enum MPVSocketWriteAttempt: Equatable, Sendable {
    case written(Int)
    case interrupted
    case failed(Int32)
}

enum MPVSocketWritePump {
    static func writeAll(
        byteCount: Int,
        attempt: (_ offset: Int, _ remaining: Int) -> MPVSocketWriteAttempt
    ) throws {
        guard byteCount >= 0 else { throw MPVSocketError.invalidResponse }
        var offset = 0
        while offset < byteCount {
            switch attempt(offset, byteCount - offset) {
            case .written(let count):
                guard count > 0, count <= byteCount - offset else {
                    throw MPVSocketError.peerClosed
                }
                offset += count
            case .interrupted:
                continue
            case .failed(let code):
                if code == EPIPE || code == ECONNRESET { throw MPVSocketError.peerClosed }
                throw MPVSocketError.systemCall(operation: "send", code: code)
            }
        }
    }
}

enum MPVSocketDescriptorPreparer {
    static func requireNoSIGPIPE(_ setOption: () -> Int32) throws {
        guard setOption() == 0 else {
            throw MPVSocketError.systemCall(operation: "setsockopt(SO_NOSIGPIPE)", code: errno)
        }
    }
}

struct PrivateMPVIPCDirectory: @unchecked Sendable {
    let directory: URL
    let socket: URL

    static func applicationTemporaryRoot(
        userID: uid_t = geteuid()
    ) throws -> URL {
        // FileManager.temporaryDirectory is long on sandboxed macOS installs and
        // can exceed sockaddr_un.sun_path once the isolated playback directory
        // and `ipc.sock` are appended. Keep a private per-user application root
        // in the system temporary directory; playback UUIDs still isolate app
        // instances and individual launches beneath it.
        let root = URL(fileURLWithPath: "/tmp/aloud-\(userID)", isDirectory: true)
        if Darwin.mkdir(root.path, S_IRWXU) != 0, errno != EEXIST {
            throw MPVSocketError.systemCall(operation: "mkdir", code: errno)
        }
        try validatePrivateDirectory(root)
        return root
    }

    static func create(
        in root: URL = FileManager.default.temporaryDirectory,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        nonce: UUID = UUID()
    ) throws -> PrivateMPVIPCDirectory {
        try validatePrivateRoot(root)
        let identifier = nonce.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // sockaddr_un paths are short on Darwin. The per-user application temp
        // root keeps this exact path within sun_path while PID+UUID isolates
        // simultaneous Aloud instances and consecutive playback sessions.
        let directory = root.appendingPathComponent("aloud-mpv-\(processID)-\(identifier)", isDirectory: true)
        let socket = directory.appendingPathComponent("ipc.sock")
        guard socket.path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw MPVSocketError.invalidPath
        }
        guard Darwin.mkdir(directory.path, S_IRWXU) == 0 else {
            if errno == EEXIST { throw MPVSocketError.unsafeEndpoint }
            throw MPVSocketError.systemCall(operation: "mkdir", code: errno)
        }
        do {
            try validatePrivateDirectory(directory)
            return PrivateMPVIPCDirectory(directory: directory, socket: socket)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func validatePrivateDirectory(_ directory: URL) throws {
        var information = stat()
        guard Darwin.lstat(directory.path, &information) == 0 else {
            throw MPVSocketError.systemCall(operation: "lstat", code: errno)
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid(),
              information.st_mode & 0o777 == 0o700 else {
            throw MPVSocketError.unsafeEndpoint
        }
    }

    private static func validatePrivateRoot(_ root: URL) throws {
        var information = stat()
        guard Darwin.lstat(root.path, &information) == 0 else {
            throw MPVSocketError.systemCall(operation: "lstat", code: errno)
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid() else {
            throw MPVSocketError.unsafeEndpoint
        }
    }

    func cleanup() {
        // `directory` is an exact UUID path created above; no broad glob or
        // caller-supplied recursive target is ever accepted.
        try? FileManager.default.removeItem(at: directory)
    }
}

protocol MPVUnixSocketConnection: Sendable {
    func write(_ data: Data) throws
    func read(timeout: Duration) throws -> Data?
    func close()
}

protocol MPVUnixSocketConnecting: Sendable {
    func connect(to path: String, expectedProcessID: pid_t) throws -> any MPVUnixSocketConnection
}

private final class DarwinMPVUnixSocketConnection: @unchecked Sendable, MPVUnixSocketConnection {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ data: Data) throws {
        let descriptor = try currentDescriptor()
        try data.withUnsafeBytes { bytes in
            try MPVSocketWritePump.writeAll(byteCount: bytes.count) { offset, remaining in
                let result = Darwin.send(descriptor, bytes.baseAddress?.advanced(by: offset), remaining, 0)
                if result >= 0 { return .written(result) }
                if errno == EINTR { return .interrupted }
                return .failed(errno)
            }
        }
    }

    func read(timeout: Duration) throws -> Data? {
        let descriptor = try currentDescriptor()
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let nanoseconds = timeout.nanosecondsClamped
        let start = DispatchTime.now().uptimeNanoseconds
        let computedDeadline = start.addingReportingOverflow(nanoseconds)
        let deadline = computedDeadline.overflow ? UInt64.max : computedDeadline.partialValue
        while true {
            try MPVMonotonicPoll.wait(untilNanoseconds: deadline) { remaining in
                let milliseconds = Int32(clamping: max(1, (remaining + 999_999) / 1_000_000))
                let result = Darwin.poll(&pollDescriptor, 1, milliseconds)
                if result > 0 { return .ready }
                if result == 0 { return .interrupted }
                if errno == EINTR { return .interrupted }
                return .failed(errno)
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == ECONNRESET { throw MPVSocketError.peerClosed }
                throw MPVSocketError.systemCall(operation: "recv", code: errno)
            }
            return Data(buffer[0..<count])
        }
    }

    func close() {
        let descriptor = lock.withLock {
            let value = self.descriptor
            self.descriptor = -1
            return value
        }
        guard descriptor >= 0 else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func currentDescriptor() throws -> Int32 {
        try lock.withLock {
            guard descriptor >= 0 else { throw MPVSocketError.peerClosed }
            return descriptor
        }
    }
}

struct DarwinMPVUnixSocketConnector: MPVUnixSocketConnecting {
    func connect(to path: String, expectedProcessID: pid_t) throws -> any MPVUnixSocketConnection {
        let endpointOwnerUID = try validateSocketEndpoint(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw MPVSocketError.systemCall(operation: "socket", code: errno)
        }
        do {
            try MPVSocketDescriptorPreparer.requireNoSIGPIPE {
                var enabled: Int32 = 1
                return Darwin.setsockopt(
                    descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard bytes.count < capacity else { throw MPVSocketError.invalidPath }
            withUnsafeMutablePointer(to: &address.sun_path) { raw in
                raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                    destination[bytes.count] = 0
                }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                throw MPVSocketError.systemCall(operation: "connect", code: errno)
            }
            var peerUID = uid_t()
            var peerGID = gid_t()
            guard getpeereid(descriptor, &peerUID, &peerGID) == 0 else {
                throw MPVSocketError.systemCall(operation: "getpeereid", code: errno)
            }
            var peerPID = pid_t()
            var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
            guard Darwin.getsockopt(
                descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize
            ) == 0 else {
                throw MPVSocketError.systemCall(operation: "getsockopt(LOCAL_PEERPID)", code: errno)
            }
            try MPVPeerIdentity.validate(
                endpointOwnerUID: endpointOwnerUID, peerUID: peerUID,
                peerPID: peerPID, expectedPID: expectedProcessID
            )
            return DarwinMPVUnixSocketConnection(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validateSocketEndpoint(_ path: String) throws -> uid_t {
        var information = stat()
        guard Darwin.lstat(path, &information) == 0 else {
            if errno == ENOENT { throw MPVSocketError.endpointNotReady }
            throw MPVSocketError.systemCall(operation: "lstat", code: errno)
        }
        guard information.st_mode & S_IFMT == S_IFSOCK else {
            throw MPVSocketError.unsafeEndpoint
        }
        return information.st_uid
    }
}

private extension Duration {
    var nanosecondsClamped: UInt64 {
        let parts = components
        guard parts.seconds >= 0, parts.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(parts.seconds)
        let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return UInt64.max }
        let fraction = UInt64(parts.attoseconds / 1_000_000_000)
        let total = whole.partialValue.addingReportingOverflow(fraction)
        return total.overflow ? UInt64.max : total.partialValue
    }
}

/// One-shot commands use the same endpoint validation and SIGPIPE-safe
/// connection as the event observer.
final class MPVSocket {
    private let path: String
    private let expectedProcessID: pid_t
    private let connector: any MPVUnixSocketConnecting

    init(
        path: String,
        expectedProcessID: pid_t,
        connector: any MPVUnixSocketConnecting = DarwinMPVUnixSocketConnector()
    ) {
        self.path = path
        self.expectedProcessID = expectedProcessID
        self.connector = connector
    }

    func send(_ command: [Any], retries: Int = 6) -> [String: Any]? {
        for attempt in 0..<retries {
            do { return try attemptOnce(command) }
            catch MPVSocketError.endpointNotReady {
                usleep(UInt32(25_000 * (attempt + 1)))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func attemptOnce(_ command: [Any]) throws -> [String: Any]? {
        let connection = try connector.connect(to: path, expectedProcessID: expectedProcessID)
        defer { connection.close() }
        let requestID = Int64.random(in: 1...Int64.max)
        guard var payload = try? JSONSerialization.data(
            withJSONObject: ["command": command, "request_id": requestID]
        ) else { throw MPVSocketError.invalidResponse }
        payload.append(0x0A)
        try connection.write(payload)
        var framer = MPVJSONLineFramer()
        while true {
            guard let data = try connection.read(timeout: .seconds(1)) else {
                throw MPVSocketError.peerClosed
            }
            for line in try framer.append(data) {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      (object["request_id"] as? NSNumber)?.int64Value == requestID else { continue }
                return object
            }
        }
    }
}

/// Persistent, acknowledged mpv JSON IPC observation. Events received before
/// all four subscription acknowledgements are dropped and can never count as
/// playback evidence.
final class MPVStructuredEventObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var connection: (any MPVUnixSocketConnection)?
    private var cancelled = false
    private var started = false
    private var task: Task<Void, Never>?
    private let path: String
    private let expectedProcessID: pid_t
    private let connector: any MPVUnixSocketConnecting
    private let requestIDs: [Int64]
    private let handshakeTimeout: Duration
    private let maximumPreHandshakeEvents: Int
    private let receive: @Sendable (MPVEvent) -> Void

    init(
        path: String,
        expectedProcessID: pid_t = 0,
        connector: any MPVUnixSocketConnecting = DarwinMPVUnixSocketConnector(),
        requestIDs: [Int64] = (0..<4).map { _ in Int64.random(in: 1...Int64.max) },
        handshakeTimeout: Duration = .seconds(1),
        maximumPreHandshakeEvents: Int = 256,
        receive: @escaping @Sendable (MPVEvent) -> Void
    ) {
        precondition(requestIDs.count == 4 && Set(requestIDs).count == 4)
        precondition(maximumPreHandshakeEvents > 0)
        self.path = path
        self.expectedProcessID = expectedProcessID
        self.connector = connector
        self.requestIDs = requestIDs
        self.handshakeTimeout = handshakeTimeout
        self.maximumPreHandshakeEvents = maximumPreHandshakeEvents
        self.receive = receive
    }

    func start() {
        let shouldStart = lock.withLock {
            guard !started else { return false }
            started = true
            completion.enter()
            return true
        }
        guard shouldStart else { return }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            defer { self?.completion.leave() }
            self?.run()
        }
    }

    func cancelAndWait() {
        let connection = lock.withLock {
            cancelled = true
            return self.connection
        }
        connection?.close()
        task?.cancel()
        _ = completion.wait(timeout: .now() + 2)
        task = nil
    }

    private func run() {
        do {
            let connection = try connectWithRetry()
            let shouldClose = lock.withLock {
                if cancelled { return true }
                self.connection = connection
                return false
            }
            guard !shouldClose else { connection.close(); return }
            defer {
                connection.close()
                lock.withLock { self.connection = nil }
            }
            try subscribe(connection)
            try observe(connection)
        } catch let failure as MPVIPCFailure {
            emitFailure(failure)
        } catch MPVSocketError.unsafeEndpoint {
            emitFailure(.unsafeEndpoint)
        } catch MPVSocketError.peerClosed {
            emitFailure(.peerClosed)
        } catch MPVSocketError.frameTooLarge {
            emitFailure(.protocolViolation)
        } catch {
            emitFailure(.connectionFailed)
        }
    }

    private func connectWithRetry() throws -> any MPVUnixSocketConnection {
        for _ in 0..<40 {
            if isCancelled { throw CancellationError() }
            do { return try connector.connect(to: path, expectedProcessID: expectedProcessID) }
            catch MPVSocketError.endpointNotReady { usleep(25_000) }
        }
        throw MPVIPCFailure.connectionFailed
    }

    private func subscribe(_ connection: any MPVUnixSocketConnection) throws {
        let commands: [[Any]] = [
            ["observe_property", 1, "pause"],
            ["observe_property", 2, "time-pos"],
            ["observe_property", 3, "duration"],
            ["request_log_messages", "warn"],
        ]
        for (command, requestID) in zip(commands, requestIDs) {
            guard var payload = try? JSONSerialization.data(
                withJSONObject: ["command": command, "request_id": requestID]
            ) else { throw MPVSocketError.invalidResponse }
            payload.append(0x0A)
            try connection.write(payload)
        }
    }

    private func observe(_ connection: any MPVUnixSocketConnection) throws {
        var acknowledgements = Set<Int64>()
        var bufferedEvents: [MPVEvent] = []
        var framer = MPVJSONLineFramer()
        let expected = Set(requestIDs)
        let clock = ContinuousClock()
        let handshakeDeadline = clock.now.advanced(by: handshakeTimeout)
        while !isCancelled {
            let readTimeout: Duration
            if acknowledgements == expected {
                readTimeout = .seconds(1)
            } else {
                guard clock.now < handshakeDeadline else {
                    throw MPVIPCFailure.handshakeTimeout
                }
                readTimeout = clock.now.duration(to: handshakeDeadline)
            }
            let data: Data
            do {
                guard let next = try connection.read(timeout: readTimeout) else {
                    throw MPVIPCFailure.peerClosed
                }
                data = next
            } catch MPVSocketError.timeout {
                if acknowledgements != expected { throw MPVIPCFailure.handshakeTimeout }
                continue
            }
            for frame in try framer.append(data) {
                let line = String(decoding: frame, as: UTF8.self)
                guard let message = MPVStructuredMessageParser.parse(line) else { continue }
                switch message {
                case .acknowledgement(let requestID, let error):
                    guard expected.contains(requestID) else { continue }
                    guard error == "success" else { throw MPVIPCFailure.handshakeRejected }
                    acknowledgements.insert(requestID)
                    if acknowledgements == expected, !bufferedEvents.isEmpty {
                        for event in bufferedEvents {
                            receive(event)
                            if case .endFile = event { return }
                        }
                        bufferedEvents.removeAll(keepingCapacity: false)
                    }
                case .event(let event):
                    if acknowledgements == expected {
                        receive(event)
                        if case .endFile = event { return }
                    } else {
                        guard bufferedEvents.count < maximumPreHandshakeEvents else {
                            throw MPVIPCFailure.protocolViolation
                        }
                        bufferedEvents.append(event)
                    }
                }
            }
        }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled || Task.isCancelled }
    }

    private func emitFailure(_ failure: MPVIPCFailure) {
        guard !isCancelled else { return }
        receive(.ipcFailure(failure))
    }
}

protocol MPVProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    var processIdentifier: Int32 { get }
    func terminate()
    func forceTerminate()
    func waitForExit() async throws
}

protocol MPVProcessLaunching: Sendable {
    func launch(
        executable: URL,
        arguments: [String],
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any MPVProcessHandle
}

private actor MPVProcessExitLatch {
    private var exited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !exited else { return }
        exited = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !exited else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class FoundationMPVProcessHandle: @unchecked Sendable, MPVProcessHandle {
    let process: Process
    let exitLatch: MPVProcessExitLatch
    init(process: Process, exitLatch: MPVProcessExitLatch) {
        self.process = process
        self.exitLatch = exitLatch
    }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }
    var processIdentifier: Int32 { process.processIdentifier }
    func terminate() { process.terminate() }
    func forceTerminate() { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    func waitForExit() async throws { await exitLatch.wait() }
}

struct FoundationMPVProcessLauncher: MPVProcessLaunching {
    func launch(
        executable: URL,
        arguments: [String],
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any MPVProcessHandle {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AloudError.binaryMissing("mpv")
        }
        let process = Process()
        let exitLatch = MPVProcessExitLatch()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await exitLatch.signal()
                onExit(status)
            }
        }
        try process.run()
        return FoundationMPVProcessHandle(process: process, exitLatch: exitLatch)
    }
}

struct MPVTerminationTiming: Sendable {
    let grace: Duration
    let poll: Duration

    static let production = MPVTerminationTiming(
        grace: .seconds(2), poll: .milliseconds(10)
    )
}

enum MPVProcessDrain {
    static func run(
        _ process: any MPVProcessHandle,
        timing: MPVTerminationTiming
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timing.grace)
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: timing.poll)
        }
        if process.isRunning { process.forceTerminate() }
        try? await process.waitForExit()
    }
}

@MainActor
final class Player: ObservableObject, PlayerClient, @unchecked Sendable {
    private static let liveShared = Player()
    private static let auditedShared = Player()

    static var shared: Player {
        withSharedPreviewAccessAudit(auditedValue: auditedShared) { liveShared }
    }

    static func withSharedPreviewAccessAudit<Value>(
        auditedValue: @autoclosure () -> Value,
        perform: () -> Value
    ) -> Value {
        PreviewAccessAudit.access(.player, auditedValue: auditedValue(), perform: perform)
    }

    @Published private(set) var alive = false
    @Published private(set) var paused = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0

    private var proc: (any MPVProcessHandle)?
    private struct TerminatingProcess {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var terminatingProcess: TerminatingProcess?
    nonisolated private let playbackEvents = PlaybackEventQueue()
    private var playbackSessionID: UUID?
    private var ipcDirectory: PrivateMPVIPCDirectory?
    private var ipc: MPVSocket?
    private var structuredEvents: MPVStructuredEventObserver?
    private var poller: Timer?
    private let processLauncher: any MPVProcessLaunching
    private let socketConnector: any MPVUnixSocketConnecting
    private let ipcRoot: URL?
    private let terminationTiming: MPVTerminationTiming

    init(
        processLauncher: any MPVProcessLaunching = FoundationMPVProcessLauncher(),
        socketConnector: any MPVUnixSocketConnecting = DarwinMPVUnixSocketConnector(),
        ipcRoot: URL? = nil,
        terminationTiming: MPVTerminationTiming = .production
    ) {
        self.processLauncher = processLauncher
        self.socketConnector = socketConnector
        self.ipcRoot = ipcRoot
        self.terminationTiming = terminationTiming
    }

    /// streaming = 首块先播,后面用 append() 往播放列表里续。
    /// mpv 必须 --idle=yes,否则播完首块就退出,后面的块没地方续。
    func play(file: URL, prefs: Prefs, streaming: Bool = false) throws {
        try startPlayback(file: file, prefs: prefs, streaming: streaming, requiresCanonicalWAV: true)
    }

    func playSample(file: URL, prefs: Prefs) throws {
        try startPlayback(file: file, prefs: prefs, streaming: false, requiresCanonicalWAV: false)
    }

    private func startPlayback(file: URL, prefs: Prefs, streaming: Bool, requiresCanonicalWAV: Bool) throws {
        guard proc == nil, terminatingProcess == nil else {
            throw MPVSocketError.processDrainRequired
        }
        let playbackSessionID = playbackEvents.reset()
        self.playbackSessionID = playbackSessionID
        if requiresCanonicalWAV { try LegacyAudioIsolation.requireCanonical(file) }
        let root = try ipcRoot ?? PrivateMPVIPCDirectory.applicationTemporaryRoot()
        let ipcDirectory = try PrivateMPVIPCDirectory.create(in: root)
        let socketPath = ipcDirectory.socket.path
        let args = [
            "--no-video", "--no-terminal", "--msg-level=all=warn",
            "--input-ipc-server=\(socketPath)",
            streaming ? "--idle=yes" : "--idle=no", "--keep-open=no",
            // 播放列表混采样率(MiniMax 32k、静音垫 24k)时,默认的 gapless=weak 会在
            // 换格式时重开音频设备并丢掉已缓冲的约 1.2 秒。统一重采样,设备只配置一次。
            "--gapless-audio=yes",
            "--audio-samplerate=48000",
            "--audio-channels=stereo",
            "--speed=\(prefs.playbackSpeed > 0 ? prefs.playbackSpeed : 1)",
            file.path,
        ]
        let process: any MPVProcessHandle
        do {
            process = try processLauncher.launch(
                executable: URL(fileURLWithPath: prefs.mpvBin), arguments: args
            ) { [playbackEvents] status in
                playbackEvents.push(.endFile(error: status != 0), session: playbackSessionID)
                ipcDirectory.cleanup()
            }
        } catch {
            ipcDirectory.cleanup()
            self.playbackSessionID = nil
            playbackEvents.reset()
            throw error
        }
        proc = process
        self.ipcDirectory = ipcDirectory
        ipc = MPVSocket(
            path: socketPath, expectedProcessID: process.processIdentifier,
            connector: socketConnector
        )
        let observer = MPVStructuredEventObserver(
            path: socketPath, expectedProcessID: process.processIdentifier,
            connector: socketConnector
        ) { [playbackEvents] event in
            playbackEvents.push(event, session: playbackSessionID)
        }
        structuredEvents = observer
        observer.start()
        alive = true
        paused = false
        position = 0
        startPolling()
    }

    /// 往播放列表尾部追加。缓冲空了(idle)时它会立刻接着播。
    func append(file: URL) throws {
        try LegacyAudioIsolation.requireCanonical(file)
        _ = ipc?.send(["loadfile", file.path, "append-play"], retries: 3)
    }

    /// Task 12 deliberately does not append the legacy MP3 silence pad.
    func finishStream(prefs: Prefs) {
        _ = prefs
    }

    func togglePause() {
        guard alive else { return }
        _ = ipc?.send(["cycle", "pause"], retries: 2)
        paused.toggle()
    }

    func seek(relative seconds: Double) {
        guard alive else { return }
        _ = ipc?.send(["seek", seconds, "relative"], retries: 2)
    }

    func seek(absolute seconds: Double) {
        guard alive else { return }
        _ = ipc?.send(["seek", seconds, "absolute"], retries: 2)
    }

    func setSpeed(_ s: Double) {
        guard alive else { return }
        _ = ipc?.send(["set_property", "speed", s], retries: 2)
    }

    func stop() {
        beginTerminationIfNeeded()
    }

    nonisolated func nextEvent() async throws -> MPVEvent? {
        try await playbackEvents.next()
    }

    func stopAndWait() async {
        beginTerminationIfNeeded()
        guard let terminating = terminatingProcess else { return }
        await terminating.task.value
        if terminatingProcess?.id == terminating.id {
            terminatingProcess = nil
        }
    }

    private func beginTerminationIfNeeded() {
        poller?.invalidate(); poller = nil
        structuredEvents?.cancelAndWait(); structuredEvents = nil
        ipc = nil
        playbackSessionID = nil
        playbackEvents.reset()
        guard terminatingProcess == nil, let process = proc else {
            alive = false
            paused = false
            position = 0
            duration = 0
            return
        }
        let directory = ipcDirectory
        ipcDirectory = nil
        proc = nil
        let id = UUID()
        let timing = terminationTiming
        if process.isRunning { process.terminate() }
        let task = Task {
            await MPVProcessDrain.run(process, timing: timing)
            directory?.cleanup()
        }
        terminatingProcess = TerminatingProcess(id: id, task: task)
        alive = false
        paused = false
        position = 0
        duration = 0
    }

    private func startPolling() {
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let p = proc else { return }
        guard playbackSessionID != nil else { return }
        if !p.isRunning { stop(); return }
        if let r = ipc?.send(["get_property", "pause"], retries: 1),
           let value = r["data"] as? Bool {
            paused = value
            guard !value else { return }
        } else {
            // A time position without a contemporaneous pause observation is
            // not evidence that audio is actively advancing.
            return
        }
        if let r = ipc?.send(["get_property", "time-pos"], retries: 1),
           let v = r["data"] as? Double {
            // 静音垫也在播放列表里,它开始播就当作已经念完了,否则进度会往回跳
            if duration > 0, v > duration { return }
            position = v
        }
        if duration == 0,
           let r = ipc?.send(["get_property", "duration"], retries: 1),
           let v = r["data"] as? Double, v > 0 {
            // 减掉静音垫,报给界面的时长才是真正的语音长度
            duration = max(0, v)
        }
    }
}

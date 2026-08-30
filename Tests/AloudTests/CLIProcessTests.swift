import Foundation
import XCTest
@testable import Aloud

final class CLIProcessTests: XCTestCase {
    // Catches a disabled route that leaks user input, writes stdout, or returns a non-usage exit code.
    func testDisabledRoutesReturnExactMigrationOracleWithoutSideEffects() throws {
        let canary = ["SECRET", "CANARY"].joined(separator: "-")
        for command in ["--import-key", "--synth", "--read-selection"] {
            let sandbox = try IsolatedProcessEnvironment()
            defer { try? sandbox.remove() }
            let before = try sandbox.fileFingerprints()
            let result = try runAloud(
                arguments: [command, canary, "--rate", "99"],
                environment: sandbox.environment
            )
            XCTAssertEqual(result.status, 64, command)
            XCTAssertEqual(result.stdout, Data(), command)
            XCTAssertEqual(result.stderr, Data("unsupported: migrate-to-app-UI\n".utf8), command)
            XCTAssertFalse(result.stdout.contains(Data(canary.utf8)), command)
            XCTAssertFalse(result.stderr.contains(Data(canary.utf8)), command)
            XCTAssertEqual(try sandbox.fileFingerprints(), before, "\(command) wrote isolated HOME/TMPDIR/XDG state")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.childProcessMarker.path), "\(command) initialized a PATH-resolved child service")
        }
    }

    // Catches malformed and unknown CLI routes that do not return the exact usage oracle.
    func testInvalidRoutesReturnExactInvalidArgumentsOracle() throws {
        for arguments in [["--export-shots"], ["--export-shots", "/tmp/shots", "tail"], ["--demo-playing"], ["--unknown"]] {
            let result = try runAloud(arguments: arguments)
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertEqual(result.stdout, Data(), "\(arguments)")
            XCTAssertEqual(result.stderr, Data("unsupported: invalid-cli-arguments\n".utf8), "\(arguments)")
        }
    }

    // Proves the profile permits only its initial executable and rejects an absolute child exec.
    func testSandboxBlocksAbsoluteChildExec() throws {
        let result = try runSandboxed(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "system { \"/bin/sh\" } \"/bin/sh\", \"-c\", \"exit 0\"; exit($? >> 8)"],
            environment: ProcessInfo.processInfo.environment
        )

        XCTAssertNotEqual(result.status, 0)
    }
}

private func runAloud(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> (status: Int32, stdout: Data, stderr: Data) {
    try runSandboxed(executable: aloudExecutableURL, arguments: arguments, environment: environment)
}

private let aloudExecutableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".build/debug/Aloud")
    .resolvingSymlinksInPath()

private func runSandboxed(
    executable: URL,
    arguments: [String],
    environment: [String: String]
) throws -> (status: Int32, stdout: Data, stderr: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = ["-p", sandboxProfile(allowingInitialExecutable: executable), executable.path] + arguments
    let stdout = Pipe()
    let stderr = Pipe()
    let input = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = input
    process.environment = environment
    // The full release gate launches these sandboxed probes concurrently with
    // hundreds of test workers. Keep a hard safety bound without mistaking
    // scheduler/loader contention for a CLI hang.
    let finished = XCTestExpectation(description: "Aloud exits within ten seconds")
    process.terminationHandler = { _ in finished.fulfill() }
    try process.run()
    let result = XCTWaiter.wait(for: [finished], timeout: 10)
    if process.isRunning { process.terminate() }
    try input.fileHandleForWriting.close()
    XCTAssertEqual(result, .completed, "Aloud did not terminate within the safety bound")
    return (process.terminationStatus, stdout.fileHandleForReading.readDataToEndOfFile(), stderr.fileHandleForReading.readDataToEndOfFile())
}

private func sandboxProfile(allowingInitialExecutable executable: URL) -> String {
    "(version 1) (allow default) (deny network*) (deny process-exec) (allow process-exec (literal \"\(executable.path)\"))"
}

private struct IsolatedProcessEnvironment {
    let root: URL
    let childProcessMarker: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        childProcessMarker = root.appendingPathComponent("child-process-marker")
        let directories = ["home", "tmp", "xdg-config", "xdg-cache", "xdg-data", "xdg-runtime", "bin"]
        for directory in directories {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for tool in ["op", "ffmpeg", "mpv"] {
            let toolURL = root.appendingPathComponent("bin/\(tool)")
            let script = "#!/bin/sh\nprintf invoked > \"$ALoud_CHILD_PROCESS_MARKER\"\nexit 97\n"
            try Data(script.utf8).write(to: toolURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
        }
    }

    var environment: [String: String] {
        [
            "HOME": root.appendingPathComponent("home").path,
            "TMPDIR": root.appendingPathComponent("tmp").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("xdg-config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("xdg-cache").path,
            "XDG_DATA_HOME": root.appendingPathComponent("xdg-data").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("xdg-runtime").path,
            "PATH": root.appendingPathComponent("bin").path,
            "ALoud_CHILD_PROCESS_MARKER": childProcessMarker.path,
        ]
    }

    func fileFingerprints() throws -> [String: String] {
        let manager = FileManager.default
        let files = try manager.subpathsOfDirectory(atPath: root.path).sorted()
        return try Dictionary(uniqueKeysWithValues: files.map { path in
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                return (path, try Data(contentsOf: url).base64EncodedString())
            }
            return (path, "directory")
        })
    }

    func remove() throws {
        try FileManager.default.removeItem(at: root)
    }
}

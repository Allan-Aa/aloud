import Foundation
import XCTest
@testable import Aloud

final class CLIDispatcherTests: XCTestCase {
    func testCurrentReplyDiagnosticRequiresExactArguments() {
        XCTAssertEqual(CLIDispatcher.route(arguments: RecordingArguments(["Aloud", "--diagnose-current-ai-reply"])), .diagnoseCurrentAIReply)
        XCTAssertEqual(CLIDispatcher.route(arguments: RecordingArguments(["Aloud", "--diagnose-current-ai-reply", "extra"])), .invalidArguments)
    }

    // Catches a dispatcher that scans or parses a disabled command's opaque tail.
    func testDisabledSynthReadsOnlyArgvOne() {
        let canary = ["SECRET", "CANARY"].joined(separator: "-")
        let arguments = RecordingArguments(["Aloud", "--synth", canary, "--rate", "99"])

        XCTAssertEqual(
            CLIDispatcher.route(arguments: arguments),
            .terminate(
                status: 64,
                stdout: Data(),
                stderr: Data("unsupported: migrate-to-app-UI\n".utf8)
            )
        )
        XCTAssertEqual(arguments.accessedIndices, [1])
    }

    // Catches disabled commands that accidentally inspect index 2 or later.
    func testDisabledRoutesDoNotReadThrowingTail() {
        for command in ["--import-key", "--synth", "--read-selection"] {
            XCTAssertEqual(
                CLIDispatcher.route(arguments: ThrowingTailArguments(command: command)),
                .terminate(
                    status: 64,
                    stdout: Data(),
                    stderr: Data("unsupported: migrate-to-app-UI\n".utf8)
                )
            )
        }
    }

    // Catches exports that accept a missing directory or silently ignore extra arguments.
    func testExportRequiresExactlyOneDirectoryArgument() {
        XCTAssertEqual(
            CLIDispatcher.route(arguments: RecordingArguments(["Aloud", "--export-shots", "/tmp/shots"])),
            .exportShots(outputDirectory: "/tmp/shots")
        )
        XCTAssertEqual(
            CLIDispatcher.route(arguments: RecordingArguments(["Aloud", "--export-shots"])),
            .invalidArguments
        )
        XCTAssertEqual(
            CLIDispatcher.route(arguments: RecordingArguments(["Aloud", "--export-shots", "/tmp/shots", "tail"])),
            .invalidArguments
        )
    }

    // Catches a first-argument router that treats later or prefix-like values as commands.
    func testOnlyExactFirstArgumentSelectsACommand() {
        let canary = ["SECRET", "CANARY"].joined(separator: "-")
        let migration = CLIRoute.terminate(
            status: 64, stdout: Data(), stderr: Data("unsupported: migrate-to-app-UI\n".utf8)
        )
        let invalid = CLIRoute.invalidArguments
        let cases: [([String], CLIRoute)] = [
            (["Aloud", "value", "--synth", canary], invalid),
            (["Aloud", "--synthesized"], invalid),
            (["Aloud", "--synth", "--synth"], migration),
            (["Aloud", "--import-key", canary], migration),
            (["Aloud", "--read-selection", canary], migration),
            (["Aloud", "--demo-playing"], invalid),
            (["Aloud", "--unknown"], invalid),
        ]

        for (arguments, expected) in cases {
            XCTAssertEqual(CLIDispatcher.route(arguments: RecordingArguments(arguments)), expected)
        }
    }

    // Catches launch paths that treat an absent argv[0] as a normal app startup.
    func testOnlyOneArgumentLaunchesApp() {
        XCTAssertEqual(CLIDispatcher.route(arguments: RecordingArguments(["Aloud"])), .launchApp)
        XCTAssertEqual(CLIDispatcher.route(arguments: RecordingArguments([])), .invalidArguments)
    }
}

private final class RecordingArguments: CLIArgumentSource {
    private let values: [String]
    private(set) var accessedIndices: [Int] = []

    init(_ values: [String]) {
        self.values = values
    }

    var count: Int { values.count }

    func argument(at index: Int) -> String {
        accessedIndices.append(index)
        return values[index]
    }
}

private struct ThrowingTailArguments: CLIArgumentSource {
    let command: String

    var count: Int { 4 }

    func argument(at index: Int) -> String {
        precondition(index == 1, "Disabled route read an opaque argument tail")
        return command
    }
}

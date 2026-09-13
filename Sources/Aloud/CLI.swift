import Foundation

protocol CLIArgumentSource {
    var count: Int { get }
    func argument(at index: Int) -> String
}

struct ProcessCLIArguments: CLIArgumentSource {
    private let values: [String]

    init() {
        values = CommandLine.arguments
    }

    var count: Int { values.count }

    func argument(at index: Int) -> String {
        values[index]
    }
}

enum CLIRoute: Equatable {
    case launchApp
    case diagnoseCurrentAIReply
    case exportShots(outputDirectory: String)
    case terminate(status: Int32, stdout: Data, stderr: Data)

    static let invalidArguments = CLIRoute.terminate(
        status: 64,
        stdout: Data(),
        stderr: Data("unsupported: invalid-cli-arguments\n".utf8)
    )
}

enum CLIDispatcher {
    static func route(arguments: any CLIArgumentSource) -> CLIRoute {
        guard arguments.count >= 1 else { return .invalidArguments }
        if arguments.count == 1 { return .launchApp }

        let first = arguments.argument(at: 1)
        if first == "--import-key" || first == "--synth" || first == "--read-selection" {
            return .terminate(
                status: 64,
                stdout: Data(),
                stderr: Data("unsupported: migrate-to-app-UI\n".utf8)
            )
        }
        if first == "--export-shots", arguments.count == 3 {
            return .exportShots(outputDirectory: arguments.argument(at: 2))
        }
        if first == "--diagnose-current-ai-reply", arguments.count == 2 {
            return .diagnoseCurrentAIReply
        }
        return .invalidArguments
    }
}

enum CurrentAIReplyDiagnosticCLI {
    // Uses the production reader without launching the app or emitting reply text.
    static func run(reader: any CurrentAIReplyReading) async -> (status: Int32, output: Data) {
        do {
            guard let text = try await reader.readIfSupported() else {
                return (69, Data("ai-reply status=failed code=unsupportedAIApplication\n".utf8))
            }
            return (0, Data("ai-reply status=success count=\(text.count)\n".utf8))
        } catch {
            let code = (error as? CurrentAIReplyFailure)?.rawValue ?? "unavailable"
            return (69, Data("ai-reply status=failed code=\(code)\n".utf8))
        }
    }
}

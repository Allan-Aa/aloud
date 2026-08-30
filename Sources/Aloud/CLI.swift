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
        return .invalidArguments
    }
}

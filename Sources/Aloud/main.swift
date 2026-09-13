import AppKit
import SwiftUI

switch CLIDispatcher.route(arguments: ProcessCLIArguments()) {
case let .terminate(status, stdout, stderr):
    FileHandle.standardOutput.write(stdout)
    FileHandle.standardError.write(stderr)
    exit(status)
case let .exportShots(outputDirectory):
    let app = NSApplication.shared
    let delegate = ShotDelegate(outDir: outputDirectory)
    app.delegate = delegate
    app.setActivationPolicy(.prohibited)
    app.run()
case .diagnoseCurrentAIReply:
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let result = await CurrentAIReplyDiagnosticCLI.run(reader: CurrentAIReplyReader.live)
        FileHandle.standardOutput.write(result.output)
        exit(result.status)
    }
    app.run()
case .launchApp:
    AloudApp.main()
}

final class ShotDelegate: NSObject, NSApplicationDelegate {
    let outDir: String
    init(outDir: String) { self.outDir = outDir }

    func applicationDidFinishLaunching(_ note: Notification) {
        MainActor.assumeIsolated {
            let sink = DirectoryScreenshotSink(directory: URL(fileURLWithPath: outDir, isDirectory: true))
            do {
                try ScreenshotExporter().export(scenes: PreviewSceneCatalog.all, sink: sink)
                print("shots written to \(outDir)")
                exit(0)
            } catch {
                _ = error
                let message = "shot export failed: output-unavailable\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            }
        }
    }
}

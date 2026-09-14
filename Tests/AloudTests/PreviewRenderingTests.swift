import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import Aloud

@MainActor
final class PreviewRenderingTests: XCTestCase {
    func testSpeedLabelShowsExactQuarterAndFineSteps() {
        let slider = InkSlider.speed(.constant(1))
        XCTAssertEqual(slider.format(1), "1×")
        XCTAssertEqual(slider.format(1.25), "1.25×")
        XCTAssertEqual(slider.format(1.05), "1.05×")
        XCTAssertEqual(slider.format(1.5), "1.5×")
        XCTAssertEqual(slider.format(3), "3×")
    }

    func testProviderSettingsScenesCoverLightDarkWorkingFailureDisabledAndRecovery() {
        let names = PreviewSceneCatalog.all.map(\.name)

        XCTAssertTrue(names.contains("08-设置-语音-MiniMax-浅色"))
        XCTAssertTrue(names.contains("09-设置-语音-MiniMax导入中-深色"))
        XCTAssertTrue(names.contains("10-设置-语音-OpenAI失败-浅色"))
        XCTAssertTrue(names.contains("11-设置-语音-Gemini禁用-深色"))
        XCTAssertTrue(names.contains("12-设置-语音-恢复模式-浅色"))
    }

    func testMenuPanelPreviewsCoverPlaybackStatesAndResetVisibility() throws {
        let scenes: [String: PanelViewState] = Dictionary(uniqueKeysWithValues: PreviewSceneCatalog.all.compactMap { scene -> (String, PanelViewState)? in
            guard case let .panel(state) = scene.content else { return nil }
            return (scene.name, state)
        })

        XCTAssertEqual(try XCTUnwrap(scenes["16-菜单栏面板-空闲-浅色"]).phase, .idle)
        XCTAssertEqual(try XCTUnwrap(scenes["17-菜单栏面板-合成中-深色"]).phase, .synthesizing)
        XCTAssertEqual(try XCTUnwrap(scenes["18-菜单栏面板-播放-1×-浅色"]).playbackSpeed, 1)
        XCTAssertEqual(try XCTUnwrap(scenes["19-菜单栏面板-播放-1.25×-深色"]).playbackSpeed, 1.25)
        XCTAssertEqual(try XCTUnwrap(scenes["20-菜单栏面板-暂停-深色"]).phase, .paused)
        XCTAssertEqual(try XCTUnwrap(scenes["EN-06-panel-paused-1.25×"]).playbackSpeed, 1.25)
    }

    func testProviderSettingsPreviewPNGsAreExactly350By666() throws {
        let sink = RecordingScreenshotSink()
        try ScreenshotExporter().export(sceneFactory: { PreviewSceneCatalog.all }, sink: sink)

        let providerShots = zip(sink.names, sink.payloads).filter { name, _ in
            [
                "08-设置-语音-MiniMax-浅色",
                "09-设置-语音-MiniMax导入中-深色",
                "10-设置-语音-OpenAI失败-浅色",
                "11-设置-语音-Gemini禁用-深色",
                "12-设置-语音-恢复模式-浅色",
            ].contains(name)
        }
        XCTAssertEqual(providerShots.count, 5)
        for (_, png) in providerShots {
            let image = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual(image.pixelsWide, 350)
            XCTAssertEqual(image.pixelsHigh, 666)
        }
    }

    func testVoiceSettingsUsesOneConfiguredDetailScrollViewAtItsIntrinsicContentSize() throws {
        let host = try hostedSettings(named: "08-设置-语音-MiniMax-浅色")

        XCTAssertEqual(host.fittingSize, NSSize(width: 350, height: 666))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        let scrollViews = scrollViews(in: host)
        XCTAssertEqual(scrollViews.count, 1)
        let detailScroller = try XCTUnwrap(scrollViews.first)
        XCTAssertEqual(detailScroller.scrollerStyle, .overlay)
        XCTAssertTrue(detailScroller.autohidesScrollers)
        XCTAssertTrue(detailScroller.hasVerticalScroller)
        XCTAssertFalse(detailScroller.hasHorizontalScroller)
        XCTAssertEqual(detailScroller.horizontalScrollElasticity, .none)
    }

    func testProviderDetailBodyRendersBoundedSearchableVoicePickerForSelectedDynamicVoice() throws {
        let selectedVoiceID = VoiceID(rawValue: "minimax.dynamic.cloned")
        let state = try groupedMiniMaxVoiceState(selectedVoiceID: selectedVoiceID)
        let presentation = ProviderSettingsPresenter.make(
            state: state, selectedProviderID: .minimax,
            credentialStatuses: [.minimax: .configured], systemVoices: [], language: .zh
        )
        var updatedVoiceID: VoiceID?
        let detail = ProviderDetail(
            card: state.card(.minimax),
            presentation: presentation.detail,
            exporting: false,
            drafts: CredentialDraftState(),
            actions: ProviderSettingsViewActions(
                setDefault: { _ in },
                preview: { _ in },
                updateSelection: { updatedVoiceID = $0.voiceID },
                toggleVoiceSample: { _, _ in },
                confirmDisclosureAndPreview: {}
            ),
            voiceSampleState: .idle,
            beginCredentialAction: { _, _ in }
        )
        let host = NSHostingView(rootView: detail)
        host.frame = NSRect(x: 0, y: 0, width: 508, height: 480)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(descendantViews(in: host).compactMap { $0 as? NSPopUpButton }.count, 1, "Only the provider menu is native; voice selection remains searchable")
        let sections = ProviderVoicePickerCatalog.sections(voices: presentation.detail.voices, query: "我的")
        XCTAssertEqual(sections.map(\.title), ["我的克隆"])
        XCTAssertEqual(sections.flatMap(\.options).map(\.id), [selectedVoiceID])
        XCTAssertFalse(presentation.detail.voices.map(\.title).contains { $0.contains("minimax.dynamic") })
        XCTAssertNil(updatedVoiceID)
    }

    func testHotkeysSettingsUsesOneConfiguredOuterScrollViewAtItsIntrinsicContentSize() throws {
        let host = try hostedSettings(named: "13-设置-快捷键")

        XCTAssertEqual(host.fittingSize, NSSize(width: 350, height: 666))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        let scrollViews = scrollViews(in: host)
        XCTAssertEqual(scrollViews.count, 1)
        let outerScroller = try XCTUnwrap(scrollViews.first)
        XCTAssertEqual(outerScroller.scrollerStyle, .overlay)
        XCTAssertTrue(outerScroller.autohidesScrollers)
        XCTAssertTrue(outerScroller.hasVerticalScroller)
        XCTAssertFalse(outerScroller.hasHorizontalScroller)
        XCTAssertEqual(outerScroller.horizontalScrollElasticity, .none)
    }

    // Catches preview construction that touches a live dependency or emits non-PNG output.
    func testPreviewRenderingUsesOnlyInjectedScreenshotSink() throws {
        let sink = RecordingScreenshotSink()
        let exporter = ScreenshotExporter()

        try exporter.export(sceneFactory: { PreviewSceneCatalog.all }, sink: sink)

        XCTAssertEqual(sink.names, [
            "01-主窗口-空闲-浅色",
            "02-主窗口-空闲-深色",
            "03-主窗口-合成中",
            "04-主窗口-播放中-浅色",
            "05-主窗口-播放中-深色",
            "06-主窗口-历史展开-浅色",
            "07-主窗口-历史展开-深色",
            "08-设置-语音-MiniMax-浅色",
            "09-设置-语音-MiniMax导入中-深色",
            "10-设置-语音-OpenAI失败-浅色",
            "11-设置-语音-Gemini禁用-深色",
            "12-设置-语音-恢复模式-浅色",
            "13-设置-快捷键",
            "14-设置-词典",
            "15-设置-高级",
            "16-菜单栏面板-空闲-浅色",
            "17-菜单栏面板-合成中-深色",
            "18-菜单栏面板-播放-1×-浅色",
            "19-菜单栏面板-播放-1.25×-深色",
            "20-菜单栏面板-暂停-深色",
            "21-菜单栏-空白-浅色",
            "22-菜单栏-空白-深色",
            "23-菜单栏-错误",
            "EN-07-panel-empty",
            "EN-08-panel-preparing",
            "EN-01-main-idle",
            "EN-02-main-playing",
            "EN-03-main-history",
            "EN-04-settings-hotkeys",
            "EN-05-panel-playing-1×",
            "EN-06-panel-paused-1.25×",
            "24-主窗口-合成语速展开",
            "25-菜单栏-倍速展开",
            "EN-09-panel-speech-expanded",
            "26-主窗口-播放时编辑正文",
            "27-主窗口-侧边设置",
            "28-主窗口-播放与设置",
        ])
        XCTAssertTrue(sink.payloads.allSatisfy { data in
            Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        })
    }

    // Catches catalog construction that happens before the export audit scope is installed.
    func testSceneFactoryDependencyAccessFailsBeforeAnySinkWrite() throws {
        let sink = RecordingScreenshotSink()

        try Store.withOperations(.inMemory) {
            XCTAssertThrowsError(
                try ScreenshotExporter().export(sceneFactory: {
                    _ = Store.load("preview-factory-canary.json", default: 0)
                    return [PreviewSceneCatalog.all[0]]
                }, sink: sink)
            ) { error in
                XCTAssertEqual(error as? PreviewDependencyViolation, .accessed(.store))
            }
        }
        XCTAssertEqual(sink.names, [])
    }

    // Catches an exporter that writes a screenshot after rendering touched a live boundary.
    func testExporterRejectsAuditedAccessBeforeWritingSink() {
        let sink = RecordingScreenshotSink()
        let exporter = ScreenshotExporter(renderScene: { _ in
            Store.withPreviewAccessAudit(auditedValue: validPNG) {
                XCTFail("audit must skip the live continuation")
                return Data()
            }
        })

        XCTAssertThrowsError(try exporter.export(sceneFactory: { [PreviewSceneCatalog.all[0]] }, sink: sink)) { error in
            XCTAssertEqual(error as? PreviewDependencyViolation, .accessed(.store))
        }
        XCTAssertEqual(sink.names, [])
    }

    // Catches Store load/save hooks or path hooks removed from the production entrances.
    func testStoreProductionEntrancesAreAuditedUsingInjectedOperations() {
        let operations = Store.Operations(
            dir: URL(fileURLWithPath: "/in-memory/store"),
            cacheDir: URL(fileURLWithPath: "/in-memory/cache"),
            runtimeDir: URL(fileURLWithPath: "/in-memory/runtime"),
            read: { _ in nil },
            write: { _, _ in }
        )
        Store.withOperations(operations) {
            assertPreviewViolation(.store) { _ = Store.load("prefs.json", default: 7) }
            assertPreviewViolation(.store) { Store.save("prefs.json", 7) }
            assertPreviewViolation(.fileManagerPathSelection) { _ = Store.dir }
            assertPreviewViolation(.fileManagerPathSelection) { _ = Store.cacheDir }
            assertPreviewViolation(.fileManagerPathSelection) { _ = Store.runtimeDir }
        }
    }

    // Catches Player.shared losing its production audit hook; Store remains safely injected as a second shield.
    func testPlayerSharedProductionEntranceIsAudited() {
        let operations = Store.Operations.inMemory
        Store.withOperations(operations) {
            assertPreviewViolation(.player) { _ = Player.shared }
        }
    }

    // Catches the provider hook removed from the real synthesize chain without reading a real key.
    func testMiniMaxSynthesizeProductionEntranceAuditsProvider() async {
        let credential = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("fake-key".utf8))
        let provider = MiniMaxProvider(httpClient: PreviewMiniMaxHTTPClient(), nativeDirectory: URL(fileURLWithPath: "/in-memory"))
        guard let request = try? await previewMiniMaxRequest(provider: provider, credential: credential) else { return XCTFail("fixture request") }
        await assertPreviewViolation(.provider) {
            _ = try await provider.synthesize(request, credential: .apiKey(providerID: .minimax, envelope: credential))
        }
    }

    // Catches the network hook removed from the real synthesize chain; transport and key are both injected fakes.
    func testMiniMaxSynthesizeProductionChainAuditsNetwork() async {
        let credential = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("fake-key".utf8))
        let provider = MiniMaxProvider(httpClient: URLSessionMiniMaxHTTPClient(), nativeDirectory: URL(fileURLWithPath: "/in-memory"))
        guard let request = try? await previewMiniMaxRequest(provider: provider, credential: credential) else { return XCTFail("fixture request") }
        do {
            _ = try await PreviewAccessAudit.withAudit(passthrough: [.provider, .keychain]) {
                try await provider.synthesize(request, credential: .apiKey(providerID: .minimax, envelope: credential))
            }
            XCTFail("expected preview network dependency violation")
        } catch {
            XCTAssertEqual(error as? PreviewDependencyViolation, .accessed(.network))
        }
    }

    func testMiniMaxV1CredentialUsesBearerHeaderAndBlockedLegacyNeverTouchesTransport() async {
        let envelope = CredentialEnvelope(providerID: .minimax, revision: UUID(), secret: Data("fake-key".utf8))
        let hits = LockedTransportHits()
        let provider = MiniMaxProvider(httpClient: PreviewMiniMaxHTTPClient(hits: hits), nativeDirectory: URL(fileURLWithPath: "/tmp"))
        guard let request = try? await previewMiniMaxRequest(provider: provider, credential: envelope) else { return XCTFail("fixture request") }
        await XCTAssertThrowsErrorAsync(try await provider.synthesize(request, credential: .apiKey(providerID: .minimax, envelope: envelope)))
        XCTAssertEqual(hits.values, ["Bearer fake-key"])
        let blocked = CredentialReadResult.blocked(.nonV1Item)
        guard case .blocked(.nonV1Item) = blocked else { return XCTFail("legacy fixture") }
        XCTAssertEqual(hits.values, ["Bearer fake-key"])
    }

    // Catches Settings' production executable probe losing its path-selection hook.
    func testSettingsProductionBinaryProbeIsAudited() {
        SettingsView.withBinaryProbe({ _ in true }) {
            assertPreviewViolation(.fileManagerPathSelection) {
                _ = SettingsView.probeBinary(atPath: "/in-memory/mpv")
            }
        }
    }

    // Catches an exporter that swallows a sink error, continues rendering, or falls back to disk.
    func testSinkFailurePropagatesWithoutFallbackWrites() {
        let sink = FailingScreenshotSink()
        let exporter = ScreenshotExporter()

        XCTAssertThrowsError(try exporter.export(sceneFactory: { PreviewSceneCatalog.all }, sink: sink)) { error in
            XCTAssertEqual(error as? SinkFailure, .refused)
        }
        XCTAssertEqual(sink.names.count, 1)
    }

    // Catches a directory sink that exposes a partial final file or fails to replace an old target atomically.
    func testDirectorySinkAtomicallyReplacesExistingPNG() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let destination = directory.url.appendingPathComponent("shot.png")
        try Data("old".utf8).write(to: destination)

        try DirectoryScreenshotSink(directory: directory.url).writePNG(validPNG, named: "shot")

        XCTAssertEqual(try Data(contentsOf: destination), validPNG)
        XCTAssertEqual(try temporaryScreenshotFiles(in: directory.url), [])
    }

    // Catches rename failures that delete the old target or leave the sink's unique temp behind.
    func testDirectorySinkRenameFailurePreservesOldTargetAndCleansTemp() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let destination = directory.url.appendingPathComponent("shot.png")
        let old = Data("old".utf8)
        try old.write(to: destination)
        let sink = DirectoryScreenshotSink(directory: directory.url, renamer: FailingScreenshotRenamer())

        XCTAssertThrowsError(try sink.writePNG(validPNG, named: "shot")) { error in
            XCTAssertEqual(error as? AtomicSinkFailure, .renameRefused)
        }
        XCTAssertEqual(try Data(contentsOf: destination), old)
        XCTAssertEqual(try temporaryScreenshotFiles(in: directory.url), [])
    }

    // Catches a sink that writes arbitrary bytes under a PNG extension.
    func testDirectorySinkRejectsInvalidPNGWithoutChangingOldTarget() throws {
        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let destination = directory.url.appendingPathComponent("shot.png")
        let old = Data("old".utf8)
        try old.write(to: destination)

        XCTAssertThrowsError(
            try DirectoryScreenshotSink(directory: directory.url).writePNG(Data("not-png".utf8), named: "shot")
        ) { error in
            XCTAssertEqual(error as? ScreenshotSinkError, .invalidPNG)
        }
        XCTAssertEqual(try Data(contentsOf: destination), old)
        XCTAssertEqual(try temporaryScreenshotFiles(in: directory.url), [])
    }

    // Catches preview export that reaches the network, spawns a provider/player process, or writes outside its sink directory.
    func testSandboxedProcessExportWritesEverySceneAsPNG() throws {
        let sandbox = try PreviewProcessSandbox()
        defer { try? sandbox.remove() }

        let result = try runPreviewProcess(
            executable: previewAloudExecutable,
            arguments: ["--export-shots", sandbox.output.path],
            profile: restrictedProfile(initialExecutable: previewAloudExecutable, outputDirectory: sandbox.output)
        )

        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        XCTAssertEqual(result.stderr, Data())
        let files = try FileManager.default.contentsOfDirectory(at: sandbox.output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, PreviewSceneCatalog.all.count)
        XCTAssertTrue(try files.allSatisfy { file in
            Array(try Data(contentsOf: file).prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        })
        XCTAssertEqual(try sandbox.filesOutsideOutput(), [])
    }

    // Mutation proof: these probes would succeed if any corresponding deny rule were removed.
    func testExportSandboxProfileBlocksChildExecNetworkAndOutsideWrites() throws {
        let sandbox = try PreviewProcessSandbox()
        defer { try? sandbox.remove() }
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        let profile = restrictedProfile(initialExecutable: perl, outputDirectory: sandbox.output)

        let allowedMarker = sandbox.output.appendingPathComponent("allowed-marker")
        let allowedScript = "open(my $f, '>', '\(allowedMarker.path)') or exit 42; print $f 'allowed'; close($f) or exit 43;"
        let allowed = try runPreviewProcess(executable: perl, arguments: ["-e", allowedScript], profile: profile)
        XCTAssertEqual(allowed.status, 0, String(decoding: allowed.stderr, as: UTF8.self))
        XCTAssertTrue(FileManager.default.fileExists(atPath: allowedMarker.path))

        let childMarker = sandbox.output.appendingPathComponent("child-marker")
        let childScript = "my $r = system {\"/bin/sh\"} \"/bin/sh\", \"-c\", \"printf child > '\(childMarker.path)'\"; exit($r == -1 ? 0 : 41);"
        let child = try runPreviewProcess(executable: perl, arguments: ["-e", childScript], profile: profile)
        XCTAssertEqual(child.status, 0, String(decoding: child.stderr, as: UTF8.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: childMarker.path))

        let networkScript = "use Socket; use Errno qw(EPERM); socket(my $s, PF_INET, SOCK_STREAM, getprotobyname('tcp')) or exit($!{EPERM} ? 0 : 42); my $ok = connect($s, sockaddr_in(9, inet_aton('127.0.0.1'))); exit($ok ? 41 : ($!{EPERM} ? 0 : 43));"
        let network = try runPreviewProcess(executable: perl, arguments: ["-e", networkScript], profile: profile)
        XCTAssertEqual(network.status, 0, String(decoding: network.stderr, as: UTF8.self))

        let outsideMarker = sandbox.root.appendingPathComponent("outside-marker")
        let writeScript = "use Errno qw(EPERM); if (open(my $f, '>', '\(outsideMarker.path)')) { print $f 'written'; close($f); exit 41; } exit($!{EPERM} ? 0 : 42);"
        let write = try runPreviewProcess(executable: perl, arguments: ["-e", writeScript], profile: profile)
        XCTAssertEqual(write.status, 0, String(decoding: write.stderr, as: UTF8.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideMarker.path))
    }

    // Catches export failures that erase the technical error category needed for diagnosis.
    func testProcessExportFailureReportsTechnicalCategoryWithoutSceneContent() throws {
        let sandbox = try PreviewProcessSandbox(createOutput: false)
        defer { try? sandbox.remove() }

        let result = try runPreviewProcess(
            executable: previewAloudExecutable,
            arguments: ["--export-shots", sandbox.output.path]
        )
        let stderr = String(decoding: result.stderr, as: UTF8.self)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(stderr.hasPrefix("shot export failed: "), stderr)
        XCTAssertGreaterThan(stderr.count, "shot export failed: \n".count)
        XCTAssertFalse(stderr.contains("念念不忘"))
        XCTAssertFalse(stderr.contains("Read anything aloud"))
    }
}

private func scrollViews(in view: NSView) -> [NSScrollView] {
    view.subviews.flatMap(scrollViews(in:)) + ((view as? NSScrollView).map { [$0] } ?? [])
}

private func descendantViews(in view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendantViews(in:))
}

@MainActor
private func hostedSettings(named name: String) throws -> NSHostingView<SettingsViewBody> {
    let scene = try XCTUnwrap(PreviewSceneCatalog.all.first { $0.name == name })
    guard case let .settings(state) = scene.content else {
        throw NSError(domain: "PreviewRenderingTests", code: 1)
    }
    return NSHostingView(rootView: SettingsViewBody(
        state: state,
        exporting: false,
        credentialActions: .unavailable,
        systemVoices: .init(load: { [] }),
        actions: .none,
        initialSelectedProviderID: state.selectedProviderID,
        previewSystemVoices: state.systemVoices
    ))
}

private func assertPreviewViolation(
    _ expected: PreviewLiveDependency,
    operation: () throws -> Void
) {
    XCTAssertThrowsError(try PreviewAccessAudit.withAudit(operation)) { error in
        XCTAssertEqual(error as? PreviewDependencyViolation, .accessed(expected))
    }
}

private func assertPreviewViolation(
    _ expected: PreviewLiveDependency,
    operation: () async throws -> Void
) async {
    do {
        try await PreviewAccessAudit.withAudit(operation)
        XCTFail("expected preview dependency violation: \(expected)")
    } catch {
        XCTAssertEqual(error as? PreviewDependencyViolation, .accessed(expected))
    }
}

private final class RecordingScreenshotSink: ScreenshotSink {
    private(set) var names: [String] = []
    private(set) var payloads: [Data] = []

    func writePNG(_ data: Data, named name: String) throws {
        names.append(name)
        payloads.append(data)
    }
}

private enum SinkFailure: Error, Equatable {
    case refused
}

private final class FailingScreenshotSink: ScreenshotSink {
    private(set) var names: [String] = []

    func writePNG(_ data: Data, named name: String) throws {
        names.append(name)
        throw SinkFailure.refused
    }
}

private let validPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

private enum AtomicSinkFailure: Error, Equatable {
    case renameRefused
}

private struct FailingScreenshotRenamer: ScreenshotRenaming {
    func rename(_ source: URL, to destination: URL) throws {
        throw AtomicSinkFailure.renameRefused
    }
}

private func temporaryScreenshotFiles(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(".aloud-shot-") }
        .sorted()
}

private let previewAloudExecutable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".build/debug/Aloud")
    .resolvingSymlinksInPath()

private final class LockedTransportHits: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [String?] = []
    var values: [String?] { lock.withLock { storage } }
    func record(_ value: String?) { lock.withLock { storage.append(value) } }
}

private struct PreviewProcessSandbox {
    let root: URL
    let output: URL

    init(createOutput: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-preview-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createOutput {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
    }

    func filesOutsideOutput() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0 != "output" && !$0.hasPrefix("output/") }
            .sorted()
    }

    func remove() throws {
        try FileManager.default.removeItem(at: root)
    }
}

private func restrictedProfile(initialExecutable: URL, outputDirectory: URL) -> String {
    let canonicalOutput = canonicalPathPreservingMissingTail(outputDirectory)
    let metalCache = FileManager.default.temporaryDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("C/com.apple.metal", isDirectory: true)
    let canonicalMetalCache = canonicalPathPreservingMissingTail(metalCache)
    return """
    (version 1)
    (allow default)
    (deny network*)
    (deny process-exec)
    (allow process-exec (literal "\(profileLiteral(initialExecutable.path))"))
    (deny file-write* (require-not (require-any
        (literal "\(profileLiteral(canonicalOutput))")
        (subpath "\(profileLiteral(canonicalOutput))")
        (literal "\(profileLiteral(canonicalMetalCache))")
        (subpath "\(profileLiteral(canonicalMetalCache))")
    )))
    """
}

private func canonicalPathPreservingMissingTail(_ url: URL) -> String {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path) {
        missing.insert(existing.lastPathComponent, at: 0)
        let parent = existing.deletingLastPathComponent()
        guard parent.path != existing.path else { return url.path }
        existing = parent
    }
    let canonicalParent = existing.withUnsafeFileSystemRepresentation { path -> String in
        guard let path, let resolved = realpath(path, nil) else { return existing.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    return missing.reduce(canonicalParent) { partial, component in
        URL(fileURLWithPath: partial, isDirectory: true).appendingPathComponent(component).path
    }
}

private func profileLiteral(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func runPreviewProcess(
    executable: URL,
    arguments: [String],
    profile: String? = nil
) throws -> (status: Int32, stdout: Data, stderr: Data) {
    let process = Process()
    if let profile {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, executable.path] + arguments
    } else {
        process.executableURL = executable
        process.arguments = arguments
    }
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        stdout.fileHandleForReading.readDataToEndOfFile(),
        stderr.fileHandleForReading.readDataToEndOfFile()
    )
}

private struct PreviewMiniMaxHTTPClient: MiniMaxHTTPClient {
    let hits: LockedTransportHits?
    init(hits: LockedTransportHits? = nil) { self.hits = hits }
    func send(_ request: URLRequest) async throws -> MiniMaxHTTPResponse {
        hits?.record(request.value(forHTTPHeaderField: "Authorization"))
        throw URLError(.cannotConnectToHost)
    }
}

private func previewMiniMaxRequest(provider: MiniMaxProvider, credential: CredentialEnvelope) async throws -> SpeechRequest {
    let selection = ProviderSelection(providerID: .minimax, modelID: MiniMaxWireContractV1.modelID, voiceID: VoiceID(rawValue: "minimax.radio-host.default"), rate: NormalizedRate(version: "legacy-minimax-rate-v1", value: 0)!)
    let chunks = try await provider.split("canary", selection: selection)
    return try SpeechRequest.make(id: SpeechRequestID(rawValue: UUID()), selection: selection, chunk: try XCTUnwrap(chunks.first), controls: MiniMaxRateMappingV1.controls(for: selection.rate), credentialScopeRevision: credential.revision, capabilities: provider.capabilities, outputFormatID: MiniMaxWireContractV1.outputFormatID, canonicalizerVersion: "canonical-wav-v1")
}

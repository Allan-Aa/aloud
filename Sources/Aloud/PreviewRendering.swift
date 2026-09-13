import AppKit
import Darwin
import Foundation
import SwiftUI

enum PreviewLiveDependency: String, CaseIterable, Equatable, Sendable {
    case store
    case keychain
    case provider
    case player
    case fileManagerPathSelection
    case network
}

enum PreviewDependencyViolation: Error, Equatable {
    case accessed(PreviewLiveDependency)
}

enum PreviewAccessAudit {
    // Every access to mutable state is serialized by lock.
    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var accesses: [PreviewLiveDependency] = []
        private let passthrough: Set<PreviewLiveDependency>

        init(passthrough: Set<PreviewLiveDependency>) {
            self.passthrough = passthrough
        }

        func record(_ dependency: PreviewLiveDependency) {
            lock.lock()
            accesses.append(dependency)
            lock.unlock()
        }

        var firstAccess: PreviewLiveDependency? {
            lock.lock()
            defer { lock.unlock() }
            return accesses.first
        }

        func disposition(for dependency: PreviewLiveDependency) -> Disposition {
            if passthrough.contains(dependency) { return .perform }
            return .record
        }
    }

    private enum Disposition {
        case perform
        case record
    }

    @TaskLocal private static var session: Session?

    static func withAudit<Value>(
        passthrough: Set<PreviewLiveDependency> = [],
        _ body: () throws -> Value
    ) throws -> Value {
        let audit = Session(passthrough: passthrough)
        do {
            let value = try $session.withValue(audit, operation: body)
            if let dependency = audit.firstAccess {
                throw PreviewDependencyViolation.accessed(dependency)
            }
            return value
        } catch {
            if let dependency = audit.firstAccess {
                throw PreviewDependencyViolation.accessed(dependency)
            }
            throw error
        }
    }

    static func withAudit<Value>(
        passthrough: Set<PreviewLiveDependency> = [],
        _ body: () async throws -> Value
    ) async throws -> Value {
        let audit = Session(passthrough: passthrough)
        do {
            let value = try await $session.withValue(audit, operation: body)
            if let dependency = audit.firstAccess {
                throw PreviewDependencyViolation.accessed(dependency)
            }
            return value
        } catch {
            if let dependency = audit.firstAccess {
                throw PreviewDependencyViolation.accessed(dependency)
            }
            throw error
        }
    }

    static func access<Value>(
        _ dependency: PreviewLiveDependency,
        auditedValue: @autoclosure () -> Value,
        perform: () -> Value
    ) -> Value {
        guard let session else { return perform() }
        switch session.disposition(for: dependency) {
        case .perform:
            return perform()
        case .record:
            session.record(dependency)
            return auditedValue()
        }
    }

    static func access<Value>(
        _ dependency: PreviewLiveDependency,
        auditedValue: @autoclosure () -> Value,
        perform: () async throws -> Value
    ) async rethrows -> Value {
        guard let session else { return try await perform() }
        switch session.disposition(for: dependency) {
        case .perform:
            return try await perform()
        case .record:
            session.record(dependency)
            return auditedValue()
        }
    }
}

struct MainViewState: Sendable {
    let text: String
    let phase: Phase
    let voiceControl: ProviderVoiceControlState?
    let voiceSampleState: VoiceSamplePlaybackState
    let voiceLabel: String
    let playbackSpeed: Double
    let position: Double
    let duration: Double
    let history: [HistoryEntry]
    let toast: String?
}

struct PanelViewState: Sendable {
    var voiceLabel: String = "清朗男声"
    var toast: String? = nil
    let text: String
    let phase: Phase
    let playbackSpeed: Double
    let position: Double
    let duration: Double
}

struct BinaryStatus: Sendable {
    let name: String
    let path: String
    let isExecutable: Bool
}

@MainActor
struct SettingsViewState {
    let initialTab: Int
    let hasKey: Bool
    let voice: String
    let rate: Int
    let stripMarkdown: Bool
    let skipCode: Bool
    let hotkeyReadSelection: String
    let hotkeyReadClipboard: String
    let hotkeyTogglePause: String
    let recordingHotkey: HotkeyAction?
    let hotkeyChime: Bool
    let launchAtLogin: Bool
    let menuBarOnly: Bool
    let rules: [DictRule]
    let cacheLimitMB: Int
    let binaryStatuses: [BinaryStatus]
    let providerSettings: ProviderSettingsState
    let selectedProviderID: ProviderID
    let credentialStatuses: [ProviderID: ProviderCredentialUIStatus]
    let systemVoices: [SystemVoiceDescriptor]
}

@MainActor
enum PreviewContent {
    case main(MainViewState, historyOpen: Bool)
    case settings(SettingsViewState)
    case panel(PanelViewState)
}

@MainActor
struct PreviewScene {
    let name: String
    let colorScheme: ColorScheme
    let language: Lang
    let content: PreviewContent
}

@MainActor
enum PreviewSceneCatalog {
    static var all: [PreviewScene] {
        let sample = "念念不忘，必有回响。这段字用来看合成和播放的动效。"
        let sampleEN = "Read anything aloud. Select text anywhere and press the hotkey."
        let panelText = "朗读时可随时调整播放语速，保持当前进度。"

        return [
            main("01-主窗口-空闲-浅色", .light),
            main("02-主窗口-空闲-深色", .dark),
            main("03-主窗口-合成中", .dark, text: sample, phase: .synthesizing),
            main("04-主窗口-播放中-浅色", .light, text: sample, phase: .playing, position: 28),
            main("05-主窗口-播放中-深色", .dark, text: sample, phase: .playing, position: 28),
            main("06-主窗口-历史展开-浅色", .light, text: sample, phase: .playing, position: 28,
                 historyOpen: true),
            main("07-主窗口-历史展开-深色", .dark, historyOpen: true),
            settings("08-设置-语音-MiniMax-浅色", .light, tab: 0, selectedProviderID: .minimax,
                     credentialStatuses: [.minimax: .configured]),
            settings("09-设置-语音-MiniMax导入中-深色", .dark, tab: 0, selectedProviderID: .minimax,
                     credentialStatuses: [.minimax: .working(.onePasswordImport)]),
            settings("10-设置-语音-OpenAI失败-浅色", .light, tab: 0, selectedProviderID: .openAI,
                     credentialStatuses: [.openAI: .saveFailed(.keychainUnavailable)]),
            settings("11-设置-语音-Gemini禁用-深色", .dark, tab: 0, selectedProviderID: .gemini,
                     credentialStatuses: [.gemini: .missing], providerSettings: disabledFixture(for: .gemini)),
            settings("12-设置-语音-恢复模式-浅色", .light, tab: 0, selectedProviderID: .macOS,
                     credentialStatuses: [:], systemVoices: previewSystemVoices, providerSettings: recoveryFixture()),
            settings("13-设置-快捷键", .light, tab: 1),
            settings("14-设置-词典", .dark, tab: 2),
            settings("15-设置-高级", .dark, tab: 3),
            panel("16-菜单栏面板-空闲-浅色", .light, text: panelText, phase: .idle),
            panel("17-菜单栏面板-合成中-深色", .dark, text: panelText, phase: .synthesizing),
            panel("18-菜单栏面板-播放-1×-浅色", .light, text: panelText, phase: .playing),
            panel("19-菜单栏面板-播放-1.25×-深色", .dark, text: panelText, phase: .playing, playbackSpeed: 1.25),
            panel("20-菜单栏面板-暂停-深色", .dark, text: panelText, phase: .paused, playbackSpeed: 1.25),
            panel("21-菜单栏-空白-浅色", .light, text: "", phase: .idle),
            panel("22-菜单栏-空白-深色", .dark, text: "", phase: .idle),
            panel("23-菜单栏-错误", .light, text: sample, phase: .idle,
                  toast: "语音服务暂时不可用，请检查网络或在设置中切换服务后重试。"),
            panel("EN-07-panel-empty", .light, language: .en, text: "", phase: .idle),
            panel("EN-08-panel-preparing", .dark, language: .en, text: sampleEN, phase: .synthesizing),
            main("EN-01-main-idle", .light, language: .en),
            main("EN-02-main-playing", .dark, language: .en, text: sampleEN, phase: .playing, position: 28),
            main("EN-03-main-history", .light, language: .en, text: sampleEN, historyOpen: true),
            settings("EN-04-settings-hotkeys", .light, language: .en, tab: 1),
            panel("EN-05-panel-playing-1×", .dark, language: .en, text: sampleEN, phase: .playing),
            panel("EN-06-panel-paused-1.25×", .light, language: .en, text: sampleEN, phase: .paused, playbackSpeed: 1.25),
        ]
    }

    private static let defaultVoice = "minimax:Chinese (Mandarin)_Radio_Host|default"
    private static let previewSystemVoices = [
        SystemVoiceDescriptor(identifier: "preview.voice.yunxi", name: "云希", language: "zh-CN"),
        SystemVoiceDescriptor(identifier: "preview.voice.samantha", name: "Samantha", language: "en-US")
    ]

    private static func main(
        _ name: String,
        _ scheme: ColorScheme,
        language: Lang = .zh,
        text: String = "",
        phase: Phase = .idle,
        position: Double = 0,
        historyOpen: Bool = false
    ) -> PreviewScene {
        PreviewScene(
            name: name,
            colorScheme: scheme,
            language: language,
            content: .main(
                MainViewState(
                    text: text,
                    phase: phase,
                    voiceControl: nil,
                    voiceSampleState: .idle,
                    voiceLabel: Voices.label(defaultVoice, language),
                    playbackSpeed: 1,
                    position: position,
                    duration: 64,
                    history: Mock.history,
                    toast: nil
                ),
                historyOpen: historyOpen
            )
        )
    }

    private static func settings(
        _ name: String,
        _ scheme: ColorScheme,
        language: Lang = .zh,
        tab: Int,
        selectedProviderID: ProviderID = .minimax,
        credentialStatuses: [ProviderID: ProviderCredentialUIStatus] = [:],
        systemVoices: [SystemVoiceDescriptor] = [],
        providerSettings: ProviderSettingsState? = nil
    ) -> PreviewScene {
        PreviewScene(
            name: name,
            colorScheme: scheme,
            language: language,
            content: .settings(
                SettingsViewState(
                    initialTab: tab,
                    hasKey: true,
                    voice: defaultVoice,
                    rate: 50,
                    stripMarkdown: true,
                    skipCode: true,
                    hotkeyReadSelection: "⌃ `",
                    hotkeyReadClipboard: "⌥ `",
                    hotkeyTogglePause: "⌥⌘ Space",
                    recordingHotkey: nil,
                    hotkeyChime: true,
                    launchAtLogin: false,
                    menuBarOnly: false,
                    rules: Mock.rules,
                    cacheLimitMB: 512,
                    binaryStatuses: [
                        BinaryStatus(name: "mpv", path: "/opt/homebrew/bin/mpv", isExecutable: true),
                        BinaryStatus(name: "ffmpeg", path: "/opt/homebrew/bin/ffmpeg", isExecutable: true),
                        BinaryStatus(name: "ffprobe", path: "/opt/homebrew/bin/ffprobe", isExecutable: true),
                        BinaryStatus(name: "edge-tts", path: "/opt/homebrew/bin/edge-tts", isExecutable: true),
                    ],
                    providerSettings: providerSettings ?? (try! ProviderSettingsState.fixture()),
                    selectedProviderID: selectedProviderID,
                    credentialStatuses: credentialStatuses,
                    systemVoices: systemVoices
                )
            )
        )
    }

    private static func disabledFixture(for providerID: ProviderID) -> ProviderSettingsState {
        var state = try! ProviderSettingsState.fixture()
        let index = state.cards.firstIndex { $0.id == providerID }!
        let current = state.cards[index].availability
        state.cards[index].availability = ProviderAvailability(
            kind: .disabled,
            reason: .explicitlyDisabled,
            maturity: current.maturity,
            featureFlagName: current.featureFlagName,
            featureFlagEnabled: current.featureFlagEnabled,
            providerContractVersion: current.providerContractVersion,
            evidenceID: current.evidenceID
        )
        return state
    }

    private static func recoveryFixture() -> ProviderSettingsState {
        var state = try! ProviderSettingsState.fixture()
        let index = state.cards.firstIndex { $0.id == .macOS }!
        state.cards[index].selection = ProviderSelection(
            providerID: .macOS,
            modelID: SystemVoiceContractV1.modelID,
            voiceID: VoiceID(rawValue: "macos.preview.voice.yunxi"),
            rate: NormalizedRate(version: SystemVoiceRateMappingV1.version, value: 0)!
        )
        return ProviderSettingsReducer.reduce(state, .recoveryModeChanged(true))
    }

    private static func panel(
        _ name: String,
        _ scheme: ColorScheme,
        language: Lang = .zh,
        text: String,
        phase: Phase,
        playbackSpeed: Double = 1,
        toast: String? = nil
    ) -> PreviewScene {
        PreviewScene(
            name: name,
            colorScheme: scheme,
            language: language,
            content: .panel(
                PanelViewState(
                    voiceLabel: language == .zh ? "清朗男声" : "Clear voice",
                    toast: toast,
                    text: text,
                    phase: phase,
                    playbackSpeed: playbackSpeed,
                    position: phase.isLive ? 23 : 0,
                    duration: 64
                )
            )
        )
    }
}

protocol ScreenshotSink {
    func writePNG(_ data: Data, named name: String) throws
}

enum ScreenshotSinkError: Error, Equatable {
    case invalidPNG
}

protocol ScreenshotRenaming {
    func rename(_ source: URL, to destination: URL) throws
}

private struct POSIXScreenshotRenamer: ScreenshotRenaming {
    func rename(_ source: URL, to destination: URL) throws {
        let status: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

struct DirectoryScreenshotSink: ScreenshotSink {
    let directory: URL
    private let renamer: any ScreenshotRenaming

    init(directory: URL, renamer: any ScreenshotRenaming = POSIXScreenshotRenamer()) {
        self.directory = directory
        self.renamer = renamer
    }

    func writePNG(_ data: Data, named name: String) throws {
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw ScreenshotSinkError.invalidPNG
        }
        let destination = directory.appendingPathComponent(name).appendingPathExtension("png")
        let temporary = directory.appendingPathComponent(".aloud-shot-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try renamer.rename(temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

enum ScreenshotExportError: LocalizedError {
    case imageRenderingFailed(String)
    case pngEncodingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .imageRenderingFailed(scene):
            return "image rendering failed for scene \(scene)"
        case let .pngEncodingFailed(scene):
            return "PNG encoding failed for scene \(scene)"
        }
    }
}

@MainActor
struct ScreenshotExporter {
    private let renderScene: @MainActor (PreviewScene) throws -> Data

    init(renderScene: (@MainActor (PreviewScene) throws -> Data)? = nil) {
        self.renderScene = renderScene ?? Self.render
    }

    func export(
        scenes: @autoclosure () -> [PreviewScene],
        sink: any ScreenshotSink
    ) throws {
        try export(sceneFactory: { scenes() }, sink: sink)
    }

    func export(
        sceneFactory: () -> [PreviewScene],
        sink: any ScreenshotSink
    ) throws {
        let rendered = try PreviewAccessAudit.withAudit {
            try sceneFactory().map { scene in
                (name: scene.name, png: try renderScene(scene))
            }
        }
        for item in rendered {
            try sink.writePNG(item.png, named: item.name)
        }
    }

    private static func render(_ scene: PreviewScene) throws -> Data {
        let content: AnyView
        switch scene.content {
        case let .main(state, historyOpen):
            content = AnyView(MainPreviewView(state: state, historyOpen: historyOpen)
                .frame(width: 720, height: 620))
        case let .settings(state):
            content = AnyView(SettingsPreviewView(state: state))
        case let .panel(state):
            content = AnyView(PanelPreviewView(state: state))
        }

        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, scene.colorScheme)
            .environment(\.lang, scene.language))
        if case .settings = scene.content {
            renderer.scale = 1
        } else {
            renderer.scale = 2
        }
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else {
            throw ScreenshotExportError.imageRenderingFailed(scene.name)
        }
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw ScreenshotExportError.pngEncodingFailed(scene.name)
        }
        return png
    }
}

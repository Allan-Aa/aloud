import SwiftUI
import AppKit

// 入口在 main.swift(要分流导出模式),所以这里不能有 @main
struct AloudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 菜单栏常驻。.window 样式=左键弹面板,跟旧版 Electron 的迷你播放器对齐。
        MenuBarExtra {
            PanelView(engine: Engine.shared)
        } label: {
            TrayLabel()
        }
        .menuBarExtraStyle(.window)

        Window("念", id: "main") {
            MainView(engine: Engine.shared)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 620)

        Settings {
            SettingsView(
                engine: Engine.shared,
                credentialIngress: AppCompositionRoot.live.credentialIngress,
                systemVoices: AppCompositionRoot.live.systemVoices
            )
        }
        .defaultSize(width: 640, height: 480)
        .windowResizability(.contentSize)
    }
}

/// Owns the two-phase application-termination attempt. Repeated AppKit
/// callbacks share one in-flight drain, and the injected reply sink is invoked
/// once on MainActor only after the store commits or cancels shutdown.
@MainActor
final class AppTerminationCoordinator {
    typealias Reply = @MainActor (Bool) -> Void
    typealias Sleep = @Sendable (Duration) async -> Void
    typealias ShutdownSpeech = @Sendable () async -> Void

    private let store: LastAudioArtifactStore
    private let timeout: Duration
    private let sleep: Sleep
    private let shutdownSpeech: ShutdownSpeech
    private var terminationTask: Task<Void, Never>?

    init(
        store: LastAudioArtifactStore,
        timeout: Duration,
        sleep: @escaping Sleep = { duration in try? await Task.sleep(for: duration) },
        shutdownSpeech: @escaping ShutdownSpeech
    ) {
        self.store = store
        self.timeout = timeout
        self.sleep = sleep
        self.shutdownSpeech = shutdownSpeech
    }

    func requestTermination(reply: @escaping Reply) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await shutdownSpeech()
            let decision = await TerminationDrain.wait(
                store: store, timeout: timeout, sleep: sleep
            )
            terminationTask = nil
            reply(decision == .proceed)
        }
        return .terminateLater
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// MainView 出现时把 openWindow 动作塞进来。AppDelegate 自己拿不到 SwiftUI 环境值。
    static var openMain: (() -> Void)?
    @MainActor private lazy var terminationCoordinator = AppTerminationCoordinator(
        store: AppCompositionRoot.live.lastAudioStore,
        timeout: .seconds(5),
        shutdownSpeech: { await Engine.shared.shutdownSpeech() }
    )

    func applicationDidFinishLaunching(_ note: Notification) {
        MainActor.assumeIsolated {
            LastAudioOrphanCleaner.remove(
                in: Store.runtimeDir,
                olderThan: Date(timeIntervalSinceNow: -86_400)
            )
            Task { @MainActor in
                await Engine.shared.installHotkeysAfterInitialHydration()
            }
            // 上次退出前窗口是关着的话,系统恢复会无窗启动——"点图标没反应"的另一半真相。
            // 除非用户选了只留菜单栏,否则启动兜底开一次主窗口。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !Engine.shared.prefs.menuBarOnly else {
                    NSApp.setActivationPolicy(.accessory)
                    return
                }
                let hasMain = NSApp.windows.contains { $0.title == "念" && $0.isVisible }
                if !hasMain { Self.openMain?() }
            }
        }

        // 关掉最后一个真窗口(带标题栏的)就从 Dock 撤下,只留菜单栏;开窗时再回来。
        // 延迟一拍:willClose 时窗口还算 visible,立刻查会误判成"还有窗"。
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let w = note.object as? NSWindow, w.styleMask.contains(.titled) else { return }
            DispatchQueue.main.async {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let anyVisible = NSApp.windows.contains {
                        $0.styleMask.contains(.titled) && $0.isVisible
                    }
                    if !anyVisible { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }

    /// 从菜单栏面板或 reopen 把窗口拉回来之前,先回到 Dock(除非用户选了永久只留菜单栏)。
    @MainActor
    static func backToDock() {
        guard !Engine.shared.prefs.menuBarOnly else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 用户点 Finder/Dock 里的 app 图标时走这里。菜单栏型 app 主窗口关了以后,
    /// 没人处理 reopen 就是"点了没反应"——必须自己把主窗口拉回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            Self.backToDock()
            if !flag { Self.openMain?() }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            terminationCoordinator.requestTermination { shouldTerminate in
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        }
    }
}

/// label 闭包本身不走 SwiftUI 响应式,单独封 View 才能观察 Engine 刷新菜单栏图标。
private struct TrayLabel: View {
    @ObservedObject private var engine = Engine.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 播放指示必须烧进同尺寸的位图里切换。曾试过"图标旁边条件显示一个 Circle":
        // 状态项宽度首渲染后锁死,后加的视图挤不进来,圆点永远不出现(实机截图证实)。
        Image(nsImage: engine.phase == .playing ? .trayGlyphPlaying : .trayGlyph)
            .onAppear {
                // openMain 必须挂在这儿:菜单栏图标永远存在。挂在 MainView 上是鸡生蛋——
                // 窗口被系统恢复成"关着"时 MainView 根本不出现,钩子永远装不上。
                AppDelegate.openMain = { openWindow(id: "main") }
            }
    }
}

extension NSImage {
    /// 菜单栏用苹方 Semibold 的「念」——实测宋体在 36px 实际像素下笔画就糊了。
    /// 模板图交给系统上色,深浅色菜单栏自动适配。
    static let trayGlyph: NSImage = makeTrayGlyph(playing: false)
    static let trayGlyphPlaying: NSImage = makeTrayGlyph(playing: true)

    private static func makeTrayGlyph(playing: Bool) -> NSImage {
        let canvas = NSSize(width: 18, height: 18)
        let img = NSImage(size: canvas, flipped: false) { rect in
            if let base = NSImage(named: "menubar") {
                base.draw(in: rect)
            } else if let sym = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "念") {
                // 资源没打进 bundle 时不至于整个菜单栏空掉
                sym.draw(in: rect)
            }
            if playing, let ctx = NSGraphicsContext.current?.cgContext {
                // 右下角圆点。先冲掉一圈底(destinationOut),不然会和「心」的笔画黏成一团
                let halo = CGRect(x: 10.5, y: -0.5, width: 8, height: 8)
                ctx.setBlendMode(.destinationOut)
                ctx.fillEllipse(in: halo)
                ctx.setBlendMode(.normal)
                NSColor.black.setFill()
                ctx.fillEllipse(in: halo.insetBy(dx: 1.7, dy: 1.7))
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

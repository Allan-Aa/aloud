import AppKit
import ApplicationServices

/// 读「选中的文字」。macOS 没有公开 API 直接拿别的 app 的选区,
/// 只能模拟一次 ⌘C 再读剪贴板。旧版在这里踩过三个坑,全都在下面防住了。
enum Selection {
    enum Failure: LocalizedError {
        case noAccessibility
        case selfIsFrontmost
        case nothingCopied(app: String)

        var errorDescription: String? {
            switch self {
            case .noAccessibility:
                return "需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，勾上「念」"
            case .selfIsFrontmost:
                return "请切到有选中文字的 app 再按热键"
            case .nothingCopied(let app):
                return "没能从「\(app)」复制到文字，先选中一段再试"
            }
        }
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func read() async throws -> String {
        guard hasAccessibility else { throw Failure.noAccessibility }

        let front = NSWorkspace.shared.frontmostApplication
        // 坑1:自己在前台时按热键,复制到的是自己窗口里的东西,报错要说人话
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier {
            throw Failure.selfIsFrontmost
        }
        let appName = front?.localizedName ?? "未知 app"

        // 坑2(实翻车过):热键触发的瞬间用户手指还压着 ⌃/⌥,这时发 ⌘C 会叠成 ⌃⌘C —— 不是复制。
        // 固定 sleep 是在赌用户手速,改成轮询物理修饰键状态,等它们真的全松开。
        await waitForModifiersReleased(timeout: 3.0)

        let client = SystemPasteboardClient()
        let transport = PasteboardTransport(client: client, interference: SystemCopyInterferenceMonitor())
        do {
            return try await transport.readSelection { ownership in
                sendCommandC(operation: ownership.marker)
                ownership.copyCommandDispatched()
            }
        } catch {
            throw Failure.nothingCopied(app: appName)
        }
    }

    /// 等所有物理修饰键松开。CGEventSource 读的是真实键盘状态,不是事件流里的。
    private static func waitForModifiersReleased(timeout: TimeInterval) async {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(mask).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private static func sendCommandC(operation: PasteboardOperationMarker) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let c: CGKeyCode = 8   // kVK_ANSI_C
        let down = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: false)
        let tag = SystemCopyInterferenceClassifier(operation: operation).expectedSourceUserData
        down?.setIntegerValueField(.eventSourceUserData, value: tag)
        up?.setIntegerValueField(.eventSourceUserData, value: tag)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

private final class SystemCopyInterferenceLease: @unchecked Sendable, CopyInterferenceLease {
    private let lifecycle: CopyInterferenceStopLifecycle
    init(tokens: [Any]) {
        let box = SystemMonitorTokenBox(tokens)
        lifecycle = CopyInterferenceStopLifecycle { box.tokens.forEach { NSEvent.removeMonitor($0) } }
    }
    func stop() { lifecycle.stop() }
}

private final class SystemMonitorTokenBox: @unchecked Sendable {
    let tokens: [Any]
    init(_ tokens: [Any]) { self.tokens = tokens }
}

private struct SystemCopyInterferenceMonitor: CopyInterferenceMonitor {
    func start(operation: PasteboardOperationMarker, onInterference: @escaping @Sendable () -> Void) -> any CopyInterferenceLease {
        let classifier = SystemCopyInterferenceClassifier(operation: operation)
        let inspect: @Sendable (NSEvent) -> Void = { event in
            let sample = SystemCopyEvent(
                keyCode: event.keyCode,
                command: event.modifierFlags.contains(.command),
                sourceUserData: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            )
            guard classifier.isInterference(sample) else { return }
            onInterference()
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: inspect)
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in inspect(event); return event }
        return SystemCopyInterferenceLease(tokens: [global, local].compactMap { $0 })
    }
}

private struct SystemCopyEvent: CopyEventAccessing {
    let keyCode: UInt16
    let command: Bool
    let sourceUserData: Int64
}

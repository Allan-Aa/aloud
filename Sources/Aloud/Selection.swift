import AppKit
import ApplicationServices

/// 优先通过辅助功能读取明确选区；普通复制路径保留给不暴露选区的 app。
enum Selection {
    enum Failure: LocalizedError {
        case noAccessibility
        case selectionUnavailable
        case selfIsFrontmost
        case nothingCopied(app: String)

        var errorDescription: String? {
            switch self {
            case .selectionUnavailable:
                return "当前控件未提供选区信息，请重新选择后再试"
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

    /// 优先只读 AX 选区；AI 控件不支持时，使用受保护的选区复制。
    @MainActor
    static func readIfPresent() async throws -> String? {
        guard hasAccessibility else { throw Failure.noAccessibility }
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        guard front.bundleIdentifier != Bundle.main.bundleIdentifier else { throw Failure.selfIsFrontmost }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let window = elementAttribute(kAXFocusedWindowAttribute, of: app)
        let focused = elementAttribute(kAXFocusedUIElementAttribute, of: app)
        let text: String?
        do {
            text = try selectedText(startingAt: focused ?? window)
        } catch Failure.selectionUnavailable {
            if ["com.openai.codex", "com.anthropic.claudefordesktop"].contains(front.bundleIdentifier ?? "") {
                text = try await copyIfPresent { try await copyCurrentSelection() }
            } else {
                text = nil
            }
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier,
              elementAttribute(kAXFocusedWindowAttribute, of: app) == window else {
            throw CurrentAIReplyFailure.frontmostApplicationDrift
        }
        return text
    }

    static func selectedText(
        startingAt focused: AXUIElement?,
        attribute: (String, AXUIElement) -> CFTypeRef? = { attribute($0, of: $1) }
    ) throws -> String? {
        var current = focused
        var visited: [AXUIElement] = []
        var supportsSelection = false
        let deadline = Date().addingTimeInterval(0.5)
        while let element = current, visited.count < 64, Date() < deadline {
            try Task.checkCancellation()
            guard !visited.contains(element) else { break }
            visited.append(element)
            if let text = attribute(kAXSelectedTextAttribute, element) as? String {
                supportsSelection = true
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            guard let parent = attribute(kAXParentAttribute, element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        guard supportsSelection else { throw Failure.selectionUnavailable }
        return nil
    }

    static func copyIfPresent(using copy: () async throws -> String) async throws -> String? {
        do { return try await copy() }
        catch PasteboardTransportError.timeout { return nil }
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func read() async throws -> String {
        guard hasAccessibility else { throw Failure.noAccessibility }

        let front = NSWorkspace.shared.frontmostApplication
        // 坑1:自己在前台时按热键,复制到的是自己窗口里的东西,报错要说人话
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier {
            throw Failure.selfIsFrontmost
        }
        let appName = front?.localizedName ?? "未知 app"

        do { return try await copyCurrentSelection() }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.nothingCopied(app: appName) }
    }

    @MainActor
    private static func copyCurrentSelection() async throws -> String {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front.map { AXUIElementCreateApplication($0.processIdentifier) }
        let window = app.flatMap { elementAttribute(kAXFocusedWindowAttribute, of: $0) }
        // 等真实修饰键松开，避免 ⌃Z 变成 ⌃⌘C。
        await waitForModifiersReleased(timeout: 3.0)
        try Task.checkCancellation()
        let client = SystemPasteboardClient()
        let transport = PasteboardTransport(client: client, interference: SystemCopyInterferenceMonitor())
        return try await transport.readSelection { ownership in
            try await MainActor.run {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front?.processIdentifier,
                      app.flatMap({ elementAttribute(kAXFocusedWindowAttribute, of: $0) }) == window else {
                    throw CurrentAIReplyFailure.frontmostApplicationDrift
                }
                sendCommandC(operation: ownership.marker)
                ownership.copyCommandDispatched()
            }
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

struct SystemCopyInterferenceMonitor: CopyInterferenceMonitor {
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

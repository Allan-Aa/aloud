import AppKit
import Carbon.HIToolbox

struct HotkeySpec: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32       // Carbon 的 cmdKey/optionKey/controlKey/shiftKey

    static let readSelection = HotkeySpec(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey))
    static let readClipboard = HotkeySpec(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey))
    static let togglePause   = HotkeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey))

    /// 空 = 已禁用(用户按 ⌫ 清掉的)
    var isEmpty: Bool { keyCode == 0 && modifiers == 0 }

    var display: String {
        if isEmpty { return "未设置" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s.isEmpty ? Self.keyName(keyCode) : s + " " + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "esc"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            // 字母数字键:问一次当前键盘布局,别硬编码美式键位
            if let name = layoutName(code) { return name.uppercased() }
            return "key\(code)"
        }
    }

    /// 用 TIS 把 keyCode 翻成当前布局下的字符
    private static func layoutName(_ code: UInt32) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

enum HotkeyAction: Int, CaseIterable {
    case readSelection = 1, readClipboard = 2, togglePause = 3
}

@MainActor
protocol HotkeyRegistering: AnyObject {
    func install(_ callback: @escaping (HotkeyAction) -> Void)
    @discardableResult func register(_ action: HotkeyAction, _ spec: HotkeySpec) -> Bool
    func registerAll(_ specs: [HotkeyAction: HotkeySpec]) -> [HotkeyAction: Bool]
}

/// 用 Carbon 的 RegisterEventHotKey,不是 NSEvent 全局监听——
/// 前者不需要辅助功能权限就能收到按键,后者要。读选中另说,那个绕不开权限。
final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var onFire: ((HotkeyAction) -> Void)?

    private init() {}

    func install(_ callback: @escaping (HotkeyAction) -> Void) {
        onFire = callback
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            if let action = HotkeyAction(rawValue: Int(hkID.id)) {
                DispatchQueue.main.async { me.onFire?(action) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(_ action: HotkeyAction, _ spec: HotkeySpec) -> Bool {
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x414C4400), id: UInt32(action.rawValue))  // 'ALD\0'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[action] = ref
        return true
    }

    func unregister(_ action: HotkeyAction) {
        if let ref = refs[action] { UnregisterEventHotKey(ref) }
        refs[action] = nil
    }

    /// 开发实例会抢注全局热键(先注册者得,正式 app 静默失败)。
    /// 这里返回注册结果,调用方可以据此提示,别让人对着不响的热键干瞪眼。
    func registerAll(_ specs: [HotkeyAction: HotkeySpec]) -> [HotkeyAction: Bool] {
        var result: [HotkeyAction: Bool] = [:]
        for (action, spec) in specs {
            result[action] = spec.isEmpty ? true : register(action, spec)   // 空 = 主动禁用,不算失败
            if spec.isEmpty { unregister(action) }
        }
        return result
    }

    /// 录制新热键时必须先摘掉所有已注册的,否则用户按到自己的旧热键会被自己截胡,
    /// 录不进去还会触发一次朗读。
    func suspendAll() {
        for action in HotkeyAction.allCases { unregister(action) }
    }
}

extension Hotkeys: HotkeyRegistering {}

/// 录键器:点一下进入录制,按下的组合直接生效。Esc 取消,⌫ 清空(=禁用)。
final class KeyRecorder: ObservableObject {
    @Published var recording: HotkeyAction?
    private var monitor: Any?

    func start(_ action: HotkeyAction, onResult: @escaping (HotkeySpec?) -> Void) {
        stop()
        recording = action
        Hotkeys.shared.suspendAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            defer { self.stop() }
            switch Int(event.keyCode) {
            case kVK_Escape:
                onResult(nil)                                   // 取消,保持原样
            case kVK_Delete, kVK_ForwardDelete:
                onResult(HotkeySpec(keyCode: 0, modifiers: 0))  // 清空 = 禁用
            default:
                onResult(HotkeySpec(keyCode: UInt32(event.keyCode),
                                    modifiers: Self.carbonFlags(event.modifierFlags)))
            }
            return nil   // 吞掉这次按键,别让它落到界面上
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
    }

    static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

import SwiftUI

enum Lang: String {
    case zh, en
    /// 跟随系统语言。导出设计图时可以用环境值强制指定。
    static var system: Lang {
        (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false) ? .zh : .en
    }
}

struct Str {
    let zh: String
    let en: String
    func callAsFunction(_ l: Lang) -> String { l == .zh ? zh : en }
}

private struct LangKey: EnvironmentKey {
    static let defaultValue = Lang.system
}

extension EnvironmentValues {
    var lang: Lang {
        get { self[LangKey.self] }
        set { self[LangKey.self] = newValue }
    }
}

/// 全部界面文案。中英一一对应,加文案必须两边一起加。
enum T {
    // 主窗口
    static let appName        = Str(zh: "念", en: "Aloud")
    static let speak          = Str(zh: "念", en: "aloud")
    static let synthesizing   = Str(zh: "合成中", en: "synthesizing")
    static let placeholder    = Str(zh: "输入或粘贴文本，或按 ⌃` 读选中的字",
                                    en: "Type or paste text, or press ⌃` to read your selection")
    static let readClipboard  = Str(zh: "读剪贴板", en: "Clipboard")
    static let clipboardMock  = Str(zh: "（剪贴板内容）", en: "(clipboard contents)")
    static let providerSettings = Str(zh: "语音服务与 API Key 设置", en: "Voice providers and API keys")

    // 历史
    static let history        = Str(zh: "历史", en: "History")
    static let searchHistory  = Str(zh: "搜索历史…", en: "Search history…")

    // 菜单栏面板
    static let nowReading     = Str(zh: "正在朗读", en: "Reading")
    static let paused         = Str(zh: "已暂停", en: "Paused")
    static let idle           = Str(zh: "空闲", en: "Idle")
    static let panelIdleHint  = Str(zh: "选中任意文字，按 ⌃` 开读",
                                    en: "Select text anywhere, then press ⌃`")
    static let synthRate      = Str(zh: "合成语速", en: "Rate")
    static let playbackSpeed  = Str(zh: "倍速", en: "Speed")
    static let readSelection  = Str(zh: "⌃` 读选中", en: "⌃` read selection")
    static let quit           = Str(zh: "退出", en: "Quit")
    static let openMain       = Str(zh: "打开主窗口", en: "Open main window")

    // 设置 · 分页
    static let tabVoice       = Str(zh: "语音", en: "Voice")
    static let tabHotkeys     = Str(zh: "快捷键", en: "Hotkeys")
    static let tabDict        = Str(zh: "词典", en: "Dictionary")
    static let tabAdvanced    = Str(zh: "高级", en: "Advanced")

    // 设置 · 语音
    static let minimaxKey     = Str(zh: "MiniMax Key", en: "MiniMax Key")
    static let keyNote        = Str(zh: "从 1Password 读取，密钥不经过剪贴板",
                                    en: "Read from 1Password — never touches the clipboard")
    static let importFrom1P   = Str(zh: "从 1Password 导入", en: "Import from 1Password")
    static let test           = Str(zh: "测试", en: "Test")
    static let defaultVoice   = Str(zh: "默认音色", en: "Default voice")
    static let defaultRate    = Str(zh: "默认合成语速", en: "Default synthesis rate")
    static let rateNote       = Str(zh: "改了要重新合成，缓存按语速分开存",
                                    en: "Changing this re-synthesises; cache is keyed by rate")
    static let stripMarkdown  = Str(zh: "去除 Markdown 标记", en: "Strip Markdown")
    static let stripMdNote    = Str(zh: "读文档时不会把 # 和 * 念出来",
                                    en: "Won't read out # and * when reading documents")
    static let skipCode       = Str(zh: "跳过代码块", en: "Skip code blocks")

    // 设置 · 快捷键
    static let hkSelection    = Str(zh: "朗读选中文字", en: "Read selection")
    static let hkSelNote      = Str(zh: "在任何 app 里按下即读", en: "Works in any app")
    static let hkClipboard    = Str(zh: "朗读剪贴板", en: "Read clipboard")
    static let hkPlayPause    = Str(zh: "播放 / 暂停", en: "Play / Pause")
    static let recording      = Str(zh: "按下想用的组合键 · Esc 取消 · ⌫ 禁用",
                                    en: "Press a combo · Esc to cancel · ⌫ to disable")
    static let pressKeys      = Str(zh: "按组合键…", en: "Press keys…")
    static let hkSound        = Str(zh: "快捷键提示音", en: "Hotkey chime")
    static let hkSoundNote    = Str(zh: "按下朗读快捷键时播放一声轻响",
                                    en: "A soft click when the read hotkey fires")
    static let launchAtLogin  = Str(zh: "开机自启", en: "Launch at login")
    static let menuBarOnly    = Str(zh: "只留在菜单栏", en: "Menu bar only")
    static let menuBarNote    = Str(zh: "从程序坞和 ⌘Tab 中移除", en: "Remove from Dock and ⌘Tab")

    // 设置 · 词典
    static let dictNote       = Str(zh: "把念错的词替换成正确读音，朗读前生效",
                                    en: "Replace mispronounced words before synthesis")
    static let dictFind       = Str(zh: "原词", en: "Word")
    static let dictReplace    = Str(zh: "读成", en: "Say")
    static let newRule        = Str(zh: "＋ 新规则", en: "＋ New rule")

    // 设置 · 高级
    static let cacheLimit     = Str(zh: "缓存上限", en: "Cache limit")
    static let cacheLimitNote = Str(zh: "超出后从最旧的开始删", en: "Oldest entries are evicted first")
    static let cacheDays      = Str(zh: "缓存保留天数", en: "Keep cache for")
    static let daysValue      = Str(zh: "14 天", en: "14 days")
    static func binPath(_ bin: String) -> Str {
        Str(zh: "\(bin) 路径", en: "\(bin) path")
    }
}

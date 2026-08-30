import SwiftUI

extension Color {
    init(_ hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// 三色系统,和 app 图标同源:宣纸(底)、墨(字)、朱砂(唯一强调色)。
/// 强调色只用在"正在发生的事"上——播放中的波形、录入焦点、主按钮。别处一律墨色。
struct Palette {
    let bg: Color          // 窗口底
    let surface: Color     // 卡片/输入区
    let ink: Color         // 正文
    let inkDim: Color      // 次要信息
    let inkFaint: Color    // 占位符、分隔
    let seal: Color        // 朱砂
    let line: Color        // 描边

    static let paper = Palette(
        bg: Color(0xF7F4ED), surface: Color(0xFFFFFF, alpha: 0.62),
        ink: Color(0x1A1A1C), inkDim: Color(0x6B6862), inkFaint: Color(0xA8A399),
        seal: Color(0xC1352B), line: Color(0x1A1A1C, alpha: 0.10))

    static let ink_ = Palette(
        bg: Color(0x141416), surface: Color(0xFFFFFF, alpha: 0.05),
        ink: Color(0xF5F3EE), inkDim: Color(0x9A968E), inkFaint: Color(0x6A665F),
        seal: Color(0xD94F3D), line: Color(0xFFFFFF, alpha: 0.10))

    static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? .ink_ : .paper }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.paper
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// 整个 app 的动效只有两条曲线:轻交互用 snap,位置变化用 rise。
/// 统一曲线是"看起来是一个东西做的"的最大来源,比任何配色都管用。
enum Motion {
    static let snap = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let rise = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let fade = Animation.easeOut(duration: 0.18)
}

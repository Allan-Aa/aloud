import SwiftUI

/// 播放时跳动的波形。用 TimelineView 驱动,不占主线程 timer;
/// 每根竖条用不同相位的正弦,看起来才像声音而不像等待动画。
struct Waveform: View {
    var active: Bool
    var color: Color
    var bars: Int = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = Double(i) * 0.7
                    let raw = sin(t * 4.4 + phase)
                    let h = active ? (0.34 + 0.66 * abs(raw)) : 0.22
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: 16 * h)
                }
            }
            .frame(height: 16)
            .animation(.linear(duration: 1.0 / 30), value: active)
        }
    }
}

/// 按下缩放必须走 ButtonStyle。别在 Button 上挂 onLongPressGesture 做这件事——
/// 两个手势会打架,点击被吞掉,而且是时好时坏的那种(实测踩过)。
struct PressScale: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? .none : Motion.snap, value: configuration.isPressed)
    }
}

/// 主操作使用统一高度和轻微按压反馈。
struct SealButton: View {
    var title: String
    var busy: Bool = false
    var enabled: Bool = true
    var foreground: Color = .white
    var systemImage: String? = nil
    var action: () -> Void

    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                }
                if let systemImage, !busy {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(enabled ? foreground : p.inkFaint)
            .padding(.horizontal, 15)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(enabled ? p.seal : p.ink.opacity(0.045))
            )
        }
        .buttonStyle(PressScale())
        .brightness(hovering && enabled && !busy ? 0.045 : 0)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .focusEffectDisabled()
        .keyboardShortcut(.return, modifiers: .command)   // ⌘↩ 直接朗读,手不用离开键盘
        .disabled(!enabled || busy)
    }
}

/// 圆形图标按钮:播放器用。hover 才显形,静止时几乎不存在。
struct GhostIcon: View {
    var systemName: String
    var action: () -> Void

    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(p.ink)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(p.ink.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // 否则窗口一开焦点环就挂在第一个图标按钮上
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
    }
}

/// 速度滑块:一条能拖的进度条,右侧常驻数值。
/// 轨道点哪跳哪(minimumDistance: 0),不用先摸到把手再拖。
struct InkSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var showsButtons: Bool = true
    var snapPoints: [Double] = []
    var resetTitle: String? = nil
    var accessibilityLabel: String = ""
    var valueWidth: CGFloat = 50
    var trackHeight: CGFloat = 1
    var knob: CGFloat = 8

    @Environment(\.palette) private var p
    @State private var dragging = false
    @State private var hovering = false

    private var span: Double { range.upperBound - range.lowerBound }
    private var ratio: Double { span > 0 ? (value - range.lowerBound) / span : 0 }

    private func clamp(_ v: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step))
    }

    private func snapped(_ v: Double) -> Double {
        guard let point = snapPoints.min(by: { abs($0 - v) < abs($1 - v) }), abs(point - v) <= step * 0.6 else {
            return clamp(v)
        }
        return point
    }

    var body: some View {
        slider.accessibilityActions {
            if let resetTitle, abs(value - 1) >= 0.001 {
                Button(resetTitle) { value = 1 }
            }
        }
    }

    private var slider: some View {
        HStack(spacing: 7) {
            if showsButtons {
                stepButton("minus", enabled: value > range.lowerBound) { value = clamp(value - step) }
            }

            GeometryReader { geo in
                let w = geo.size.width
                let x = w * ratio
                ZStack(alignment: .leading) {
                    Capsule().fill(p.ink.opacity(0.12))
                        .frame(height: trackHeight)
                    Capsule().fill(p.seal)
                        .frame(width: max(0, x), height: trackHeight)
                    ForEach(snapPoints, id: \.self) { point in
                        Circle()
                            .fill(p.ink.opacity(0.26))
                            .frame(width: 3, height: 3)
                            .offset(x: max(0, min(w - 3, w * (point - range.lowerBound) / span - 1.5)))
                    }
                    Circle()
                        .fill(p.seal)
                        .frame(width: dragging ? knob + 2 : knob, height: dragging ? knob + 2 : knob)
                        .overlay(Circle().stroke(p.ink.opacity(0.10), lineWidth: 0.5))
                        .offset(x: max(0, min(w - knob, x - knob / 2)))
                }
                .frame(height: max(knob + 4, trackHeight))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .gesture(
                    // minimumDistance 0 = 点一下也算,轨道任意位置直接跳过去
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let r = max(0, min(1, g.location.x / max(w, 1)))
                            value = snapped(range.lowerBound + r * span)
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(Motion.fade, value: dragging)
            }
            .frame(height: knob + 4)

            if showsButtons {
                stepButton("plus", enabled: value < range.upperBound) { value = clamp(value + step) }
            }

            Text(format(value))
                .font(.system(size: 11, weight: dragging ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(dragging ? p.seal : p.inkDim)
                .frame(width: valueWidth, alignment: .trailing)

            if let resetTitle {
                Button { value = 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(p.inkDim)
                .help(resetTitle)
                .accessibilityLabel(resetTitle)
                .accessibilityHidden(true)
                .opacity(abs(value - 1) < 0.001 ? 0 : 1)
                .disabled(abs(value - 1) < 0.001)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = clamp(value + step)
            case .decrement: value = clamp(value - step)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? p.inkDim : p.inkFaint)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
    }
}

extension InkSlider {
    private static func speedFormat(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        if hundredths.isMultiple(of: 100) { return "\(hundredths / 100)×" }
        if hundredths.isMultiple(of: 10) { return String(format: "%.1f×", value) }
        return String(format: "%.2f×", value)
    }

    /// 合成语速:−50%–+100%,5% 一档
    static func rate(_ binding: Binding<Int>, showsButtons: Bool = true, valueWidth: CGFloat = 46,
                     accessibilityLabel: String = "Synthesis rate") -> InkSlider {
        InkSlider(
            value: Binding(get: { Double(binding.wrappedValue) },
                           set: { binding.wrappedValue = Int($0.rounded()) }),
            range: -50...100, step: 5,
            format: { $0 >= 0 ? "+\(Int($0))%" : "\(Int($0))%" },
            showsButtons: showsButtons,
            accessibilityLabel: accessibilityLabel,
            valueWidth: valueWidth
        )
    }

    /// 播放倍速:0.5×–3×,0.05 一档。播放层的,拖着就立即变
    static func speed(_ binding: Binding<Double>, showsButtons: Bool = true,
                      valueWidth: CGFloat = 40, resetTitle: String? = nil,
                      accessibilityLabel: String = "Speed") -> InkSlider {
        InkSlider(value: binding, range: 0.5...3.0, step: 0.05,
                  format: { Self.speedFormat($0) },
                  showsButtons: showsButtons, snapPoints: [1, 1.25, 1.5, 2],
                  resetTitle: resetTitle, accessibilityLabel: accessibilityLabel,
                  valueWidth: valueWidth)
    }
}

/// 可拖可点的数值控件:中间那块左右拖着调,两侧 −/+ 点着微调。
/// 拖拽用累积位移换档,不是跟手线性映射——后者在小范围里根本调不准。
struct DragStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var width: CGFloat = 54
    /// 拖多少点走一档。太小会手抖乱跳,太大又拖不动。
    var pointsPerStep: CGFloat = 9

    @Environment(\.palette) private var p
    @State private var lastX: CGFloat = 0
    @State private var accum: CGFloat = 0
    @State private var dragging = false
    @State private var hovering = false

    private func clamp(_ v: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step))
    }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) { value = clamp(value - step) }

            Text(format(value))
                .font(.system(size: 12, weight: dragging ? .semibold : .medium))
                .monospacedDigit()
                .frame(width: width)
                .foregroundStyle(dragging ? p.seal : p.ink)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(p.ink.opacity(dragging ? 0.10 : (hovering ? 0.05 : 0)))
                )
                .onHover { inside in
                    hovering = inside
                    // 光标变成左右箭头,不然没人知道这块能拖
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            dragging = true
                            accum += g.translation.width - lastX
                            lastX = g.translation.width
                            let steps = (accum / pointsPerStep).rounded(.towardZero)
                            if steps != 0 {
                                value = clamp(value + Double(steps) * step)
                                accum -= steps * pointsPerStep
                            }
                        }
                        .onEnded { _ in
                            dragging = false
                            lastX = 0
                            accum = 0
                        }
                )

            stepButton("plus", enabled: value < range.upperBound) { value = clamp(value + step) }
        }
        .padding(.vertical, 3)
        .background(Capsule().fill(p.ink.opacity(0.05)))
        .overlay(Capsule().stroke(dragging ? p.seal.opacity(0.5) : p.line, lineWidth: 1))
        .animation(Motion.fade, value: dragging)
    }

    private func stepButton(_ icon: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? p.ink : p.inkFaint)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
    }
}

extension DragStepper {
    /// 合成语速:整数百分比,5% 一档
    static func rate(_ binding: Binding<Int>, width: CGFloat = 54) -> DragStepper {
        DragStepper(
            value: Binding(get: { Double(binding.wrappedValue) },
                           set: { binding.wrappedValue = Int($0.rounded()) }),
            range: -50...100, step: 5,
            format: { $0 >= 0 ? "+\(Int($0))%" : "\(Int($0))%" },
            width: width
        )
    }

    /// 播放倍速:0.5×–3×,0.05 一档。这个是播放层的,立即生效,不重新合成。
    static func speed(_ binding: Binding<Double>, width: CGFloat = 50) -> DragStepper {
        DragStepper(value: binding, range: 0.5...3.0, step: 0.05,
                    format: { String(format: "%.2g×", $0) },
                    width: width, pointsPerStep: 7)
    }
}

/// −/+ 步进器。这次是 SwiftUI 原生版,行为和刚给 Electron 版加的那个一致(5% 一档)。
struct Stepper5: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 5

    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }
            Text(value >= 0 ? "+\(value)%" : "\(value)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(width: 48)
                .foregroundStyle(p.ink)
            stepButton("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + step)
            }
        }
        .padding(.vertical, 3)
        .background(
            Capsule().fill(p.ink.opacity(0.05))
        )
        .overlay(Capsule().stroke(p.line, lineWidth: 1))
    }

    private func stepButton(_ icon: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? p.ink : p.inkFaint)
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

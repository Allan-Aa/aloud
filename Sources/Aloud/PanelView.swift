import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PanelViewBody(
            state: PanelViewState(
                text: engine.text,
                phase: engine.phase,
                rate: engine.prefs.rate,
                playbackSpeed: engine.prefs.playbackSpeed,
                position: engine.position,
                duration: engine.duration
            ),
            actions: PanelViewActions(
                seek: { engine.seek($0) },
                togglePause: { engine.togglePause() },
                stop: { engine.stop() },
                setRate: { engine.setRate($0) },
                setPlaybackSpeed: { engine.setSpeed($0) },
                openMain: { openWindow(id: "main") },
                quit: { NSApplication.shared.terminate(nil) }
            )
        )
    }
}

struct PanelPreviewView: View {
    let state: PanelViewState

    var body: some View {
        PanelViewBody(state: state, actions: .none)
    }
}

private struct PanelViewActions {
    let seek: (Double) -> Void
    let togglePause: () -> Void
    let stop: () -> Void
    let setRate: (Int) -> Void
    let setPlaybackSpeed: (Double) -> Void
    let openMain: () -> Void
    let quit: () -> Void

    static let none = PanelViewActions(
        seek: { _ in }, togglePause: {}, stop: {}, setRate: { _ in },
        setPlaybackSpeed: { _ in }, openMain: {}, quit: {}
    )
}

private struct PanelViewBody: View {
    let state: PanelViewState
    let actions: PanelViewActions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.lang) private var lang

    private var p: Palette { Palette.of(scheme) }
    private var idle: Bool { !state.phase.isLive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Waveform(active: state.phase == .playing, color: p.seal)
                Text(state.phase == .playing ? T.nowReading(lang)
                     : state.phase == .paused ? T.paused(lang) : T.idle(lang))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(p.inkDim)
                Spacer()
                if !idle {
                    Text("\(fmt(state.position)) / \(fmt(state.duration))")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(p.inkFaint)
                }
            }

            Text(idle ? T.panelIdleHint(lang) : String(state.text.prefix(60)))
                .font(.system(size: 12))
                .foregroundStyle(idle ? p.inkFaint : p.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.ink.opacity(0.10))
                    Capsule().fill(p.seal)
                        .frame(width: geometry.size.width * (idle ? 0 : progress))
                }
            }
            .frame(height: 3)

            HStack(spacing: 2) {
                GhostIcon(systemName: "gobackward.10") { actions.seek(-10) }
                GhostIcon(systemName: state.phase == .playing ? "pause.fill" : "play.fill", action: actions.togglePause)
                GhostIcon(systemName: "goforward.10") { actions.seek(10) }
                GhostIcon(systemName: "stop.fill", action: actions.stop)
                Spacer()
                GhostIcon(systemName: "macwindow", action: actions.openMain)
                    .help(T.openMain(lang))
            }

            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    Text(T.synthRate(lang))
                        .font(.system(size: 10))
                        .foregroundStyle(p.inkFaint)
                        .frame(width: 46, alignment: .leading)
                    InkSlider.rate(Binding(get: { state.rate }, set: actions.setRate))
                }
                HStack(spacing: 8) {
                    Text(T.playbackSpeed(lang))
                        .font(.system(size: 10))
                        .foregroundStyle(p.inkFaint)
                        .frame(width: 46, alignment: .leading)
                    InkSlider.speed(Binding(get: { state.playbackSpeed }, set: actions.setPlaybackSpeed))
                }
            }

            Divider().overlay(p.line)

            HStack {
                Text(T.readSelection(lang))
                    .font(.system(size: 10))
                    .foregroundStyle(p.inkFaint)
                Spacer()
                Button(T.quit(lang), action: actions.quit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(p.inkDim)
            }
        }
        .padding(14)
        .frame(width: 296)
        .background(p.bg)
        .environment(\.palette, p)
    }

    private var progress: Double {
        guard state.duration.isFinite, state.duration > 0, state.position.isFinite else { return 0 }
        return min(1, max(0, state.position / state.duration))
    }

    private func fmt(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

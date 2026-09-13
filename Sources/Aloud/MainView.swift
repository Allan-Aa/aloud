import AppKit
import SwiftUI

enum Phase: Equatable, Sendable {
    case idle, synthesizing, playing, paused
    var isLive: Bool { self == .playing || self == .paused }
}

struct MainView: View {
    @ObservedObject var engine: Engine
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var historyOpen: Bool

    init(engine: Engine, historyOpen: Bool = false) {
        self.engine = engine
        _historyOpen = State(initialValue: historyOpen)
    }

    var body: some View {
        MainViewBody(
            state: MainViewState(
                text: engine.text,
                phase: engine.phase,
                voiceControl: engine.currentDefaultVoiceControlState,
                voiceSampleState: engine.voiceSamplePlaybackState,
                voiceLabel: engine.currentVoiceDisplayLabel,
                playbackSpeed: engine.prefs.playbackSpeed,
                position: engine.position,
                duration: engine.duration,
                history: engine.history,
                toast: engine.toast
            ),
            historyOpen: $historyOpen,
            exporting: false,
            actions: MainViewActions(
                setText: { engine.text = $0 },
                setVoice: { voiceID in
                    Task { @MainActor in _ = await engine.updateCurrentDefaultVoice(voiceID) }
                },
                toggleVoiceSample: { providerID, voiceID in engine.toggleVoiceSample(providerID: providerID, voiceID: voiceID) },
                setPlaybackSpeed: { engine.setSpeed($0) },
                readClipboard: { engine.readClipboard() },
                speak: { engine.speak() },
                seek: { engine.seek($0) },
                togglePause: { engine.togglePause() },
                stop: { engine.stop() },
                saveAudio: { engine.saveAudio() },
                replay: { engine.replay($0) },
                load: { engine.loadHistory($0) },
                copy: { entry in
                    NSPasteboard.general.clearContents()
                    if let text = entry.text { NSPasteboard.general.setString(text, forType: .string) }
                },
                dismissToast: { engine.toast = nil },
                openSettings: { openSettings() }
            )
        )
        .onAppear {
            AppDelegate.openMain = { openWindow(id: "main") }
            AppDelegate.backToDock()
        }
    }
}

struct MainPreviewView: View {
    let state: MainViewState
    @State private var historyOpen: Bool

    init(state: MainViewState, historyOpen: Bool) {
        self.state = state
        _historyOpen = State(initialValue: historyOpen)
    }

    var body: some View {
        MainViewBody(
            state: state,
            historyOpen: $historyOpen,
            exporting: true,
            actions: .none
        )
    }
}

private struct MainViewActions {
    let setText: (String) -> Void
    let setVoice: (VoiceID) -> Void
    let toggleVoiceSample: (ProviderID, VoiceID) -> Void
    let setPlaybackSpeed: (Double) -> Void
    let readClipboard: () -> Void
    let speak: () -> Void
    let seek: (Double) -> Void
    let togglePause: () -> Void
    let stop: () -> Void
    let saveAudio: () -> Void
    let replay: (HistoryEntry) -> Void
    let load: (HistoryEntry) -> Void
    let copy: (HistoryEntry) -> Void
    let dismissToast: () -> Void
    let openSettings: () -> Void

    static let none = MainViewActions(
        setText: { _ in }, setVoice: { _ in }, toggleVoiceSample: { _, _ in }, setPlaybackSpeed: { _ in },
        readClipboard: {}, speak: {}, seek: { _ in }, togglePause: {}, stop: {}, saveAudio: {},
        replay: { _ in }, load: { _ in }, copy: { _ in }, dismissToast: {}, openSettings: {}
    )
}

private struct MainViewBody: View {
    let state: MainViewState
    @Binding var historyOpen: Bool
    let exporting: Bool
    let actions: MainViewActions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.lang) private var lang
    @State private var focused = false

    private var p: Palette { Palette.of(scheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            editor
            Divider().overlay(p.line)
            controls
            if state.phase.isLive {
                player.transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HistoryPanel(
                expanded: $historyOpen,
                entries: state.history,
                exporting: exporting,
                onReplay: actions.replay,
                onLoad: actions.load,
                onCopy: actions.copy
            )
        }
        .background(p.bg)
        .environment(\.palette, p)
        .animation(Motion.rise, value: state.phase)
        .overlay(alignment: .top) { toast }
        .frame(minWidth: 620, minHeight: 480)
    }

    @ViewBuilder private var toast: some View {
        if let message = state.toast {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color(0x2A2A2E)))
                .padding(.top, 10)
                .onTapGesture(perform: actions.dismissToast)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("念")
                .font(.custom("STSongti-SC-Bold", size: 25))
                .foregroundStyle(p.ink)
            Text("Aloud")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(p.inkFaint)
                .padding(.top, 3)
            Spacer()
            GhostIcon(systemName: "gearshape") { actions.openSettings() }
                .accessibilityLabel(T.providerSettings(lang))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if state.text.isEmpty {
                Text(T.placeholder(lang))
                    .font(.system(size: 14))
                    .foregroundStyle(p.inkFaint)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
            }
            if exporting {
                Text(state.text)
                    .font(.system(size: 14))
                    .foregroundStyle(p.ink)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: Binding(get: { state.text }, set: actions.setText))
                    .font(.system(size: 14))
                    .foregroundStyle(p.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
        }
        .frame(minHeight: 120, maxHeight: .infinity)
        .background(p.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(focused ? p.seal : .clear).frame(height: 1.5)
                .animation(Motion.fade, value: focused)
        }
        .onTapGesture { focused = true }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if exporting {
                HStack(spacing: 4) {
                    Text(state.voiceLabel).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(p.ink)
            } else {
                if let control = state.voiceControl {
                    ProviderVoicePicker(
                        voices: control.voices,
                        providerID: control.providerID,
                        selection: Binding(get: { control.selectedVoiceID }, set: actions.setVoice),
                        sampleState: state.voiceSampleState,
                        toggleSample: actions.toggleVoiceSample,
                        showsFieldLabel: false
                    )
                    .fixedSize()
                } else {
                    Text("当前音色不可用").font(.system(size: 12, weight: .medium)).foregroundStyle(p.ink)
                }
            }

            Text(T.playbackSpeed(lang))
                .font(.system(size: 10))
                .foregroundStyle(p.inkFaint)
            InkSlider.speed(
                Binding(get: { state.playbackSpeed }, set: actions.setPlaybackSpeed),
                showsButtons: false,
                valueWidth: 36,
                resetTitle: T.resetSpeed(lang),
                accessibilityLabel: T.playbackSpeed(lang)
            )
            .frame(width: 120)

            Button(action: actions.readClipboard) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 10))
                    Text(T.readClipboard(lang)).font(.system(size: 11))
                }
                .foregroundStyle(p.inkDim)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Spacer()

            SealButton(
                title: state.phase == .synthesizing ? T.synthesizing(lang) : T.speak(lang),
                busy: state.phase == .synthesizing,
                enabled: !state.text.isEmpty,
                action: actions.speak
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(p.bg)
    }

    private var player: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Waveform(active: state.phase == .playing, color: p.seal)
                Text(String(state.text.prefix(26)))
                    .font(.system(size: 12))
                    .foregroundStyle(p.inkDim)
                    .lineLimit(1)
                Spacer()
                Text("\(fmt(state.position)) / \(fmt(state.duration))")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(p.inkFaint)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.ink.opacity(0.10))
                    Capsule().fill(p.seal)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 3)

            HStack(spacing: 2) {
                GhostIcon(systemName: "gobackward.10") { actions.seek(-10) }
                GhostIcon(systemName: state.phase == .playing ? "pause.fill" : "play.fill", action: actions.togglePause)
                GhostIcon(systemName: "goforward.10") { actions.seek(10) }
                GhostIcon(systemName: "stop.fill", action: actions.stop)
                Spacer()
                GhostIcon(systemName: "square.and.arrow.down", action: actions.saveAudio)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(p.ink.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
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

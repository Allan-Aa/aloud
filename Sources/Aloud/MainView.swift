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
    let compact: Bool

    init(engine: Engine, historyOpen: Bool = false, compact: Bool = false) {
        self.compact = compact
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
            compact: compact,
            actions: MainViewActions(
                setText: { engine.text = $0 },
                setVoice: { voiceID in
                    Task { @MainActor in _ = await engine.updateCurrentDefaultVoice(voiceID) }
                },
                toggleVoiceSample: { providerID, voiceID in engine.toggleVoiceSample(providerID: providerID, voiceID: voiceID) },
                setPlaybackSpeed: { engine.setSpeed($0) },
                pasteClipboard: {
                    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                        engine.toast = T.clipboardEmpty(Lang.system)
                        return
                    }
                    engine.text = text
                },
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
                openSettings: {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                },
                openMain: {
                    AppDelegate.backToDock()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                },
                quit: { NSApp.terminate(nil) }
            )
        )
        .onAppear {
            AppDelegate.openMain = { openWindow(id: "main") }
            if !compact { AppDelegate.backToDock() }
        }
    }
}

struct MainPreviewView: View {
    let state: MainViewState
    @State private var historyOpen: Bool
    var compact: Bool = false

    init(state: MainViewState, historyOpen: Bool, compact: Bool = false) {
        self.compact = compact
        self.state = state
        _historyOpen = State(initialValue: historyOpen)
    }

    var body: some View {
        MainViewBody(
            state: state,
            historyOpen: $historyOpen,
            exporting: true,
            compact: compact,
            actions: .none
        )
    }
}

struct MainViewActions {
    let setText: (String) -> Void
    let setVoice: (VoiceID) -> Void
    let toggleVoiceSample: (ProviderID, VoiceID) -> Void
    let setPlaybackSpeed: (Double) -> Void
    let pasteClipboard: () -> Void
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
    let openMain: () -> Void
    let quit: () -> Void

    static let none = MainViewActions(
        setText: { _ in }, setVoice: { _ in }, toggleVoiceSample: { _, _ in }, setPlaybackSpeed: { _ in },
        pasteClipboard: {}, speak: {}, seek: { _ in }, togglePause: {}, stop: {}, saveAudio: {},
        replay: { _ in }, load: { _ in }, copy: { _ in }, dismissToast: {}, openSettings: {}, openMain: {}, quit: {}
    )
}

struct MainViewBody: View {
    let state: MainViewState
    @Binding var historyOpen: Bool
    let exporting: Bool
    var compact: Bool = false
    let actions: MainViewActions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.lang) private var lang
    @FocusState private var editorFocused: Bool

    private var p: Palette { Palette.of(scheme) }
    private var inset: CGFloat { compact ? 20 : 28 }
    private var busy: Bool { state.phase == .synthesizing }
    private var canSpeak: Bool { !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !compact && !historyOpen {
                VStack(alignment: .leading, spacing: 6) {
                    Text(T.editorTitle(lang))
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(p.ink)
                    Text(T.editorSubtitle(lang))
                        .font(.system(size: 13))
                        .foregroundStyle(p.inkDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset)
                .padding(.bottom, 22)
            }
            editor
                .padding(.horizontal, inset)
            voiceControls
            if state.phase.isLive {
                player
            } else {
                readingAction
            }
            if let message = state.toast {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                    Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: actions.dismissToast) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(T.dismiss(lang))
                }
                .font(.system(size: 12))
                .foregroundStyle(p.ink)
                .padding(12)
                .background(p.seal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, inset)
                .padding(.bottom, 14)
            }
            if compact {
                HStack {
                    Button(action: actions.openMain) {
                        Label(T.expandWindow(lang), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Spacer()
                    Button(T.quit(lang), action: actions.quit)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(p.inkDim)
                .padding(.horizontal, inset)
                .padding(.vertical, 15)
                .overlay(alignment: .top) { p.line.frame(height: 1) }
            } else {
                HistoryPanel(
                    expanded: $historyOpen,
                    entries: state.history,
                    exporting: exporting,
                    onReplay: actions.replay,
                    onLoad: actions.load,
                    onCopy: actions.copy
                )
            }
        }
        .background(p.bg)
        .environment(\.palette, p)
        .tint(p.seal)
        .frame(minWidth: compact ? 420 : 620, minHeight: compact ? nil : (state.phase.isLive ? 620 : 560))
        .onAppear { if !exporting { editorFocused = true } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("念")
                .font(.custom("STSongti-SC-Bold", size: 25))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(p.seal, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Aloud").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                Text(T.readingText(lang)).font(.system(size: 11)).foregroundStyle(p.inkDim)
            }
            Spacer()
            Button(action: actions.openSettings) {
                Label(T.settings(lang), systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.inkDim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, inset)
        .padding(.top, compact ? 20 : 24)
        .padding(.bottom, compact ? 20 : 26)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if state.text.isEmpty {
                    Text(T.placeholder(lang))
                        .font(.system(size: compact ? 14 : 16))
                        .foregroundStyle(p.inkFaint)
                        .padding(.horizontal, 16)
                        .padding(.top, 15)
                        .allowsHitTesting(false)
                }
                if exporting {
                    Text(state.text)
                        .font(.system(size: compact ? 14 : 16))
                        .lineSpacing(6)
                        .foregroundStyle(p.ink)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: Binding(get: { state.text }, set: actions.setText))
                        .font(.system(size: compact ? 14 : 16))
                        .lineSpacing(6)
                        .foregroundStyle(p.ink)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 11)
                        .padding(.top, 9)
                        .focused($editorFocused)
                        .accessibilityLabel(T.readingText(lang))
                        .accessibilityIdentifier("reading-editor")
                }
            }
            .frame(minHeight: compact ? 130 : (historyOpen ? 60 : 100), maxHeight: compact ? 130 : .infinity)
            HStack {
                Button(action: {
                    actions.pasteClipboard()
                    editorFocused = true
                }) {
                    Label(T.pasteText(lang), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paste-text")
                Spacer()
                Text(T.characterCount(state.text.count, lang)).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(p.inkDim)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(p.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(editorFocused ? p.seal.opacity(0.5) : p.line, lineWidth: 1)
        }
    }

    private var voiceControls: some View {
        Group {
            if !compact {
                HStack(spacing: 16) {
                    voicePicker.disabled(busy || state.phase.isLive)
                    Spacer(minLength: 0)
                    speedControl
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    voicePicker.disabled(busy || state.phase.isLive)
                    speedControl
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 16)
    }

    private var voicePicker: some View {
        HStack(spacing: 8) {
            Text(T.voice(lang)).font(.system(size: 12)).foregroundStyle(p.inkDim)
            if exporting {
                Text(state.voiceLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.ink)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(p.inkDim)
            } else if let control = state.voiceControl {
                ProviderVoicePicker(
                    voices: control.voices,
                    providerID: control.providerID,
                    selection: Binding(get: { control.selectedVoiceID }, set: actions.setVoice),
                    sampleState: state.voiceSampleState,
                    toggleSample: actions.toggleVoiceSample,
                    showsFieldLabel: false
                )
                .fixedSize()
                .disabled(!control.canMutate)
            } else {
                Button(T.configureVoice(lang), action: actions.openSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.seal)
            }
        }
    }

    private var speedControl: some View {
        HStack(spacing: 8) {
            Text(T.playbackSpeed(lang)).font(.system(size: 12)).foregroundStyle(p.inkDim)
            InkSlider.speed(
                Binding(get: { state.playbackSpeed }, set: actions.setPlaybackSpeed),
                showsButtons: false,
                valueWidth: 36,
                resetTitle: T.resetSpeed(lang),
                accessibilityLabel: T.playbackSpeed(lang)
            )
            .frame(width: compact ? 240 : 168)
        }
        .fixedSize()
    }

    private var readingAction: some View {
        HStack(spacing: 12) {
            if busy {
                if exporting {
                    Image(systemName: "waveform").foregroundStyle(p.seal)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(T.synthesizing(lang))
                    .font(.system(size: 12))
                    .foregroundStyle(p.inkDim)
                Spacer(minLength: 0)
                Button(T.cancel(lang), action: actions.stop)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(p.ink)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("⌘ ↵").font(.system(size: 12, weight: .medium)).foregroundStyle(p.inkFaint)
                Spacer()
                SealButton(title: T.speak(lang), enabled: canSpeak, action: actions.speak)
                    .accessibilityIdentifier("read-aloud")
            }
        }
        .padding(.horizontal, inset)
        .padding(.bottom, 20)
    }

    private var player: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Waveform(active: state.phase == .playing, color: p.seal)
                Text(state.phase == .playing ? T.nowReading(lang) : T.paused(lang))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.ink)
                Spacer()
                Text("\(fmt(state.position)) / \(fmt(state.duration))")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(p.inkDim)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.ink.opacity(0.10))
                    Capsule().fill(p.seal).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 4)
            HStack(spacing: 8) {
                GhostIcon(systemName: "gobackward.10") { actions.seek(-10) }
                    .help(T.backTen(lang)).accessibilityLabel(T.backTen(lang))
                Button(action: actions.togglePause) {
                    Label(state.phase == .playing ? T.pause(lang) : T.resume(lang),
                          systemImage: state.phase == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.seal)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(p.seal.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                GhostIcon(systemName: "goforward.10") { actions.seek(10) }
                    .help(T.forwardTen(lang)).accessibilityLabel(T.forwardTen(lang))
                Spacer(minLength: 0)
                Button(T.stop(lang), action: actions.stop)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(p.inkDim)
            }
            HStack {
                Spacer()
                Button(action: actions.saveAudio) {
                    Label(T.saveAudio(lang), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(p.inkDim)
            }
        }
        .padding(16)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.line, lineWidth: 1))
        .padding(.horizontal, inset)
        .padding(.bottom, 20)
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

import AppKit
import SwiftUI

enum Phase: Equatable, Sendable {
    case idle, synthesizing, playing, paused
    var isLive: Bool { self == .playing || self == .paused }
}

enum ReadingSpeedControl: Equatable, Sendable {
    case synthesis, playback
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
                setSynthesisRate: { engine.setRate($0) },
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
    var expandedSpeedControl: ReadingSpeedControl? = nil
    var showingText = false

    init(state: MainViewState, historyOpen: Bool, compact: Bool = false, expandedSpeedControl: ReadingSpeedControl? = nil, showingText: Bool = false) {
        self.compact = compact
        self.state = state
        self.expandedSpeedControl = expandedSpeedControl
        self.showingText = showingText
        _historyOpen = State(initialValue: historyOpen)
    }

    var body: some View {
        MainViewBody(
            state: state,
            historyOpen: $historyOpen,
            exporting: true,
            compact: compact,
            actions: .none,
            expandedSpeedControl: expandedSpeedControl,
            showingText: showingText
        )
    }
}

struct MainViewActions {
    let setText: (String) -> Void
    let setVoice: (VoiceID) -> Void
    let toggleVoiceSample: (ProviderID, VoiceID) -> Void
    let setPlaybackSpeed: (Double) -> Void
    let setSynthesisRate: (Int) -> Void
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
        setText: { _ in }, setVoice: { _ in }, toggleVoiceSample: { _, _ in }, setPlaybackSpeed: { _ in }, setSynthesisRate: { _ in },
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
    @State var expandedSpeedControl: ReadingSpeedControl? = nil
    @State var showingText = false

    @Environment(\.lang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var editorFocused: Bool
    @State private var playbackHovered = false
    @StateObject private var orbClock = ThinkingOrbClock()

    // The reading surface intentionally owns this graphite palette. Settings and
    // the rest of the app keep the existing paper/ink theme.
    private var p: Palette {
        Palette(
            bg: Color(0x141719), surface: Color(0x1C2022),
            ink: Color(0xEEEEE9), inkDim: Color(0xABB3AF), inkFaint: Color(0x969E9B),
            seal: Color(0xD7E4DD), line: Color(0x2D3333)
        )
    }
    private var inset: CGFloat { compact ? 24 : 28 }
    private var busy: Bool { state.phase == .synthesizing }
    private var canSpeak: Bool { !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsEditor: Bool { state.phase == .idle || showingText || historyOpen }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsEditor {
                if !historyOpen { readingStatus }
                editor.padding(.horizontal, inset)
            } else {
                listeningHero
            }
            if state.phase.isLive {
                player
            } else {
                readingAction
            }
            voiceControls
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
                .font(.system(size: 11))
                .foregroundStyle(p.inkFaint)
                .padding(.horizontal, inset)
                .padding(.vertical, 14)
                .overlay(alignment: .top) { p.line.frame(height: 0.5).padding(.horizontal, inset) }
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
        .frame(minWidth: compact ? 420 : 520, minHeight: compact ? nil : (expandedSpeedControl == nil ? 620 : 720))
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .background(p.bg.ignoresSafeArea())
        .environment(\.palette, p)
        .environment(\.colorScheme, .dark)
        .tint(p.seal)
        .onAppear { if !exporting && showsEditor { editorFocused = true } }
        .onChange(of: state.phase) { old, new in
            if old == .idle && new == .synthesizing {
                showingText = false
                editorFocused = false
            }
        }
    }

    private var header: some View {
        HStack {
            Text(T.appName(lang))
                .font(.system(size: 18, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(p.ink)
                .accessibilityIdentifier("reader-brand")
            Spacer()
            if state.phase != .idle && !historyOpen {
                GhostIcon(systemName: showsEditor ? "waveform" : "square.and.pencil") {
                    showingText.toggle()
                    editorFocused = showingText
                }
                .help(showsEditor ? T.showPlayer(lang) : T.editReadingText(lang))
                .accessibilityLabel(showsEditor ? T.showPlayer(lang) : T.editReadingText(lang))
                .accessibilityIdentifier("reader-edit-toggle")
            }
            GhostIcon(systemName: "gearshape", action: actions.openSettings)
                .help(T.settings(lang))
                .accessibilityLabel(T.settings(lang))
                .accessibilityIdentifier("reader-settings")
        }
        .padding(.horizontal, inset)
        .padding(.top, compact ? 19 : 24)
        .padding(.bottom, compact ? 10 : 16)
    }

    private var readingStatus: some View {
        HStack(spacing: 12) {
            orb.frame(width: 40, height: 40)

            Text(statusLabel)
                .font(.system(size: 12))
                .foregroundStyle(p.inkDim)
            Spacer(minLength: 0)
        }
        .frame(height: 46)
        .padding(.horizontal, inset)
        .padding(.bottom, compact ? 12 : 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusLabel)
    }

    private var orb: some View {
        Group {
            if exporting {
                ParticleSphereFrame(mode: orbMode, time: staticOrbTime, level: 0)
            } else {
                LiveThinkingOrb(mode: orbMode, running: state.phase != .paused, reducedMotion: reduceMotion, clock: orbClock)
            }
        }
        .accessibilityHidden(true)
    }

    private var listeningHero: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(p.seal).frame(width: 4, height: 4)
                Text(statusLabel).font(.system(size: 11)).foregroundStyle(p.inkFaint)
            }
            .padding(.top, 8)
            orb.frame(width: 176, height: 176).padding(.top, 10)
            Text(state.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? T.readingText(lang))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(p.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 320)
                .padding(.top, 5)
            Text(state.voiceLabel)
                .font(.system(size: 12)).foregroundStyle(p.inkFaint)
                .padding(.top, 9)
            if let excerpt = state.text.split(separator: "\n", maxSplits: 1).dropFirst().first {
                Text(excerpt.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13)).lineSpacing(5)
                    .foregroundStyle(p.inkDim).multilineTextAlignment(.center)
                    .lineLimit(2).frame(maxWidth: 300)
                    .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inset)
        .padding(.bottom, 25)
    }

    private var orbMode: ThinkingOrbMode {
        switch state.phase {
        case .idle: .breathe
        case .synthesizing: .rings
        case .playing, .paused: .vortex
        }
    }

    private var statusLabel: String {
        switch state.phase {
        case .idle: T.readyToRead(lang)
        case .synthesizing: T.synthesizing(lang)
        case .playing: T.nowReading(lang)
        case .paused: T.paused(lang)
        }
    }

    // Export previews are deterministic and never read live engine or clock state.
    private var staticOrbTime: Double {
        switch state.phase {
        case .idle: 0
        case .synthesizing: 1.4
        case .playing: 2.8
        case .paused: 0.8
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if state.text.isEmpty {
                    Text(T.placeholder(lang))
                        .font(.system(size: compact ? 14 : 16))
                        .foregroundStyle(p.inkFaint)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
                if exporting {
                    Text(state.text)
                        .font(.system(size: compact ? 14 : 16))
                        .lineSpacing(6)
                        .foregroundStyle(p.ink)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: Binding(get: { state.text }, set: actions.setText))
                        .font(.system(size: compact ? 14 : 16))
                        .lineSpacing(6)
                        .foregroundStyle(p.ink)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .padding(.horizontal, -5)
                        .padding(.top, 6)
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
            .font(.system(size: 11))
            .foregroundStyle(p.inkFaint)
            .padding(.vertical, 13)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(editorFocused ? p.seal.opacity(0.22) : p.line).frame(height: 0.5)
        }
    }

    private var voiceControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                if showsEditor { voicePicker.disabled(busy || state.phase.isLive) }
                speedDisclosure(.synthesis)
                speedDisclosure(.playback)
            }
            .frame(maxWidth: .infinity)
            if let expandedSpeedControl {
                Group {
                    switch expandedSpeedControl {
                    case .synthesis: synthesisRateControl
                    case .playback: speedControl
                    }
                }
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inset)
        .padding(.bottom, 18)
    }

    private var voicePicker: some View {
        HStack(spacing: 8) {
            if exporting {
                Text(state.voiceLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(p.inkDim)
            } else if let control = state.voiceControl {
                ProviderVoicePicker(
                    voices: control.voices,
                    providerID: control.providerID,
                    selection: Binding(get: { control.selectedVoiceID }, set: actions.setVoice),
                    sampleState: state.voiceSampleState,
                    toggleSample: actions.toggleVoiceSample,
                    showsFieldLabel: false,
                    maximumWidth: compact ? 120 : 220
                )
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .disabled(!control.canMutate)
            } else {
                Button(T.configureVoice(lang), action: actions.openSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.seal)
            }
        }
        .frame(maxWidth: compact ? 120 : 220, alignment: .leading)
    }

    private func speedDisclosure(_ control: ReadingSpeedControl) -> some View {
        let synthesis = control == .synthesis
        let title = synthesis ? T.synthRate(lang) : T.playbackSpeed(lang)
        let shortTitle = synthesis ? T.synthRateShort(lang) : T.playbackSpeedShort(lang)
        let value = synthesis
            ? state.voiceControl.map { String(format: "%+d%%", $0.rate.value) } ?? "—"
            : String(format: "%g×", state.playbackSpeed)
        let expanded = expandedSpeedControl == control
        return Button {
            withAnimation(reduceMotion ? .none : Motion.fade) {
                expandedSpeedControl = expanded ? nil : control
            }
        } label: {
            HStack(spacing: 5) {
                Text(shortTitle).foregroundStyle(p.inkFaint)
                Text(value).monospacedDigit().foregroundStyle(p.ink)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .medium)).foregroundStyle(p.inkFaint)
            }
            .font(.system(size: 11))
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(synthesis && state.voiceControl == nil)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(synthesis ? "synthesis-rate-disclosure" : "playback-speed-disclosure")
    }

    private var speedControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(T.playbackSpeed(lang)).font(.system(size: 12)).foregroundStyle(p.inkDim)
            InkSlider.speed(
                Binding(get: { state.playbackSpeed }, set: actions.setPlaybackSpeed),
                showsButtons: false,
                valueWidth: 36,
                resetTitle: T.resetSpeed(lang),
                accessibilityLabel: T.playbackSpeed(lang)
            )
            Text(T.playbackSpeedNote(lang)).font(.system(size: 10)).foregroundStyle(p.inkFaint)
        }
        .frame(maxWidth: .infinity)
    }

    private var synthesisRateControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(T.synthRate(lang)).font(.system(size: 12)).foregroundStyle(p.inkDim)
            if let control = state.voiceControl {
                InkSlider.rate(
                    Binding(get: { control.rate.value }, set: actions.setSynthesisRate),
                    showsButtons: false,
                    valueWidth: 36,
                    accessibilityLabel: T.synthRate(lang)
                )
                .disabled(!control.canMutate)
                .accessibilityIdentifier("synthesis-rate")
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(p.inkFaint).frame(height: 16)
            }
            Text(T.synthRateNextReadNote(lang)).font(.system(size: 10)).foregroundStyle(p.inkFaint)
        }
        .frame(maxWidth: .infinity)
    }

    private var readingAction: some View {
        HStack(spacing: 12) {
            if busy {
                if historyOpen {
                    Text(T.synthesizing(lang))
                        .font(.system(size: 12))
                        .foregroundStyle(p.inkDim)
                }
                Button(T.cancel(lang), action: actions.stop)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(p.inkDim)
                    .padding(.vertical, 9)
            } else {
                SealButton(title: T.speak(lang), enabled: canSpeak, foreground: p.bg, systemImage: "play.fill", action: actions.speak)
                    .accessibilityIdentifier("read-aloud")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, showsEditor ? 18 : 0)
        .padding(.horizontal, inset)
        .padding(.bottom, 20)
    }

    private var player: some View {
        VStack(spacing: 16) {
            VStack(spacing: 7) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.ink.opacity(0.08))
                        Capsule().fill(p.inkDim).frame(width: geometry.size.width * progress)
                    }
                    .frame(height: 2).frame(maxHeight: .infinity)
                }.frame(height: 2)
                HStack {
                    Text(fmt(state.position))
                    Spacer()
                    Text(fmt(state.duration))
                }
            }
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(p.inkFaint)

            HStack(spacing: 20) {
                GhostIcon(systemName: "gobackward.10") { actions.seek(-10) }
                    .help(T.backTen(lang)).accessibilityLabel(T.backTen(lang))
                Button(action: actions.togglePause) {
                    Image(systemName: state.phase == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .offset(x: state.phase == .playing ? 0 : 1)
                        .foregroundStyle(p.bg)
                        .frame(width: 44, height: 44)
                        .background(p.seal, in: Circle())
                        .brightness(playbackHovered ? 0.045 : 0)
                }
                .buttonStyle(PressScale())
                .onHover { playbackHovered = $0 }
                .animation(reduceMotion ? .none : Motion.fade, value: playbackHovered)
                .keyboardShortcut(.return, modifiers: .command)
                .help(state.phase == .playing ? T.pause(lang) : T.resume(lang))
                .accessibilityLabel(state.phase == .playing ? T.pause(lang) : T.resume(lang))
                .accessibilityIdentifier("playback-toggle")
                GhostIcon(systemName: "goforward.10") { actions.seek(10) }
                    .help(T.forwardTen(lang)).accessibilityLabel(T.forwardTen(lang))
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                GhostIcon(systemName: "stop.fill", action: actions.stop)
                    .opacity(0.55)
                    .help(T.stop(lang)).accessibilityLabel(T.stop(lang))
            }
            .overlay(alignment: .trailing) {
                GhostIcon(systemName: "square.and.arrow.down", action: actions.saveAudio)
                    .opacity(0.55)
                    .help(T.saveAudio(lang)).accessibilityLabel(T.saveAudio(lang))
            }
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inset)
        .padding(.top, showsEditor ? 18 : 2)
        .padding(.bottom, 10)
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

private struct LiveThinkingOrb: View {
    let mode: ThinkingOrbMode
    let running: Bool
    let reducedMotion: Bool
    @ObservedObject var clock: ThinkingOrbClock
    @State private var visible = false

    var body: some View {
        ThinkingOrb(mode: mode, level: 0, running: running && visible, reducedMotion: reducedMotion, clock: clock)
            .onAppear { visible = true }
            .onDisappear { visible = false; clock.setRunning(false) }
    }
}

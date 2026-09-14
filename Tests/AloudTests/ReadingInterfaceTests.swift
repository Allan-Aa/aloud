import AppKit
import SwiftUI
import XCTest
@testable import Aloud

@MainActor
final class ReadingInterfaceTests: XCTestCase {
    func testSettingsRouteKeepsOneSharedSidebarState() {
        let route = ReaderWindowRoute()
        XCTAssertFalse(route.isSettingsPresented)
        route.present()
        XCTAssertTrue(route.isSettingsPresented)
        route.dismiss()
        XCTAssertFalse(route.isSettingsPresented)
    }

    func testMenuBarEditorAcceptsTextWithoutOpeningAnotherWindow() throws {
        var edited = ""
        let host = hostReadingView(compact: true, setText: { edited = $0 })
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(editor.isEditable)
        XCTAssertGreaterThan(editor.visibleRect.height, 50)
        editor.insertText("直接在菜单栏输入", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edited, "直接在菜单栏输入")
        XCTAssertEqual(host.frame.width, 420)
    }

    func testMainWindowUsesTheSameEditableTextSurface() throws {
        var edited = ""
        let host = hostReadingView(compact: false, setText: { edited = $0 })
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        editor.insertText("长文编辑", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edited, "长文编辑")
    }

    func testPlayingSurfaceShowsPlayerWithoutAnAlwaysVisibleEditor() {
        let host = hostReadingView(compact: true, phase: .playing, setText: { _ in })
        XCTAssertFalse(descendants(host).contains { $0 is NSTextView })
    }

    func testPausedPlaybackCanExposeTheEditableTextSurface() throws {
        var edited = ""
        let host = hostReadingView(compact: false, phase: .paused, showingText: true, setText: { edited = $0 })
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        editor.insertText("仍可编辑正文", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edited, "仍可编辑正文")
    }

    func testMenuBarPreviewCoversAllReadingPhasesAndBothLanguages() {
        let panels = PreviewSceneCatalog.all.compactMap { scene -> (PreviewScene, PanelViewState)? in
            guard case let .panel(state) = scene.content else { return nil }
            return (scene, state)
        }
        for phase in [Phase.idle, .synthesizing, .playing, .paused] {
            XCTAssertTrue(panels.contains { $0.1.phase == phase })
        }
        XCTAssertTrue(panels.contains { $0.1.text.isEmpty && $0.0.colorScheme == .light })
        XCTAssertTrue(panels.contains { $0.1.text.isEmpty && $0.0.colorScheme == .dark })
        XCTAssertTrue(panels.contains { $0.0.language == .en && $0.1.phase == .synthesizing })
        XCTAssertTrue(panels.contains { $0.1.toast != nil })
    }

    func testParticleClockFreezesWhileHiddenAndResumesWithoutJump() {
        let clock = ThinkingOrbClock()
        let start = Date(timeIntervalSince1970: 100)
        clock.setRunning(true, at: start)
        clock.setRunning(false, at: start.addingTimeInterval(2))
        XCTAssertEqual(clock.value(at: start.addingTimeInterval(20)), 2)
        clock.setRunning(true, at: start.addingTimeInterval(20))
        XCTAssertEqual(clock.value(at: start.addingTimeInterval(21)), 3)
    }

    func testRepeatedAppearDoesNotRestartParticleAnimation() {
        let clock = ThinkingOrbClock()
        let start = Date(timeIntervalSince1970: 100)
        clock.setRunning(true, at: start)
        clock.setRunning(true, at: start.addingTimeInterval(2))
        XCTAssertEqual(clock.value(at: start.addingTimeInterval(3)), 3)
    }

    private func hostReadingView(compact: Bool, phase: Phase = .idle, showingText: Bool = false, setText: @escaping (String) -> Void) -> NSHostingView<MainViewBody> {
        let actions = MainViewActions(
            setText: setText, setVoice: { _ in },
            toggleVoiceSample: { _, _ in }, setPlaybackSpeed: { _ in },
            setSynthesisRate: { _ in },
            pasteClipboard: {}, speak: {}, seek: { _ in }, togglePause: {}, stop: {},
            saveAudio: {}, replay: { _ in }, load: { _ in }, copy: { _ in },
            dismissToast: {}, openSettings: {}, openMain: {}, quit: {}
        )
        let host = NSHostingView(rootView: MainViewBody(
            state: MainViewState(
                text: "", phase: phase, voiceControl: nil, voiceSampleState: .idle,
                voiceLabel: "测试音色", playbackSpeed: 1,
                position: 0, duration: 0, history: [], toast: nil
            ),
            historyOpen: .constant(false), exporting: false, compact: compact, actions: actions, showingText: showingText
        ))
        host.frame = NSRect(x: 0, y: 0, width: compact ? 420 : 720, height: 620)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return host
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}

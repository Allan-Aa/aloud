import SwiftUI

/// 菜单栏直接提供编辑和朗读，与主窗口共享文本、控制器和界面组件。
struct PanelView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        MainView(engine: engine, compact: true)
            .frame(width: 420)
    }
}

struct PanelPreviewView: View {
    let state: PanelViewState
    var expandedSpeedControl: ReadingSpeedControl? = nil

    var body: some View {
        MainPreviewView(
            state: MainViewState(
                text: state.text, phase: state.phase, voiceControl: PreviewSceneCatalog.readerVoiceControl,
                voiceSampleState: .idle, voiceLabel: state.voiceLabel,
                playbackSpeed: state.playbackSpeed,
                position: state.position, duration: state.duration, history: [], toast: state.toast
            ),
            historyOpen: false,
            compact: true,
            expandedSpeedControl: expandedSpeedControl
        )
        .frame(width: 420)
    }
}

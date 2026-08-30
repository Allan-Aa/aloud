import SwiftUI

/// 可折叠历史。收起时只占一行(一个触发条),展开时从底部长出来。
/// 设计要点:收起态必须轻到"看不见",否则极简就没了;展开态必须能搜、能重播。
struct HistoryPanel: View {
    @Binding var expanded: Bool
    var entries: [HistoryEntry]
    var exporting: Bool = false
    var onReplay: (HistoryEntry) -> Void = { _ in }
    var onLoad: (HistoryEntry) -> Void = { _ in }
    var onCopy: (HistoryEntry) -> Void = { _ in }

    @Environment(\.palette) private var p
    @Environment(\.lang) private var lang
    @State private var query = ""
    @State private var hoveredID: HistoryEntry.ID?

    private var filtered: [HistoryEntry] {
        query.isEmpty ? entries : entries.filter { HistoryEligibility(for: $0).allows(.search) && ($0.text?.localizedCaseInsensitiveContains(query) == true) }
    }

    var body: some View {
        VStack(spacing: 0) {
            trigger
            if expanded {
                Divider().overlay(p.line)
                list
            }
        }
        .background(p.ink.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
    }

    private var trigger: some View {
        Button {
            withAnimation(Motion.rise) { expanded.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                Text(T.history(lang))
                    .font(.system(size: 12, weight: .medium))
                Text("\(entries.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(p.inkFaint)
                Spacer()
                if expanded {
                    searchField
                }
            }
            .foregroundStyle(p.inkDim)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10))
            if exporting {
                Text(T.searchHistory(lang)).font(.system(size: 11)).foregroundStyle(p.inkFaint)
            } else {
                TextField(T.searchHistory(lang), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 120)
            }
        }
        .foregroundStyle(p.inkFaint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(p.ink.opacity(0.05)))
    }

    @ViewBuilder private var list: some View {
        // ScrollView + LazyVStack 在 ImageRenderer 里渲染为空(懒加载没有可见区域可依据),
        // 导出时退回普通 VStack。
        if exporting {
            VStack(spacing: 0) {
                ForEach(filtered.prefix(4)) { e in
                    row(e)
                    Divider().overlay(p.line.opacity(0.6)).padding(.leading, 20)
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { e in
                        row(e)
                        Divider().overlay(p.line.opacity(0.6)).padding(.leading, 20)
                    }
                }
            }
            .frame(height: 186)
        }
    }

    private func row(_ e: HistoryEntry) -> some View {
        let eligibility = HistoryEligibility(for: e)
        let policy = Self.actionPolicy(for: e)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.text ?? eligibility.contentMessage ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(p.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(String(format: "%d:%02d", e.seconds / 60, e.seconds % 60))
                        .monospacedDigit()
                    Text(e.displayLabelSnapshot)
                    Text(e.rate.value >= 0 ? "+\(e.rate.value)%" : "\(e.rate.value)%").monospacedDigit()
                    Text(e.agoText(lang))
                    if let selection = eligibility.selectionMessage { Text(selection) }
                }
                .font(.system(size: 10))
                .foregroundStyle(p.inkFaint)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !exporting && policy.allows(.load) { onLoad(e) } }
            Spacer(minLength: 8)
            // 操作只在 hover 时出现,静止时列表是干净的
            if hoveredID == e.id || exporting {
                HStack(spacing: 0) {
                    if policy.allows(.replay) { GhostIcon(systemName: "arrow.counterclockwise") { onReplay(e) } }
                    if policy.allows(.copy) { GhostIcon(systemName: "doc.on.doc") { onCopy(e) } }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(hoveredID == e.id ? p.ink.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? e.id : nil }
        .animation(Motion.fade, value: hoveredID)
    }

    static func actionPolicy(for entry: HistoryEntry) -> HistoryActionPolicy { HistoryActionPolicy(entry: entry) }
}

import SwiftUI

/// 可折叠历史，搜索与折叠分别操作；载入、重播和复制始终可发现。
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
        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 0.5).padding(.horizontal, 28) }
    }

    private var trigger: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(Motion.rise) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(T.history(lang)).fontWeight(.medium)
                    Text("\(entries.count)").monospacedDigit().foregroundStyle(p.inkFaint)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if expanded { searchField }
        }
        .font(.system(size: 12))
        .foregroundStyle(p.inkDim)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
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
        if filtered.isEmpty {
            Text(query.isEmpty ? T.noHistory(lang) : T.noHistoryMatch(lang))
                .font(.system(size: 13))
                .foregroundStyle(p.inkDim)
                .frame(maxWidth: .infinity)
                .frame(height: 90)
        } else if exporting {
            VStack(spacing: 0) {
                ForEach(filtered.prefix(2)) { e in
                    row(e)
                    Divider().overlay(p.line.opacity(0.6)).padding(.leading, 20)
                }
            }
            .frame(height: 128, alignment: .top)
            .clipped()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { e in
                        row(e)
                        Divider().overlay(p.line.opacity(0.6)).padding(.leading, 20)
                    }
                }
            }
            .frame(height: 128)
        }
    }

    private func row(_ e: HistoryEntry) -> some View {
        let eligibility = HistoryEligibility(for: e)
        let policy = Self.actionPolicy(for: e)
        return HStack(alignment: .top, spacing: 10) {
            Button { if policy.allows(.load) { onLoad(e) } } label: {
                VStack(alignment: .leading, spacing: 5) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!policy.allows(.load))
            .help(T.loadText(lang))
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                if policy.allows(.replay) {
                    Button(T.replay(lang)) { onReplay(e) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.inkDim)
                }
                if policy.allows(.copy) {
                    GhostIcon(systemName: "doc.on.doc") { onCopy(e) }
                        .help(T.copyText(lang)).accessibilityLabel(T.copyText(lang))
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(hoveredID == e.id ? p.ink.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? e.id : nil }
        .animation(Motion.fade, value: hoveredID)
    }

    static func actionPolicy(for entry: HistoryEntry) -> HistoryActionPolicy { HistoryActionPolicy(entry: entry) }
}

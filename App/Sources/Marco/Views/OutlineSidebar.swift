import MarcoCore
import SwiftUI
import MarcoRendering

/// The J3 outline column: a native (floating-glass) `NavigationSplitView`
/// leading sidebar listing the document's heading tree. The current section
/// highlights as you scroll (debounced so it doesn't flicker at heading
/// boundaries); clicking a row smooth-scrolls to that heading (jumps under
/// Reduce Motion). Long headings truncate in the middle. Updates live when
/// the document reloads because `items` reads the observed block model.
struct OutlineSidebar: View {
    let model: WindowModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The heading currently containing the top of the viewport. Committed on
    /// a short debounce off the scroll signal so quick jitter at a boundary
    /// doesn't ping-pong the highlight.
    @State private var currentID: String?
    @State private var trackTask: Task<Void, Never>?
    /// After a click sets `currentID` optimistically, the scroll-position
    /// tracker re-derives the same value on its debounce and re-fires the
    /// highlight. Ignore tracker updates until this instant so the highlight
    /// settles exactly once on the clicked row.
    @State private var suppressTrackingUntil: Date = .distantPast

    private var blocks: [Block] { model.controller?.blocks ?? [] }
    private var items: [OutlineItem] { OutlineBuilder.build(from: blocks) }

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        // Re-track when the reading view's top-most block changes (user scroll
        // or programmatic). Reading this establishes observation on the scroll
        // position without re-running `body` on every tick.
        .onChange(of: model.controller?.scrollPosition.viewID as? String, initial: true) { _, top in
            scheduleTrack(to: top)
        }
    }

    @ViewBuilder
    private func row(_ item: OutlineItem) -> some View {
        let isCurrent = item.id == currentID
        Button {
            model.scrollToHeading(item.id, reduceMotion: reduceMotion)
            currentID = item.id
            suppressTrackingUntil = Date().addingTimeInterval(0.35)
        } label: {
            Text(item.title)
                .font(.system(size: 13, weight: item.level <= 2 ? .semibold : .regular))
                .foregroundStyle(isCurrent ? theme.accent : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, CGFloat(item.depth) * 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            (isCurrent ? theme.accent.opacity(0.12) : Color.clear)
                .animation(reduceMotion ? nil : Theme.Motion.state, value: isCurrent)
        )
        .animation(reduceMotion ? nil : Theme.Motion.state, value: isCurrent)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No headings")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleTrack(to top: String?) {
        trackTask?.cancel()
        trackTask = Task {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            guard Date() >= suppressTrackingUntil else { return }
            currentID = nearestHeading(topBlockID: top)
        }
    }

    /// The last heading at or above the top-most visible block — the section
    /// the reader is currently inside.
    private func nearestHeading(topBlockID: String?) -> String? {
        guard let topBlockID, let topIndex = blocks.firstIndex(where: { $0.id == topBlockID }) else {
            return items.first?.id
        }
        var current: String? = items.first?.id
        for index in 0...topIndex {
            if case .heading = blocks[index].kind {
                current = blocks[index].id
            }
        }
        return current
    }
}

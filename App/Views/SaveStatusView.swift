import SwiftUI

/// Small toolbar pill that shows the active note's save lifecycle —
/// "Unsaved", "Saving…", "Saved · just now". Without this, users had
/// to trust that the 0.3s autosave debounce had actually fired before
/// closing the window. The "Xs ago" relative timer ticks via a
/// TimelineView so it stays accurate without the editor needing to
/// re-render on a clock.
struct SaveStatusView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.saveState {
            case .idle:
                EmptyView()
            case .dirty:
                Label("Unsaved", systemImage: "circle.dotted")
                    .foregroundStyle(.secondary)
            case .saving:
                Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .saved(let date):
                TimelineView(.periodic(from: date, by: 1)) { context in
                    Label(
                        "Saved · \(Self.relative(from: date, now: context.date))",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .animation(.easeInOut(duration: 0.18), value: appState.saveState)
    }

    private static func relative(from date: Date, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m ago" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h ago" }
        let days = hrs / 24
        return "\(days)d ago"
    }
}

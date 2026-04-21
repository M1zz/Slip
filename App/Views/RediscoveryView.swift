import SwiftUI
import SlipCore

struct RediscoveryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("Rediscover")
                    .font(.headline)
                Spacer()
                Button {
                    appState.refreshRediscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh (⇧⌘R)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if appState.rediscovery.isEmpty {
                Text("Nothing to resurface yet — write more notes and come back.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appState.rediscovery) { card in
                            RediscoveryCardView(card: card) {
                                appState.openNote(card.id)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct RediscoveryCardView: View {
    let card: RediscoveryEngine.RediscoveryCard
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    ForEach(card.reasons, id: \.self) { reason in
                        ReasonPill(reason: reason)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

private struct ReasonPill: View {
    let reason: RediscoveryEngine.RediscoveryCard.Reason

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }

    private var label: String {
        switch reason {
        case .forgotten:   return "forgotten"
        case .orphan:      return "orphan"
        case .weakTie:     return "weak tie"
        case .sharesTag:   return "shared tag"
        case .untouched:   return "untouched"
        }
    }

    private var color: Color {
        switch reason {
        case .forgotten:   return .purple
        case .orphan:      return .orange
        case .weakTie:     return .blue
        case .sharesTag:   return .teal
        case .untouched:   return .pink
        }
    }
}

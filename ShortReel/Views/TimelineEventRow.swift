import SwiftUI

struct TimelineEventRow: View {
    let event: TimelineEvent

    var body: some View {
        // Rows can be re-rendered after their event was cascade-deleted
        // with its account; reading any other property would trap.
        if !event.isLive {
            EmptyView()
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: event.kind.symbolName)
                .font(.callout)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(event.platform.color.gradient, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(event.detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(event.platform.displayName)
                        .font(.caption2.bold())
                        .foregroundStyle(event.platform.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(event.platform.color.opacity(0.12), in: Capsule())
                    Text(event.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            statusIndicator
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch event.status {
        case .scheduled:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

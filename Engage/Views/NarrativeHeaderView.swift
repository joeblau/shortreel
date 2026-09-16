import SwiftData
import SwiftUI

struct NarrativeHeaderView: View {
    @Bindable var account: Account
    @Environment(\.modelContext) private var modelContext

    private var actionsToday: Int {
        account.events.filter { Calendar.current.isDateInToday($0.timestamp) }.count
    }

    private var scheduledCount: Int {
        account.events.filter { $0.status == .scheduled }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.title2.bold())
                    Text("@\(account.handle) · \(account.boundDeviceName) · \(account.farm?.name ?? "No Farm")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WARM-UP NARRATIVE")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                TextEditor(text: $account.narrative)
                    .font(.body)
                    .frame(minHeight: 56, maxHeight: 96)
                    .scrollContentBackground(.hidden)
                    .onChange(of: account.narrative) { _, _ in
                        try? modelContext.save()
                    }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                StatChip(title: "Actions today", value: "\(actionsToday)")
                StatChip(title: "Scheduled", value: "\(scheduledCount)")
                StatChip(title: "Active hours", value: "9 AM – 9 PM")
                Spacer()
            }
        }
        .padding()
    }
}

private struct StatChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

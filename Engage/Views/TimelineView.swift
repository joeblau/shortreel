import SwiftUI

struct TimelineView: View {
    let account: Account

    private var sortedEvents: [TimelineEvent] {
        guard account.isLive else { return [] }
        return account.events
            .filter(\.isLive)
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var groups: [(day: Date, events: [TimelineEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sortedEvents) { calendar.startOfDay(for: $0.timestamp) }
        return grouped
            .map { (day: $0.key, events: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if sortedEvents.isEmpty {
                    ContentUnavailableView {
                        Label("Warming Up", systemImage: "hourglass")
                    } description: {
                        Text("Agent is planning the first interactions…")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Color.clear
                                .frame(height: 0)
                                .id("top")
                            ForEach(groups, id: \.day) { group in
                                Section {
                                    ForEach(group.events, id: \.persistentModelID) { event in
                                        TimelineEventRow(event: event)
                                            .padding(.vertical, 4)
                                    }
                                } header: {
                                    Text(Self.dayTitle(for: group.day))
                                        .font(.headline)
                                        .padding(.top, 12)
                                        .padding(.bottom, 4)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .onChange(of: sortedEvents.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo("top", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    private static func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

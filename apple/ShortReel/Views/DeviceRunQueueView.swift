import SwiftUI

/// Shared queue controls for the Stage inspector and Agent composer.
struct DeviceRunQueueView: View {
    let session: DevicePromptSession

    var body: some View {
        if session.queuedCount > 0 || session.hasUnreviewedRuns || session.persistenceError != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Queue · \(session.queuedCount)", systemImage: "list.bullet")
                        .font(.headline)
                    Spacer()
                    if session.queuePaused && session.queuedCount > 0 {
                        Button("Resume") { session.resumeQueue() }
                            .disabled(session.hasUnreviewedRuns || session.isRunning)
                    }
                }
                if let error = session.persistenceError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if session.hasUnreviewedRuns {
                    Text("Check interrupted runs on the phone before resuming. Acknowledging a result does not retry it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if session.queuePaused {
                    Text("Paused. Queued runs will start when you resume.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.entries.filter { $0.status == .queued || ($0.status == .needsReview && $0.reviewedAt == nil) }) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.scriptTitle ?? entry.workflow?.title ?? "Agent request")
                                .font(.callout)
                            Spacer()
                            if entry.status == .queued {
                                Button("Cancel") { session.cancelQueued(id: entry.id) }
                            } else {
                                Button("I checked the result") { session.acknowledgeReview(id: entry.id) }
                            }
                        }
                        if entry.status == .needsReview {
                            Text(entry.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

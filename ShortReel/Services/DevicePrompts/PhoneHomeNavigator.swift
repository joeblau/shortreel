import Foundation

struct PhoneHomeTarget: Sendable {
    let text: String
    let x: Double
    let y: Double
}

/// Sends the AssistiveTouch bottom-edge Home swipe between fresh frames.
/// The visual runner uses the resulting screen to decide whether its goal is met.
@MainActor
struct PhoneHomeNavigator {
    let swipeHome: () async throws -> Void
    let capture: (Date) async throws -> PhoneScreenFrame
    let blockedReason: () -> String?

    func goHome(sourceID: String) async throws {
        try checkAvailability()
        let requestedAt = Date()
        let before = try await capture(requestedAt)
        try checkFrame(before, after: requestedAt, sourceID: sourceID)

        try await swipeHome()
        try await Task.sleep(for: .milliseconds(350))
        try checkAvailability()
        // Require a frame captured after the Home animation has settled.
        let settledAt = Date()
        let result = try await capture(settledAt)
        try checkFrame(result, after: settledAt, sourceID: sourceID)
        guard result.id != before.id else { throw PhoneVisionError.staleFrame }
    }

    private func checkAvailability() throws {
        try Task.checkCancellation()
        if let reason = blockedReason() { throw PhoneVisionError.unavailable(reason) }
    }

    private func checkFrame(_ frame: PhoneScreenFrame, after: Date, sourceID: String) throws {
        try checkAvailability()
        guard frame.sourceID == sourceID else { throw PhoneVisionError.sourceChanged }
        let age = Date().timeIntervalSince(frame.capturedAt)
        guard frame.capturedAt > after, age.isFinite, age >= -1, age <= 10 else {
            throw PhoneVisionError.staleFrame
        }
    }
}

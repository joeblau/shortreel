import Foundation

struct PhoneHomeTarget: Sendable {
    let text: String
    let x: Double
    let y: Double
}

/// Home through an observed AssistiveTouch menu. No model or edge gesture is
/// involved, and an unavailable/ambiguous menu stops without fallback input.
@MainActor
struct PhoneHomeNavigator {
    let openMenu: () async throws -> Void
    let capture: (Date) async throws -> PhoneScreenFrame
    let recognize: (PhoneScreenFrame) async throws -> [PhoneHomeTarget]
    let tap: (Double, Double) async throws -> Void
    let blockedReason: () -> String?

    func goHome(sourceID: String) async throws {
        try checkAvailability()
        try await openMenu()
        try await Task.sleep(for: .milliseconds(200))
        try checkAvailability()
        let menuOpenedAt = Date()
        let frame = try await capture(menuOpenedAt)
        try checkFrame(frame, after: menuOpenedAt, sourceID: sourceID)
        let targets = try await recognize(frame)
        try checkFrame(frame, after: menuOpenedAt, sourceID: sourceID)
        let target = try Self.homeTarget(in: targets)
        try checkAvailability()
        try await tap(target.x, target.y)
        try await Task.sleep(for: .milliseconds(250))
        try checkAvailability()
        let tappedAt = Date()
        let result = try await capture(tappedAt)
        try checkFrame(result, after: tappedAt, sourceID: sourceID)
        guard result.id != frame.id else { throw PhoneVisionError.staleFrame }
    }

    static func homeTarget(in targets: [PhoneHomeTarget]) throws -> PhoneHomeTarget {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let homes = targets.filter { normalized($0.text) == "home" }
        let menuLabels: Set<String> = ["device", "gestures", "control center", "notification center", "custom"]
        let recognizedLabels = Set(targets.map { normalized($0.text) }).intersection(menuLabels)
        guard homes.count == 1, let home = homes.first, recognizedLabels.count >= 2,
              home.x.isFinite, home.y.isFinite, (0...1).contains(home.x), (0...1).contains(home.y) else {
            throw PhoneVisionError.unavailable("The AssistiveTouch menu’s Home control could not be identified. Enable AssistiveTouch and keep Home in its top-level menu, then try again.")
        }
        return home
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

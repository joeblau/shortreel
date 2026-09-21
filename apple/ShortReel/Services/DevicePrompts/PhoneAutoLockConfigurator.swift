import Foundation

struct PhoneHomeTarget: Sendable {
    let text: String
    let x: Double
    let y: Double
}

/// Drives Settings › Display & Brightness › Auto-Lock › Never using the
/// Bluetooth keyboard (Spotlight → type → Return) plus one observed tap. No
/// model is involved, and an unrecognized page stops without tapping. iOS
/// offers no USB-writable preference for auto-lock on unsupervised phones, so
/// the setting is changed through the same input path the user has.
@MainActor
struct PhoneAutoLockConfigurator {
    let openSearch: () async throws -> Void
    let type: (String) async throws -> Void
    let confirm: () async throws -> Void
    let capture: (Date) async throws -> PhoneScreenFrame
    let recognize: (PhoneScreenFrame) async throws -> [PhoneHomeTarget]
    let tap: (Double, Double) async throws -> Void
    let blockedReason: () -> String?

    func disableAutoLock(sourceID: String) async throws {
        try checkAvailability()
        try await openSearch()
        try await Task.sleep(for: .milliseconds(700))
        try checkAvailability()
        try await type("Auto-Lock")
        try await Task.sleep(for: .milliseconds(1200))
        try checkAvailability()
        try await confirm()
        let openedAt = Date()
        try await Task.sleep(for: .milliseconds(1200))
        try checkAvailability()
        let frame = try await capture(openedAt)
        try checkFrame(frame, after: openedAt, sourceID: sourceID)
        let target = try Self.neverTarget(in: try await recognize(frame))
        try checkAvailability()
        try await tap(target.x, target.y)
        try await Task.sleep(for: .milliseconds(250))
        let tappedAt = Date()
        let result = try await capture(tappedAt)
        try checkFrame(result, after: tappedAt, sourceID: sourceID)
    }

    /// The Auto-Lock page lists durations above the Never row. Require that
    /// shape so an unexpected screen cannot turn this into a stray tap.
    static func neverTarget(in targets: [PhoneHomeTarget]) throws -> PhoneHomeTarget {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let nevers = targets.filter { normalized($0.text) == "never" }
        let durations = targets.filter {
            let text = normalized($0.text)
            return text.hasSuffix("seconds") || text.hasSuffix("minute") || text.hasSuffix("minutes")
        }
        guard nevers.count == 1, let never = nevers.first, durations.count >= 2,
              never.x.isFinite, never.y.isFinite, (0...1).contains(never.x), (0...1).contains(never.y) else {
            throw PhoneVisionError.unavailable("The Auto-Lock page’s Never option could not be identified. Keep the iPhone unlocked and try again.")
        }
        return never
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

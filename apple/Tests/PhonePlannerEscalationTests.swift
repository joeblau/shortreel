import CoreGraphics
import Foundation

// swiftc -swift-version 6 ShortReel/Models/*.swift ShortReel/Services/DeviceHost.swift ShortReel/Services/DevicePrompts/DevicePromptPlan.swift ShortReel/Services/DevicePrompts/DevicePromptPlanner.swift ShortReel/Services/DevicePrompts/DeviceWorkflow.swift ShortReel/Services/DevicePrompts/WarmUpPlaybook.swift ShortReel/Services/DevicePrompts/PhoneVisionTypes.swift ShortReel/Services/DevicePrompts/PhonePlannerEscalation.swift Tests/PhonePlannerEscalationTests.swift -o /tmp/shortreel-escalation-tests
@main
enum PhonePlannerEscalationTests {
    static func main() async throws {
        try await actionPassesThroughUntouched()
        try await needsInputEscalates()
        try await stalledHistoryEscalates()
        try await escalationNeedsInputStopsForUser()
        try await failedEscalationKeepsOriginalClarification()
        try await failedEscalationOnStallFallsBackToPrimary()
        try await finishedAndWaitAreMarked()

        print("Phone planner escalation tests passed")
    }

    private static let frame = PhoneScreenFrame(
        id: UUID(), capturedAt: Date(), pixelWidth: 100, pixelHeight: 200,
        jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]), cgImage: blankImage(), sourceID: "test")

    private static func blankImage() -> CGImage {
        CGContext(data: nil, width: 100, height: 200, bitsPerComponent: 8, bytesPerRow: 100,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            .makeImage()!
    }

    private static func step(_ number: Int, _ action: String) -> PhoneVisionStep {
        PhoneVisionStep(id: UUID(), number: number, action: action, detail: "reason", capturedAt: Date())
    }

    private static func actionPassesThroughUntouched() async throws {
        let escalation = PhonePlannerEscalation(
            primary: { _, _, _ in .action(.tap(0.5, 0.5), reason: "Tap the middle") },
            escalation: { _, _, _ in throw PhoneVisionError.unavailable("escalation must not run") })
        let decision = try await escalation.decide(goal: "Goal", frame: frame, history: [])
        guard case .action(.tap(0.5, 0.5), let reason) = decision, reason == "Tap the middle" else {
            throw TestFailure("Primary action was not passed through: \(decision)")
        }
    }

    private static func needsInputEscalates() async throws {
        let escalation = PhonePlannerEscalation(
            primary: { _, _, _ in .needsInput("Which account should I use?") },
            escalation: { _, _, _ in .action(.tap(0.2, 0.3), reason: "Use the first account") })
        let decision = try await escalation.decide(goal: "Goal", frame: frame, history: [])
        guard case .action(.tap(0.2, 0.3), let reason) = decision,
              reason.contains("Escalated"), reason.contains("Which account should I use?") else {
            throw TestFailure("Escalated decision missing trigger context: \(decision)")
        }
    }

    private static func stalledHistoryEscalates() async throws {
        let primaryRan = LockedFlag()
        let escalation = PhonePlannerEscalation(
            primary: { _, _, _ in primaryRan.set(); return .action(.tap(0.5, 0.5), reason: "Repeat") },
            escalation: { _, _, _ in .wait(seconds: 1, reason: "Let the feed load") })
        let stalled = [step(1, "Tap at 50%, 50%"), step(2, "Tap at 50%, 50%")]
        let decision = try await escalation.decide(goal: "Goal", frame: frame, history: stalled)
        guard !primaryRan.value, case .wait(let seconds, let reason) = decision, seconds == 1,
              reason.contains("Escalated"), reason.contains("repeating") else {
            throw TestFailure("Stall did not escalate: \(decision)")
        }
        // One repeat is not yet a stall.
        let almost = PhonePlannerEscalation(
            primary: { _, _, _ in .finished("Done") },
            escalation: { _, _, _ in throw PhoneVisionError.unavailable("escalation must not run") })
        let decision2 = try await almost.decide(goal: "Goal", frame: frame, history: [step(1, "Tap at 50%, 50%")])
        guard case .finished = decision2 else { throw TestFailure("Single repeat escalated: \(decision2)") }
    }

    private static func escalationNeedsInputStopsForUser() async throws {
        let escalation = PhonePlannerEscalation(
            primary: { _, _, _ in .needsInput("Primary is unsure") },
            escalation: { _, _, _ in .needsInput("Sign in on the phone first") })
        do {
            _ = try await escalation.decide(goal: "Goal", frame: frame, history: [])
            throw TestFailure("Expected needsClarification")
        } catch PhonePromptPlanningError.needsClarification(let message) {
            guard message == "Sign in on the phone first" else {
                throw TestFailure("Wrong clarification: \(message)")
            }
        }
    }

    private static func failedEscalationKeepsOriginalClarification() async throws {
        let escalation = PhonePlannerEscalation(
            primary: { _, _, _ in .needsInput("Which account should I use?") },
            escalation: { _, _, _ in throw PhoneVisionError.unavailable("Grok CLI unreachable") })
        do {
            _ = try await escalation.decide(goal: "Goal", frame: frame, history: [])
            throw TestFailure("Expected needsClarification")
        } catch PhonePromptPlanningError.needsClarification(let message) {
            guard message == "Which account should I use?" else {
                throw TestFailure("Original clarification was replaced: \(message)")
            }
        }
    }

    private static func failedEscalationOnStallFallsBackToPrimary() async throws {
        let escalation = PhonePlannerEscalation(
            primary: { _, _, _ in .action(.tap(0.5, 0.5), reason: "Repeat") },
            escalation: { _, _, _ in throw PhoneVisionError.unavailable("Grok CLI unreachable") })
        let stalled = [step(1, "Tap at 50%, 50%"), step(2, "Tap at 50%, 50%")]
        let decision = try await escalation.decide(goal: "Goal", frame: frame, history: stalled)
        guard case .action(.tap(0.5, 0.5), let reason) = decision, reason == "Repeat" else {
            throw TestFailure("Stall fallback did not reach the primary: \(decision)")
        }
    }

    private static func finishedAndWaitAreMarked() async throws {
        let finishing = PhonePlannerEscalation(
            primary: { _, _, _ in .needsInput("unsure") },
            escalation: { _, _, _ in .finished("The goal is visible on screen") })
        guard case .finished(let result) = try await finishing.decide(goal: "Goal", frame: frame, history: []),
              result == "The goal is visible on screen" else {
            throw TestFailure("Finished decision was not preserved")
        }
    }

    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    final class LockedFlag: @unchecked Sendable {
        private var flag = false
        private let lock = NSLock()

        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }
}

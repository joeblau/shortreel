import Foundation

struct PhonePlannerEscalation: Sendable {
    typealias Decide = @Sendable (String, PhoneScreenFrame, [PhoneVisionStep]) async throws -> PhoneVisionDecision

    let primary: Decide
    let escalation: Decide
    var stallThreshold = 2

    func decide(goal: String, frame: PhoneScreenFrame, history: [PhoneVisionStep]) async throws -> PhoneVisionDecision {
        if isStalled(history) {
            do {
                return try await escalated(goal: goal, frame: frame, history: history,
                                           trigger: "the same action kept repeating without changing the screen")
            } catch {
                return try await primary(goal, frame, history)
            }
        }
        let decision = try await primary(goal, frame, history)
        guard case .needsInput(let explanation) = decision else { return decision }
        do {
            return try await escalated(goal: goal, frame: frame, history: history, trigger: explanation)
        } catch let error as PhonePromptPlanningError {
            throw error
        } catch {
            throw PhonePromptPlanningError.needsClarification(explanation)
        }
    }

    private func escalated(goal: String, frame: PhoneScreenFrame, history: [PhoneVisionStep],
                           trigger: String) async throws -> PhoneVisionDecision {
        switch try await escalation(goal, frame, history) {
        case .needsInput(let explanation):
            throw PhonePromptPlanningError.needsClarification(explanation)
        case .action(let action, let reason):
            return .action(action, reason: "Escalated (\(trigger)): \(reason)")
        case .wait(let seconds, let reason):
            return .wait(seconds: seconds, reason: "Escalated (\(trigger)): \(reason)")
        case .finished(let result):
            return .finished(result)
        }
    }

    func isStalled(_ history: [PhoneVisionStep]) -> Bool {
        let tail = history.suffix(stallThreshold)
        guard tail.count == stallThreshold, let first = tail.first else { return false }
        return tail.allSatisfy { $0.action == first.action }
    }
}

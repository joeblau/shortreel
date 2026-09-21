import Foundation

/// Two-tier planning: a fast pixel-level planner (UI-TARS, on-device) acts
/// first; when it gets stuck, a stronger reasoning planner (Grok) makes one
/// decision from the same frame and history, then control returns to the
/// primary. Stuck means the primary asked the user for help, or its attempted
/// actions stopped changing anything. Escalated steps are marked so the
/// request history shows which model acted.
struct PhonePlannerEscalation: Sendable {
    typealias Decide = @Sendable (String, PhoneScreenFrame, [PhoneVisionStep]) async throws -> PhoneVisionDecision

    let primary: Decide
    let escalation: Decide
    /// Identical attempted actions at the history tail that count as stalled.
    /// The visual runner aborts on a third repeat; escalating at two preempts it.
    var stallThreshold = 2

    func decide(goal: String, frame: PhoneScreenFrame, history: [PhoneVisionStep]) async throws -> PhoneVisionDecision {
        if isStalled(history) {
            do {
                return try await escalated(goal: goal, frame: frame, history: history,
                                           trigger: "the same action kept repeating without changing the screen")
            } catch {
                // A stalled loop still has the runner's repeated-input guard as
                // a backstop; a failed escalation must not mask it.
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
            // The reasoning tier could not be reached; keep the primary's
            // original request for user input.
            throw PhonePromptPlanningError.needsClarification(explanation)
        }
    }

    private func escalated(goal: String, frame: PhoneScreenFrame, history: [PhoneVisionStep],
                           trigger: String) async throws -> PhoneVisionDecision {
        switch try await escalation(goal, frame, history) {
        case .needsInput(let explanation):
            // The reasoning model cannot proceed either: stop for the user,
            // exactly as the primary's request for input would have.
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

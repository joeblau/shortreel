import CoreGraphics
import Foundation

/// Image bytes and identity stay together so a plan cannot use another phone's screen.
struct PhoneScreenFrame: Identifiable, Sendable, Equatable {
    let id: UUID
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let jpegData: Data
    /// Pre-decoded on the capture queue so views never decode JPEG on the main actor.
    let cgImage: CGImage
    let sourceID: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct PhoneVisionStep: Identifiable, Sendable, Equatable {
    let id: UUID
    let number: Int
    let action: String
    let detail: String
    let capturedAt: Date
    // Execution facts stay separate from the planner's (possibly wrong) reason.
    var input: PhonePromptAction? = nil
    var beforeFrame: PhoneScreenFrame? = nil
    var afterFrame: PhoneScreenFrame? = nil
    var screenChanged: Bool? = nil
    /// Opt-in task memory for long stage workflows; ordinary requests exclude
    /// earlier planner reasoning from subsequent prompts.
    var progressNote: String? = nil
    /// Retained across a run of waits so a video replay can be compared with
    /// the start of observation instead of only the last two transitions.
    var playbackStartFrame: PhoneScreenFrame? = nil
    var playbackReviewRequested = false
    var playbackEvidence: String? = nil

    var pageState: String? = nil
    var decisionSource: String? = nil
    /// The local SemanticIf account-step verdict (contract TASK-8, issue #15),
    /// with the probabilities, margin, and prompt hash behind it. Journaled
    /// with the step so a stopped run names the local decision.
    var accountCheck: WarmUpAccountDecision? = nil
    /// The local SemanticIf failure-mode verdict for the active step (contract
    /// TASK-5, issue #16). Journaled with the step so a recovered or stopped
    /// run names the detected failureMode id and its contract recovery.
    var failureCheck: WarmUpFailureDecision? = nil

    var executionFeedback: String {
        let command = input?.modelInputDescription ?? action
        let result = screenChanged.map { $0
            ? "Screen pixels changed; this does NOT establish that the intended action succeeded."
            : "Screen pixels did not materially change; the intended transition is unconfirmed." }
            ?? "No post-action observation available."
        let timing = "Screenshot captured at \(capturedAt.ISO8601Format())."
        let review = playbackReviewRequested ? "\n" + PhoneSearchGuidance.playbackCompletionReview : ""
        let playback = playbackEvidence.map { "\n" + $0 } ?? ""
        let route = pageState.map { " Page: \($0); decision: \(decisionSource ?? "model")." } ?? ""
        return "\(number). Sent input (coordinates are normalized 0...1): \(command). Result: \(result) \(timing)\(route)\(review)\(playback)"
    }
}

/// The local account-step verdict (contract TASK-8, issue #15): the SemanticIf
/// scorer's decision on the current frame's OCR, with the evidence the runner
/// acts on and the readout diagnostics the journal keeps. `Codable` so
/// `DeviceRunJournal` persists it with the step.
struct WarmUpAccountDecision: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// OCR of the current frame satisfies the account success criteria.
        case matches
        /// A different signed-in handle was read. Terminal: needsInput.
        case mismatch
        /// A sign-in / account-picker surface was read. Terminal: needsInput.
        case signedOut = "signed-out"
        /// No confident handle (or the margin was below threshold): the
        /// contract's recovery — one Home + reopen, then needsInput.
        case unreadable
    }

    var outcome: Outcome
    /// Finished/needsInput message the runner uses for this verdict.
    var evidence: String
    /// Probability of each option id, in the row's declared option order.
    var probabilities: [String: Double]
    var margin: Double
    var threshold: Double
    var promptHash: String
}

/// The local failure-mode verdict for one warm-up step (contract TASK-5,
/// issue #16): the SemanticIf scorer's decision on the current frame scored
/// against the step's contract failureModes. `failureModeID == nil` means no
/// failure was detected (or the margin was too close to call) and the planner
/// decides as before. `Codable` so `DeviceRunJournal` persists it with the step.
struct WarmUpFailureDecision: Codable, Equatable, Sendable {
    var stepID: String
    /// The detected contract `failureModes[].id`; nil for none/uncertain.
    var failureModeID: String?
    /// The margin was below threshold; never an assertive branch.
    var uncertain: Bool
    /// The contract's `terminal` flag for the detected mode.
    var terminal: Bool
    /// The contract's detection and recovery text for the detected mode.
    var detection: String
    var recovery: String
    /// Message the runner journals and uses for needsInput.
    var evidence: String
    /// Probability of each option id, in the row's declared option order.
    var probabilities: [String: Double]
    var margin: Double
    var threshold: Double
    var promptHash: String
}

enum PhoneVisionDecision: Sendable, Equatable {
    case action(PhonePromptAction, reason: String)
    case wait(seconds: Double, reason: String)
    case finished(String)
    case needsInput(String)

    func validated() throws -> PhoneVisionDecision {
        switch self {
        case .action(let action, let reason):
            try Self.requireDescription(reason)
            // App launch and search are compound command sequences. The visual
            // agent must observe the screen between their individual inputs.
            switch action {
            case .openApp, .search:
                throw PhoneVisionError.invalidDecision("Choose one visible interaction at a time.")
            case .typeText(let text):
                guard text.count <= 100 else {
                    throw PhoneVisionError.invalidDecision("Type at most 100 characters in one step.")
                }
            default: break
            }
            // Every rejection is a malformed model answer, whichever planner
            // produced it, so the runner can retry once with the reason.
            do { try DevicePromptPlanner.validate(.init(actions: [action])) }
            catch { throw PhoneVisionError.invalidDecision(error.localizedDescription) }
        case .wait(let seconds, let reason):
            try Self.requireDescription(reason)
            guard seconds.isFinite, (0.25...3).contains(seconds) else {
                throw PhoneVisionError.invalidDecision("Wait between a quarter second and three seconds.")
            }
        case .finished(let message), .needsInput(let message):
            try Self.requireDescription(message)
        }
        return self
    }

    private static func requireDescription(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 1_000 else {
            throw PhoneVisionError.invalidDecision("The model must explain its next step briefly.")
        }
    }
}

enum PhoneVisionError: LocalizedError {
    case unavailable(String)
    case invalidDecision(String)
    case staleFrame
    case sourceChanged
    case limitReached

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidDecision(let message): message
        case .staleFrame: "A fresh iPhone screen wasn’t available. Reconnect the USB screen and try again."
        case .sourceChanged: "The screen source changed. Select the screen belonging to this phone and try again."
        case .limitReached: "Stopped at the request limit. Review the phone’s screen before continuing."
        }
    }
}


struct PhoneScreenObservation: Decodable, Sendable, Equatable {
    enum State: String, Decodable, Sendable {
        case home, homeEditing, appSwitcher, foregroundApp, spotlight, assistiveTouch, dialog, unknown
    }
    let state: State
    let appCardsVisible: Bool
    let evidence: String

    var summary: String { "Screen classification: \(state.rawValue). App preview cards visible: \(appCardsVisible). Evidence: \(evidence)" }

    static func decode(_ text: String) throws -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels: [(String, State)] = [("ASSISTIVETOUCH", .assistiveTouch), ("SPOTLIGHT", .spotlight), ("HOME", .home), ("EDITING", .homeEditing),
                                         ("SWITCHER", .appSwitcher), ("APP", .foregroundApp), ("UNKNOWN", .unknown)]
        for (label, state) in labels where trimmed.uppercased().hasPrefix(label) {
            let separator = trimmed.dropFirst(label.count).first
            guard separator == nil || separator!.isWhitespace || ":;,.(-".contains(separator!) else { continue }
            guard trimmed.count <= 600 else { break }
            return .init(state: state, appCardsVisible: state == .appSwitcher, evidence: trimmed)
        }
        let value: Self = try UITarsScreenVerification.decodeJSON(text)
        guard !value.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.evidence.count <= 600,
              value.appCardsVisible == (value.state == .appSwitcher) else {
            throw PhoneVisionError.invalidDecision("The screen observation was incomplete or contradictory. No input was sent.")
        }
        return value
    }
}

struct PhoneActionReview: Decodable, Sendable {
    enum Verdict: String, Decodable, Sendable { case allow, replan, stop }
    let verdict: Verdict
    let evidence: String

    static func decode(_ text: String) throws -> Self {
        let value: Self = try UITarsScreenVerification.decodeJSON(text)
        guard !value.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.evidence.count <= 600 else {
            throw PhoneVisionError.invalidDecision("The action check did not supply evidence. No input was sent.")
        }
        return value
    }
}

enum UITarsScreenVerification {
    static func decodeJSON<Value: Decodable>(_ text: String) throws -> Value {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json\n"), value.hasSuffix("```") { value = String(value.dropFirst(8).dropLast(3)) }
        else if value.hasPrefix("```\n"), value.hasSuffix("```") { value = String(value.dropFirst(4).dropLast(3)) }
        guard value.utf8.count <= 4096, let decoded = try? JSONDecoder().decode(Value.self, from: Data(value.utf8)) else {
            throw PhoneVisionError.invalidDecision("UI-TARS could not verify the screen. No input was sent.")
        }
        return decoded
    }
}

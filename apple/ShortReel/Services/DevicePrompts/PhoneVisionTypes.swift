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

    var executionFeedback: String {
        let command = input?.modelInputDescription ?? action
        let result = screenChanged.map { $0
            ? "Screen pixels changed; this does NOT establish that the intended action succeeded."
            : "Screen pixels did not materially change; the intended transition is unconfirmed." }
            ?? "No post-action observation available."
        return "\(number). Sent input (coordinates are normalized 0...1): \(command). Result: \(result)"
    }
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
            try DevicePromptPlanner.validate(.init(actions: [action]))
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

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

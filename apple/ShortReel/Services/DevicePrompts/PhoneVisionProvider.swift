import Foundation

enum PhoneVisionProvider: String, CaseIterable, Identifiable, Sendable {
    // Preserve the saved selection from releases that called Codex "Astra".
    case codex = "astra"
    case claude
    case uiTars
    case onDevice

    static let preferenceKey = "phoneVisionProvider"
    static let defaultProvider: Self = .codex
    static let modelPreferenceKey = "phoneVisionModels"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .uiTars: "UI-TARS"
        case .codex: "Codex"
        case .claude: "Claude"
        case .onDevice: "On this Mac"
        }
    }

    var screenRequestDescription: String {
        switch self {
        case .uiTars:
            "Screen requests are interpreted by UI-TARS running on this Mac; screenshots stay local unless ~/.ui-tars-cli.json points UI-TARS at a hosted model service."
        case .codex:
            "Codex uses your Codex CLI login. Phone screenshots and task context are sent to OpenAI; ShortReel executes each phone action."
        case .claude:
            "Claude uses your Claude Code login. Phone screenshots and task context are sent to Anthropic; ShortReel executes each phone action."
        case .onDevice:
            "Screen requests are interpreted on this Mac with Apple Intelligence. Screenshots and recognized text stay on this Mac."
        }
    }

    var modelChoices: [String] {
        switch self {
        case .codex: ["gpt-6-astra"]
        case .claude: ["sonnet", "opus", "haiku"]
        case .uiTars, .onDevice: []
        }
    }

    var defaultModel: String? { modelChoices.first }

    static func isValidModel(_ model: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/[]")
        return !model.isEmpty && model.count <= 128 && model.first != "-"
            && model.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

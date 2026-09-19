import Foundation

enum PhoneVisionProvider: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case grok

    static let preferenceKey = "phoneVisionProvider"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: "On this Mac"
        case .grok: "Grok"
        }
    }

    var screenRequestDescription: String {
        switch self {
        case .onDevice:
            "Screen requests are interpreted on this Mac with Apple Intelligence. Screenshots and recognized text stay on this Mac."
        case .grok:
            "Screen requests send your request, the current screenshot, recognized text, and recent actions to Grok for each step."
        }
    }
}

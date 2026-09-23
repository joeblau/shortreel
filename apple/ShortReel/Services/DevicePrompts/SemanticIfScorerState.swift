import Foundation

enum SemanticIfScorerState: Equatable, Sendable {
    case disabled
    case idle
    case loading
    case ready
    case failed(String)

    static let enabledKey = "semanticIfEnabled"

    var menuStatus: String {
        switch self {
        case .disabled: "Off"
        case .idle: "Not loaded"
        case .loading: "Loading…"
        case .ready: "Ready"
        case .failed: "Failed to load"
        }
    }

    var canWarm: Bool {
        switch self {
        case .idle, .failed: true
        case .disabled, .loading, .ready: false
        }
    }

    var localChecksOffNotice: String? {
        if case .failed(let reason) = self {
            return "Local checks are off: \(reason) The planner keeps deciding every step."
        }
        return nil
    }
}

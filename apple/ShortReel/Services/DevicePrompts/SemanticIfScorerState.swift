import Foundation

/// Lifecycle state of the local Semif decision scorer (issue #14), owned by
/// `DeviceManager`. Pure value type so the standalone swiftc tests can map
/// every state to its UI copy without the app.
enum SemanticIfScorerState: Equatable, Sendable {
    /// Turned off in the planner menu: nothing loads, nothing downloads, and
    /// runs take the planner-only path exactly as before local checks existed.
    case disabled
    /// On, but no load has been requested yet. Loading (and the one-time
    /// checkpoint download) happens only on the menu's warm-up action or when
    /// a run needs a decision.
    case idle
    case loading
    case ready
    case failed(String)

    static let enabledKey = "semanticIfEnabled"

    /// Short status shown next to the planner submenus.
    var menuStatus: String {
        switch self {
        case .disabled: "Off"
        case .idle: "Not loaded"
        case .loading: "Loading…"
        case .ready: "Ready"
        case .failed: "Failed to load"
        }
    }

    /// Whether the menu offers the load/warm action in this state.
    var canWarm: Bool {
        switch self {
        case .idle, .failed: true
        case .disabled, .loading, .ready: false
        }
    }

    /// Why local checks are off, for the Stage panel. Only a load failure is
    /// surfaced: disabled and not-yet-loaded are the user's own choice, and
    /// neither blocks a run, so they stay quiet.
    var localChecksOffNotice: String? {
        if case .failed(let reason) = self {
            return "Local checks are off: \(reason) The planner keeps deciding every step."
        }
        return nil
    }
}

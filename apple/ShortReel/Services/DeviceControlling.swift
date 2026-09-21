import Foundation

/// A single interaction the agent asks a device to perform.
struct DeviceAction: Sendable {
    var kind: InteractionKind
    var platform: Platform
    var personaHandle: String
    var keyword: String
}

/// Seam between the warm-up agent and whatever drives the iPhone.
/// The MVP ships a simulated implementation; a real WebDriverAgent-backed
/// controller will conform to this same protocol later.
@MainActor
protocol DeviceControlling {
    /// Performs the action on the iPhone bound to `persona` and returns a
    /// human-readable result string for the timeline.
    func perform(_ action: DeviceAction, on persona: Persona) async throws -> String
}

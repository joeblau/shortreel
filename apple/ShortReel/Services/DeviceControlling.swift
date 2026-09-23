import Foundation

struct DeviceAction: Sendable {
    var kind: InteractionKind
    var platform: Platform
    var personaHandle: String
    var keyword: String
}

@MainActor
protocol DeviceControlling {
    func perform(_ action: DeviceAction, on persona: Persona) async throws -> String
}

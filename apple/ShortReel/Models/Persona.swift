import Foundation
import SwiftData

@Model
final class Persona {
    var handle: String
    var displayName: String
    /// Legacy label kept for stores created before `device` existed.
    var deviceName: String
    var narrative: String
    var isActive: Bool
    var createdAt: Date
    /// Empty in older stores; preserve the first existing social profile's network.
    var networkRawValue: String = ""

    @Relationship(deleteRule: .cascade, inverse: \SocialLink.persona)
    var socialLinks: [SocialLink] = []

    @Relationship(deleteRule: .cascade, inverse: \TimelineEvent.persona)
    var events: [TimelineEvent] = []

    var farm: Farm?

    /// The physical phone this persona's agent drives.
    var device: Device?

    init(
        handle: String,
        displayName: String,
        deviceName: String,
        narrative: String,
        isActive: Bool = true,
        createdAt: Date = .now,
        network: Platform = .instagram
    ) {
        self.handle = handle
        self.displayName = displayName
        self.deviceName = deviceName
        self.narrative = narrative
        self.isActive = isActive
        self.createdAt = createdAt
        self.networkRawValue = network.rawValue
    }

    static let networks: [Platform] = [.tikTok, .instagram, .youtube, .x]

    var network: Platform {
        get { Platform(rawValue: networkRawValue) ?? socialLinks.first?.platform ?? .instagram }
        set { networkRawValue = newValue.rawValue }
    }

    /// Only a live device relationship represents an assignment.
    var boundDeviceName: String {
        guard let device, device.isLive else { return "" }
        return device.name
    }

    var initials: String {
        displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

/// Removes the old seeded identities before any persona tasks start.
enum LegacySamplePersonaCleanup {
    @MainActor
    static func remove(in context: ModelContext) throws {
        let sampleNames = [
            "maya.shoots": "Maya Chen",
            "dre.wears": "Andre Wilson",
            "priya.eats": "Priya Nair",
        ]
        let personas = try context.fetch(FetchDescriptor<Persona>())
        let samples = personas.filter { sampleNames[$0.handle] == $0.displayName }
        let sampleIDs = Set(samples.map(\.persistentModelID))
        // Plans have no inverse cascade relationship on Persona.
        for plan in try context.fetch(FetchDescriptor<WarmUpPlan>()) {
            if let persona = plan.persona, sampleIDs.contains(persona.persistentModelID) {
                context.delete(plan)
            }
        }
        for persona in samples {
            context.delete(persona)
        }
        try context.save()
    }
}

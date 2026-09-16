import Foundation
import SwiftData

@Model
final class Account {
    var handle: String
    var displayName: String
    /// Legacy label kept for stores created before `device` existed.
    var deviceName: String
    var narrative: String
    var isActive: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SocialLink.account)
    var socialLinks: [SocialLink] = []

    @Relationship(deleteRule: .cascade, inverse: \TimelineEvent.account)
    var events: [TimelineEvent] = []

    var farm: Farm?

    /// The physical phone this account's agent drives.
    var device: Device?

    init(
        handle: String,
        displayName: String,
        deviceName: String,
        narrative: String,
        isActive: Bool = true,
        createdAt: Date = .now
    ) {
        self.handle = handle
        self.displayName = displayName
        self.deviceName = deviceName
        self.narrative = narrative
        self.isActive = isActive
        self.createdAt = createdAt
    }

    /// Name of the bound device, falling back to the legacy label.
    var boundDeviceName: String {
        device?.name ?? deviceName
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

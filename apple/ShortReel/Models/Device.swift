import Foundation
import SwiftData
import SwiftUI

enum DeviceTransport: String, Codable, CaseIterable, Sendable {
    case bluetoothHID
    case usb

    var displayName: String {
        switch self {
        case .bluetoothHID: "Bluetooth"
        case .usb: "USB"
        }
    }

    var symbolName: String {
        switch self {
        case .bluetoothHID: "dot.radiowaves.left.and.right"
        case .usb: "cable.connector"
        }
    }

    var identifierLabel: String {
        switch self {
        case .bluetoothHID: "Bluetooth address"
        case .usb: "UDID"
        }
    }
}

enum DeviceConnectionState: String, Codable, Sendable {
    case disconnected
    case pairing
    case connected

    var displayName: String {
        switch self {
        case .disconnected: "Disconnected"
        case .pairing: "Pairing…"
        case .connected: "Connected"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: .gray
        case .pairing: .orange
        case .connected: .green
        }
    }
}

@Model
final class Device {
    var name: String
    var modelName: String
    var transport: DeviceTransport
    var connectionState: DeviceConnectionState
    var identifier: String
    var lastSeen: Date?
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Persona.device)
    var personas: [Persona] = []

    init(
        name: String,
        modelName: String,
        transport: DeviceTransport,
        identifier: String,
        connectionState: DeviceConnectionState = .disconnected,
        createdAt: Date = .now
    ) {
        self.name = name
        self.modelName = modelName
        self.transport = transport
        self.identifier = identifier
        self.connectionState = connectionState
        self.createdAt = createdAt
    }

    var isConnected: Bool { connectionState == .connected }

    var descriptor: DeviceDescriptor {
        DeviceDescriptor(identifier: identifier, name: name, transport: transport)
    }
}

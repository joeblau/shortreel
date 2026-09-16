import Foundation
import Observation
import SwiftData

/// Owns the registry of phones and keeps their SwiftData connection state in
/// sync with the underlying `DeviceHost`.
@Observable
@MainActor
final class DeviceManager {
    private let container: ModelContainer
    private let host: any DeviceHost
    private var listener: Task<Void, Never>?

    init(container: ModelContainer, host: (any DeviceHost)? = nil) {
        self.container = container
        self.host = host ?? SimulatedDeviceHost()
    }

    private var context: ModelContext { container.mainContext }

    /// Starts listening for host events and re-establishes every known
    /// connection. Connections never survive a relaunch, so stored state is
    /// reset first.
    func start() {
        guard listener == nil else { return }
        listener = Task { [weak self, host] in
            for await event in host.events {
                guard let self else { break }
                self.handle(event)
            }
        }

        let devices = allDevices()
        for device in devices {
            device.connectionState = .disconnected
        }
        try? context.save()
        for device in devices {
            connect(device)
        }
    }

    // MARK: - Connections

    func connect(_ device: Device) {
        guard device.connectionState == .disconnected else { return }
        let descriptor = device.descriptor
        Task { [host] in
            do {
                try await host.connect(descriptor)
            } catch {
                handle(.connectionChanged(identifier: descriptor.identifier, state: .disconnected))
            }
        }
    }

    func disconnect(_ device: Device) {
        host.disconnect(device.descriptor)
    }

    // MARK: - Registry

    func bind(_ device: Device, to account: Account) {
        account.device = device
        account.deviceName = device.name
        try? context.save()
    }

    func unbind(_ account: Account) {
        account.device = nil
        try? context.save()
    }

    func remove(_ device: Device) {
        host.disconnect(device.descriptor)
        context.delete(device)
        try? context.save()
    }

    // MARK: - Private

    private func handle(_ event: DeviceHostEvent) {
        switch event {
        case .connectionChanged(let identifier, let state):
            guard let device = allDevices().first(where: { $0.identifier == identifier }) else { return }
            device.connectionState = state
            if state == .connected {
                device.lastSeen = .now
            }
            try? context.save()
        }
    }

    private func allDevices() -> [Device] {
        (try? context.fetch(FetchDescriptor<Device>())) ?? []
    }
}

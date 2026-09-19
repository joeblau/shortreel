import SwiftData
import SwiftUI

struct DeviceListView: View {
    @Binding var selection: PersistentIdentifier?
    let onAddDevice: () -> Void

    @Query(sort: \Device.createdAt) private var devices: [Device]
    @Environment(DeviceManager.self) private var deviceManager

    private var liveDevices: [Device] {
        devices.filter(\.isLive)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(liveDevices, id: \.persistentModelID) { device in
                DeviceSidebarRow(device: device)
                    .tag(device.persistentModelID)
                    .contextMenu {
                        if device.isLive {
                            deviceMenu(for: device)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ShortReel")
        .overlay {
            if liveDevices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Devices")
                        .font(.headline)
                    Text("Connect an iPhone to make it available to your agents.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Connect iPhone", action: onAddDevice)
                }
                .padding(20)
            }
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                if !liveDevices.isEmpty {
                    Text("\(liveDevices.filter(\.isConnected).count) of \(liveDevices.count) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: onAddDevice) {
                    Label("Connect iPhone", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func deviceMenu(for device: Device) -> some View {
        if device.isConnected {
            if device.transport == .bluetoothHID {
                Button("Test Pointer Movement") {
                    deviceManager.testControl(device)
                }
            }
            Button {
                deviceManager.disconnect(device)
            } label: {
                Label("Disconnect", systemImage: "iphone.gen3.slash")
            }
        } else {
            Button {
                deviceManager.connect(device)
            } label: {
                Label("Connect", systemImage: "iphone.gen3.radiowaves.left.and.right")
            }
            .disabled(device.connectionState == .pairing)
        }

        Divider()
        Button(role: .destructive) {
            remove(device)
        } label: {
            Label("Remove Device", systemImage: "trash")
        }
    }

    private func remove(_ device: Device) {
        if selection == device.persistentModelID {
            selection = nil
        }
        // Tear down a selected device's detail before detaching its model.
        Task { @MainActor in
            await Task.yield()
            guard device.isLive else { return }
            deviceManager.remove(device)
        }
    }
}

private struct DeviceSidebarRow: View {
    let device: Device
    @Environment(DeviceManager.self) private var deviceManager

    var body: some View {
        if device.isLive {
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                    .foregroundStyle(device.isConnected ? Color.accentColor : Color.secondary)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(device.transport.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(device.connectionState.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if device.connectionState == .pairing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(device.connectionState.color)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 4)
            .help(deviceManager.connectionErrors[device.identifier] ?? device.connectionState.displayName)
        }
    }
}

import SwiftData
import SwiftUI

/// Right-hand inspector: the fleet of phones agents can control, followed by
/// the selected account's bound device and social profiles.
struct InspectorView: View {
    let account: Account?
    let onAddDevice: () -> Void

    @Query(sort: \Device.createdAt) private var devices: [Device]
    @Environment(DeviceManager.self) private var deviceManager
    @Environment(\.modelContext) private var modelContext

    @State private var newPlatform: Platform = .instagram
    @State private var newHandle = ""
    @State private var newURL = ""

    private var connectedCount: Int {
        devices.filter(\.isConnected).count
    }

    var body: some View {
        List {
            devicesSection

            if let account {
                boundDeviceSection(for: account)
                socialSections(for: account)
            } else {
                Section("Account") {
                    Text("Select an account to see its bound device and social profiles.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
    }

    // MARK: - Devices

    private var devicesSection: some View {
        Section {
            if devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No devices yet. Add an iPhone so agents have something to control.")
                        .foregroundStyle(.secondary)
                    Button("Add Device", action: onAddDevice)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(devices, id: \.persistentModelID) { device in
                    DeviceRow(device: device)
                        .contextMenu { deviceMenu(for: device) }
                }
            }
        } header: {
            HStack {
                Text("Devices")
                Spacer()
                if !devices.isEmpty {
                    Text("\(connectedCount)/\(devices.count) connected")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func deviceMenu(for device: Device) -> some View {
        if device.isConnected {
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

        if let account {
            Divider()
            if account.device == device {
                Button {
                    deviceManager.unbind(account)
                } label: {
                    Label("Unbind from @\(account.handle)", systemImage: "link.badge.plus")
                }
            } else {
                Button {
                    deviceManager.bind(device, to: account)
                } label: {
                    Label("Bind to @\(account.handle)", systemImage: "link")
                }
            }
        }

        Divider()
        Button(role: .destructive) {
            deviceManager.remove(device)
        } label: {
            Label("Remove Device", systemImage: "trash")
        }
    }

    // MARK: - Bound device

    private func boundDeviceSection(for account: Account) -> some View {
        Section("Bound device") {
            if let device = account.device {
                DeviceRow(device: device)
                    .contextMenu { deviceMenu(for: device) }
            } else if devices.isEmpty {
                Text("No device bound.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: boundDeviceSelection(for: account)) {
                    Text("None").tag(nil as PersistentIdentifier?)
                    ForEach(devices, id: \.persistentModelID) { device in
                        Text(device.name).tag(device.persistentModelID as PersistentIdentifier?)
                    }
                }
            }
        }
    }

    private func boundDeviceSelection(for account: Account) -> Binding<PersistentIdentifier?> {
        Binding(
            get: { account.device?.persistentModelID },
            set: { id in
                if let id, let device = devices.first(where: { $0.persistentModelID == id }) {
                    deviceManager.bind(device, to: account)
                } else {
                    deviceManager.unbind(account)
                }
            }
        )
    }

    // MARK: - Social links

    @ViewBuilder
    private func socialSections(for account: Account) -> some View {
        Section("Social accounts on iPhone") {
            if account.socialLinks.isEmpty {
                Text("No social accounts linked yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedLinks(for: account), id: \.persistentModelID) { link in
                    SocialLinkRow(link: link)
                        .contextMenu {
                            Button(role: .destructive) {
                                delete(link)
                            } label: {
                                Label("Remove Link", systemImage: "trash")
                            }
                        }
                }
                .onDelete { offsets in
                    let sorted = sortedLinks(for: account)
                    for index in offsets {
                        delete(sorted[index])
                    }
                }
            }
        }

        Section("Add link") {
            Picker("Platform", selection: $newPlatform) {
                ForEach(Platform.allCases, id: \.self) { platform in
                    Text(platform.displayName).tag(platform)
                }
            }
            TextField("Handle", text: $newHandle, prompt: Text("username"))
            TextField("Profile URL", text: $newURL, prompt: Text("https://…"))
            Button("Add Link") {
                addLink(to: account)
            }
            .disabled(newHandle.trimmingCharacters(in: .whitespaces).isEmpty
                      || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func sortedLinks(for account: Account) -> [SocialLink] {
        account.socialLinks.sorted { $0.platform.rawValue < $1.platform.rawValue }
    }

    private func addLink(to account: Account) {
        var urlString = newURL.trimmingCharacters(in: .whitespaces)
        if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
            urlString = "https://\(urlString)"
        }
        guard let url = URL(string: urlString) else { return }

        let link = SocialLink(
            platform: newPlatform,
            profileURL: url,
            handle: newHandle.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "@")),
            account: account
        )
        modelContext.insert(link)
        account.socialLinks.append(link)
        try? modelContext.save()

        newHandle = ""
        newURL = ""
    }

    private func delete(_ link: SocialLink) {
        modelContext.delete(link)
        try? modelContext.save()
    }
}

// MARK: - Rows

struct DeviceRow: View {
    let device: Device

    private var subtitle: String {
        var parts = [device.modelName, device.transport.displayName]
        if let handle = device.accounts.first?.handle {
            parts.append("@\(handle)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.title3)
                .foregroundStyle(device.isConnected ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: device.transport.symbolName)
                    Text(subtitle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        .help(device.connectionState.displayName)
    }
}

private struct SocialLinkRow: View {
    let link: SocialLink

    var body: some View {
        Link(destination: link.profileURL) {
            HStack(spacing: 10) {
                Image(systemName: link.platform.symbolName)
                    .font(.callout)
                    .foregroundStyle(link.platform.color)
                    .frame(width: 24, height: 24)
                    .background(link.platform.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text("@\(link.handle)")
                        .font(.callout)
                        .lineLimit(1)
                    Text(link.profileURL.host() ?? link.profileURL.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

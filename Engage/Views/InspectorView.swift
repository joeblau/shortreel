import SwiftData
import SwiftUI

/// Agent inspector: the selected agent's device assignment and social profiles.
/// Fleet management lives in the Devices section.
struct InspectorView: View {
    let account: Account?
    let onAddDevice: () -> Void
    let onShowDevice: (Device) -> Void

    @Query(sort: \Device.createdAt) private var devices: [Device]
    @Environment(DeviceManager.self) private var deviceManager
    @Environment(\.modelContext) private var modelContext

    @State private var newPlatform: Platform = .instagram
    @State private var newHandle = ""
    @State private var newURL = ""

    private var liveDevices: [Device] { devices.filter(\.isLive) }

    var body: some View {
        List {
            if let account, account.isLive {
                boundDeviceSection(for: account)
                socialSections(for: account)
            } else {
                Section("Agent") {
                    Text("Select an agent to see its bound device and social profiles.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
    }

    // MARK: - Bound device

    private func boundDeviceSection(for account: Account) -> some View {
        Section("Bound device") {
            if liveDevices.isEmpty {
                Text("No devices connected to Engage yet.")
                    .foregroundStyle(.secondary)
                Button("Connect iPhone", action: onAddDevice)
            } else {
                Picker("Device", selection: boundDeviceSelection(for: account)) {
                    Text("None").tag(nil as PersistentIdentifier?)
                    ForEach(liveDevices, id: \.persistentModelID) { device in
                        Text(device.name).tag(device.persistentModelID as PersistentIdentifier?)
                    }
                }
                if let device = account.device, device.isLive {
                    Button {
                        onShowDevice(device)
                    } label: {
                        DeviceRow(device: device)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Devices")
                    .contextMenu {
                        Button("Show in Devices") { onShowDevice(device) }
                        Button("Unbind Device") { deviceManager.unbind(account) }
                    }
                }
            }
        }
    }

    private func boundDeviceSelection(for account: Account) -> Binding<PersistentIdentifier?> {
        Binding(
            get: { account.device?.persistentModelID },
            set: { id in
                if let id, let device = liveDevices.first(where: { $0.persistentModelID == id }) {
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
        account.socialLinks.filter(\.isLive).sorted { $0.platform.rawValue < $1.platform.rawValue }
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
    @Environment(DeviceManager.self) private var deviceManager

    private var subtitle: String {
        var parts = [device.modelName, device.transport.displayName]
        if let handle = device.accounts.first(where: \.isLive)?.handle {
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
        .help(deviceManager.connectionErrors[device.identifier] ?? device.connectionState.displayName)
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

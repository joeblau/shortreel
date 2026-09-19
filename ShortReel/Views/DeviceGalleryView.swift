import AVFoundation
import SwiftData
import SwiftUI

/// The whole app is this wall of phones. Tap a phone to give it instructions;
/// every registered phone keeps its place in the gallery and uses the capture
/// session owned by DeviceManager.
struct DeviceGalleryView: View {
    var onAddDevice: () -> Void

    @Query(sort: \Device.createdAt) private var devices: [Device]
    @Environment(DeviceManager.self) private var deviceManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var promptDevice: Device?
    @State private var settingsDevice: Device?
    @State private var refreshRevision = 0
    @State private var refreshing = false

    private var liveDevices: [Device] { devices.filter(\.isLive) }
    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 24, alignment: .top)]

    private struct RefreshID: Equatable {
        let devices: [PersistentIdentifier]
        let revision: Int
    }

    var body: some View {
        Group {
            if liveDevices.isEmpty {
                ContentUnavailableView {
                    Label("No Phones", systemImage: "iphone")
                } description: {
                    Text("Connect an iPhone to see its screen and give it instructions.")
                } actions: {
                    Button("Connect iPhone", action: onAddDevice)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        ForEach(liveDevices, id: \.persistentModelID) { device in
                            if device.isLive {
                                DeviceScreenCard(
                                    device: device,
                                    onPrompt: { promptDevice = device },
                                    onSettings: { settingsDevice = device }
                                )
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .navigationTitle("ShortReel")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshRevision += 1
                } label: {
                    Label("Refresh Screens", systemImage: "arrow.clockwise")
                }
                .disabled(refreshing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddDevice) {
                    Label("Connect iPhone", systemImage: "plus")
                }
            }
        }
        .task(id: RefreshID(devices: liveDevices.map(\.persistentModelID), revision: refreshRevision)) {
            refreshing = true
            await deviceManager.refreshDeviceScreens()
            if !Task.isCancelled { refreshing = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            refreshRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            refreshRevision += 1
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshRevision += 1 }
        }
        .sheet(item: $promptDevice) { device in
            DevicePromptSheet(device: device)
        }
        .sheet(item: $settingsDevice, onDismiss: { refreshRevision += 1 }) { device in
            DeviceSettingsSheet(device: device)
        }
    }
}

private struct DeviceScreenCard: View {
    let device: Device
    let onPrompt: () -> Void
    let onSettings: () -> Void

    @Environment(DeviceManager.self) private var deviceManager

    var body: some View {
        if device.isLive {
            let capture = deviceManager.screenCapture(for: device)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.name)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(device.connectionState.color)
                                .frame(width: 6, height: 6)
                            Text("\(device.transport.displayName) · \(device.connectionState.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Menu {
                        Button("Device Settings…", action: onSettings)
                        Divider()
                        if device.isConnected {
                            Button("Disconnect \(device.transport.displayName)") { deviceManager.disconnect(device) }
                        } else {
                            Button("Connect \(device.transport.displayName)") { deviceManager.connect(device) }
                                .disabled(device.connectionState == .pairing)
                        }
                        if capture.isRunning {
                            Button("Disconnect Screen") {
                                Task { await deviceManager.stopScreen(for: device) }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Options for \(device.name)")
                }

                Button(action: onPrompt) {
                    screen(capture)
                        .aspectRatio(9.0 / 19.5, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Screen of \(device.name)")
                .help("Give \(device.name) instructions")

                HStack {
                    screenStatus(capture)
                    Spacer(minLength: 4)
                    Button(capture.isRunning ? "Settings" : "Set Up Screen", action: onSettings)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func screen(_ capture: PhoneScreenCaptureService) -> some View {
        if capture.isRunning,
           let frame = capture.latestFrame,
           frame.sourceID == deviceManager.verifiedScreens[device.identifier],
           let image = NSImage(data: frame.jpegData) {
            // Preserve the complete captured image, including landscape screens.
            Color.clear.overlay {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
        } else {
            Color.clear.overlay {
                VStack(spacing: 14) {
                    if capture.isStarting {
                        ProgressView().controlSize(.small)
                        Text("Connecting screen…").font(.headline)
                    } else {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(placeholderTitle(capture))
                            .font(.headline)
                        Text(placeholderMessage(capture))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(24)
            }
        }
    }

    private func screenStatus(_ capture: PhoneScreenCaptureService) -> some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let hasFrame = capture.isRunning && capture.latestFrame.map {
                $0.sourceID == deviceManager.verifiedScreens[device.identifier]
            } == true
            let isFresh = hasFrame && capture.latestFrame.map { context.date.timeIntervalSince($0.capturedAt) < 5 } == true
            HStack(spacing: 6) {
                Circle()
                    .fill(isFresh ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(isFresh ? "Live screen" : hasFrame ? "Last screen" : capture.isStarting ? "Connecting…" : "Screen offline")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func placeholderTitle(_ capture: PhoneScreenCaptureService) -> String {
        if deviceManager.isScreenAutoConnectDisabled(for: device) { return "Screen disconnected" }
        if capture.authorizationStatus != .authorized { return "Screen access needed" }
        if capture.errorMessage != nil || deviceManager.screenConnectionErrors[device.identifier] != nil { return "Screen unavailable" }
        return capture.sources.isEmpty ? "Connect via USB" : "Set up this screen"
    }

    private func placeholderMessage(_ capture: PhoneScreenCaptureService) -> String {
        if deviceManager.isScreenAutoConnectDisabled(for: device) { return "Open screen settings to reconnect this iPhone’s live view." }
        if capture.authorizationStatus != .authorized { return "Open screen settings to allow this iPhone’s live view." }
        if let error = deviceManager.screenConnectionErrors[device.identifier] ?? capture.errorMessage { return error }
        return "Connect this iPhone by USB, unlock it, and confirm Trust to see its screen."
    }
}

private struct DevicePromptSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(device.name).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            Form {
                DevicePromptView(device: device)
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 640)
    }
}

private struct DeviceSettingsSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Device Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            DeviceDetailView(device: device)
        }
        .frame(width: 620, height: 720)
    }
}

import AVFoundation
import SwiftUI

struct PhoneScreenView: View {
    let device: Device

    @Environment(DeviceManager.self) private var deviceManager
    @State private var selectedSourceID = ""
    @State private var busy = false
    @State private var setupError: String?

    var body: some View {
        let capture = deviceManager.screenCapture(for: device)
        let prompt = deviceManager.promptSession(for: device)

        Section("Phone Screen") {
            VStack(alignment: .leading, spacing: 12) {
                if let frame = capture.latestFrame {
                    Image(decorative: frame.cgImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 440)
                        .accessibilityLabel("Live USB screen of \(device.name)")
                    Label(deviceManager.visionProvider == .onDevice
                        ? "Live screen · processed on this Mac" : "Live screen", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if capture.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the iPhone screen…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("See the screen while the agent works", systemImage: "iphone.gen3")
                        .font(.headline)
                    Text("For requests that need to see the phone, connect \(device.name) by USB, unlock it, and confirm Trust. Direct commands already work over Bluetooth.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !capture.isRunning {
                    if capture.sources.isEmpty {
                        Text("No USB iPhone screen found.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Screen for \(device.name)", selection: $selectedSourceID) {
                            Text("Choose an iPhone").tag("")
                            ForEach(capture.sources) { source in
                                Text(source.name).tag(source.id)
                            }
                        }
                    }
                }

                HStack {
                    if capture.isRunning {
                        Button("Disconnect Screen") {
                            Task { await deviceManager.stopScreen(for: device) }
                        }
                    } else if capture.authorizationStatus == .notDetermined {
                        Button("Allow Screen Access") {
                            Task {
                                busy = true
                                _ = await capture.requestCameraAuthorization()
                                await refresh()
                                busy = false
                            }
                        }
                        .disabled(busy)
                    } else if capture.authorizationStatus == .denied || capture.authorizationStatus == .restricted {
                        Button("Camera Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        Button("Connect Screen") {
                            Task {
                                busy = true
                                setupError = nil
                                defer { busy = false }
                                do { try await deviceManager.connectScreen(for: device, sourceID: selectedSourceID) }
                                catch is CancellationError { }
                                catch { setupError = error.localizedDescription }
                            }
                        }
                        .disabled(selectedSourceID.isEmpty || busy || capture.isStarting || prompt.isRunning)
                    }

                    Button("Refresh") { Task { await refresh() } }
                        .disabled(busy || capture.isStarting || prompt.isRunning)

                    if busy || capture.isStarting { ProgressView().controlSize(.small) }
                }

                if let error = setupError ?? deviceManager.screenConnectionErrors[device.identifier] ?? capture.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = deviceManager.visionUnavailabilityReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .task(id: device.identifier) { await refresh() }
        .onChange(of: capture.sources) { _, _ in
            guard !busy else { return }
            Task { await refresh() }
        }
        .onChange(of: device.isConnected) { _, connected in
            guard connected, !busy else { return }
            Task { await refresh() }
        }
    }

    @MainActor private func refresh() async {
        guard device.isLive else { return }
        busy = true
        setupError = nil
        defer { busy = false }
        await deviceManager.refreshDeviceScreens()
        guard device.isLive, !Task.isCancelled else { return }
        let capture = deviceManager.screenCapture(for: device)
        let previousSource = capture.selectedSourceID.flatMap { selected in
            capture.sources.contains(where: { $0.id == selected }) ? selected : nil
        }
        selectedSourceID = previousSource ?? deviceManager.matchingScreenSource(for: device) ?? ""
    }
}

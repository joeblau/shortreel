import SwiftUI

struct DeviceInspectorView: View {
    let device: Device?

    var body: some View {
        Form {
            if let device, device.isLive {
                Section("Device") {
                    HStack(spacing: 10) {
                        Image(systemName: "iphone.gen3")
                            .font(.title2)
                            .foregroundStyle(.tint)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                                .font(.headline)
                                .textSelection(.enabled)

                            HStack(spacing: 6) {
                                if device.connectionState == .pairing {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Circle()
                                        .fill(device.connectionState.color)
                                        .frame(width: 7, height: 7)
                                }
                                Text(device.connectionState.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }

                DevicePromptView(device: device)
            } else {
                Section("Device") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No iPhone Selected", systemImage: "iphone")
                            .font(.headline)
                        Text("Select a device screen or a device in the sidebar to give it instructions and see its requests.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
    }
}

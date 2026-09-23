import SwiftData
import SwiftUI

struct DeviceSettingsView: View {
    let device: Device

    @Query(sort: \Persona.createdAt) private var personas: [Persona]
    @Environment(DeviceManager.self) private var deviceManager
    @State private var testedDeviceID: PersistentIdentifier?

    private var boundAgents: [Persona] {
        personas.filter { $0.isLive && $0.device == device }
    }

    private var otherAgents: [Persona] {
        personas.filter { $0.isLive && $0.device != device }
    }

    var body: some View {
        if device.isLive {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    PhoneScreenView(device: device)
                        .id(device.persistentModelID)

                    InspectorSection("Connection") {
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                if device.connectionState == .pairing {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Circle()
                                        .fill(device.connectionState.color)
                                        .frame(width: 8, height: 8)
                                }
                                Text(device.connectionState.displayName)
                            }
                        }

                        HStack(spacing: 8) {
                            if device.isConnected {
                                Button("Disconnect") {
                                    deviceManager.disconnect(device)
                                }
                                if device.transport == .bluetoothHID {
                                    Button("Test Pointer Movement") {
                                        testedDeviceID = device.persistentModelID
                                        deviceManager.testControl(device)
                                    }
                                    .disabled(deviceManager.promptSession(for: device).isRunning)
                                }
                            } else {
                                Button("Connect") {
                                    deviceManager.connect(device)
                                }
                                .disabled(device.connectionState == .pairing)
                            }
                        }

                        if let error = deviceManager.connectionErrors[device.identifier] {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if testedDeviceID == device.persistentModelID {
                            Text("Check that the pointer moved on this iPhone.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    InspectorSection("iPhone Runner") {
                        Text(deviceManager.phoneRunners.status(for: device.identifier))
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry Runner") {
                            Task { await deviceManager.phoneRunners.retry(device.identifier) }
                        }
                        .disabled(deviceManager.promptSession(for: device).isRunning)
                    }

                    InspectorSection("Automation") {
                        Button("Test App Switcher") {
                            deviceManager.promptSession(for: device).submit(testAppSwitcher: true)
                        }
                        .disabled(!device.isConnected || deviceManager.promptSession(for: device).isRunning
                            || !deviceManager.promptSession(for: device).canUseScreen)
                        Text("Sends the App Switcher gesture, then verifies app preview cards on the next screenshot. See Agent for the result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Set Auto-Lock to Never") {
                            deviceManager.disableAutoLock(device)
                        }
                        .disabled(!device.isConnected || deviceManager.promptSession(for: device).isRunning)
                        Text("Keeps this iPhone unlocked so its screen and agent stay available. The phone’s Settings app is driven over Bluetooth to change it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let status = deviceManager.autoLockStatus {
                            Text(status)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    InspectorSection("Device") {
                        LabeledContent("Model", value: device.modelName)
                        LabeledContent("Connection", value: device.transport.displayName)
                        LabeledContent(device.transport.identifierLabel) {
                            Text(device.identifier)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let lastSeen = device.lastSeen {
                            LabeledContent("Last connected") {
                                Text(lastSeen, format: .dateTime.month().day().hour().minute())
                            }
                        }
                    }

                    InspectorSection("Agents") {
                        if boundAgents.isEmpty {
                            Text("No agents are bound to this device.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(boundAgents, id: \.persistentModelID) { persona in
                                if persona.isLive {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(persona.displayName)
                                            Text("@\(persona.handle)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Unbind") {
                                            deviceManager.unbind(persona)
                                        }
                                    }
                                }
                            }
                        }

                        if !otherAgents.isEmpty {
                            Menu("Bind Agent") {
                                ForEach(otherAgents, id: \.persistentModelID) { persona in
                                    if persona.isLive {
                                        Button("\(persona.displayName) (@\(persona.handle))") {
                                            deviceManager.bind(device, to: persona)
                                        }
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .labeledContentStyle(.inspector)
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }
}

struct InspectorLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.label
                .foregroundStyle(.secondary)
            configuration.content
        }
    }
}

extension LabeledContentStyle where Self == InspectorLabeledContentStyle {
    static var inspector: InspectorLabeledContentStyle { .init() }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

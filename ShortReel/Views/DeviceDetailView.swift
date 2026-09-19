import SwiftData
import SwiftUI

struct DeviceDetailView: View {
    let device: Device

    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Environment(DeviceManager.self) private var deviceManager
    @State private var testedDeviceID: PersistentIdentifier?

    private var boundAgents: [Account] {
        accounts.filter { $0.isLive && $0.device == device }
    }

    private var otherAgents: [Account] {
        accounts.filter { $0.isLive && $0.device != device }
    }

    var body: some View {
        if device.isLive {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                            .frame(width: 56)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                                .font(.title2.bold())
                                .textSelection(.enabled)
                            Text(device.modelName)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                PhoneScreenView(device: device)
                    .id(device.persistentModelID)

                Section("Connection") {
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

                    HStack {
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
                    }

                    if testedDeviceID == device.persistentModelID {
                        Text("Check that the pointer moved on this iPhone.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Device Information") {
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

                Section("Agents") {
                    if boundAgents.isEmpty {
                        Text("No agents are bound to this device.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(boundAgents, id: \.persistentModelID) { account in
                            if account.isLive {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.displayName)
                                        Text("@\(account.handle)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Unbind") {
                                        deviceManager.unbind(account)
                                    }
                                }
                            }
                        }
                    }

                    if !otherAgents.isEmpty {
                        Menu("Bind Agent") {
                            ForEach(otherAgents, id: \.persistentModelID) { account in
                                if account.isLive {
                                    Button("\(account.displayName) (@\(account.handle))") {
                                        deviceManager.bind(device, to: account)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

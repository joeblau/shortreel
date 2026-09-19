import SwiftData
import SwiftUI

/// Discover and pair a real Bluetooth device; its identity comes from the scan.
struct AddDeviceView: View {
    let defaultAccount: Account?
    @Environment(\.dismiss) private var dismiss
    @Environment(DeviceManager.self) private var deviceManager
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @State private var selection: String?
    @State private var boundAccount: Account?
    @State private var pairedDevice: Device?
    @State private var pin = ""
    @State private var setupTask: Task<Void, Never>?

    init(defaultAccount: Account?) {
        self.defaultAccount = defaultAccount
        _boundAccount = State(initialValue: defaultAccount)
    }

    private var discovery: BluetoothDiscovery { deviceManager.discovery }
    private var selectedDevice: DiscoveredBluetoothDevice? {
        discovery.devices.first { $0.id == selection }
    }
    private var selectedPhone: ConnectedUSBPhone? {
        deviceManager.phoneSetup.phones.first { "usb:\($0.id)" == selection }
    }
    private var isPreparing: Bool { deviceManager.phoneSetup.preparingIdentifier != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connect a Device").font(.title2.bold())
                Spacer()
                if discovery.isScanning { ProgressView().controlSize(.small) }
                Button(discovery.isScanning ? "Stop Scan" : "Scan Again") {
                    if discovery.isScanning { discovery.stopScan() }
                    else { deviceManager.scanForDevices() }
                }
                .disabled(discovery.pairingAddress != nil || pairedDevice != nil)
            }

            Text("Select your iPhone below. A USB cable lets ShortReel identify it and enable AssistiveTouch. For Bluetooth control, select this Mac in the iPhone’s AssistiveTouch › Devices › Bluetooth Devices settings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                if !deviceManager.phoneSetup.phones.isEmpty {
                    Section("Connected by USB") {
                        ForEach(deviceManager.phoneSetup.phones) { phone in
                            HStack {
                                Image(systemName: "iphone")
                                VStack(alignment: .leading) {
                                    Text(phone.name)
                                    Text(phone.trusted ? "Ready for Bluetooth setup" : "Trust this Mac on the iPhone to continue")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.tag("usb:\(phone.id)")
                        }
                    }
                }
                Section("Nearby") {
                    if !discovery.devices.contains(where: \.isNearby) {
                        Text(discovery.isScanning ? "Searching for nearby devices…" : "No nearby devices found.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(discovery.devices.filter(\.isNearby)) { device in
                        discoveryRow(device).tag(device.id)
                    }
                }
                let known = discovery.devices.filter { !$0.isNearby }
                if !known.isEmpty {
                    Section("Previously paired with this Mac") {
                        ForEach(known) { device in
                            discoveryRow(device).tag(device.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .disabled(discovery.pairingAddress != nil || pairedDevice != nil || isPreparing)

            Picker("Bind to account", selection: $boundAccount) {
                Text("None").tag(nil as Account?)
                ForEach(accounts.filter(\.isLive), id: \.persistentModelID) { account in
                    Text("@\(account.handle)").tag(account as Account?)
                }
            }
            .disabled(discovery.pairingAddress != nil || pairedDevice != nil)

            if let code = discovery.displayedPasskey {
                Text("Enter \(code) on your phone.").font(.title3.monospacedDigit())
            } else if discovery.needsPIN {
                HStack {
                    TextField("Device PIN", text: $pin)
                    Button("Submit PIN") { discovery.submitPIN(pin) }
                        .disabled(pin.isEmpty || pin.utf8.count > 16)
                }
            }

            if let error = discovery.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if let device = pairedDevice {
                if device.isConnected {
                    Label("\(device.name) is connected.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(deviceManager.connectionErrors[device.identifier] ?? "Bluetooth paired. To enable control, turn on AssistiveTouch on the iPhone and select this Mac under Devices › Bluetooth Devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(discovery.status).font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Button(pairedDevice == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isPreparing {
                    ProgressView().controlSize(.small)
                    Text("Setting up your iPhone…").foregroundStyle(.secondary)
                } else if discovery.pairingAddress != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel Pairing") { discovery.cancelPairing(); discovery.stopScan() }
                } else if pairedDevice == nil {
                    Button(selectedPhone != nil ? "Enable Control" : (selectedDevice?.isPaired == true ? "Connect" : "Pair & Connect")) {
                        if let selectedPhone {
                            setupTask = deviceManager.connectUSBPhone(selectedPhone, to: boundAccount) { pairedDevice = $0 }
                        } else if let selectedDevice {
                            deviceManager.pair(selectedDevice, to: boundAccount) { pairedDevice = $0 }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDevice == nil && selectedPhone == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 640)
        .onAppear { deviceManager.scanForDevices() }
        .task {
            while !Task.isCancelled {
                await deviceManager.phoneSetup.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onDisappear {
            setupTask?.cancel()
            discovery.cancelPairing()
            discovery.stopScan()
        }
    }

    private func discoveryRow(_ device: DiscoveredBluetoothDevice) -> some View {
        HStack {
            Image(systemName: "dot.radiowaves.left.and.right")
            VStack(alignment: .leading) {
                Text(device.name)
                Text(device.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if device.isPaired { Text("Paired").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
    }
}

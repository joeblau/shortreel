import SwiftData
import SwiftUI

/// Sheet for registering a phone the agents can control.
struct AddDeviceView: View {
    let defaultAccount: Account?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(DeviceManager.self) private var deviceManager

    @Query(sort: \Account.createdAt) private var accounts: [Account]

    @State private var name = ""
    @State private var modelName = ""
    @State private var transport: DeviceTransport = .bluetoothHID
    @State private var identifier = ""
    @State private var boundAccount: Account?
    @State private var connectNow = true

    init(defaultAccount: Account?) {
        self.defaultAccount = defaultAccount
        _boundAccount = State(initialValue: defaultAccount)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var pairingHint: String {
        switch transport {
        case .bluetoothHID:
            "Engage exposes this Mac as a Bluetooth mouse and keyboard. On the iPhone, open Settings › Accessibility › Touch › AssistiveTouch › Devices › Bluetooth Devices and pair with this Mac. Leave the address blank to fill it in when the phone pairs."
        case .usb:
            "Plug the iPhone in and tap Trust. Engage uses the USB session to turn on AssistiveTouch and mirror the screen. Leave the UDID blank to read it from the device."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Device name", text: $name, prompt: Text("e.g. Joe's iPhone 16 Pro"))
                TextField("Model", text: $modelName, prompt: Text("e.g. iPhone 16 Pro"))
                Picker("Transport", selection: $transport) {
                    ForEach(DeviceTransport.allCases, id: \.self) { transport in
                        Label(transport.displayName, systemImage: transport.symbolName).tag(transport)
                    }
                }
                TextField(transport.identifierLabel, text: $identifier, prompt: Text("optional"))
                Picker("Bind to account", selection: $boundAccount) {
                    Text("None").tag(nil as Account?)
                    ForEach(accounts, id: \.persistentModelID) { account in
                        Text("@\(account.handle)").tag(account as Account?)
                    }
                }
                Toggle("Connect after adding", isOn: $connectNow)

                Section("Pairing") {
                    Text(pairingHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Device") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 440, height: 500)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespaces)
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespaces)

        let device = Device(
            name: trimmedName,
            modelName: trimmedModel.isEmpty ? "iPhone" : trimmedModel,
            transport: transport,
            identifier: trimmedIdentifier.isEmpty ? Self.placeholderIdentifier(for: transport) : trimmedIdentifier
        )
        modelContext.insert(device)
        if let boundAccount {
            deviceManager.bind(device, to: boundAccount)
        }
        try? modelContext.save()

        if connectNow {
            deviceManager.connect(device)
        }
        dismiss()
    }

    /// Stands in until the real host learns the address from the pairing.
    private static func placeholderIdentifier(for transport: DeviceTransport) -> String {
        switch transport {
        case .bluetoothHID:
            (0..<6).map { _ in String(format: "%02X", Int.random(in: 0...255)) }.joined(separator: ":")
        case .usb:
            "pending-\(UUID().uuidString.prefix(8).lowercased())"
        }
    }
}

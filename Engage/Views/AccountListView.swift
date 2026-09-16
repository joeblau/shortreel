import SwiftData
import SwiftUI

struct AccountListView: View {
    @Binding var selection: PersistentIdentifier?

    @Query(sort: \Farm.createdAt) private var farms: [Farm]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Environment(\.modelContext) private var modelContext
    @Environment(WarmUpAgent.self) private var agent

    @State private var farmSheet: FarmSheet?
    @State private var farmPendingDeletion: Farm?
    @State private var showAddAccount = false

    private var selectedAccount: Account? {
        guard let selection else { return nil }
        return accounts.first { $0.persistentModelID == selection }
    }

    private var farmlessAccounts: [Account] {
        accounts.filter { $0.farm == nil }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(farms) { farm in
                Section {
                    ForEach(farm.accounts.sorted { $0.createdAt < $1.createdAt }, id: \.persistentModelID) { account in
                        accountRow(account)
                    }
                } header: {
                    Text(farm.name)
                        .contextMenu {
                            Button {
                                farmSheet = FarmSheet(farm: farm)
                            } label: {
                                Label("Rename Farm", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                farmPendingDeletion = farm
                            } label: {
                                Label("Delete Farm", systemImage: "trash")
                            }
                        }
                }
            }

            if !farmlessAccounts.isEmpty {
                Section("No Farm") {
                    ForEach(farmlessAccounts, id: \.persistentModelID) { account in
                        accountRow(account)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Engage")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showAddAccount = true
                } label: {
                    Label("Add Agent", systemImage: "plus")
                }
                .help("Add Agent")
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountView(defaultFarm: selectedAccount?.farm)
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            Button {
                farmSheet = FarmSheet(farm: nil)
            } label: {
                Label("Add Farm", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(item: $farmSheet) { sheet in
            FarmNameSheet(farm: sheet.farm)
        }
        .alert(
            "Delete Farm?",
            isPresented: Binding(
                get: { farmPendingDeletion != nil },
                set: { if !$0 { farmPendingDeletion = nil } }
            ),
            presenting: farmPendingDeletion
        ) { farm in
            Button("Delete", role: .destructive) {
                delete(farm)
            }
            Button("Cancel", role: .cancel) {}
        } message: { farm in
            Text("This deletes “\(farm.name)” and its \(farm.accounts.count) account(s), along with all of their timeline events and social links.")
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account) -> some View {
        AccountRow(account: account, isAgentRunning: agent.isRunning(account))
            .tag(account.persistentModelID)
            .contextMenu {
                Button {
                    agent.isPaused(account) ? agent.resume(account: account) : agent.pause(account: account)
                } label: {
                    Label(
                        agent.isPaused(account) ? "Resume Agent" : "Pause Agent",
                        systemImage: agent.isPaused(account) ? "play.fill" : "pause.fill"
                    )
                }
                Divider()
                Button(role: .destructive) {
                    delete(account)
                } label: {
                    Label("Delete Account", systemImage: "trash")
                }
            }
    }

    private func delete(_ account: Account) {
        agent.stop(account: account)
        if selection == account.persistentModelID {
            selection = nil
        }
        modelContext.delete(account)
        try? modelContext.save()
    }

    private func delete(_ farm: Farm) {
        for account in farm.accounts {
            agent.stop(account: account)
            if selection == account.persistentModelID {
                selection = nil
            }
        }
        modelContext.delete(farm)
        try? modelContext.save()
    }
}

// MARK: - Farm name sheet (add / rename)

private struct FarmSheet: Identifiable {
    let id = UUID()
    let farm: Farm?
}

private struct FarmNameSheet: View {
    let farm: Farm?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(farm: Farm?) {
        self.farm = farm
        _name = State(initialValue: farm?.name ?? "")
    }

    private var isNew: Bool { farm == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Farm" : "Rename Farm")
                .font(.headline)
            TextField("Farm name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let farm {
            farm.name = trimmed
        } else {
            modelContext.insert(Farm(name: trimmed))
        }
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Account row

private struct AccountRow: View {
    let account: Account
    let isAgentRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 32, height: 32)
                Text(account.initials)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("@\(account.handle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(account.boundDeviceName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(isAgentRunning ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
                .help(isAgentRunning ? "Agent running" : "Agent idle")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add account sheet

private struct AddAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Farm.createdAt) private var farms: [Farm]
    @Query(sort: \Device.createdAt) private var devices: [Device]

    @State private var displayName = ""
    @State private var handle = ""
    @State private var narrative = ""
    @State private var selectedFarm: Farm?
    @State private var selectedDevice: Device?

    init(defaultFarm: Farm?) {
        _selectedFarm = State(initialValue: defaultFarm)
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !handle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Display name", text: $displayName)
                TextField("Handle (without @)", text: $handle)
                if devices.isEmpty {
                    LabeledContent("Device") {
                        Text("None yet — use Add Device in the toolbar")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Device", selection: $selectedDevice) {
                        Text("None").tag(nil as Device?)
                        ForEach(devices, id: \.persistentModelID) { device in
                            Text(device.name).tag(device as Device?)
                        }
                    }
                }
                if farms.isEmpty {
                    LabeledContent("Farm") {
                        Text("Farm 1 (will be created)")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Farm", selection: $selectedFarm) {
                        ForEach(farms) { farm in
                            Text(farm.name).tag(farm as Farm?)
                        }
                    }
                }
                Section("Warm-up narrative") {
                    TextEditor(text: $narrative)
                        .frame(minHeight: 90)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Agent") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 420, height: 460)
        .onAppear {
            if selectedFarm == nil {
                selectedFarm = farms.first
            }
        }
    }

    private func save() {
        let account = Account(
            handle: handle.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "@")),
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            deviceName: selectedDevice?.name ?? "No device",
            narrative: narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let farm: Farm
        if let selectedFarm {
            farm = selectedFarm
        } else {
            let newFarm = Farm(name: "Farm 1")
            modelContext.insert(newFarm)
            farm = newFarm
        }
        account.farm = farm
        account.device = selectedDevice
        modelContext.insert(account)
        try? modelContext.save()
        dismiss()
    }
}

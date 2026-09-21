import SwiftData
import SwiftUI

struct ContentView: View {
    @Query(sort: \Persona.createdAt) private var personas: [Persona]
    @State private var selectedSection: Section = .devices
    @State private var showAddDevice = false
    @State private var showAddPersona = false
    @State private var selectedPersonaID: PersistentIdentifier?
    @State private var showPersonaInspector = false

    private enum Section: String, CaseIterable, Identifiable {
        case devices = "Devices"
        case personas = "Personas"

        var id: Self { self }
    }

    var body: some View {
        Group {
            switch selectedSection {
            case .devices:
                DeviceGalleryView {
                    showAddDevice = true
                }
            case .personas:
                personasView
            }
        }
        .navigationTitle("ShortReel")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $selectedSection) {
                    ForEach(Section.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if selectedSection == .personas {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddPersona = true
                    } label: {
                        Label("Add Persona", systemImage: "plus")
                    }
                    .help("Add Persona")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if !showPersonaInspector, selectedPersonaID == nil {
                            selectedPersonaID = personas.first { $0.isLive }?.persistentModelID
                        }
                        showPersonaInspector.toggle()
                    } label: {
                        Label(showPersonaInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(showPersonaInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
                }
            }
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceView(defaultPersona: personas.first { $0.isLive && $0.persistentModelID == selectedPersonaID }
                ?? personas.first { $0.isLive })
        }
        .sheet(isPresented: $showAddPersona) {
            AddPersonaView()
        }
    }

    private var personasView: some View {
        let livePersonas = personas.filter(\.isLive)

        return Group {
            if livePersonas.isEmpty {
                ContentUnavailableView(
                    "No Personas",
                    systemImage: "person.crop.circle",
                    description: Text("Your saved personas will appear here.")
                )
            } else {
                Table(livePersonas, selection: $selectedPersonaID) {
                    TableColumn("Name", value: \Persona.displayName)
                    TableColumn("Network") { persona in
                        Text(persona.network.displayName)
                    }
                    TableColumn("Handle", value: \Persona.handle)
                    TableColumn("Device") { persona in
                        Text(persona.boundDeviceName.isEmpty ? "Unassigned" : persona.boundDeviceName)
                    }
                    TableColumn("Status") { persona in
                        Text(persona.isActive ? "Active" : "Paused")
                            .foregroundStyle(persona.isActive ? .primary : .secondary)
                    }
                }
            }
        }
        .onChange(of: selectedPersonaID) { _, selection in
            showPersonaInspector = selection != nil
        }
        .onChange(of: showPersonaInspector) { _, presented in
            if !presented { selectedPersonaID = nil }
        }
        .onChange(of: livePersonas.map(\.persistentModelID)) { _, ids in
            if let selectedPersonaID, !ids.contains(selectedPersonaID) {
                self.selectedPersonaID = nil
            }
        }
        .inspector(isPresented: $showPersonaInspector) {
            Group {
                if let persona = livePersonas.first(where: { $0.persistentModelID == selectedPersonaID }) {
                    PersonaInspector(persona: persona) {
                        showAddDevice = true
                    }
                        .id(persona.persistentModelID)
                } else {
                    ContentUnavailableView("No Persona Selected", systemImage: "person.crop.circle", description: Text("Select a persona to configure it."))
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
        }
    }
}

private struct PersonaInspector: View {
    @Bindable var persona: Persona
    var onConnectDevice: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(WarmUpAgent.self) private var agent
    @Query(sort: \Device.createdAt) private var devices: [Device]
    @State private var saveError: String?

    var body: some View {
        if persona.isLive {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Persona")
                        .font(.headline)
                        .padding(16)

                    InspectorSection("Identity") {
                        Picker("Network", selection: $persona.network) {
                            ForEach(Persona.networks, id: \.self) { network in
                                Text(network.displayName).tag(network)
                            }
                        }
                        TextField("Name", text: $persona.displayName)
                        TextField("Handle", text: $persona.handle)
                    }

                    InspectorSection("Personality") {
                        Text("Describe this persona’s interests, voice, and goals.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("Persona description", text: $persona.narrative, axis: .vertical)
                            .lineLimit(6...16)
                    }

                    InspectorSection("Device") {
                        Picker("Assigned device", selection: $persona.device) {
                            Text("Unassigned").tag(nil as Device?)
                            ForEach(devices.filter(\.isLive), id: \.persistentModelID) { device in
                                Text(device.name).tag(device as Device?)
                            }
                        }
                        .labelsHidden()
                        if !devices.contains(where: \.isLive) {
                            Text("Connect an iPhone to assign it to this persona.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Connect iPhone", action: onConnectDevice)
                        }
                    }

                    InspectorSection("Activity") {
                        Toggle("Active", isOn: $persona.isActive)
                        Text("Changes are saved automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let saveError {
                        InspectorSection("Couldn’t Save Changes") {
                            Text(saveError)
                                .font(.callout)
                                .foregroundStyle(.red)
                            Button("Retry", action: save)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            .onChange(of: [persona.displayName, persona.handle, persona.narrative, persona.networkRawValue]) { _, _ in
                save()
            }
            .onChange(of: persona.device?.persistentModelID) { _, _ in
                persona.deviceName = persona.device?.name ?? ""
                save()
            }
            .onChange(of: persona.isActive) { _, active in
                if active { agent.resume(persona: persona) }
                else { agent.pause(persona: persona) }
                save()
            }
        }
    }

    private func save() {
        guard persona.isLive else { return }
        do {
            try modelContext.save()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct AddPersonaView: View {
    var onCreated: (Persona) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Device.createdAt) private var devices: [Device]
    @State private var displayName = ""
    @State private var handle = ""
    @State private var narrative = ""
    @State private var network: Platform = .instagram
    @State private var device: Device?
    @State private var saveError: String?
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHandle: String {
        String(handle.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Persona")
                .font(.title2.bold())

            Form {
                Picker("Network", selection: $network) {
                    ForEach(Persona.networks, id: \.self) { network in
                        Text(network.displayName).tag(network)
                    }
                }
                TextField("Name", text: $displayName)
                    .focused($isNameFocused)
                TextField("Handle", text: $handle)
                Picker("Device", selection: $device) {
                    Text("Unassigned").tag(nil as Device?)
                    ForEach(devices.filter(\.isLive), id: \.persistentModelID) { device in
                        Text(device.name).tag(device as Device?)
                    }
                }
                TextField("Persona", text: $narrative, axis: .vertical)
                    .lineLimit(4...6)
                    .help("Describe this persona’s interests, voice, and goals.")
            }
            .textFieldStyle(.roundedBorder)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Persona", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || trimmedHandle.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { isNameFocused = true }
    }

    private func save() {
        guard !trimmedName.isEmpty, !trimmedHandle.isEmpty else { return }
        let selectedDevice = device.flatMap { $0.isLive ? $0 : nil }
        let persona = Persona(
            handle: trimmedHandle,
            displayName: trimmedName,
            deviceName: selectedDevice?.name ?? "",
            narrative: narrative.trimmingCharacters(in: .whitespacesAndNewlines),
            network: network
        )
        modelContext.insert(persona)
        persona.device = selectedDevice

        do {
            try modelContext.save()
            onCreated(persona)
            dismiss()
        } catch {
            modelContext.delete(persona)
            saveError = "Couldn’t save the persona. \(error.localizedDescription)"
        }
    }
}

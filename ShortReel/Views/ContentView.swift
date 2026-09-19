import SwiftData
import SwiftUI

struct ContentView: View {
    private enum Section: String, CaseIterable {
        case agents = "Agents"
        case devices = "Devices"
    }

    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \Device.createdAt) private var devices: [Device]
    @Environment(WarmUpAgent.self) private var agent

    @State private var section: Section = .agents
    @State private var accountSelection: PersistentIdentifier?
    @State private var deviceSelection: PersistentIdentifier?
    @State private var showAddDevice = false
    @State private var deviceSetupAccountID: PersistentIdentifier?
    @State private var inspectorVisible = true
    @State private var deviceInspectorVisible = true

    private var selectedAccount: Account? {
        guard let accountSelection else { return nil }
        return accounts.first { $0.isLive && $0.persistentModelID == accountSelection }
    }

    private var selectedDevice: Device? {
        guard let deviceSelection else { return nil }
        return devices.first { $0.isLive && $0.persistentModelID == deviceSelection }
    }

    private var currentInspectorVisible: Binding<Bool> {
        Binding(
            get: { section == .agents ? inspectorVisible : deviceInspectorVisible },
            set: {
                if section == .agents { inspectorVisible = $0 }
                else { deviceInspectorVisible = $0 }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            Group {
                switch section {
                case .agents:
                    AccountListView(selection: $accountSelection)
                case .devices:
                    DeviceListView(selection: $deviceSelection) {
                        openDeviceSetup()
                    }
                }
            }
            .navigationTitle("ShortReel")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            switch section {
            case .agents:
                agentDetail
            case .devices:
                deviceDetail
            }
        }
        .inspector(isPresented: currentInspectorVisible) {
            switch section {
            case .agents:
                InspectorView(account: selectedAccount) {
                    let account = selectedAccount
                    section = .devices
                    openDeviceSetup(for: account)
                } onShowDevice: { device in
                    deviceSelection = device.persistentModelID
                    section = .devices
                }
            case .devices:
                DeviceInspectorView(device: selectedDevice)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Agents or Devices")
            }

            if section == .agents {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        agent.isRunning ? agent.stop() : agent.start()
                    } label: {
                        Label(
                            agent.isRunning ? "Pause All Agents" : "Start All Agents",
                            systemImage: agent.isRunning ? "pause.fill" : "play.fill"
                        )
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openDeviceSetup()
                    } label: {
                        Label("Connect iPhone", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    currentInspectorVisible.wrappedValue.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(section == .devices ? "Show or hide the device inspector" : "Show or hide the agent inspector")
            }
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceView(defaultAccount: accounts.first {
                $0.isLive && $0.persistentModelID == deviceSetupAccountID
            })
        }
    }

    @ViewBuilder
    private var agentDetail: some View {
        if let account = selectedAccount {
            VStack(spacing: 0) {
                NarrativeHeaderView(account: account)
                Divider()
                TimelineView(account: account)
            }
        } else {
            ContentUnavailableView {
                Label("No Agent Selected", systemImage: "person.crop.circle")
            } description: {
                Text("Select an agent in the sidebar, or add a new one to get started.")
            }
        }
    }

    @ViewBuilder
    private var deviceDetail: some View {
        DeviceGalleryView(selection: $deviceSelection) {
            openDeviceSetup()
        }
    }

    private func openDeviceSetup(for account: Account? = nil) {
        deviceSetupAccountID = account?.persistentModelID
        showAddDevice = true
    }
}

import SwiftData
import SwiftUI

struct ContentView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Environment(WarmUpAgent.self) private var agent

    @State private var selection: PersistentIdentifier?
    @State private var showAddDevice = false
    @State private var inspectorVisible = true

    private var selectedAccount: Account? {
        guard let selection else { return nil }
        return accounts.first { $0.persistentModelID == selection }
    }

    var body: some View {
        NavigationSplitView {
            AccountListView(selection: $selection)
        } detail: {
            if let account = selectedAccount {
                VStack(spacing: 0) {
                    NarrativeHeaderView(account: account)
                    Divider()
                    TimelineView(account: account)
                }
            } else {
                ContentUnavailableView {
                    Label("No Account Selected", systemImage: "iphone")
                } description: {
                    Text("Select an account in the sidebar, or create a new one to start warming it up.")
                }
            }
        }
        .inspector(isPresented: $inspectorVisible) {
            InspectorView(account: selectedAccount) {
                showAddDevice = true
            }
        }
        .toolbar {
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddDevice = true
                } label: {
                    Label("Add Device", systemImage: "iphone.gen3")
                        .labelStyle(.titleAndIcon)
                }
                .help("Add Device")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceView(defaultAccount: selectedAccount)
        }
    }
}

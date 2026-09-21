import SwiftData
import SwiftUI

@main
struct ShortReelApp: App {
    @NSApplicationDelegateAdaptor(ShortReelAppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var agent: WarmUpAgent
    @State private var deviceManager: DeviceManager

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Persona.self, SocialLink.self, TimelineEvent.self, Farm.self, Device.self, WarmUpPlan.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let cleanupKey = "didRemoveSamplePersonasV1"
        if !UserDefaults.standard.bool(forKey: cleanupKey) {
            do {
                try LegacySamplePersonaCleanup.remove(in: container.mainContext)
                UserDefaults.standard.set(true, forKey: cleanupKey)
            } catch {
                fatalError("Failed to remove sample personas: \(error)")
            }
        }
        self.container = container
        _agent = State(initialValue: WarmUpAgent(container: container))
        _deviceManager = State(initialValue: DeviceManager(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(agent)
                .environment(deviceManager)
                .onAppear {
                    appDelegate.shutdown = {
                        agent.stop()
                        await deviceManager.shutdown()
                    }
                    deviceManager.start()
                    agent.start()
                }
        }
        .modelContainer(container)
    }

}

@MainActor
final class ShortReelAppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (() async -> Void)?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateNow }
        if !terminating {
            terminating = true
            Task {
                await shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

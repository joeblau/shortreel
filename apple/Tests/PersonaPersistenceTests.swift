// From apple/: swiftc ShortReel/Models/*.swift ShortReel/Services/DeviceHost.swift
// ShortReel/Services/DevicePrompts/{WarmUpPlaybook,DeviceWorkflow,DevicePromptPlanner,DevicePromptPlan}.swift Tests/PersonaPersistenceTests.swift
// -o /tmp/shortreel-persona-tests && /tmp/shortreel-persona-tests
import Foundation
import SwiftData

@main
struct PersonaPersistenceTests {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Persona.self, Device.self, SocialLink.self, TimelineEvent.self, Farm.self, WarmUpPlan.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("test.store"))
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let device = Device(name: "Real phone", modelName: "iPhone", transport: .bluetoothHID, identifier: "test-phone")
        context.insert(device)
        let real = Persona(handle: "real.creator", displayName: "Real Creator", deviceName: "", narrative: "Real persona", network: .tikTok)
        context.insert(real)
        real.personalityBrief = "Curious creator with a dry sense of humor."
        real.device = device
        let customized = Persona(handle: "maya.shoots", displayName: "Custom Creator", deviceName: "", narrative: "Customized")
        context.insert(customized)
        for (handle, name) in [("maya.shoots", "Maya Chen"), ("dre.wears", "Andre Wilson"), ("priya.eats", "Priya Nair")] {
            let sample = Persona(handle: handle, displayName: name, deviceName: "", narrative: "Sample")
            context.insert(sample)
            sample.device = device
            let link = SocialLink(platform: .instagram, profileURL: URL(string: "https://example.com/profile")!, handle: handle, persona: sample)
            context.insert(link)
            sample.socialLinks = [link]
            let event = TimelineEvent(kind: .like, detail: "Sample", platform: .instagram, persona: sample)
            context.insert(event)
            sample.events = [event]
            context.insert(WarmUpPlan(platform: .instagram, persona: sample))
        }
        context.insert(WarmUpPlan(platform: .tikTok, persona: real))
        try context.save()
        try LegacySamplePersonaCleanup.remove(in: context)

        let reader = ModelContext(container)
        let remaining = try reader.fetch(FetchDescriptor<Persona>())
        precondition(Set(remaining.map(\.displayName)) == ["Real Creator", "Custom Creator"])
        let savedReal = remaining.first { $0.handle == "real.creator" }!
        precondition(savedReal.network == .tikTok)
        precondition(savedReal.personalityBrief == "Curious creator with a dry sense of humor.")
        precondition(savedReal.boundDeviceName == "Real phone")
        let deviceCount = try reader.fetchCount(FetchDescriptor<Device>())
        let linkCount = try reader.fetchCount(FetchDescriptor<SocialLink>())
        let eventCount = try reader.fetchCount(FetchDescriptor<TimelineEvent>())
        let plans = try reader.fetch(FetchDescriptor<WarmUpPlan>())
        precondition(deviceCount == 1 && linkCount == 0 && eventCount == 0)
        precondition(plans.count == 1 && plans.first?.persona?.handle == "real.creator")

        for network in Persona.networks {
            savedReal.network = network
            try reader.save()
            let reloaded = try ModelContext(container).fetch(FetchDescriptor<Persona>())
            precondition(reloaded.first { $0.handle == "real.creator" }?.network == network)
        }
        try LegacySamplePersonaCleanup.remove(in: reader)
        let finalCount = try reader.fetchCount(FetchDescriptor<Persona>())
        precondition(finalCount == 2)
        print("Persona persistence tests passed: sample cleanup, related data, device preservation, and all four networks.")
    }
}

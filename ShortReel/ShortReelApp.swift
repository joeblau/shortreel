import SwiftData
import SwiftUI

@main
struct ShortReelApp: App {
    private let container: ModelContainer
    @State private var agent: WarmUpAgent
    @State private var deviceManager: DeviceManager

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Account.self, SocialLink.self, TimelineEvent.self, Farm.self, Device.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        Self.seedIfNeeded(in: container)
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
                    deviceManager.start()
                    agent.start()
                }
        }
        .modelContainer(container)
    }

    // MARK: - Seed data

    private static func seedIfNeeded(in container: ModelContainer) {
        let context = container.mainContext
        let existing = (try? context.fetchCount(FetchDescriptor<Account>())) ?? 0
        guard existing == 0 else { return }

        let maya = Account(
            handle: "maya.shoots",
            displayName: "Maya Chen",
            deviceName: "Joe's iPhone 16 Pro",
            narrative: "Maya is an amateur landscape and street photographer. She searches for photography hashtags, follows photographers whose work she admires, likes well-composed shots, and occasionally comments on editing techniques. She watches stories from camera gear reviewers."
        )
        maya.socialLinks = [
            SocialLink(platform: .instagram, profileURL: URL(string: "https://instagram.com/maya.shoots")!, handle: "maya.shoots", account: maya),
            SocialLink(platform: .threads, profileURL: URL(string: "https://threads.net/@maya.shoots")!, handle: "maya.shoots", account: maya),
            SocialLink(platform: .youtube, profileURL: URL(string: "https://youtube.com/@mayashoots")!, handle: "mayashoots", account: maya),
        ]

        let dre = Account(
            handle: "dre.wears",
            displayName: "Andre Wilson",
            deviceName: "Joe's iPhone 15",
            narrative: "Andre is into streetwear and fashion design. He saves outfit inspiration posts, likes new sneaker drops, follows small independent fashion labels, and engages with design community posts to grow his presence."
        )
        dre.socialLinks = [
            SocialLink(platform: .instagram, profileURL: URL(string: "https://instagram.com/dre.wears")!, handle: "dre.wears", account: dre),
            SocialLink(platform: .tikTok, profileURL: URL(string: "https://tiktok.com/@dre.wears")!, handle: "dre.wears", account: dre),
            SocialLink(platform: .x, profileURL: URL(string: "https://x.com/drewears")!, handle: "drewears", account: dre),
        ]

        let priya = Account(
            handle: "priya.eats",
            displayName: "Priya Nair",
            deviceName: "Joe's iPhone 16e",
            narrative: "Priya documents home cooking and food travel. She searches for regional recipes, saves cooking technique videos, watches stories from food bloggers, and follows restaurants in cities she plans to visit."
        )
        priya.socialLinks = [
            SocialLink(platform: .instagram, profileURL: URL(string: "https://instagram.com/priya.eats")!, handle: "priya.eats", account: priya),
            SocialLink(platform: .tikTok, profileURL: URL(string: "https://tiktok.com/@priya.eats")!, handle: "priya.eats", account: priya),
        ]

        for account in [maya, dre, priya] {
            context.insert(account)
            for link in account.socialLinks {
                context.insert(link)
            }
        }

        let photographyFarm = Farm(name: "Photography Creators")
        let lifestyleFarm = Farm(name: "Lifestyle Brands")
        context.insert(photographyFarm)
        context.insert(lifestyleFarm)
        maya.farm = photographyFarm
        dre.farm = lifestyleFarm
        priya.farm = lifestyleFarm

        try? context.save()
    }

}

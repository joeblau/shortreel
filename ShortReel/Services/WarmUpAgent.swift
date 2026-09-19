import Foundation
import Observation
import SwiftData

/// Schedules and executes warm-up interactions for every active account.
/// One `Task` per running account; each loop iteration plans an interaction
/// (weighted by keywords in the account's narrative), records it in SwiftData
/// as it moves through scheduled → inProgress → completed/failed, then sleeps
/// a randomized demo-friendly interval before planning the next one.
@Observable
@MainActor
final class WarmUpAgent {
    private let container: ModelContainer
    private let controller: any DeviceControlling

    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var pausedIDs: Set<PersistentIdentifier> = []

    private(set) var isRunning = false
    private(set) var runningAccountIDs: Set<PersistentIdentifier> = []

    init(container: ModelContainer, controller: (any DeviceControlling)? = nil) {
        self.container = container
        self.controller = controller ?? SimulatedDeviceController()
    }

    private var context: ModelContext { container.mainContext }

    // MARK: - Global control

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        for account in accounts where account.isActive && !pausedIDs.contains(account.persistentModelID) {
            startLoop(for: account.persistentModelID)
        }
    }

    func stop() {
        isRunning = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        runningAccountIDs.removeAll()
    }

    // MARK: - Per-account control

    func isPaused(_ account: Account) -> Bool {
        pausedIDs.contains(account.persistentModelID)
    }

    func isRunning(_ account: Account) -> Bool {
        runningAccountIDs.contains(account.persistentModelID)
    }

    func pause(account: Account) {
        pausedIDs.insert(account.persistentModelID)
        stopLoop(for: account.persistentModelID)
    }

    func resume(account: Account) {
        pausedIDs.remove(account.persistentModelID)
        if isRunning {
            startLoop(for: account.persistentModelID)
        }
    }

    /// Call before deleting an account so its loop never touches dead objects.
    func stop(account: Account) {
        stopLoop(for: account.persistentModelID)
    }

    // MARK: - Loops

    private func startLoop(for id: PersistentIdentifier) {
        guard tasks[id] == nil else { return }
        runningAccountIDs.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.runLoop(accountID: id)
        }
    }

    private func stopLoop(for id: PersistentIdentifier) {
        tasks[id]?.cancel()
        tasks[id] = nil
        runningAccountIDs.remove(id)
    }

    private func runLoop(accountID: PersistentIdentifier) async {
        defer {
            tasks[accountID] = nil
            runningAccountIDs.remove(accountID)
        }
        while !Task.isCancelled {
            // Re-resolve the account every iteration: it may have been deleted.
            guard let account = fetchAccount(accountID) else { break }

            let plan = nextInteraction(for: account)
            let event = TimelineEvent(
                kind: plan.kind,
                detail: "Planning: \(plan.kind.label.lowercased()) on \(plan.platform.displayName)",
                status: .scheduled,
                platform: plan.platform,
                account: account
            )
            context.insert(event)
            try? context.save()

            do {
                try await Task.sleep(for: .seconds(Double.random(in: 5...20)))
            } catch {
                break // cancelled while waiting
            }
            guard !Task.isCancelled, fetchAccount(accountID) != nil else { break }

            event.status = .inProgress
            try? context.save()

            if let device = account.device, !device.isConnected {
                event.detail = "\(plan.kind.label) skipped — \(device.name) is not connected"
                event.status = .failed
                try? context.save()
                continue
            }

            let action = DeviceAction(
                kind: plan.kind,
                platform: plan.platform,
                accountHandle: account.handle,
                keyword: plan.keyword
            )
            do {
                let result = try await controller.perform(action, on: account)
                guard fetchAccount(accountID) != nil else { break }
                event.detail = result
                event.status = .completed
            } catch is CancellationError {
                break
            } catch {
                guard fetchAccount(accountID) != nil else { break }
                event.detail = "\(plan.kind.label) failed on \(account.boundDeviceName) — will retry later"
                event.status = .failed
            }
            try? context.save()
        }
    }

    /// Fetch by identity rather than holding a model reference across awaits,
    /// so a deleted account can never be dereferenced.
    private func fetchAccount(_ id: PersistentIdentifier) -> Account? {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        return accounts.first { $0.persistentModelID == id }
    }

    // MARK: - Interaction planning

    private struct PlannedInteraction {
        var kind: InteractionKind
        var platform: Platform
        var keyword: String
    }

    private func nextInteraction(for account: Account) -> PlannedInteraction {
        let kind = weightedKind(for: account.narrative)
        let platform = account.socialLinks.map(\.platform).randomElement() ?? Platform.allCases.randomElement()!
        let keywords = Self.keywords(in: account.narrative)
        let keyword = keywords.randomElement() ?? "explore"
        return PlannedInteraction(kind: kind, platform: platform, keyword: keyword)
    }

    private func weightedKind(for narrative: String) -> InteractionKind {
        var weights: [InteractionKind: Int] = [
            .scrollFeed: 4, .like: 4, .viewStory: 3,
            .savePost: 2, .search: 2, .follow: 2, .comment: 1,
        ]
        let text = narrative.lowercased()
        let boosts: [(trigger: String, kind: InteractionKind, boost: Int)] = [
            ("photograph", .search, 3), ("photograph", .follow, 2), ("photo", .like, 1),
            ("design", .savePost, 3), ("design", .like, 2),
            ("art", .savePost, 2), ("aesthetic", .savePost, 2),
            ("fitness", .follow, 3), ("gym", .follow, 2),
            ("food", .savePost, 2), ("food", .search, 2), ("cook", .savePost, 2),
            ("travel", .viewStory, 3), ("travel", .search, 1),
            ("tech", .search, 2), ("code", .comment, 2),
            ("fashion", .like, 2), ("fashion", .savePost, 2), ("streetwear", .like, 2),
            ("music", .viewStory, 2),
            ("comment", .comment, 3), ("engage", .comment, 2), ("engage", .like, 2),
            ("follow", .follow, 3), ("grow", .follow, 2),
            ("story", .viewStory, 3), ("stories", .viewStory, 2),
        ]
        for boost in boosts where text.contains(boost.trigger) {
            weights[boost.kind, default: 0] += boost.boost
        }

        let total = weights.values.reduce(0, +)
        var roll = Int.random(in: 0..<total)
        for (kind, weight) in weights {
            roll -= weight
            if roll < 0 { return kind }
        }
        return .scrollFeed
    }

    private static let stopWords: Set<String> = [
        "with", "from", "that", "this", "their", "about", "into", "your", "yours",
        "them", "they", "then", "than", "will", "would", "should", "could", "have",
        "has", "and", "the", "for", "are", "who", "what", "when", "where", "over",
        "under", "while", "through", "daily", "posts", "post", "content", "account",
        "profile", "like", "likes", "follow", "follows", "followers", "community",
    ]

    /// Significant words in the narrative, reused as hashtags/search terms.
    private static func keywords(in narrative: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in narrative.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let word = String(word)
            guard word.count > 3, !stopWords.contains(word), !seen.contains(word) else { continue }
            seen.insert(word)
            result.append(word)
        }
        return result
    }
}

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class WarmUpAgent {
    private let container: ModelContainer
    private let controller: any DeviceControlling

    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var pausedIDs: Set<PersistentIdentifier> = []

    private(set) var isRunning = false
    private(set) var runningPersonaIDs: Set<PersistentIdentifier> = []

    init(container: ModelContainer, controller: (any DeviceControlling)? = nil) {
        self.container = container
        self.controller = controller ?? SimulatedDeviceController()
    }

    private var context: ModelContext { container.mainContext }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let personas = (try? context.fetch(FetchDescriptor<Persona>())) ?? []
        for persona in personas where persona.isActive && !pausedIDs.contains(persona.persistentModelID) {
            startLoop(for: persona.persistentModelID)
        }
    }

    func stop() {
        isRunning = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        runningPersonaIDs.removeAll()
    }

    func isPaused(_ persona: Persona) -> Bool {
        pausedIDs.contains(persona.persistentModelID)
    }

    func isRunning(_ persona: Persona) -> Bool {
        runningPersonaIDs.contains(persona.persistentModelID)
    }

    func pause(persona: Persona) {
        pausedIDs.insert(persona.persistentModelID)
        stopLoop(for: persona.persistentModelID)
    }

    func resume(persona: Persona) {
        pausedIDs.remove(persona.persistentModelID)
        if isRunning {
            startLoop(for: persona.persistentModelID)
        }
    }

    func stop(persona: Persona) {
        stopLoop(for: persona.persistentModelID)
    }

    private func startLoop(for id: PersistentIdentifier) {
        guard tasks[id] == nil else { return }
        runningPersonaIDs.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.runLoop(personaID: id)
        }
    }

    private func stopLoop(for id: PersistentIdentifier) {
        tasks[id]?.cancel()
        tasks[id] = nil
        runningPersonaIDs.remove(id)
    }

    private func runLoop(personaID: PersistentIdentifier) async {
        defer {
            tasks[personaID] = nil
            runningPersonaIDs.remove(personaID)
        }
        while !Task.isCancelled {
            guard let persona = fetchPersona(personaID) else { break }

            let plan = nextInteraction(for: persona)
            let event = TimelineEvent(
                kind: plan.kind,
                detail: "Planning: \(plan.kind.label.lowercased()) on \(plan.platform.displayName)",
                status: .scheduled,
                platform: plan.platform,
                persona: persona
            )
            context.insert(event)
            try? context.save()

            do {
                try await Task.sleep(for: .seconds(Double.random(in: 5...20)))
            } catch {
                break
            }
            guard !Task.isCancelled, fetchPersona(personaID) != nil else { break }

            event.status = .inProgress
            try? context.save()

            if let device = persona.device, !device.isConnected {
                event.detail = "\(plan.kind.label) skipped — \(device.name) is not connected"
                event.status = .failed
                try? context.save()
                continue
            }

            let action = DeviceAction(
                kind: plan.kind,
                platform: plan.platform,
                personaHandle: persona.handle,
                keyword: plan.keyword
            )
            do {
                let result = try await controller.perform(action, on: persona)
                guard fetchPersona(personaID) != nil else { break }
                event.detail = result
                event.status = .completed
            } catch is CancellationError {
                break
            } catch {
                guard fetchPersona(personaID) != nil else { break }
                event.detail = "\(plan.kind.label) failed on \(persona.boundDeviceName) — will retry later"
                event.status = .failed
            }
            try? context.save()
        }
    }

    private func fetchPersona(_ id: PersistentIdentifier) -> Persona? {
        let personas = (try? context.fetch(FetchDescriptor<Persona>())) ?? []
        return personas.first { $0.persistentModelID == id }
    }

    private struct PlannedInteraction {
        var kind: InteractionKind
        var platform: Platform
        var keyword: String
    }

    private func nextInteraction(for persona: Persona) -> PlannedInteraction {
        let kind = weightedKind(for: persona.narrative)
        let platform = persona.network
        let keywords = Self.keywords(in: persona.narrative)
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

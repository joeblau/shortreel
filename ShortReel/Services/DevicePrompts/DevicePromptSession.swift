import Foundation
import Observation

enum DevicePromptStatus: String, Sendable {
    case planning, running, sent, completed, failed, cancelled, needsInput

    var displayName: String {
        switch self {
        case .planning: "Understanding…"
        case .running: "Running…"
        case .sent: "Sent"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .needsInput: "Needs clarification"
        }
    }

    var isActive: Bool { self == .planning || self == .running }
}

struct DevicePromptEntry: Identifiable, Sendable {
    let id: UUID
    let prompt: String
    var status: DevicePromptStatus
    var message: String
    var steps: [PhoneVisionStep] = []
}

/// One independent conversation and serial action task for each physical phone.
/// Visual requests finish only after the runner checks another screen. Legacy
/// command requests report sent input rather than claiming a verified result.
@Observable @MainActor
final class DevicePromptSession {
    var draft = ""
    private(set) var entries: [DevicePromptEntry] = []
    private(set) var isRunning = false

    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let blockedReason: () -> String?
    @ObservationIgnored private let planner: (String) async throws -> PhonePromptPlan
    @ObservationIgnored private let perform: (PhonePromptAction) async throws -> Void
    @ObservationIgnored private let visualRunner: PhoneVisualRunner?
    @ObservationIgnored private let visualBlockedReason: () -> String?
    @ObservationIgnored private let onVisualStart: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancellationMessage = "Stopped. Input already sent to the phone cannot be undone."

    init(deviceName: String,
         blockedReason: @escaping () -> String?,
         planner: @escaping (String) async throws -> PhonePromptPlan,
         perform: @escaping (PhonePromptAction) async throws -> Void,
         visualRunner: PhoneVisualRunner? = nil,
         visualBlockedReason: @escaping () -> String? = { nil },
         onVisualStart: (() -> Void)? = nil) {
        self.deviceName = deviceName
        self.blockedReason = blockedReason
        self.planner = planner
        self.perform = perform
        self.visualRunner = visualRunner
        self.visualBlockedReason = visualBlockedReason
        self.onVisualStart = onVisualStart
    }

    var unavailableReason: String? { blockedReason() }
    var canUseScreen: Bool { visualRunner != nil && visualBlockedReason() == nil }

    func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !prompt.isEmpty else { return }
        let id = UUID()
        entries.append(DevicePromptEntry(id: id, prompt: prompt, status: .planning,
            message: "Understanding your request…"))
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
        if let reason = blockedReason() {
            update(id, status: .failed, message: reason)
            return
        }
        draft = ""
        isRunning = true
        cancellationMessage = "Stopped. Input already sent to the phone cannot be undone."
        // Literal inputs keep their exact meaning. App navigation and search
        // need screen feedback when available, even if their wording parses.
        // Parse the whole request first: never execute a known prefix before
        // handing the rest of a compound goal to the visual runner.
        let deterministicPlan = try? DevicePromptPlanner.plan(prompt)
        let needsVisualNavigation = deterministicPlan?.actions.contains { action in
            switch action {
            case .openApp, .search: true
            case .home, .typeText, .tap, .swipe, .drag, .press: false
            }
        } ?? false
        // Choose once, before execution. A visual run that loses its screen
        // must stop; it must never replay the request as direct commands.
        let useVisualLoop = canUseScreen && (deterministicPlan == nil || needsVisualNavigation)
        task = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            defer { self.isRunning = false; self.task = nil }
            do {
                if useVisualLoop, let runner = self.visualRunner {
                    // Overlap model warm-up with the first capture and OCR.
                    self.onVisualStart?()
                    let summary = try await runner.run(goal: prompt, onProgress: { message in
                        self.update(id, status: .running, message: message)
                    }, onStep: { step in
                        guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                        self.entries[index].steps.append(step)
                        completed += 1
                    })
                    try Task.checkCancellation()
                    self.update(id, status: .completed, message: summary)
                    return
                }
                let plan: PhonePromptPlan
                if let deterministicPlan {
                    plan = deterministicPlan
                } else {
                    plan = try await self.planner(prompt)
                }
                try Task.checkCancellation()
                try DevicePromptPlanner.validate(plan)
                for (index, action) in plan.actions.enumerated() {
                    try Task.checkCancellation()
                    if let reason = self.blockedReason() {
                        throw PromptExecutionError.unavailable(reason)
                    }
                    self.update(id, status: .running,
                        message: "Step \(index + 1) of \(plan.actions.count): \(action.promptDescription)")
                    try await self.perform(action)
                    completed += 1
                }
                try Task.checkCancellation()
                self.update(id, status: .sent,
                    message: "Sent \(completed) \(completed == 1 ? "action" : "actions") to \(self.deviceName). Check the phone to confirm the result.")
            } catch is CancellationError {
                self.update(id, status: .cancelled, message: self.cancellationMessage)
            } catch let error as PhonePromptPlanningError {
                guard !Task.isCancelled else {
                    self.update(id, status: .cancelled, message: self.cancellationMessage)
                    return
                }
                var message = error.localizedDescription
                if !useVisualLoop, let reason = self.visualBlockedReason() {
                    message += "\n\nBluetooth commands such as ‘Open Safari’ or ‘Scroll down’ work without screen access. \(reason)"
                }
                self.update(id, status: .needsInput, message: message)
                if self.draft.isEmpty { self.draft = prompt }
            } catch {
                guard !Task.isCancelled else {
                    self.update(id, status: .cancelled, message: self.cancellationMessage)
                    return
                }
                let unit = useVisualLoop ? "step" : "action"
                let prefix = completed > 0 ? "Stopped after \(completed) \(unit)\(completed == 1 ? "" : "s"). " : ""
                self.update(id, status: .failed, message: prefix + error.localizedDescription)
                if self.draft.isEmpty && completed == 0 { self.draft = prompt }
            }
        }
    }

    func cancel() { cancel(because: "Stopped. Input already sent to the phone cannot be undone.") }

    func cancel(because reason: String) {
        guard isRunning else { return }
        cancellationMessage = reason
        task?.cancel()
    }

    private func update(_ id: UUID, status: DevicePromptStatus, message: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].message = message
    }
}

private enum PromptExecutionError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): reason }
    }
}

private extension PhonePromptAction {
    var promptDescription: String {
        switch self {
        case .openApp(let name): "Open \(name)"
        case .home: "Go Home"
        case .search(let query): "Search for \(query)"
        case .typeText: "Type text"
        case .tap(let x, let y): "Tap at \(Int(x * 100))%, \(Int(y * 100))%"
        case .swipe(let direction): "Swipe \(direction.rawValue)"
        case .drag: "Drag on screen"
        case .press(let key): "Press \(key.rawValue)"
        }
    }
}

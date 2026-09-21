import Foundation
import Observation

enum DevicePromptStatus: String, Sendable {
    case planning, running, completed, failed, cancelled, needsInput

    var displayName: String {
        switch self {
        case .planning: "Understanding…"
        case .running: "Running…"
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
    /// Kept for request-history rendering; the pure visual loop records
    /// frame-bound `steps` instead.
    var sentActions: [String] = []
    var workflow: DeviceWorkflow? = nil
}

/// One independent conversation and serial action task for each physical phone.
/// Every request runs the same loop: capture the screen, let the selected model
/// choose one action, execute it, capture again. No scripted prefixes, no
/// parser shortcuts — a request finishes only after the model verifies the goal
/// on a fresh screen.
@Observable @MainActor
final class DevicePromptSession {
    var draft = ""
    private(set) var entries: [DevicePromptEntry] = []
    private(set) var isRunning = false

    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let blockedReason: () -> String?
    @ObservationIgnored private let visualRunner: PhoneVisualRunner?
    @ObservationIgnored private let visualBlockedReason: () -> String?
    @ObservationIgnored private let onVisualStart: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancellationMessage = "Stopped. Input already sent to the phone cannot be undone."

    init(deviceName: String,
         blockedReason: @escaping () -> String?,
         visualRunner: PhoneVisualRunner? = nil,
         visualBlockedReason: @escaping () -> String? = { nil },
         onVisualStart: (() -> Void)? = nil) {
        self.deviceName = deviceName
        self.blockedReason = blockedReason
        self.visualRunner = visualRunner
        self.visualBlockedReason = visualBlockedReason
        self.onVisualStart = onVisualStart
    }

    var unavailableReason: String? { blockedReason() }
    var canUseScreen: Bool { visualRunner != nil && visualBlockedReason() == nil }
    var screenUnavailableReason: String? {
        visualBlockedReason() ?? (visualRunner == nil ? "Connect a live phone screen before running an action." : nil)
    }

    func submit(testAppSwitcher: Bool = false, workflow: DeviceWorkflow? = nil, details: String = "") {
        let workflow = testAppSwitcher ? nil : workflow
        let prompt = testAppSwitcher ? "Test App Switcher gesture"
            : workflow?.goal(details: details) ?? draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !prompt.isEmpty else { return }
        let id = UUID()
        entries.append(DevicePromptEntry(id: id, prompt: prompt, status: .planning,
            message: "Understanding your request…", workflow: workflow))
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
        if let workflow, workflow != .clearHomeScreen, details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            update(id, status: .needsInput, message: workflow.summary)
            return
        }
        if let reason = blockedReason() {
            update(id, status: .failed, message: reason)
            return
        }
        guard let runner = visualRunner, visualBlockedReason() == nil else {
            update(id, status: .failed,
                message: visualBlockedReason() ?? "The selected model needs a live phone screen before it can choose an action.")
            return
        }
        if !testAppSwitcher && workflow == nil { draft = "" }
        isRunning = true
        cancellationMessage = "Stopped. Input already sent to the phone cannot be undone."
        task = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            defer { self.isRunning = false; self.task = nil }
            do {
                // Overlap model warm-up with the first capture.
                self.onVisualStart?()
                let progress: (String) -> Void = { message in
                    self.update(id, status: .running, message: message)
                }
                let record: (PhoneVisionStep) -> Void = { step in
                    guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                    self.entries[index].steps.append(step)
                    completed += 1
                }
                let summary = testAppSwitcher
                    ? try await runner.testAppSwitcher(onProgress: progress, onStep: record)
                    : try await runner.run(goal: prompt, workflow: workflow, onProgress: progress, onStep: record)
                try Task.checkCancellation()
                self.update(id, status: .completed, message: summary)
            } catch is CancellationError {
                self.update(id, status: .cancelled, message: self.cancellationMessage)
            } catch let error as PhonePromptPlanningError {
                guard !Task.isCancelled else {
                    self.update(id, status: .cancelled, message: self.cancellationMessage)
                    return
                }
                self.update(id, status: .needsInput, message: error.localizedDescription)
                if workflow == nil && self.draft.isEmpty { self.draft = prompt }
            } catch {
                guard !Task.isCancelled else {
                    self.update(id, status: .cancelled, message: self.cancellationMessage)
                    return
                }
                let prefix = completed > 0 ? "Stopped after \(completed) step\(completed == 1 ? "" : "s"). " : ""
                self.update(id, status: .failed, message: prefix + error.localizedDescription)
                if workflow == nil && self.draft.isEmpty && completed == 0 { self.draft = prompt }
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

import Foundation
import Observation

enum DevicePromptStatus: String, Codable, Sendable {
    case queued, planning, running, completed, failed, cancelled, needsInput, needsReview

    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .needsReview: "Needs review"
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
    /// Kept for request-history rendering; transactions record frame-bound steps.
    var sentActions: [String] = []
    var workflow: DeviceWorkflow? = nil
    var scriptTitle: String? = nil
    var scriptProgress: String? = nil
    var createdAt = Date()
    var updatedAt = Date()
    var reviewedAt: Date? = nil
    var submission: PhoneSubmissionCheckpoint? = nil
    var scriptCheckpoint: WarmUpScriptCheckpoint? = nil
    var transactionPlan: PhoneTransactionPlan? = nil
    var transactionCheckpoint: PhoneTransactionCheckpoint? = nil
    var warmUpScript: WarmUpScript? = nil
    var testAppSwitcher = false
}

/// One independent conversation and serial action task for each physical phone.
/// Agent and Stage share the same saved transaction engine. Commands and
/// transitions are fixed before execution; every input requires fresh evidence.
@Observable @MainActor
final class DevicePromptSession {
    var draft = ""
    private(set) var entries: [DevicePromptEntry] = []
    private(set) var isRunning = false
    private(set) var queuePaused = false
    private(set) var persistenceError: String?
    private(set) var restartRequiresReview = false
    var hasUnreviewedRuns: Bool { restartRequiresReview || entries.contains { $0.status == .needsReview && $0.reviewedAt == nil } }
    /// Watch starts with fresh observations and has no submission phase. A
    /// previous launch's uncertainty must not block this new, independent run.
    var queueRequiresReview: Bool {
        entries.contains { $0.status == .needsReview && $0.reviewedAt == nil }
            || (restartRequiresReview && entries.first(where: { $0.status == .queued })?.warmUpScript?.activity != .watch)
    }
    var queuedCount: Int { entries.filter { $0.status == .queued }.count }

    @ObservationIgnored private let journal: DeviceRunJournal?
    @ObservationIgnored private var journalLoaded = true
    @ObservationIgnored private var retired = false

    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let blockedReason: () -> String?
    @ObservationIgnored private let visualRunner: PhoneVisualRunner?
    @ObservationIgnored private let visualBlockedReason: () -> String?
    @ObservationIgnored private let onVisualStart: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancellationMessage = "Stopped. Input already sent to the phone cannot be undone."

    init(deviceName: String,
         deviceIdentifier: String? = nil,
         journal: DeviceRunJournal? = nil,
         blockedReason: @escaping () -> String?,
         visualRunner: PhoneVisualRunner? = nil,
         visualBlockedReason: @escaping () -> String? = { nil },
         onVisualStart: (() -> Void)? = nil) {
        self.journal = journal ?? deviceIdentifier.map { DeviceRunJournal(deviceIdentifier: $0) }
        self.deviceName = deviceName
        self.blockedReason = blockedReason
        self.visualRunner = visualRunner
        self.visualBlockedReason = visualBlockedReason
        self.onVisualStart = onVisualStart
        do {
            let recovered = try self.journal?.loadForSession()
            entries = recovered?.entries ?? []
            restartRequiresReview = recovered?.requiresReview ?? false
            for index in entries.indices where entries[index].status.isActive
                || ((entries[index].submission?.requiresReview == true || entries[index].transactionCheckpoint?.requiresReview == true) && entries[index].reviewedAt == nil) {
                entries[index].status = .needsReview
                entries[index].message = "Interrupted by an app restart. Check the phone before starting a new request; this run will not be retried."
                entries[index].updatedAt = Date()
            }
            queuePaused = queuedCount > 0 || entries.contains { $0.status == .needsReview && $0.reviewedAt == nil }
            try persist()
        } catch {
            journalLoaded = false
            persistenceError = error.localizedDescription
            queuePaused = true
        }
    }

    var unavailableReason: String? { blockedReason() }
    var canUseScreen: Bool { visualRunner != nil && visualBlockedReason() == nil }
    var screenUnavailableReason: String? {
        visualBlockedReason() ?? (visualRunner == nil ? "Connect a live phone screen before running an action." : nil)
    }

    func submit(testAppSwitcher: Bool = false, workflow: DeviceWorkflow? = nil, details: String = "",
                warmUpScript: WarmUpScript? = nil) {
        let workflow = testAppSwitcher ? nil : workflow
        let warmUpScript = workflow == .warmUp ? warmUpScript : nil
        let prompt = testAppSwitcher ? "Test App Switcher gesture"
            : warmUpScript != nil ? details : workflow?.goal(details: details) ?? draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !retired, !prompt.isEmpty else { return }
        let id = UUID()
        entries.append(DevicePromptEntry(id: id, prompt: prompt, status: .queued,
            message: "Waiting for this phone…", workflow: workflow, scriptTitle: warmUpScript?.title,
            warmUpScript: warmUpScript, testAppSwitcher: testAppSwitcher))
        trimHistory()
        guard journalLoaded else {
            update(id, status: .failed, message: persistenceError ?? "Device history is unavailable.")
            return
        }
        if let workflow, workflow != .clearHomeScreen, details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            update(id, status: .needsInput, message: workflow.summary)
            return
        }
        if let reason = blockedReason() {
            update(id, status: .failed, message: reason)
            return
        }
        guard visualRunner != nil, visualBlockedReason() == nil else {
            update(id, status: .failed,
                message: visualBlockedReason() ?? "The selected model needs a live phone screen before it can choose an action.")
            return
        }
        if !testAppSwitcher && workflow == nil { draft = "" }
        guard persistOrPause() else {
            update(id, status: .failed, message: persistenceError ?? "Unable to save this request.")
            return
        }
        if queueRequiresReview, let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].message = "Waiting for the interrupted run to be reviewed."
            guard persistOrPause() else { return }
        }
        startNext()
    }

    /// Explicitly resume only never-started jobs; interrupted jobs are never retried.
    func resumeQueue() {
        guard journalLoaded, !queueRequiresReview, persistOrPause() else { return }
        queuePaused = false
        startNext()
    }

    func acknowledgeRestartReview() {
        restartRequiresReview = false
        guard persistOrPause() else { restartRequiresReview = true; return }
        resumeQueue()
    }

    func acknowledgeReview(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.status == .needsReview }) else { return }
        entries[index].reviewedAt = Date()
        entries[index].updatedAt = Date()
        if persistOrPause() { resumeQueue() }
    }

    func cancelQueued(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.status == .queued }) else { return }
        entries[index].status = .cancelled
        entries[index].message = "Removed from the queue before starting."
        entries[index].updatedAt = Date()
        persistOrPause()
    }

    func cancelAllQueued() {
        for id in entries.filter({ $0.status == .queued }).map(\.id) { cancelQueued(id: id) }
    }

    private func startNext() {
        guard !retired, !isRunning, !queuePaused, !queueRequiresReview,
              let entry = entries.first(where: { $0.status == .queued }), let runner = visualRunner else { return }
        let id = entry.id
        let prompt = entry.prompt
        let workflow = entry.workflow
        let warmUpScript = entry.warmUpScript
        let testAppSwitcher = entry.testAppSwitcher
        if let reason = blockedReason() ?? visualBlockedReason() {
            queuePaused = true
            update(id, status: .queued, message: reason + " Resume the queue when ready.")
            return
        }
        update(id, status: .planning, message: "Understanding your request…")
        guard persistenceError == nil else { return }
        isRunning = true
        cancellationMessage = "Stopped. Input already sent to the phone cannot be undone."
        task = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            defer { self.isRunning = false; self.task = nil; self.startNext() }
            do {
                // Overlap model warm-up with the first capture.
                self.onVisualStart?()
                let progress: @MainActor (String) -> Void = { message in
                    self.update(id, status: .running, message: message)
                }
                let record: (PhoneVisionStep) -> Void = { step in
                    guard !self.retired, let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                    self.entries[index].steps.append(step)
                    completed += 1
                    self.entries[index].updatedAt = Date()
                    self.persistOrPause()
                }
                let summary = testAppSwitcher
                    ? try await runner.testAppSwitcher(onProgress: progress, onStep: record)
                    : try await runner.run(goal: prompt, workflow: workflow, warmUpScript: warmUpScript,
                        onScriptProgress: { message in
                            guard !self.retired, let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                            self.entries[index].scriptProgress = message
                            self.persistOrPause()
                        }, onScriptCheckpoint: { checkpoint in
                            guard !self.retired else { throw CancellationError() }
                            guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                            self.entries[index].scriptCheckpoint = checkpoint
                            self.entries[index].updatedAt = Date()
                            try self.persist()
                        }, onSubmissionCheckpoint: { checkpoint in
                            guard !self.retired else { throw CancellationError() }
                            guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
                            self.entries[index].submission = checkpoint
                            self.entries[index].updatedAt = Date()
                            try self.persist()
                        }, onTransactionPlan: { plan in
                            guard !self.retired, let index = self.entries.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                            self.entries[index].transactionPlan = plan
                            try self.persist()
                        }, onTransactionCheckpoint: { checkpoint in
                            guard !self.retired, let index = self.entries.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                            self.entries[index].transactionCheckpoint = checkpoint
                            self.entries[index].updatedAt = Date()
                            try self.persist()
                        }, onProgress: progress, onStep: record)
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
        queuePaused = queuedCount > 0
        guard isRunning else { return }
        cancellationMessage = reason
        task?.cancel()
    }

    /// Freeze a discarded session before a replacement can load its journal.
    /// Its cancelled task may still unwind, but must never overwrite newer work.
    func retire(because reason: String) {
        guard !retired else { return }
        cancel(because: reason)
        for id in entries.filter({ $0.status.isActive }).map(\.id) {
            update(id, status: .cancelled, message: reason)
        }
        queuePaused = true
        retired = true
    }

    private func trimHistory() {
        // Keep all active, queued, and unresolved runs even if the history cap is exceeded.
        let terminal = entries.filter { !$0.status.isActive && $0.status != .queued && !($0.status == .needsReview && $0.reviewedAt == nil) }
        let remove = Set(terminal.prefix(max(0, entries.count - 50)).map(\.id))
        entries.removeAll { remove.contains($0.id) }
    }

    private func persist() throws {
        guard !retired else { throw CancellationError() }
        guard journalLoaded else { throw DeviceRunJournal.JournalError.invalidData }
        try journal?.save(entries, restartRequiresReview: restartRequiresReview)
        persistenceError = nil
    }

    @discardableResult private func persistOrPause() -> Bool {
        do { try persist(); return true }
        catch {
            persistenceError = "Could not save device history: " + error.localizedDescription
            queuePaused = true
            cancellationMessage = persistenceError!
            task?.cancel()
            return false
        }
    }

    private func update(_ id: UUID, status: DevicePromptStatus, message: String) {
        guard !retired, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let unconfirmed = entries[index].submission?.requiresReview == true || entries[index].transactionCheckpoint?.requiresReview == true
        entries[index].status = !status.isActive && status != .queued && unconfirmed ? .needsReview : status
        entries[index].message = unconfirmed && !status.isActive
            ? message + " An input may already have taken effect. Check the phone before retrying." : message
        entries[index].updatedAt = Date()
        if entries.contains(where: { $0.status == .needsReview && $0.reviewedAt == nil }) { queuePaused = true }
        if [.failed, .needsInput, .needsReview, .cancelled].contains(entries[index].status), queuedCount > 0 { queuePaused = true }
        trimHistory()
        persistOrPause()
    }
}

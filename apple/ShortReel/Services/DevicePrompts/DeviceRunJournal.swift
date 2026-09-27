import CryptoKit
import Foundation

struct DeviceRunJournal {
    struct Step: Codable {
        let id: UUID
        let number: Int
        let action: String
        let detail: String
        let capturedAt: Date
        let screenChanged: Bool?
        let progressNote: String?
        let playbackEvidence: String?
        let accountCheck: WarmUpAccountDecision?
        let failureCheck: WarmUpFailureDecision?

        init(_ step: PhoneVisionStep) {
            id = step.id; number = step.number; action = step.action; detail = step.detail
            capturedAt = step.capturedAt; screenChanged = step.screenChanged; progressNote = step.progressNote
            playbackEvidence = step.playbackEvidence; accountCheck = step.accountCheck
            failureCheck = step.failureCheck
        }
        var restored: PhoneVisionStep {
            var step = PhoneVisionStep(id: id, number: number, action: action, detail: detail, capturedAt: capturedAt,
                  screenChanged: screenChanged, progressNote: progressNote, playbackEvidence: playbackEvidence)
            step.accountCheck = accountCheck
            step.failureCheck = failureCheck
            return step
        }
    }
    struct Record: Codable {
        let id: UUID
        let prompt: String
        var status: DevicePromptStatus
        var message: String
        let createdAt: Date
        var updatedAt: Date
        let workflow: String?
        let script: WarmUpScriptEnvelope?
        let testAppSwitcher: Bool
        let steps: [Step]
        let scriptProgress: String?
        let reviewedAt: Date?
        let submission: PhoneSubmissionCheckpoint?
        let scriptCheckpoint: WarmUpScriptCheckpoint?
        let transactionPlan: PhoneTransactionPlan?
        let transactionCheckpoint: PhoneTransactionCheckpoint?

        init(_ entry: DevicePromptEntry) throws {
            id = entry.id; prompt = entry.prompt; status = entry.status; message = entry.message
            createdAt = entry.createdAt; updatedAt = entry.updatedAt; workflow = entry.workflow?.rawValue
            script = try entry.warmUpScript.map { try WarmUpScriptEnvelope(script: $0) }
            testAppSwitcher = entry.testAppSwitcher; steps = entry.steps.map(Step.init)
            scriptProgress = entry.scriptProgress; reviewedAt = entry.reviewedAt; submission = entry.submission
            scriptCheckpoint = entry.scriptCheckpoint
            transactionPlan = entry.transactionPlan
            transactionCheckpoint = entry.transactionCheckpoint
        }
        func restored() throws -> DevicePromptEntry {
            try script?.validate()
            try transactionPlan?.validate(script: script?.script)
            if let checkpoint = transactionCheckpoint {
                guard let phase = transactionPlan?.phases.first(where: { $0.id == checkpoint.phase }),
                      let state = phase.states.first(where: { $0.id == checkpoint.state }),
                      checkpoint.branch == nil || state.branches.contains(where: { $0.id == checkpoint.branch }),
                      checkpoint.visits.values.allSatisfy({ $0 >= 0 }) else { throw JournalError.invalidData }
            }
            if let workflow, DeviceWorkflow(rawValue: workflow) == nil { throw JournalError.invalidData }
            return DevicePromptEntry(id: id, prompt: prompt, status: status, message: message,
                steps: steps.map(\.restored), workflow: workflow.flatMap(DeviceWorkflow.init(rawValue:)),
                scriptTitle: script?.script.title, scriptProgress: scriptProgress,
                createdAt: createdAt, updatedAt: updatedAt, reviewedAt: reviewedAt, submission: submission, scriptCheckpoint: scriptCheckpoint,
                transactionPlan: transactionPlan, transactionCheckpoint: transactionCheckpoint,
                warmUpScript: script?.script, testAppSwitcher: testAppSwitcher)
        }
    }
    struct Document: Codable {
        var schemaVersion = 1
        let deviceIdentifier: String
        var entries: [Record]
        var appSessionID: UUID? = nil
        var restartRequiresReview: Bool? = nil
    }
    enum JournalError: LocalizedError {
        case invalidData
        var errorDescription: String? { "The saved device history has an unsupported format. It was preserved for review." }
    }

    static let currentAppSessionID = UUID()
    let deviceIdentifier: String
    let appSessionID: UUID
    let fileURL: URL

    init(deviceIdentifier: String, directory: URL? = nil, appSessionID: UUID = Self.currentAppSessionID) {
        self.deviceIdentifier = deviceIdentifier
        self.appSessionID = appSessionID
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShortReel/RunHistory", isDirectory: true)
        let key = SHA256.hash(data: Data(deviceIdentifier.utf8)).map { String(format: "%02x", $0) }.joined()
        fileURL = root.appendingPathComponent(key + ".json")
    }

    private func document() throws -> Document? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
        guard document.schemaVersion == 1, document.deviceIdentifier == deviceIdentifier else { throw JournalError.invalidData }
        return document
    }

    func load() throws -> [DevicePromptEntry] {
        try document()?.entries.map { try $0.restored() } ?? []
    }

    func loadForSession() throws -> (entries: [DevicePromptEntry], requiresReview: Bool) {
        guard let saved = try document() else { return ([], false) }
        if saved.appSessionID == appSessionID {
            return (try saved.entries.map { try $0.restored() }, saved.restartRequiresReview == true)
        }
        let unresolved = saved.entries.contains {
            guard $0.reviewedAt == nil else { return false }
            if $0.submission?.requiresReview == true { return true }
            guard $0.script?.script.activity != .watch else { return false }
            return $0.status == .needsReview
                || ($0.status.isActive && $0.transactionPlan == nil && !$0.steps.isEmpty)
                || $0.transactionCheckpoint?.requiresReview == true
        }
        return ([], unresolved || saved.restartRequiresReview == true)
    }

    func save(_ entries: [DevicePromptEntry], restartRequiresReview: Bool = false) throws {
        let document = Document(deviceIdentifier: deviceIdentifier, entries: try entries.map(Record.init),
            appSessionID: appSessionID, restartRequiresReview: restartRequiresReview)
        let data = try JSONEncoder().encode(document)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

struct SemanticIfCaptureRecord: Encodable, Sendable {
    enum Source: String, Encodable, Sendable { case laya, shortCircuit = "short-circuit", deterministic, account, failure }
    struct Region: Encodable, Sendable {
        let text: String
        let confidence: Float
        let x, y, width, height: Double

        init(_ region: PhonePlaybackTracker.TextRegion) {
            text = region.text; confidence = region.confidence
            x = region.bounds.minX; y = region.bounds.minY; width = region.bounds.width; height = region.bounds.height
        }
    }
    let run: String
    let sequence: Int
    let capturedAt: Date
    let phase: String
    let state: String
    let pending: String?
    let question: PhoneTransactionQuestion?
    let source: Source
    let selected: String?
    let probabilities: [String: Double]?
    let margin: Double?
    let observation: PhoneScreenObservation
    let regions: [Region]
    let signals: [PhoneScreenSignal]

    static func run(startedAt date: Date, script: WarmUpScript?, workflow: DeviceWorkflow?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date) + "-" + (script?.identifier ?? workflow?.rawValue ?? "prompt")
    }
}

/// Opt-in capture of every Semantic If decision for replay as fixtures. Write failures are ignored.
struct SemanticIfCaptureJournal: Sendable {
    static let directoryKey = "semanticIfCaptureDirectory"
    let directory: URL

    static func configured(_ defaults: UserDefaults = .standard) -> Self? {
        guard let path = defaults.string(forKey: directoryKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return .init(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
    }

    func write(_ record: SemanticIfCaptureRecord, jpeg: Data) {
        let folder = directory.appendingPathComponent(record.run, isDirectory: true)
        let name = String(format: "%04d", record.sequence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let data = try? encoder.encode(record) else { return }
        try? data.write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
        try? jpeg.write(to: folder.appendingPathComponent(name + ".jpg"), options: .atomic)
    }
}

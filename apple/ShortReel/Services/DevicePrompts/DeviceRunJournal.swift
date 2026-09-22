import CryptoKit
import Foundation

/// A device-scoped atomic journal. Screenshots and image buffers never enter it.
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

        init(_ entry: DevicePromptEntry) throws {
            id = entry.id; prompt = entry.prompt; status = entry.status; message = entry.message
            createdAt = entry.createdAt; updatedAt = entry.updatedAt; workflow = entry.workflow?.rawValue
            script = try entry.warmUpScript.map { try WarmUpScriptEnvelope(script: $0) }
            testAppSwitcher = entry.testAppSwitcher; steps = entry.steps.map(Step.init)
            scriptProgress = entry.scriptProgress; reviewedAt = entry.reviewedAt; submission = entry.submission
            scriptCheckpoint = entry.scriptCheckpoint
        }
        func restored() throws -> DevicePromptEntry {
            try script?.validate()
            if let workflow, DeviceWorkflow(rawValue: workflow) == nil { throw JournalError.invalidData }
            return DevicePromptEntry(id: id, prompt: prompt, status: status, message: message,
                steps: steps.map(\.restored), workflow: workflow.flatMap(DeviceWorkflow.init(rawValue:)),
                scriptTitle: script?.script.title, scriptProgress: scriptProgress,
                createdAt: createdAt, updatedAt: updatedAt, reviewedAt: reviewedAt, submission: submission, scriptCheckpoint: scriptCheckpoint,
                warmUpScript: script?.script, testAppSwitcher: testAppSwitcher)
        }
    }
    struct Document: Codable {
        var schemaVersion = 1
        let deviceIdentifier: String
        var entries: [Record]
    }
    enum JournalError: LocalizedError {
        case invalidData
        var errorDescription: String? { "The saved device history has an unsupported format. It was preserved for review." }
    }

    let deviceIdentifier: String
    let fileURL: URL

    init(deviceIdentifier: String, directory: URL? = nil) {
        self.deviceIdentifier = deviceIdentifier
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShortReel/RunHistory", isDirectory: true)
        let key = SHA256.hash(data: Data(deviceIdentifier.utf8)).map { String(format: "%02x", $0) }.joined()
        fileURL = root.appendingPathComponent(key + ".json")
    }

    func load() throws -> [DevicePromptEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
        guard document.schemaVersion == 1, document.deviceIdentifier == deviceIdentifier else { throw JournalError.invalidData }
        return try document.entries.map { try $0.restored() }
    }

    func save(_ entries: [DevicePromptEntry]) throws {
        let document = Document(deviceIdentifier: deviceIdentifier, entries: try entries.map(Record.init))
        let data = try JSONEncoder().encode(document)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

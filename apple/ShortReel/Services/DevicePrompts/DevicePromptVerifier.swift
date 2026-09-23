import Foundation

struct DevicePromptVerifier: Sendable {
    typealias Capture = @MainActor (Date) async throws -> PhoneScreenFrame
    typealias RecognizeText = @Sendable (PhoneScreenFrame) async throws -> String

    var oracle: RunnerOracle?
    var capture: Capture?
    var recognizeText: RecognizeText?
    var settledFrameCount = 3
    var settleTimeout: TimeInterval = 3

    init(oracle: RunnerOracle? = nil, capture: Capture? = nil, recognizeText: RecognizeText? = nil) {
        self.oracle = oracle
        self.capture = capture
        self.recognizeText = recognizeText
    }

    static func recognizedText(in frame: PhoneScreenFrame) throws -> String {
        try PhoneVisionClient.makeScreenContext(frame).targets.map(\.text).joined(separator: " ")
    }

    var checkFactory: DevicePromptCheckFactory {
        { [self] expectation in
            switch expectation {
            case .none:
                return { .satisfied("Nothing to verify.") }
            case .textAppears, .textDisappears:
                let before = await currentText()
                return { [self] in await run(expectation, beforeText: before) }
            case .appForeground, .screenSettles, .treeContains:
                return { [self] in await run(expectation, beforeText: nil) }
            }
        }
    }

    private func run(_ expectation: DeviceActionExpectation, beforeText: String?) async -> DevicePromptCheckOutcome {
        if let oracle, case .value(true) = await oracle.isLocked() {
            return .failed("The phone is locked. Unlock it, then run the request again.")
        }
        let outcome: DevicePromptCheckOutcome
        switch expectation {
        case .none:
            outcome = .satisfied("Nothing to verify.")
        case .appForeground(let bundleID):
            outcome = await checkForeground(bundleID)
        case .screenSettles:
            outcome = await settledFrame()
        case .textAppears(let text):
            outcome = await checkText(text, shouldAppear: true, beforeText: beforeText)
        case .textDisappears(let text):
            outcome = await checkText(text, shouldAppear: false, beforeText: beforeText)
        case .treeContains(let query):
            outcome = await checkTree(query)
        }
        guard case .failed(let evidence) = outcome, let alerts = await alertEvidence() else {
            return outcome
        }
        return .failed(evidence + "\n" + alerts)
    }

    private func checkForeground(_ bundleID: String) async -> DevicePromptCheckOutcome {
        if let oracle {
            switch await oracle.isAppForeground(bundleID: bundleID) {
            case .value(.foreground(let observed)):
                return .satisfied("\(observed) is in the foreground.")
            case .value(.mismatch(let observed)):
                return .failed("Expected \(bundleID) in the foreground, but the phone shows \(observed).")
            case .value(.indeterminate), .unavailable, .failed:
                break
            }
        }
        return await settledFrame()
    }

    private func checkTree(_ query: String) async -> DevicePromptCheckOutcome {
        guard let oracle else { return .unverified }
        switch await oracle.treeText() {
        case .value(let tree):
            if tree.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return .satisfied("The accessibility tree contains ‘\(query)’.")
            }
            return .failed("Expected the accessibility tree to contain ‘\(query)’.\nTree excerpt: “\(Self.snippet(tree))”")
        case .unavailable, .failed:
            return .unverified
        }
    }

    private func checkText(_ text: String, shouldAppear: Bool, beforeText: String?) async -> DevicePromptCheckOutcome {
        if capture != nil, recognizeText != nil {
            _ = await settledFrame()
            guard let after = await currentText() else { return .unverified }
            let found = after.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            guard found != shouldAppear else {
                return .satisfied(shouldAppear ? "‘\(text)’ is visible." : "‘\(text)’ is gone.")
            }
            var evidence = shouldAppear
                ? "Expected to see ‘\(text)’ after the action, but it is not visible."
                : "Expected ‘\(text)’ to disappear after the action, but it is still visible."
            evidence += "\nScreen text before: “\(beforeText.map { Self.snippet($0) } ?? "unknown")”"
            evidence += "\nScreen text after: “\(Self.snippet(after))”"
            if let tree = await treeTextValue() {
                evidence += "\nTree excerpt: “\(Self.snippet(tree))”"
            }
            return .failed(evidence)
        }
        guard let oracle, case .value(let tree) = await oracle.treeText() else { return .unverified }
        let found = tree.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        guard found != shouldAppear else {
            return .satisfied(shouldAppear ? "The tree contains ‘\(text)’." : "The tree no longer contains ‘\(text)’.")
        }
        let verdict = shouldAppear
            ? "Expected the accessibility tree to contain ‘\(text)’."
            : "Expected ‘\(text)’ to leave the accessibility tree."
        return .failed("\(verdict)\nTree excerpt: “\(Self.snippet(tree))”")
    }

    private func settledFrame() async -> DevicePromptCheckOutcome {
        guard let capture else { return .unverified }
        let start = Date()
        do {
            var frame = try await capture(start)
            var stable = 1
            while Date().timeIntervalSince(start) < settleTimeout {
                let next = try await capture(frame.capturedAt)
                if Self.framesMatch(frame, next) {
                    stable += 1
                    if stable >= settledFrameCount {
                        return .satisfied("The phone’s screen settled.")
                    }
                } else {
                    stable = 1
                    frame = next
                }
            }
            return .failed("The phone’s screen was still changing \(settleTimeout) seconds after the action.")
        } catch {
            return .unverified
        }
    }

    static func framesMatch(_ a: PhoneScreenFrame, _ b: PhoneScreenFrame) -> Bool {
        abs(a.jpegData.count - b.jpegData.count) <= max(512, a.jpegData.count / 100)
    }

    private func currentText() async -> String? {
        guard let capture, let recognizeText,
              let frame = try? await capture(Date()),
              let text = try? await recognizeText(frame) else { return nil }
        return text
    }

    private func treeTextValue() async -> String? {
        guard let oracle, case .value(let tree) = await oracle.treeText() else { return nil }
        return tree
    }

    private func alertEvidence() async -> String? {
        guard let oracle, case .value(let alerts) = await oracle.springboardAlerts(), !alerts.isEmpty else { return nil }
        let descriptions = alerts.map { "“\($0.title)” (\($0.buttonLabels.joined(separator: ", ")))" }
        return "Alert on the phone: \(descriptions.joined(separator: "; "))"
    }

    static func snippet(_ text: String, limit: Int = 240) -> String {
        let flattened = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flattened.count > limit ? String(flattened.prefix(limit - 1)) + "…" : flattened
    }
}

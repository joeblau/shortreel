import CoreGraphics
import Foundation
import Vision

/// An extra local check for app/widget removal menus. OCR is not a guarantee of visual
/// correctness; the planner still has to identify the app and verify each result.
enum HomeScreenRemovalGuard {
    struct Target: Sendable {
        let text: String
        /// Normalized screenshot coordinates, origin at top left.
        let bounds: CGRect
    }

    static func prepare(_ action: PhonePromptAction, frame: PhoneScreenFrame) async throws -> PhonePromptAction {
        let targets = try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: frame.cgImage).perform([request])
            return (request.results ?? []).compactMap { observation -> Target? in
                guard let text = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return Target(text: text.string, bounds: CGRect(x: box.minX, y: 1 - box.maxY,
                    width: box.width, height: box.height))
            }
        }.value
        try Task.checkCancellation()
        return try prepare(action, targets: targets)
    }

    static func prepare(_ action: PhonePromptAction, targets: [Target]) throws -> PhonePromptAction {
        let normalized = targets.map { target in
            (target, target.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " "))
        }
        let prohibited = ["delete", "uninstall", "offload", "erase", "require face id", "require touch id"]
        // A generic Remove button is safe only in an explicitly identified
        // widget/stack confirmation, never an unrelated removal dialog.
        let widgetConfirmation = normalized.contains { target, text in
            text.hasPrefix("remove ") && target.text.contains("?")
                && (text.contains("widget") || text.contains("stack"))
        }
        var allowedLabels = ["edit home screen", "remove app", "remove from home screen", "remove widget", "remove stack", "cancel"]
        if widgetConfirmation { allowedLabels.append("remove") }
        let hasRemovalControls = normalized.contains { _, text in
            text.hasPrefix("remove") || prohibited.contains(where: text.contains)
        }
        guard hasRemovalControls else { return action }
        func blocked() -> PhonePromptPlanningError {
            let controls = normalized.filter { target, text in
                allowedLabels.contains(text) && !target.bounds.isEmpty
                    && target.bounds.minX >= 0 && target.bounds.maxX <= 1
                    && target.bounds.minY >= 0 && target.bounds.maxY <= 1
            }.map { target, text in
                "\(text): x=\(String(format: "%.3f", target.bounds.midX)), y=\(String(format: "%.3f", target.bounds.midY))"
            }.joined(separator: "; ")
            return .needsClarification("Cleanup couldn’t match the proposed input to a safe menu control. No input was sent. "
                + (controls.isEmpty ? "No safe menu labels were recognized." : "Recognized controls (normalized coordinates): \(controls).")
                + " Choose Remove App, then Remove from Home Screen on the next screenshot; never Delete App.")
        }
        if action == .press(.escape) { return action }
        // Do not allow keyboard activation, double taps, or drags in a removal menu.
        guard case .tap(let x, let y) = action, x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y) else { throw blocked() }
        // iOS menu rows extend beyond the text, often to an icon on the right.
        // Match the observed row, then send the tap at the safe label's center.
        // Never execute the original off-label coordinate in a removal menu.
        let rowTargets = normalized.filter { target, _ in
            let bounds = target.bounds.insetBy(dx: 0, dy: -0.016)
            return y >= bounds.minY && y <= bounds.maxY
        }
        guard !rowTargets.contains(where: { _, text in prohibited.contains(where: text.contains) }) else { throw blocked() }
        let allowed = rowTargets.filter { _, text in
            allowedLabels.contains(text)
        }.sorted { abs($0.0.bounds.midX - x) < abs($1.0.bounds.midX - x) }
        // Widget alerts can place Cancel and Remove side by side. Use X to
        // disambiguate them, while refusing an equidistant/overlapping target.
        if allowed.count > 1 {
            let nearest = abs(allowed[0].0.bounds.midX - x)
            let next = abs(allowed[1].0.bounds.midX - x)
            guard next - nearest > 0.025 else { throw blocked() }
        }
        guard let target = allowed.first?.0,
              !target.bounds.isEmpty, target.bounds.minX >= 0, target.bounds.maxX <= 1,
              target.bounds.minY >= 0, target.bounds.maxY <= 1 else { throw blocked() }
        return .tap(target.bounds.midX, target.bounds.midY)
    }

}

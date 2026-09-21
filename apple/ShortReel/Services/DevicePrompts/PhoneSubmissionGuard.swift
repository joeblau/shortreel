import CoreGraphics
import Foundation
import Vision

/// A local boundary around irreversible submissions. This supplements visual
/// planning: OCR cannot identify every unlabeled or localized publish control.
/// Final submission fails closed unless its explicit label is recognized.
enum PhoneSubmissionGuard {
    struct TextRegion: Sendable {
        let text: String
        let confidence: Float
        /// Normalized screenshot coordinates, origin at top left.
        let bounds: CGRect
    }

    static func validate(action: PhonePromptAction, frame: PhoneScreenFrame, isFinalSubmission: Bool) async throws {
        let regions = try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: frame.cgImage).perform([request])
            } catch {
                throw failure("The submission control could not be checked in the current screenshot. No input was sent. Make the composer and its labeled submit button visible, then review the draft.")
            }
            return (request.results ?? []).compactMap { result -> TextRegion? in
                guard let candidate = result.topCandidates(1).first else { return nil }
                let box = result.boundingBox
                return TextRegion(text: candidate.string, confidence: candidate.confidence,
                    bounds: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            }
        }.value
        try Task.checkCancellation()
        try validate(action: action, regions: regions, isFinalSubmission: isFinalSubmission)
    }

    static func validate(action: PhonePromptAction, regions: [TextRegion], isFinalSubmission: Bool) throws {
        let controls = regions.filter { region in
            let label = region.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let box = region.bounds
            return region.confidence >= 0.85 && labels.contains(label)
                && [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite)
                && box.width > 0 && box.height > 0 && box.height <= 0.08
                && box.minX >= 0 && box.maxX <= 1 && box.minY >= 0 && box.maxY <= 1
        }
        let targets = controls.map { $0.bounds.insetBy(dx: -0.025, dy: -0.015) }

        if isFinalSubmission {
            guard case .tap(let x, let y) = action,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw failure("Final submission requires one tap on a visible, labeled submit button. Keyboard activation, typing, repeated taps, and gestures are not allowed. No input was sent.")
            }
            let point = CGPoint(x: x, y: y)
            guard targets.filter({ $0.contains(point) }).count == 1 else {
                throw failure("The proposed submission did not match one unambiguous visible Post, Publish, Send, Comment, Reply, Share, or Upload control. No input was sent. Keep the draft open and make its submit label visible before trying again.")
            }
            return
        }

        switch action {
        case .press(.enter), .press(.search):
            throw failure("Return/Search can submit the draft before the submission step. No input was sent. Finish preparing the draft without keyboard submission.")
        case .typeText(let text) where text.rangeOfCharacter(from: .newlines) != nil:
            throw failure("A newline can submit the draft during preparation. No input was sent. Prepare the text without line breaks, then use the separate submission step.")
        case .tap(let x, let y), .doubleTap(let x, let y), .longPress(let x, let y, _):
            if targets.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { throw prematureSubmission() }
        case .drag(let x, let y, let endX, let endY), .timedDrag(let x, let y, let endX, let endY, _, _, _):
            if targets.contains(where: { intersects($0, from: CGPoint(x: x, y: y), to: CGPoint(x: endX, y: endY)) }) {
                throw prematureSubmission()
            }
        default: break
        }
    }

    private static let labels: Set<String> = [
        "post", "post now", "publish", "publish now", "send", "send now", "comment", "post comment",
        "reply", "post reply", "share", "share now", "share post", "upload", "upload video", "post video"
    ]

    private static func prematureSubmission() -> PhonePromptPlanningError {
        failure("That input touches a visible submission control while the script is still preparing the draft. No input was sent. Verify the completed draft and advance to the separate submission step before publishing.")
    }

    private static func failure(_ message: String) -> PhonePromptPlanningError { .needsClarification(message) }

    /// Segment clipping catches a drag crossing the control even when neither
    /// endpoint lies inside it; a bounding-box test alone overblocks diagonals.
    private static func intersects(_ rect: CGRect, from start: CGPoint, to end: CGPoint) -> Bool {
        let dx = end.x - start.x, dy = end.y - start.y
        var lower: CGFloat = 0, upper: CGFloat = 1
        let constraints: [(CGFloat, CGFloat)] = [(-dx, start.x - rect.minX), (dx, rect.maxX - start.x),
                                               (-dy, start.y - rect.minY), (dy, rect.maxY - start.y)]
        for (p, q) in constraints {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let ratio = q / p
                if p < 0 { lower = max(lower, ratio) } else { upper = min(upper, ratio) }
                if lower > upper { return false }
            }
        }
        return true
    }
}

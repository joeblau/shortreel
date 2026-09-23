import CoreGraphics
import Foundation

@main
enum PhoneSubmissionGuardTests {
    enum Failure: Error { case assertion(String) }
    static let post = PhoneSubmissionGuard.TextRegion(text: "Post", confidence: 0.99,
        bounds: CGRect(x: 0.80, y: 0.10, width: 0.10, height: 0.03))

    static func rejects(_ action: PhonePromptAction, final: Bool, regions: [PhoneSubmissionGuard.TextRegion] = [post]) throws {
        do {
            try PhoneSubmissionGuard.validate(action: action, regions: regions, isFinalSubmission: final)
        } catch is PhonePromptPlanningError { return }
        throw Failure.assertion("Unexpectedly accepted \(action), final=\(final)")
    }

    static func main() throws {
        let touches: [PhonePromptAction] = [.tap(0.85, 0.115), .doubleTap(0.85, 0.115),
            .longPress(0.85, 0.115, seconds: 1), .drag(0.5, 0.115, 0.95, 0.115),
            .timedDrag(0.85, 0.0, 0.85, 0.3, duration: 0.5, pressDuration: 0, holdDuration: 0)]
        for action in touches { try rejects(action, final: false) }
        for action in [PhonePromptAction.press(.enter), .press(.search), .typeText("hello\nworld"),
                       .typeText("hello\rworld"), .typeText("hello\u{2028}world")] {
            try rejects(action, final: false, regions: [])
        }
        for action in [PhonePromptAction.tap(0.2, 0.4), .typeText("A single-line draft"),
                       .drag(0.1, 0.4, 0.9, 0.4), .press(.backspace)] {
            try PhoneSubmissionGuard.validate(action: action, regions: [post], isFinalSubmission: false)
        }
        try PhoneSubmissionGuard.validate(action: .tap(0.85, 0.115), regions: [post], isFinalSubmission: true)
        for action in touches.dropFirst() { try rejects(action, final: true) }
        try rejects(.press(.enter), final: true)
        try rejects(.typeText("hello"), final: true)
        try rejects(.tap(0.2, 0.4), final: true)
        try rejects(.tap(0.85, 0.115), final: true, regions: [])
        try rejects(.tap(.nan, 0.115), final: true)
        try rejects(.tap(0.85, 0.115), final: true, regions: [post, post])
        let uncertain = PhoneSubmissionGuard.TextRegion(text: "Post", confidence: 0.5, bounds: post.bounds)
        try rejects(.tap(0.85, 0.115), final: true, regions: [uncertain])
        let sentence = PhoneSubmissionGuard.TextRegion(text: "Post your thoughts here", confidence: 0.99, bounds: post.bounds)
        try rejects(.tap(0.85, 0.115), final: true, regions: [sentence])
        for label in ["Send", "Comment", "Reply", "Share", "Upload", " POST NOW ", "Publish now"] {
            let region = PhoneSubmissionGuard.TextRegion(text: label, confidence: 0.99, bounds: post.bounds)
            try PhoneSubmissionGuard.validate(action: .tap(0.85, 0.115), regions: [region], isFinalSubmission: true)
            try rejects(.tap(0.85, 0.115), final: false, regions: [region])
        }
        print("Submission guard tests passed (early publish gestures, keyboard submission, exact label dispatch, ambiguity/unknown rejection)")
    }
}

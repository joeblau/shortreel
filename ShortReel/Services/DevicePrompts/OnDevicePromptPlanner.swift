import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Interprets command phrasing locally. Every generated action is validated before
/// the executor receives a plan; this model has no access to the phone's screen.
@MainActor
enum OnDevicePromptPlanner {
    static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence on this Mac to interpret more natural requests. Simple commands such as ‘Open Safari’ still work."
            case .unavailable(.deviceNotEligible):
                return "This Mac does not support on-device language understanding. Try a simple command such as ‘Open Safari’."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is not ready yet. Try a simple command such as ‘Open Safari’."
            case .unavailable:
                return "On-device language understanding is unavailable. Try a simple command such as ‘Open Safari’."
            }
        }
        #endif
        return "More natural requests require macOS 26 or later with Apple Intelligence. Simple commands such as ‘Open Safari’ still work."
    }

    static func plan(_ prompt: String) async throws -> PhonePromptPlan {
        try Task.checkCancellation()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= DevicePromptPlanner.maximumPromptLength else {
            throw clarification("Describe a short phone action, such as ‘Open Safari’.")
        }
        if let reason = unavailabilityReason { throw clarification(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await generatePlan(prompt)
        }
        #endif
        throw clarification("Try a simple command such as ‘Open Safari’.")
    }

    private static func clarification(_ message: String) -> PhonePromptPlanningError {
        .needsClarification(message)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func generatePlan(_ prompt: String) async throws -> PhonePromptPlan {
        // Each prompt gets an independent session: there is no inferred screen
        // state or previous conversation to turn into unrequested actions.
        let session = LanguageModelSession(instructions: instructions)
        let generated: GeneratedPhonePlan
        do {
            generated = try await session.respond(
                to: prompt,
                generating: GeneratedPhonePlan.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 2400)
            ).content
        } catch {
            try Task.checkCancellation()
            throw clarification("I couldn’t interpret that request. Try explicit steps, such as ‘Open Safari, then type \"hello\"’.")
        }
        try Task.checkCancellation()
        guard generated.clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Do not execute even a supported prefix of a rejected request.
            throw clarification("That request needs more detail. I can open a named app, go Home, search, type supplied text, swipe, press a key, or tap explicit coordinates. I can’t see the phone’s screen.")
        }
        guard !generated.steps.isEmpty, generated.steps.count <= DevicePromptPlanner.maximumActions else {
            throw clarification("Describe up to \(DevicePromptPlanner.maximumActions) explicit phone actions.")
        }

        var cursor = prompt.startIndex
        var actions: [PhonePromptAction] = []
        for step in generated.steps {
            guard !step.source.isEmpty,
                  let sourceRange = prompt.range(of: step.source, range: cursor..<prompt.endIndex),
                  containsOnlyConnectors(String(prompt[cursor..<sourceRange.lowerBound])) else {
                throw clarification("I couldn’t account for every part of that request. Separate the actions with ‘then’ and include any text to type in quotes.")
            }
            cursor = sourceRange.upperBound
            let action = try validatedAction(step)
            // A model must not reinterpret a clause our exact parser understands.
            if let parsed = try? DevicePromptPlanner.plan(step.source), parsed.actions != [action] {
                throw clarification("That instruction has more than one interpretation. Try one explicit action at a time.")
            }
            actions.append(action)
        }
        guard containsOnlyConnectors(String(prompt[cursor...]), allowSequencing: false) else {
            throw clarification("I couldn’t account for the whole request. Try one explicit action at a time.")
        }
        let plan = PhonePromptPlan(actions: actions)
        try DevicePromptPlanner.validate(plan)
        return plan
    }

    @available(macOS 26.0, *)
    private static func validatedAction(_ step: GeneratedPhoneStep) throws -> PhonePromptAction {
        var commandWords = step.source
        if !step.text.isEmpty {
            guard step.text.count <= DevicePromptPlanner.maximumTextLength,
                  let payloadRange = commandWords.range(of: step.text) else {
                throw clarification("App names, search queries, and typed text must be supplied exactly in the request.")
            }
            commandWords.replaceSubrange(payloadRange, with: " ")
        }
        // Payloads may contain these words literally. Outside a payload, they
        // indicate another action or a goal that requires screen feedback.
        let unsupportedWords = #"\b(?:and|then|next|after|before|not|never|without|don['’]t|can['’]t|won['’]t|cannot|avoid|stop|times|twice|thrice|repeat|repeatedly|forever|again|\d+x|like|follow|unfollow|post|publish|send|message|buy|purchase|delete|remove|reply|comment|share|book|pay|read|inspect|find|locate|choose|select|wait|until|if)\b"#
        guard commandWords.range(of: unsupportedWords, options: [.regularExpression, .caseInsensitive]) == nil else {
            throw clarification("I can’t reliably carry out that whole instruction. Use separate, explicit phone actions.")
        }
        if step.kind != .tap {
            guard step.x == 0, step.y == 0 else { throw invalidFields() }
        }
        if step.kind != .swipe, !step.direction.isEmpty { throw invalidFields() }
        if step.kind != .press, !step.key.isEmpty { throw invalidFields() }

        switch step.kind {
        case .openApp:
            try requireText(step.text)
            return .openApp(step.text)
        case .search:
            try requireText(step.text)
            return .search(step.text)
        case .typeText:
            try requireText(step.text)
            return .typeText(step.text)
        case .home:
            guard step.text.isEmpty else { throw invalidFields() }
            return .home
        case .tap:
            guard step.text.isEmpty, step.x.isFinite, step.y.isFinite,
                  (0...1).contains(step.x), (0...1).contains(step.y),
                  coordinatesExplicitlyMatch(step) else {
                throw clarification("Give explicit tap coordinates, for example ‘Tap at 50%, 40%’. I can’t locate controls by their appearance.")
            }
            return .tap(step.x, step.y)
        case .swipe:
            guard step.text.isEmpty, let direction = PhoneSwipeDirection(rawValue: step.direction) else {
                throw invalidFields()
            }
            return .swipe(direction)
        case .press:
            guard step.text.isEmpty, let key = PhoneKey(rawValue: step.key) else {
                throw invalidFields()
            }
            return .press(key)
        }
    }

    private static func requireText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= DevicePromptPlanner.maximumTextLength else {
            throw clarification("Supply up to \(DevicePromptPlanner.maximumTextLength) characters of text for that action.")
        }
    }

    @available(macOS 26.0, *)
    private static func coordinatesExplicitlyMatch(_ step: GeneratedPhoneStep) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: #"[-+]?(?:\d+(?:\.\d+)?|\.\d+)\s*%?"#) else { return false }
        let matches = expression.matches(in: step.source, range: NSRange(step.source.startIndex..., in: step.source))
        let numbers = matches.compactMap { match -> Double? in
            guard let range = Range(match.range, in: step.source) else { return nil }
            let text = String(step.source[range]).trimmingCharacters(in: .whitespaces)
            let percent = text.hasSuffix("%")
            let raw = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            guard let value = Double(raw), value.isFinite else { return nil }
            return percent ? value / 100 : value
        }
        return numbers.count == 2 && abs(numbers[0] - step.x) < 0.000001 && abs(numbers[1] - step.y) < 0.000001
    }

    private static func containsOnlyConnectors(_ text: String, allowSequencing: Bool = true) -> Bool {
        let words = allowSequencing
            ? #"\b(?:and|then|next|after|that|first|finally|please|could|would|can|will|you|for|me|now)\b"#
            : #"\b(?:please|for|me|now)\b"#
        let withoutConnectors = text.replacingOccurrences(
            of: words,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        return withoutConnectors.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    private static func invalidFields() -> PhonePromptPlanningError {
        clarification("I couldn’t confidently interpret that action. Try a direct command such as ‘Open Safari’ or ‘Swipe up’.")
    }

    private static let instructions = """
        Translate the user's entire phone request into supported actions. You never observe or operate the phone.
        Supported kinds:
        openApp: open any explicitly named app. Its text is exactly the supplied app name. This action already includes phone Search and opening its result: do not add intermediate steps.
        home: go to the Home Screen.
        search: search the phone with an explicitly supplied literal query.
        typeText: type supplied literal text into the current focused field. Preserve capitalization, punctuation, and spacing; omit surrounding quotation marks that delimit the payload.
        tap: tap explicitly supplied coordinates x,y. Use fractions in 0...1; divide percentages by 100. Never infer coordinates from a named control or appearance.
        swipe: physical finger movement in up/down/left/right. Scrolling down requires swipe up, scrolling up requires swipe down; scrolling left requires swipe right and vice versa.
        press: enter, escape, backspace, or tab.
        For unused text, direction, and key fields use an empty string; unused x and y must be zero.
        Use only the actions explicitly requested, in order, with at most 12 actions. Each source is an exact contiguous clause copied verbatim from the request, including the action verb. Each clause describes one action. All requested actions must be covered. Preserve app names, queries and typed text verbatim from their source clauses. Never invent or compose text, app names or coordinates.
        Do not turn negated requests into actions. If the request says not to do something, or describes repetitions, return clarification and empty steps. A trailing connector such as ‘and then’ without a following action requires clarification.
        You cannot see or read the screen, locate named buttons, choose content, verify results, perform conditional tasks, wait for screen conditions, or perform goals such as messaging, posting, liking, following, purchases or deletions. Opening an app named Messages or typing literal words about these actions is supported. Opening Instagram or Safari is supported. Do not reinterpret an unsupported goal as a supported shortcut.
        If ANY part is unsupported, ambiguous or requires unseen screen state, set clarification and return an empty steps array. Never return a supported prefix of a request with unsupported remaining steps. If the entire request is supported, clarification is an empty string.
        Example request: Could you bring up Instagram for me?
        Example output: {"clarification":"","steps":[{"source":"bring up Instagram","kind":"openApp","text":"Instagram","x":0,"y":0,"direction":"","key":""}]}
        Example request: Open Instagram and like the first post
        Example output: {"clarification":"I cannot locate or like a post without screen feedback.","steps":[]}
        Example request: Tap the blue button
        Example output: {"clarification":"Provide explicit tap coordinates.","steps":[]}
        """
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private enum GeneratedPhoneActionKind {
    case openApp, home, search, typeText, tap, swipe, press
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedPhoneStep {
    @Guide(description: "Exact verbatim request clause for this action, including its verb")
    var source: String
    var kind: GeneratedPhoneActionKind
    @Guide(description: "Exact app name, search query, or typed text copied from source; empty for other kinds")
    var text: String
    @Guide(description: "Explicit normalized tap x coordinate, or zero for non-tap actions", .range(0...1))
    var x: Double
    @Guide(description: "Explicit normalized tap y coordinate, or zero for non-tap actions", .range(0...1))
    var y: Double
    @Guide(description: "Physical finger direction for swipe only; empty otherwise", .anyOf(["", "up", "down", "left", "right"]))
    var direction: String
    @Guide(description: "Key for press only; empty otherwise", .anyOf(["", "enter", "escape", "backspace", "tab"]))
    var key: String
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedPhonePlan {
    @Guide(description: "Empty if every requested action is supported, otherwise explain what requires clarification")
    var clarification: String
    @Guide(description: "All requested actions in order; empty if any part needs clarification", .count(0...12))
    var steps: [GeneratedPhoneStep]
}
#endif

import Foundation

enum DevicePromptPlanner {
    static let maximumActions = 12
    static let maximumRepetitions = 5
    static let maximumTextLength = 500
    static let maximumPromptLength = 4_000

    static func plan(_ prompt: String) throws -> PhonePromptPlan {
        guard prompt.count <= maximumPromptLength else {
            throw clarification("Keep a request under \(maximumPromptLength) characters and \(maximumActions) actions.")
        }
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw clarification("Describe an action, such as ‘Open Safari’ or ‘Swipe up’.")
        }

        var actions: [PhonePromptAction] = []
        for step in try splitSteps(input) {
            let next = try parseStep(step)
            guard actions.count + next.count <= maximumActions else {
                throw clarification("Use at most \(maximumActions) actions in one request.")
            }
            actions.append(contentsOf: next)
        }
        let result = PhonePromptPlan(actions: actions)
        try validate(result)
        return result
    }

    static func validate(_ plan: PhonePromptPlan) throws {
        guard !plan.actions.isEmpty, plan.actions.count <= maximumActions else {
            throw clarification("Use between 1 and \(maximumActions) actions in one request.")
        }
        for action in plan.actions {
            switch action {
            case .openApp(let name):
                try validatePayload(name, purpose: .app)
            case .search(let query):
                try validatePayload(query, purpose: .search)
            case .typeText(let text):
                try validatePayload(text, purpose: .text)
            case .tap(let x, let y), .doubleTap(let x, let y):
                guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                    throw clarification("Tap coordinates must be finite numbers between 0 and 1.")
                }
            case .drag(let x1, let y1, let x2, let y2):
                guard [x1, y1, x2, y2].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw clarification("Drag coordinates must be finite numbers between 0 and 1.")
                }
            case .longPress(let x, let y, let seconds):
                try validate(.init(actions: [.tap(x, y)]))
                guard seconds.isFinite, (0.2...3).contains(seconds) else {
                    throw clarification("Long press duration must be between 0.2 and 3 seconds.")
                }
            case .timedDrag(let x1, let y1, let x2, let y2, let duration, let press, let hold):
                try validate(.init(actions: [.drag(x1, y1, x2, y2)]))
                guard x1 != x2 || y1 != y2,
                      duration.isFinite, (0.1...3).contains(duration),
                      press.isFinite, (0...3).contains(press),
                      hold.isFinite, (0...3).contains(hold) else {
                    throw clarification("A drag needs distinct endpoints, 0.1–3 seconds of movement, and 0–3 seconds for each hold.")
                }
            case .home, .swipe, .press:
                break
            }
        }
    }

    private static func parseStep(_ original: String) throws -> [PhonePromptAction] {
        var step = original
        for _ in 0..<3 {
            guard let match = captures(#"^(?:please|can you|could you|would you)\s+(.+)$"#, in: step) else { break }
            step = match[0]
        }

        if let match = captures(#"^(?:open|launch)\s+(.+)$"#, in: step) {
            var value = match[0]
            if let namedApp = captures(#"^the app\s+(.+)$"#, in: value) {
                value = namedApp[0]
            } else if let namedApp = captures(#"^the\s+(.+?)\s+app[.!]?$"#, in: value) {
                value = namedApp[0]
            }
            let payload = try parsePayload(value, purpose: .app)
            return [.openApp(payload)]
        }
        if step.lowercased() == "search for" {
            throw clarification("Include the query after ‘Search for’, or quote the word you want to search for.")
        }
        if let match = captures(#"^search(?: for)?\s+(.+)$"#, in: step) {
            return [.search(try parsePayload(match[0], purpose: .search))]
        }
        if let match = captures(#"^type\s+(.+)$"#, in: step) {
            return [.typeText(try parsePayload(match[0], purpose: .text))]
        }

        var repetitions = 1
        if let match = captures(#"^(.+?)\s+(\d+)\s+times?[.!]?$"#, in: step) {
            guard let count = Int(match[1]), (1...maximumRepetitions).contains(count) else {
                throw clarification("Repeat an action between 1 and \(maximumRepetitions) times.")
            }
            step = match[0]
            repetitions = count
        } else if let match = captures(#"^(.+?)\s+(once|twice|three times)[.!]?$"#, in: step) {
            step = match[0]
            repetitions = ["once": 1, "twice": 2, "three times": 3][match[1].lowercased()]!
        }

        let action: PhonePromptAction
        if captures(#"^(?:home|go home|go to home|go to (?:the )?home screen|return home)[.!]?$"#, in: step) != nil {
            action = .home
        } else if captures(#"^(?:tap|click)(?: (?:at|in))? (?:the )?cent(?:er|re)(?: of (?:the )?screen)?[.!]?$"#, in: step) != nil {
            action = .tap(0.5, 0.5)
        } else if let match = captures(#"^(swipe|scroll)\s+(up|down|left|right)[.!]?$"#, in: step) {
            let direction = PhoneSwipeDirection(rawValue: match[1].lowercased())!
            if match[0].lowercased() == "scroll" {
                let opposite: [PhoneSwipeDirection: PhoneSwipeDirection] = [.up: .down, .down: .up, .left: .right, .right: .left]
                action = .swipe(opposite[direction]!)
            } else {
                action = .swipe(direction)
            }
        } else if let match = captures(#"^press\s+(?:the )?(enter|return|escape|esc|backspace|tab)(?: key)?[.!]?$"#, in: step) {
            let key: PhoneKey = switch match[0].lowercased() {
            case "return", "enter": .enter
            case "esc", "escape": .escape
            case "backspace": .backspace
            default: .tab
            }
            action = .press(key)
        } else if let match = captures(#"^(?:tap|click)(?: at)?\s+(.+)$"#, in: step) {
            action = try parseCoordinates(match[0])
        } else {
            throw clarification("I couldn’t understand ‘\(preview(original))’. Use actions like ‘Open Safari’, ‘Go home’, ‘Type \"Hello\"’, ‘Tap 50%, 50%’, or ‘Swipe up’, separated by ‘then’.")
        }
        return Array(repeating: action, count: repetitions)
    }

    private enum PayloadPurpose {
        case app, search, text
    }

    private static func parsePayload(_ input: String, purpose: PayloadPurpose) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String
        if let first = raw.first, let closing = closingQuote(for: first) {
            payload = try unquote(raw, closing: closing)
        } else {
            let appTail = #"\s(?:and|or|to|with|without|before|after|if|when|unless|until|while|because|but|also|not|except)\s"#
            let appAction = #"\s(?:open|launch|go|search|type|tap|click|swipe|scroll|press|send|post|publish|delete|remove|buy|purchase|like|follow|unfollow|message|reply|share)\b"#
            let actionTail = #"(?:\s|[,.!?])(?:and|or|to|before|after|while|but|also)\s+(?:please\s+)?(?:open|launch|go|return|search|type|tap|click|swipe|scroll|press|send|post|publish|delete|remove|buy|purchase|like|follow|unfollow|message|reply|share|don't|do not)\b"#
            if (purpose == .app && (contains(appTail, in: raw) || contains(appAction, in: raw))) || contains(actionTail, in: raw) {
                throw clarification("Separate each action with ‘then’. Put literal app names or text containing instructions in quotes. I can’t infer messages, purchases, deletions, or actions on named screen controls.")
            }
            payload = raw
        }

        try validatePayload(payload, purpose: purpose)
        return payload
    }

    private static func validatePayload(_ payload: String, purpose: PayloadPurpose) throws {
        guard !payload.isEmpty, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw clarification("Include an app name, search query, or text to type.")
        }
        guard payload.count <= maximumTextLength else {
            throw clarification("Keep each app name, search query, or typed text under \(maximumTextLength + 1) characters. Nothing has been sent.")
        }
        if purpose != .text && payload.contains(where: { $0.isNewline }) {
            throw clarification("Use a single line for an app name or search query.")
        }
        guard payload.unicodeScalars.allSatisfy({ (32...126).contains($0.value) || $0.value == 10 }) else {
            throw clarification("The phone’s Bluetooth keyboard currently supports US keyboard characters only. Use plain English letters, numbers, and punctuation; emoji and accented characters can’t be typed yet.")
        }
    }

    private static func parseCoordinates(_ original: String) throws -> PhonePromptAction {
        var value = original.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("(") && value.hasSuffix(")") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let number = #"([+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))"#
        guard let match = captures("^" + number + #"\s*(%)?\s*,\s*"# + number + #"\s*(%)?$"#, in: value),
              let x = Double(match[0]), let y = Double(match[2]), x.isFinite, y.isFinite,
              match[1].isEmpty == match[3].isEmpty else {
            throw clarification("Specify a tap as two coordinates, such as ‘Tap 50%, 25%’ or ‘Tap 0.5, 0.25’. I can’t locate named controls on the screen yet.")
        }
        let upperLimit = match[1].isEmpty ? 1.0 : 100.0
        guard (0...upperLimit).contains(x), (0...upperLimit).contains(y) else {
            throw clarification("Tap coordinates must both be between 0 and 1, or both between 0% and 100%.")
        }
        return .tap(x / upperLimit, y / upperLimit)
    }

    private static func splitSteps(_ input: String) throws -> [String] {
        let characters = Array(input)
        var steps: [String] = []
        var buffer = ""
        var quote: Character?
        var escaped = false
        var index = 0

        func appendStep(allowEmpty: Bool = false) throws {
            let step = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if step.isEmpty {
                if allowEmpty { return }
                throw clarification("Add an action on both sides of ‘then’ or a semicolon.")
            }
            steps.append(step)
            buffer = ""
            guard steps.count <= maximumActions else {
                throw clarification("Use at most \(maximumActions) actions in one request.")
            }
        }

        while index < characters.count {
            let character = characters[index]
            if let closing = quote {
                buffer.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == closing && isClosingQuote(closing, at: index, in: characters) {
                    quote = nil
                }
                index += 1
                continue
            }

            if let closing = closingQuote(for: character),
               character != "'" || index == 0 || characters[index - 1].isWhitespace {
                quote = closing
                buffer.append(character)
                index += 1
                continue
            }
            if character == ";" || character.isNewline {
                try appendStep(allowEmpty: character.isNewline)
                index += 1
                continue
            }
            if index + 4 <= characters.count,
               String(characters[index..<(index + 4)]).lowercased() == "then",
               (index == 0 || characters[index - 1].isWhitespace),
               (index + 4 == characters.count || characters[index + 4].isWhitespace) {
                buffer = buffer.trimmingCharacters(in: .whitespaces)
                if buffer.hasSuffix(",") { buffer.removeLast() }
                try appendStep()
                index += 4
                continue
            }
            buffer.append(character)
            index += 1
        }
        guard quote == nil else {
            throw clarification("Close the quotation marks around the text or app name.")
        }
        try appendStep()
        return steps
    }

    private static func unquote(_ raw: String, closing: Character) throws -> String {
        let characters = Array(raw)
        var result = ""
        var index = 1
        while index < characters.count {
            let character = characters[index]
            if character == closing && isClosingQuote(closing, at: index, in: characters) {
                guard index == characters.count - 1 else {
                    throw clarification("Put ‘then’ between actions. Text after a closing quote can’t be interpreted as another action.")
                }
                return result
            }
            if character == "\\", index + 1 < characters.count,
               characters[index + 1] == closing || characters[index + 1] == "\\" {
                result.append(characters[index + 1])
                index += 2
            } else {
                result.append(character)
                index += 1
            }
        }
        throw clarification("Close the quotation marks around the text or app name.")
    }

    private static func closingQuote(for opening: Character) -> Character? {
        switch opening {
        case "\"": "\""
        case "'": "'"
        case "“": "”"
        case "‘": "’"
        default: nil
        }
    }

    private static func isClosingQuote(_ quote: Character, at index: Int, in text: [Character]) -> Bool {
        if (quote == "'" || quote == "’"), index + 1 < text.count,
           text[index + 1].isLetter || text[index + 1].isNumber {
            return false
        }
        return true
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }

    private static func contains(_ pattern: String, in value: String) -> Bool {
        captures(pattern, in: value) != nil
    }

    private static func preview(_ value: String) -> String {
        value.count > 70 ? String(value.prefix(67)) + "…" : value
    }

    private static func clarification(_ message: String) -> PhonePromptPlanningError {
        .needsClarification(message)
    }
}

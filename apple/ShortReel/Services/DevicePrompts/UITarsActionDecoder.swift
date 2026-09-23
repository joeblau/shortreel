import Foundation

enum UITarsActionDecoder {
    static let actionSpace = """
        click(start_box='(x,y)')
        double_tap(start_box='(x,y)')
        long_press(start_box='(x,y)', duration='0.8')
        swipe(start_box='(x,y)', end_box='(x,y)')
        drag(start_box='(x,y)', end_box='(x,y)', duration='0.4', press_duration='0.5', hold_duration='0')
        scroll(start_box='(x,y)', direction='up|down|left|right', distance='300')
        type(content='text')
        hotkey(key='\(PhoneKey.allCases.map(\.rawValue).joined(separator: "|"))')
        press_home()
        open_app_switcher()
        open_assistive_touch()
        wait(seconds='1')
        finished()
        call_user()
        """
    static func decode(_ prediction: String, coordinateWidth: Double = 1000, coordinateHeight: Double = 1000) throws -> PhoneVisionDecision {
        guard coordinateWidth.isFinite, coordinateHeight.isFinite,
              (1...8192).contains(coordinateWidth), (1...8192).contains(coordinateHeight) else { throw invalid() }
        guard prediction.utf8.count <= 32_768 else { throw invalid(prediction) }
        var value = prediction.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), value.hasSuffix("```"), let newline = value.firstIndex(of: "\n") {
            value = String(value[value.index(after: newline)..<value.index(value.endIndex, offsetBy: -3)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headPattern = #"(?s)\AThought:\s*(.+?)\s*Action:\s*"#
        let headRegex = try NSRegularExpression(pattern: headPattern)
        guard let head = headRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let thoughtRange = Range(head.range(at: 1), in: value),
              let headEnd = Range(head.range(at: 0), in: value) else { throw invalid(value) }
        let reason = String(value[thoughtRange].trimmingCharacters(in: .whitespacesAndNewlines).prefix(900))
        let (name, argsText, tail) = try scanAction(value[headEnd.upperBound...], value)
        if tail.range(of: #"\bAction:|\b[a-z_]+\("#, options: .regularExpression) != nil { throw invalid(value) }
        let args = try arguments(argsText, value)
        func point(_ text: String, _ prediction: String) throws -> (Double, Double) {
            try Self.point(text, prediction, width: coordinateWidth, height: coordinateHeight)
        }
        func require(_ keys: Set<String>, optional: Set<String> = []) throws {
            guard keys.isSubset(of: Set(args.keys)), Set(args.keys).isSubset(of: keys.union(optional)) else { throw invalid(value) }
        }
        func number(_ key: String, default fallback: Double) throws -> Double {
            guard let text = args[key] else { return fallback }
            guard let number = Double(text), number.isFinite else { throw invalid(value) }
            return number
        }
        let decision: PhoneVisionDecision
        switch name {
        case "click", "tap":
            try require(["start_box"])
            let point = try point(args["start_box"]!, value)
            decision = .action(.tap(point.0, point.1), reason: reason)
        case "double_tap", "double_click", "left_double":
            try require(["start_box"])
            let point = try point(args["start_box"]!, value)
            decision = .action(.doubleTap(point.0, point.1), reason: reason)
        case "long_press":
            try require(["start_box"], optional: ["duration"])
            let point = try point(args["start_box"]!, value)
            decision = .action(.longPress(point.0, point.1, seconds: try number("duration", default: 0.8)), reason: reason)
        case "swipe", "drag":
            try require(["start_box", "end_box"], optional: ["duration", "press_duration", "hold_duration"])
            let start = try point(args["start_box"]!, value), end = try point(args["end_box"]!, value)
            guard start != end else { throw invalid(value) }
            if args.count == 2 {
                decision = .action(.drag(start.0, start.1, end.0, end.1), reason: reason)
            } else {
                decision = .action(.timedDrag(start.0, start.1, end.0, end.1,
                    duration: try number("duration", default: 0.4),
                    pressDuration: try number("press_duration", default: 0),
                    holdDuration: try number("hold_duration", default: 0)), reason: reason)
            }
        case "scroll":
            try require(["start_box", "direction", "distance"])
            let start = try point(args["start_box"]!, value)
            let horizontal = ["left", "right"].contains(args["direction"]!)
            let units = try number("distance", default: 300)
            let distance = units / (horizontal ? coordinateWidth : coordinateHeight)
            guard units >= 1, distance <= 1 else { throw invalid(value) }
            var end = start
            switch args["direction"]! {
            case "down": end.1 -= distance
            case "up": end.1 += distance
            case "right": end.0 -= distance
            case "left": end.0 += distance
            default: throw invalid(value)
            }
            decision = .action(.drag(start.0, start.1, end.0, end.1), reason: reason)
        case "type":
            try require(["content"])
            guard !args["content"]!.contains(where: \.isNewline) else {
                throw PhoneVisionError.invalidDecision("UI-TARS must type text and press Enter in separate steps.")
            }
            decision = .action(.typeText(args["content"]!), reason: reason)
        case "hotkey":
            try require(["key"])
            let key = args["key"]!.lowercased().trimmingCharacters(in: .whitespaces)
            let keys: [String: PhoneKey] = [
                "enter": .enter, "return": .enter, "escape": .escape, "esc": .escape,
                "backspace": .backspace, "tab": .tab, "search": .search,
                "selectall": .selectAll, "command+a": .selectAll, "cmd+a": .selectAll,
                "addressbar": .addressBar, "command+l": .addressBar, "cmd+l": .addressBar,
                "appswitcher": .appSwitcher,
                "command+space": .search, "cmd+space": .search,
                "cmd+c": .copy, "command+c": .copy, "cmd+x": .cut, "command+x": .cut,
                "cmd+v": .paste, "command+v": .paste, "cmd+z": .undo, "command+z": .undo,
                "cmd+shift+z": .redo, "command+shift+z": .redo, "shift+tab": .shiftTab
            ]
            if key == "home" {
                decision = .action(.home, reason: reason)
            } else if let mapped = PhoneKey.allCases.first(where: { $0.rawValue.lowercased() == key }) ?? keys[key] {
                decision = .action(.press(mapped), reason: reason)
            } else { throw PhoneVisionError.invalidDecision("UI-TARS requested an unsupported phone key.") }
        case "press_home":
            try require([])
            decision = .action(.home, reason: reason)
        case "open_app_switcher":
            try require([])
            decision = .action(.press(.appSwitcher), reason: reason)
        case "open_assistive_touch":
            try require([])
            decision = .action(.press(.assistiveTouch), reason: reason)
        case "wait":
            try require([], optional: ["seconds"])
            decision = .wait(seconds: try number("seconds", default: 2), reason: reason)
        case "finished":
            try require([], optional: ["content"])
            let content = args["content"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            decision = .finished(content?.isEmpty == false ? content! : reason)
        case "call_user":
            try require([], optional: ["content"])
            let content = args["content"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            decision = .needsInput(content?.isEmpty == false ? content! : reason)
        default:
            throw invalid(value, detail: "UI-TARS requested an unsupported phone action.")
        }
        return try decision.validated()
    }

    private static func point(_ text: String, _ prediction: String, width: Double, height: Double) throws -> (Double, Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) else { throw invalid(prediction) }
        let parts = trimmed.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 4 else { throw invalid(prediction) }
        let numbers = try parts.enumerated().map { index, part -> Double in
            let scale = index.isMultiple(of: 2) ? width : height
            guard let n = Double(part.trimmingCharacters(in: .whitespaces)), n.isFinite, (0...scale).contains(n) else {
                throw invalid(prediction)
            }
            return n
        }
        if numbers.count == 4 {
            guard numbers[0] <= numbers[2], numbers[1] <= numbers[3] else { throw invalid(prediction) }
            return ((numbers[0] + numbers[2]) / (2 * width), (numbers[1] + numbers[3]) / (2 * height))
        }
        return (numbers[0] / width, numbers[1] / height)
    }

    private static func arguments(_ text: String, _ prediction: String) throws -> [String: String] {
        let chars = Array(text)
        var index = 0
        var result: [String: String] = [:]
        func skipSpace() { while index < chars.count && chars[index].isWhitespace { index += 1 } }
        skipSpace()
        while index < chars.count {
            let start = index
            while index < chars.count && (chars[index].isASCII && (chars[index].isLetter || chars[index] == "_")) { index += 1 }
            guard index > start else { throw invalid(prediction) }
            let key = String(chars[start..<index])
            skipSpace()
            guard index < chars.count && chars[index] == "=" else { throw invalid(prediction) }
            index += 1
            skipSpace()
            guard index < chars.count && (chars[index] == "'" || chars[index] == "\"") else { throw invalid(prediction) }
            let quote = chars[index]
            index += 1
            var value = ""
            var closed = false
            while index < chars.count {
                let char = chars[index]
                index += 1
                if char == quote { closed = true; break }
                if char == "\\" {
                    guard index < chars.count else { throw invalid(prediction) }
                    let escaped = chars[index]
                    index += 1
                    switch escaped {
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    case "\\", "'", "\"": value.append(escaped)
                    default: throw invalid(prediction)
                    }
                } else { value.append(char) }
            }
            guard closed, result[key] == nil else { throw invalid(prediction) }
            result[key] = value
            skipSpace()
            if index == chars.count { break }
            guard chars[index] == "," else { throw invalid(prediction) }
            index += 1
            skipSpace()
            guard index < chars.count else { throw invalid(prediction) }
        }
        return result
    }

    private static func scanAction(_ text: Substring, _ prediction: String) throws -> (name: String, args: String, tail: Substring) {
        var index = text.startIndex
        let nameStart = index
        while index < text.endIndex, text[index].isASCII, text[index].isLetter || text[index] == "_" {
            index = text.index(after: index)
        }
        guard index > nameStart else { throw invalid(prediction) }
        let name = String(text[nameStart..<index])
        guard index < text.endIndex, text[index] == "(" else { throw invalid(prediction) }
        index = text.index(after: index)
        let argsStart = index
        var quote: Character?
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if let active = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == active { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ")" {
                return (name, String(text[argsStart..<index]), text[text.index(after: index)...])
            }
            index = text.index(after: index)
        }
        throw invalid(prediction)
    }

    private static func invalid(_ prediction: String? = nil,
                                detail: String = "UI-TARS must return one supported action with valid coordinates and arguments.") -> PhoneVisionError {
        var message = "\(detail) No input was sent."
        if let snippet = prediction?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160), !snippet.isEmpty {
            message += " The model returned: “\(snippet)”"
        }
        return .invalidDecision(message)
    }
}

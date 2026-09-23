import Foundation

enum PhonePlannerResponse {
    private enum Kind: String, Decodable, CaseIterable {
        case home, tap, doubleTap, longPress, drag, swipe, typeText, press, wait, finished, needsInput

        var fields: [String] {
            switch self {
            case .home, .finished, .needsInput: []
            case .tap, .doubleTap: ["x", "y"]
            case .longPress: ["x", "y", "seconds"]
            case .drag: ["x", "y", "endX", "endY", "duration", "pressDuration", "holdDuration"]
            case .swipe: ["direction"]
            case .typeText: ["text"]
            case .press: ["key"]
            case .wait: ["seconds"]
            }
        }
    }

    private struct Payload: Decodable {
        let kind: Kind
        let reason: String
        var x: Double?, y: Double?, endX: Double?, endY: Double?
        var seconds: Double?, duration: Double?, pressDuration: Double?, holdDuration: Double?
        var text: String?, key: String?, direction: String?

        mutating func normalizeCoordinates(imageSize: CGSize?) {
            let width = imageSize.map { Double($0.width) } ?? 0
            let height = imageSize.map { Double($0.height) } ?? 0
            var pairs: [(value: Double, extent: Double)] = []
            for (value, extent) in [(x, width), (y, height), (endX, width), (endY, height)] {
                guard let value else { continue }
                pairs.append((value, extent))
            }
            guard !pairs.isEmpty, let converted = PhonePlannerResponse.normalized(pairs) else { return }
            var next = converted.makeIterator()
            if x != nil { x = next.next() }
            if y != nil { y = next.next() }
            if endX != nil { endX = next.next() }
            if endY != nil { endY = next.next() }
        }
    }

    private static func normalized(_ coordinates: [(value: Double, extent: Double)]) -> [Double]? {
        let values = coordinates.map(\.value)
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        if values.allSatisfy({ $0 <= 1 }) { return values }
        if values.allSatisfy({ $0 <= 100 }) { return values.map { $0 / 100 } }
        guard coordinates.allSatisfy({ $0.extent > 100 && $0.value <= $0.extent }) else { return nil }
        return coordinates.map { $0.value / $0.extent }
    }

    static func schema(inspectOnly: Bool) throws -> Data {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        let text: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number"]
        let coordinate: [String: Any] = ["type": "number", "description":
            "Fraction of the CURRENT image, 0 to 1, with (0,0) at the top-left. Never pixels or percent."]
        var properties: [String: Any] = ["screen": object([
            "state": ["type": "string", "enum": ["home", "homeEditing", "appSwitcher", "foregroundApp", "spotlight", "assistiveTouch", "dialog", "unknown"]],
            "appCardsVisible": ["type": "boolean"], "evidence": text,
            "checkEvidence": ["type": ["string", "null"], "maxLength": 180],
            "keyboardVisible": ["type": ["boolean", "null"]],
            "video": ["anyOf": [object([
                "creator": text, "caption": text,
                "progress": ["type": ["number", "null"], "minimum": 0, "maximum": 1],
                "durationSeconds": ["type": ["number", "null"]],
                "playing": ["type": ["boolean", "null"]],
                "liked": ["type": ["boolean", "null"]],
                "followButtonVisible": ["type": ["boolean", "null"]]
            ]), ["type": "null"]]]
        ])]
        if !inspectOnly {
            properties["decision"] = ["anyOf": Kind.allCases.filter { $0 != .home }.map { kind in
                var fields: [String: Any] = ["kind": ["type": "string", "enum": [kind.rawValue]], "reason": text]
                for field in kind.fields {
                    switch field {
                    case "text": fields[field] = text
                    case "key": fields[field] = ["type": "string", "enum": PhoneKey.allCases.map(\.rawValue)]
                    case "direction": fields[field] = ["type": "string", "enum": PhoneSwipeDirection.allCases.map(\.rawValue)]
                    case "x", "y", "endX", "endY": fields[field] = coordinate
                    default: fields[field] = number
                    }
                }
                return object(fields)
            }]
        }
        return try JSONSerialization.data(withJSONObject: object(properties), options: [.sortedKeys])
    }

    static func observation(from data: Data) throws -> PhoneScreenObservation {
        let root = try object(data, keys: ["screen"])
        return try screen(root["screen"])
    }

    static func decision(from data: Data, goal: String, imageSize: CGSize? = nil) throws -> PhoneVisionDecision {
        let root = try object(data, keys: ["screen", "decision"])
        let observation = try screen(root["screen"])
        guard let value = root["decision"] as? [String: Any],
              let name = value["kind"] as? String, let kind = Kind(rawValue: name),
              Set(value.keys) == Set(["kind", "reason"] + kind.fields),
              var payload = try? JSONDecoder().decode(Payload.self, from: JSONSerialization.data(withJSONObject: value)) else {
            throw invalid("one complete phone action")
        }
        guard value.values.allSatisfy({ !($0 is NSNull) }) else { throw invalid("non-null action fields") }
        payload.normalizeCoordinates(imageSize: imageSize)
        func number(_ value: Double?) throws -> Double {
            guard let value, value.isFinite else { throw invalid("finite input coordinates and timing") }
            return value
        }
        let decision: PhoneVisionDecision
        switch kind {
        case .home: decision = .action(.home, reason: payload.reason)
        case .tap: decision = .action(try .tap(number(payload.x), number(payload.y)), reason: payload.reason)
        case .doubleTap: decision = .action(try .doubleTap(number(payload.x), number(payload.y)), reason: payload.reason)
        case .longPress:
            decision = .action(try .longPress(number(payload.x), number(payload.y), seconds: number(payload.seconds)), reason: payload.reason)
        case .drag:
            decision = .action(try .timedDrag(number(payload.x), number(payload.y), number(payload.endX), number(payload.endY),
                duration: number(payload.duration), pressDuration: number(payload.pressDuration), holdDuration: number(payload.holdDuration)), reason: payload.reason)
        case .swipe:
            guard let name = payload.direction, let direction = PhoneSwipeDirection(rawValue: name) else { throw invalid("a finger-swipe direction") }
            decision = .action(.swipe(direction), reason: payload.reason)
        case .typeText:
            guard let text = payload.text, !text.contains(where: \.isNewline) else { throw invalid("one line of text") }
            decision = .action(.typeText(text), reason: payload.reason)
        case .press:
            guard let name = payload.key, let key = PhoneKey(rawValue: name) else { throw invalid("a supported phone key") }
            decision = .action(.press(key), reason: payload.reason)
        case .wait: decision = .wait(seconds: try number(payload.seconds), reason: payload.reason)
        case .finished: decision = .finished(payload.reason)
        case .needsInput: decision = .needsInput(payload.reason)
        }
        do { _ = try decision.validated() }
        catch { throw invalid("an action within the phone input limits") }
        try checkNavigation(decision, observation: observation, goal: goal)
        return decision
    }

    private static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys else {
            throw invalid("a single JSON response matching the requested schema")
        }
        return object
    }

    private static func screen(_ value: Any?) throws -> PhoneScreenObservation {
        guard let value = value as? [String: Any],
              Set(value.keys).isSubset(of: ["state", "appCardsVisible", "evidence", "checkEvidence", "keyboardVisible", "video"]),
              let screen = try? JSONDecoder().decode(PhoneScreenObservation.self, from: JSONSerialization.data(withJSONObject: value)),
              !screen.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, screen.evidence.count <= 600,
              screen.appCardsVisible == (screen.state == .appSwitcher),
              screen.checkEvidence.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 180 }) ?? true,
              screen.video?.isValid ?? true else {
            throw invalid("a consistent screen observation with visible evidence")
        }
        return screen
    }

    private static func checkNavigation(_ decision: PhoneVisionDecision, observation: PhoneScreenObservation, goal: String) throws {
        if case .action(.home, _) = decision {
            throw invalid("a tap on the visible AssistiveTouch button, then its Home control on the next screenshot, instead of a Home swipe")
        }
        if observation.state == .appSwitcher, case .action(.press(.appSwitcher), _) = decision { throw invalid("an action inside the already open App Switcher") }
        if observation.state == .unknown {
            switch decision {
            case .action(.press(.assistiveTouch), _), .wait, .needsInput: break
            default: throw invalid("an identified screen before selecting targets or claiming completion")
            }
        }
        guard let plan = try? DevicePromptPlanner.plan(goal), case .openApp = plan.actions.first else { return }
        if plan.actions.count == 1, case .finished = decision, observation.state != .foregroundApp {
            throw invalid("the requested app visibly in the foreground before finishing")
        }
        if observation.state == .home {
            switch decision {
            case .action(.tap, _), .action(.swipe(.down), _), .action(.press(.search), _), .wait, .needsInput: break
            case .action(.timedDrag(let x, let y, let endX, let endY, _, _, _), _)
                where (0.2...0.7).contains(y) && endY > y + 0.15 && abs(endX - x) < 0.15: break
            default: throw invalid("tapping the visible app icon or opening Spotlight from Home; inspect search before typing")
            }
        }
    }

    private static func invalid(_ requirement: String) -> PhoneVisionError {
        .invalidDecision("The planner must return \(requirement). No input was sent.")
    }
}

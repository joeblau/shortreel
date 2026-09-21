import Foundation

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/SemanticIfPrompt.swift Tests/SemanticIfPromptTests.swift -o /tmp/shortreel-semif-prompt-tests
@main
enum SemanticIfPromptTests {
    enum Failure: Error { case assertion(String) }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    static func expectThrows<E: Error & Equatable>(_ expected: E, _ message: String,
                                                   _ body: () throws -> Void) throws {
        do {
            try body()
            throw Failure.assertion("\(message): expected \(expected), nothing was thrown")
        } catch let error as E {
            try expect(error == expected, "\(message): expected \(expected), got \(error)")
        }
    }

    static func main() throws {
        try validationRejectsBadRows()
        try letterAssignmentAndMessageShape()
        try pythonJSONRendering()
        try jsonParsing()
        try answerSlotChecks()
        try goldenPromptParity()
        print("SemanticIf prompt tests passed (6 scenarios)")
    }

    static func sampleRow(optionCount: Int = 3) -> SemanticIfDecision {
        SemanticIfDecision(
            id: "support-1",
            state: .string("The deployment completed at 14:02 UTC."),
            question: "Is there evidence that the deployment succeeded?",
            options: (0..<optionCount).map {
                .init(id: "option-\($0)", description: "Description \($0).")
            })
    }

    // MARK: - validate_row parity

    static func validationRejectsBadRows() throws {
        try expectThrows(SemanticIfPromptError.missingFields(["state"]), "Missing state accepted") {
            _ = try SemanticIfDecision(json: .object([
                ("id", .string("x")), ("question", .string("q")),
                ("options", .array([optionJSON("a"), optionJSON("b")])),
            ]))
        }
        try expectThrows(SemanticIfPromptError.missingFields(["id", "options"]), "Missing fields accepted") {
            _ = try SemanticIfDecision(json: .object([
                ("question", .string("q")), ("state", .string("s")),
            ]))
        }
        try expectThrows(SemanticIfPromptError.invalidIDOrQuestion, "Empty id accepted") {
            try SemanticIfPrompt.validate(SemanticIfDecision(id: "", state: .string("s"), question: "q",
                options: [.init(id: "a", description: "A"), .init(id: "b", description: "B")]))
        }
        try expectThrows(SemanticIfPromptError.invalidIDOrQuestion, "Empty question accepted") {
            try SemanticIfPrompt.validate(SemanticIfDecision(id: "x", state: .string("s"), question: "",
                options: [.init(id: "a", description: "A"), .init(id: "b", description: "B")]))
        }
        for state: SemanticIfJSON in [.null, .bool(true), .integer(1), .string(""), .array([]), .object([])] {
            try expectThrows(SemanticIfPromptError.invalidState, "Invalid state accepted: \(state.pythonDumped)") {
                try SemanticIfPrompt.validate(SemanticIfDecision(id: "x", state: state, question: "q",
                    options: [.init(id: "a", description: "A"), .init(id: "b", description: "B")]))
            }
        }
        for state: SemanticIfJSON in [.object([("x", .double(.nan))]),
                                      .array([.string("ok"), .double(-.infinity)])] {
            try expectThrows(SemanticIfPromptError.nonFiniteState, "Non-finite state accepted") {
                try SemanticIfPrompt.validate(SemanticIfDecision(id: "x", state: state, question: "q",
                    options: [.init(id: "a", description: "A"), .init(id: "b", description: "B")]))
            }
        }
        try expectThrows(SemanticIfPromptError.invalidOptionCount, "Single option accepted") {
            try SemanticIfPrompt.validate(sampleRow(optionCount: 1))
        }
        try expectThrows(SemanticIfPromptError.invalidOptionCount, "Seventeen options accepted") {
            try SemanticIfPrompt.validate(sampleRow(optionCount: 17))
        }
        try SemanticIfPrompt.validate(sampleRow(optionCount: 16))
        try SemanticIfPrompt.validate(sampleRow(optionCount: 2))
        try expectThrows(SemanticIfPromptError.duplicateOptionIDs, "Duplicate option ids accepted") {
            try SemanticIfPrompt.validate(SemanticIfDecision(id: "x", state: .string("s"), question: "q",
                options: [.init(id: "same", description: "A"), .init(id: "same", description: "B")]))
        }
        try expectThrows(SemanticIfPromptError.invalidOptionCount, "Non-array options accepted") {
            _ = try SemanticIfDecision(json: .object([
                ("id", .string("x")), ("question", .string("q")), ("state", .string("s")),
                ("options", .string("not-a-list")),
            ]))
        }
        try expectThrows(SemanticIfPromptError.invalidOption, "Option without description accepted") {
            _ = try SemanticIfDecision(json: .object([
                ("id", .string("x")), ("question", .string("q")), ("state", .string("s")),
                ("options", .array([optionJSON("a"), .object([("id", .string("b"))])])),
            ]))
        }
        try expect(SemanticIfPromptError.invalidAnswerSlot("A").message
            == "Answer slot 'A' is not one exact round-trip token", "Error text drifted from Semif")
        try expect(SemanticIfPromptError.inputTokensExceedLimit(rowID: "r", count: 5000, maxTokens: 4096).message
            == "Row r: 5000 input tokens exceed limit 4096; no truncation allowed", "Limit error text drifted from Semif")
    }

    static func optionJSON(_ id: String) -> SemanticIfJSON {
        .object([("id", .string(id)), ("description", .string("Description for \(id)."))])
    }

    // MARK: - direct_messages parity

    static func letterAssignmentAndMessageShape() throws {
        let row = SemanticIfDecision(
            id: "route-1",
            state: .object([("queue", .string("reset")), ("attempts", .integer(2))]),
            question: "Which queue?",
            options: [.init(id: "yes", description: "Yes."), .init(id: "no", description: "No.")])
        let messages = try SemanticIfPrompt.directMessages(row)
        try expect(messages.count == 2 && messages[0].role == .system && messages[1].role == .user,
            "Semif sends exactly one system and one user message")
        try expect(messages[0].content == SemanticIfPrompt.directSystem, "System prompt drifted from DIRECT_SYSTEM")
        try expect(SemanticIfPrompt.directSystem == "Apply the supplied criterion to the supplied evidence. "
            + "Choose exactly one listed option. "
            + "Respond with only its uppercase letter, with no explanation or reasoning.",
            "DIRECT_SYSTEM is not verbatim")
        let expected = #"{"evidence": {"queue": "reset", "attempts": 2}, "criterion": "Which queue?", "#
            + #""options": [{"letter": "A", "description": "Yes."}, {"letter": "B", "description": "No."}]}"#
        try expect(messages[1].content == expected, "User payload drifted:\n\(messages[1].content)")
        try expect(!messages[1].content.contains("yes"), "Option ids must not leak into the prompt")
        let sixteen = try SemanticIfPrompt.directMessages(sampleRow(optionCount: 16))
        let last = #""letter": "P""#
        try expect(sixteen[1].content.contains(last), "Sixteenth option must use letter P")
        try expect(SemanticIfPrompt.letters.map(String.init) == Array("ABCDEFGHIJKLMNOP").map(String.init),
            "LETTERS drifted")
        try expect(SemanticIfPrompt.promptVersion == "direct-options-v1", "PROMPT_VERSION drifted")
    }

    // MARK: - json.dumps(value, ensure_ascii=False) parity

    static func pythonJSONRendering() throws {
        let value: SemanticIfJSON = .object([
            ("unicode", .string("héllo → 世界")),
            ("escaped", .string("quote \" slash \\ tab \t newline \n bell \u{07}")),
            ("integer", .integer(-42)),
            ("double", .double(1.0)),
            ("fraction", .double(0.1)),
            ("big", .double(1e20)),
            ("list", .array([.bool(true), .null])),
        ])
        let expected = #"{"unicode": "héllo → 世界", "escaped": "quote \" slash \\ tab \t newline \n bell \u0007", "#
            + #""integer": -42, "double": 1.0, "fraction": 0.1, "big": 1e+20, "list": [true, null]}"#
        try expect(value.pythonDumped == expected, "Python-style dump drifted:\n\(value.pythonDumped)")
        try expect(SemanticIfJSON.double(-0.0).pythonDumped == "-0.0", "Negative zero drifted")
        try expect(SemanticIfJSON.double(1e-5).pythonDumped == "1e-05", "Small exponent drifted")
        try expect(SemanticIfJSON.double(.infinity).pythonDumped == "Infinity"
            && SemanticIfJSON.double(.nan).pythonDumped == "NaN", "Python non-finite rendering drifted")
    }

    // MARK: - JSONL decoding

    static func jsonParsing() throws {
        let parsed = try SemanticIfJSON.parse(#"{"a": [1, 1.5, "x", true, null], "b": {"c": "😀"}}"#)
        let expected: SemanticIfJSON = .object([
            ("a", .array([.integer(1), .double(1.5), .string("x"), .bool(true), .null])),
            ("b", .object([("c", .string("😀"))])),
        ])
        try expect(parsed == expected, "JSON parse drifted: \(parsed)")
        let escaped = try SemanticIfJSON.parse(#""A😀""#)
        try expect(escaped == .string("A😀"), "Unicode escapes drifted")
        try expectThrows(SemanticIfPromptError.malformedJSON("Trailing content after JSON document"),
            "Trailing content accepted") {
            _ = try SemanticIfJSON.parse("{} {}")
        }
        let roundTripped = try SemanticIfJSON.parse(parsed.pythonDumped)
        try expect(roundTripped == parsed, "Parse/dump round trip drifted")
    }

    // MARK: - answer slots and the boundary check

    static func answerSlotChecks() throws {
        let tokenizer = CharacterTokenizer()
        let encoded = try SemanticIfPrompt.encodePrompt(sampleRow(), tokenizer: tokenizer)
        let letters = ["A", "B", "C"].map { tokenizer.encode($0) }
        try expect(encoded.answerSlots == letters.flatMap { $0 }, "Slot ids are not the single-token letter encodings")
        try expect(encoded.answerSlots.count == 3 && Set(encoded.answerSlots).count == 3, "Slot ids drifted")
        let renderedPrompt = try SemanticIfPrompt.applyQwen35ChatTemplate(
            SemanticIfPrompt.directMessages(sampleRow()))
        try expect(encoded.promptHash == SemanticIfPrompt.digest(renderedPrompt),
            "Prompt hash is not digest(rendered prompt)")

        // A letter that needs two tokens is rejected, never approximated.
        try expectThrows(SemanticIfPromptError.invalidAnswerSlot("A"), "Multi-token slot accepted") {
            _ = try SemanticIfPrompt.encodePrompt(sampleRow(), tokenizer: SplittingSlotTokenizer())
        }
        // A letter whose decode round trip differs is rejected.
        try expectThrows(SemanticIfPromptError.invalidAnswerSlot("B"), "Bad round trip accepted") {
            _ = try SemanticIfPrompt.encodePrompt(sampleRow(), tokenizer: MisdecodingSlotTokenizer())
        }
        // Two letters sharing one token collide.
        try expectThrows(SemanticIfPromptError.answerSlotCollision, "Colliding slots accepted") {
            _ = try SemanticIfPrompt.answerSlotIDs(tokenizer: CollidingSlotTokenizer(script: DecodeScript()), count: 2)
        }
        // A merge across the prompt/letter boundary shifts tokenization.
        try expectThrows(SemanticIfPromptError.answerBoundaryShift("A"), "Boundary merge accepted") {
            _ = try SemanticIfPrompt.encodePrompt(sampleRow(), tokenizer: CharacterTokenizer(merges: ["\nA": 900]))
        }
        // Over-limit and empty encodings are rejected without truncation.
        let probe = CharacterTokenizer()
        let promptCount = try probe.encode(SemanticIfPrompt.applyQwen35ChatTemplate(
            SemanticIfPrompt.directMessages(sampleRow()))).count
        try expectThrows(SemanticIfPromptError.inputTokensExceedLimit(rowID: "support-1", count: promptCount, maxTokens: 3),
            "Over-limit prompt accepted") {
            _ = try SemanticIfPrompt.encodePrompt(sampleRow(), tokenizer: CharacterTokenizer(), maxTokens: 3)
        }
        try expectThrows(SemanticIfPromptError.inputTokensExceedLimit(rowID: "support-1", count: 0, maxTokens: 4096),
            "Empty encoding accepted") {
            _ = try SemanticIfPrompt.encodePrompt(sampleRow(), tokenizer: EmptyTokenizer())
        }
    }

    // MARK: - prompt hash parity with Semif's recorded pipeline

    /// Golden hashes computed by rendering the pinned Qwen3.5-4B chat template
    /// (chat_template.jinja sha256 a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715)
    /// with jinja2 under Semif's exact flags and hashing with Semif's digest().
    /// That pipeline reproduces the recorded prompt_sha256 values in Semif's
    /// results/mlx/2026-09-17-cli-smoke rows byte-for-byte (3/3 matched).
    static func goldenPromptParity() throws {
        let fixture = try String(contentsOfFile: "SemanticIf/Fixtures/decisions.jsonl", encoding: .utf8)
        let rows = try fixture.split(separator: "\n", omittingEmptySubsequences: true)
            .map { try SemanticIfDecision(json: SemanticIfJSON.parse(String($0))) }
        try expect(rows.map(\.id) == ["support-1", "route-1", "policy-1"], "Fixture rows drifted")
        let golden = [
            "7ac35785358f0c656eeb741ca0a51f03e0133753a71e2879a18ad0ab56d0c024",
            "016267542103ab91422c425d2234ec7e1b9aef77f9d3e481b96db2de7cca470a",
            "6884fc4a9117b63369dd79e3042b92f92678f1e08dba2600e93d1da6754b1787",
        ]
        for (row, hash) in zip(rows, golden) {
            let prompt = try SemanticIfPrompt.applyQwen35ChatTemplate(SemanticIfPrompt.directMessages(row))
            try expect(SemanticIfPrompt.digest(prompt) == hash, "Prompt hash for \(row.id) diverged from Semif")
        }
        let supportPrompt = try SemanticIfPrompt.applyQwen35ChatTemplate(SemanticIfPrompt.directMessages(rows[0]))
        let expected = "<|im_start|>system\n"
            + "Apply the supplied criterion to the supplied evidence. Choose exactly one listed option. "
            + "Respond with only its uppercase letter, with no explanation or reasoning.<|im_end|>\n"
            + "<|im_start|>user\n"
            + #"{"evidence": "The deployment completed at 14:02 UTC. Health checks passed in all three zones. "#
            + #"No rollback was initiated.", "criterion": "Is there evidence that the deployment succeeded?", "#
            + #""options": [{"letter": "A", "description": "The deployment succeeded."}, "#
            + #"{"letter": "B", "description": "The deployment did not succeed."}, "#
            + #"{"letter": "C", "description": "The evidence is insufficient to decide."}]}<|im_end|>"#
            + "\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        try expect(supportPrompt == expected, "Rendered prompt bytes drifted:\n\(supportPrompt)")
        try expect(SemanticIfPrompt.digest("") ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "digest() is not SHA-256 hex")
    }
}

/// One-token-per-character tokenizer; optional greedy merges model BPE pairs.
struct CharacterTokenizer: SemanticIfTokenizing {
    var merges: [String: Int32] = [:]

    func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        var rest = text[...]
        while !rest.isEmpty {
            if let (merge, token) = merges.filter({ rest.hasPrefix($0.key) }).max(by: { $0.key.count < $1.key.count }) {
                ids.append(token)
                rest = rest.dropFirst(merge.count)
            } else {
                ids.append(Int32(rest.first!.unicodeScalars.first!.value))
                rest = rest.dropFirst()
            }
        }
        return ids
    }

    func decode(_ tokens: [Int32]) -> String {
        tokens.compactMap { Unicode.Scalar(UInt32($0)).map(String.init) }.joined()
    }

    func applyDirectChatTemplate(_ messages: [SemanticIfMessage]) throws -> String {
        try SemanticIfPrompt.applyQwen35ChatTemplate(messages)
    }
}

/// Every "A" costs two tokens: the slot check must reject the row.
struct SplittingSlotTokenizer: SemanticIfTokenizing {
    func encode(_ text: String) -> [Int32] {
        text.flatMap { $0 == "A" ? [65, 651] : [Int32($0.unicodeScalars.first!.value)] }
    }

    func decode(_ tokens: [Int32]) -> String {
        tokens.filter { $0 != 651 }
            .compactMap { Unicode.Scalar(UInt32($0)).map(String.init) }.joined()
    }

    func applyDirectChatTemplate(_ messages: [SemanticIfMessage]) throws -> String {
        try SemanticIfPrompt.applyQwen35ChatTemplate(messages)
    }
}

/// "B" decodes back as "X": the round-trip check must reject the row.
struct MisdecodingSlotTokenizer: SemanticIfTokenizing {
    func encode(_ text: String) -> [Int32] {
        text.map { Int32($0.unicodeScalars.first!.value) }
    }

    func decode(_ tokens: [Int32]) -> String {
        tokens.map { $0 == 66 ? "X" : Unicode.Scalar(UInt32($0)).map(String.init) ?? "" }.joined()
    }

    func applyDirectChatTemplate(_ messages: [SemanticIfMessage]) throws -> String {
        try SemanticIfPrompt.applyQwen35ChatTemplate(messages)
    }
}

/// Both "A" and "B" claim token 70 while round-tripping correctly: collision.
final class DecodeScript: @unchecked Sendable {
    var results = ["A", "B"]
    var index = 0
}

struct CollidingSlotTokenizer: SemanticIfTokenizing {
    let script: DecodeScript

    func encode(_ text: String) -> [Int32] {
        if text == "A" || text == "B" { return [70] }
        return text.map { Int32($0.unicodeScalars.first!.value) }
    }

    func decode(_ tokens: [Int32]) -> String {
        defer { script.index += 1 }
        return script.index < script.results.count ? script.results[script.index] : "?"
    }

    func applyDirectChatTemplate(_ messages: [SemanticIfMessage]) throws -> String {
        try SemanticIfPrompt.applyQwen35ChatTemplate(messages)
    }
}

/// Encodes everything to nothing: Semif rejects empty encodings.
struct EmptyTokenizer: SemanticIfTokenizing {
    func encode(_ text: String) -> [Int32] { [] }
    func decode(_ tokens: [Int32]) -> String { "" }
    func applyDirectChatTemplate(_ messages: [SemanticIfMessage]) throws -> String {
        try SemanticIfPrompt.applyQwen35ChatTemplate(messages)
    }
}

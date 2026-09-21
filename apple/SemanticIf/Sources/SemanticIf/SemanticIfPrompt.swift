import CryptoKit
import Foundation

/// Pure-Swift port of Semif's direct-readout prompt contract, from
/// `src/semif_phase1/core.py` and `src/semif_phase1/direct.py`
/// (TheoLeeCJ/SemIf, MIT license). A decision row is rendered into a
/// system + user chat pair, templated exactly as Semif's
/// `apply_chat_template(..., tokenize=False, add_generation_prompt=True,
/// enable_thinking=False)` call, encoded, and every answer letter is proven
/// to occupy exactly one token appended after the prompt. Rows that fail any
/// check are rejected by throwing; nothing is ever approximated.
///
/// Tokenization stays behind `SemanticIfTokenizing` so tests can run against
/// a stub; issue #10 wires the real swift-transformers tokenizer in.
enum SemanticIfPrompt {
    /// `LETTERS` in core.py: answer slots in declaration order.
    static let letters = Array("ABCDEFGHIJKLMNOP")

    /// `DIRECT_SYSTEM` in core.py, verbatim.
    static let directSystem = "Apply the supplied criterion to the supplied evidence. "
        + "Choose exactly one listed option. "
        + "Respond with only its uppercase letter, with no explanation or reasoning."

    /// `PROMPT_VERSION` in direct.py.
    static let promptVersion = "direct-options-v1"

    // MARK: - Row validation (`validate_row` in core.py)

    static func validate(_ row: SemanticIfDecision) throws {
        if row.id.isEmpty || row.question.isEmpty {
            throw SemanticIfPromptError.invalidIDOrQuestion
        }
        let stateIsUsable: Bool
        switch row.state {
        case .string(let text): stateIsUsable = !text.isEmpty
        case .array(let items): stateIsUsable = !items.isEmpty
        case .object(let fields): stateIsUsable = !fields.isEmpty
        case .null, .bool, .integer, .double: stateIsUsable = false
        }
        guard stateIsUsable else {
            throw SemanticIfPromptError.invalidState
        }
        guard row.state.isFiniteJSON else {
            throw SemanticIfPromptError.nonFiniteState
        }
        guard (2...letters.count).contains(row.options.count) else {
            throw SemanticIfPromptError.invalidOptionCount
        }
        if Set(row.options.map(\.id)).count != row.options.count {
            throw SemanticIfPromptError.duplicateOptionIDs
        }
    }

    // MARK: - Message construction (`direct_messages` in core.py)

    static func directMessages(_ row: SemanticIfDecision) throws -> [SemanticIfMessage] {
        try validate(row)
        let payload: SemanticIfJSON = .object([
            ("evidence", row.state),
            ("criterion", .string(row.question)),
            ("options", .array(row.options.enumerated().map { index, option in
                .object([
                    ("letter", .string(String(letters[index]))),
                    ("description", .string(option.description)),
                ])
            })),
        ])
        return [
            SemanticIfMessage(role: .system, content: directSystem),
            // json.dumps(payload, ensure_ascii=False): default separators, raw Unicode.
            SemanticIfMessage(role: .user, content: payload.pythonDumped),
        ]
    }

    // MARK: - Chat template

    /// Renders messages the way the pinned Qwen3.5-4B chat template
    /// (`chat_template.jinja`, sha256 a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715,
    /// Qwen/Qwen3.5-4B @ 851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a) renders them under
    /// Semif's `apply_chat_template` flags `tokenize=False, add_generation_prompt=True,
    /// enable_thinking=False`. Only Semif's direct-readout shape is supported: an
    /// optional leading system message followed by user messages, no tools, no
    /// assistant/tool history. Contents are trimmed as the template's `|trim` does.
    /// Issue #10 may replace this with swift-transformers' Jinja application; this
    /// function pins the expected output so the swap can be diffed byte-for-byte.
    static func applyQwen35ChatTemplate(_ messages: [SemanticIfMessage]) throws -> String {
        guard !messages.isEmpty else { throw SemanticIfPromptError.emptyMessages }
        var rendered = ""
        var offset = 0
        if messages.first?.role == .system {
            rendered += "<|im_start|>system\n" + messages[0].content.trimmedForTemplate + "<|im_end|>\n"
            offset = 1
        }
        for message in messages.dropFirst(offset) {
            guard message.role == .user else { throw SemanticIfPromptError.unsupportedMessageShape }
            rendered += "<|im_start|>user\n" + message.content.trimmedForTemplate + "<|im_end|>\n"
        }
        rendered += "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        return rendered
    }

    // MARK: - Encoding and answer slots (`encode_prompt` / `_slot_ids` in direct.py)

    /// Renders, encodes, and boundary-checks one decision. Mirrors direct.py's
    /// `encode_prompt`: any failure throws and the row is rejected outright.
    static func encodePrompt<T: SemanticIfTokenizing>(
        _ row: SemanticIfDecision, tokenizer: T, maxTokens: Int = 4096
    ) throws -> SemanticIfEncodedPrompt {
        let messages = try directMessages(row)
        let prompt = try tokenizer.applyDirectChatTemplate(messages)
        let ids = tokenizer.encode(prompt)
        guard !ids.isEmpty, ids.count <= maxTokens else {
            throw SemanticIfPromptError.inputTokensExceedLimit(rowID: row.id, count: ids.count, maxTokens: maxTokens)
        }
        let slots = try answerSlotIDs(tokenizer: tokenizer, count: row.options.count)
        for (letter, token) in zip(letters, slots) {
            guard tokenizer.encode(prompt + String(letter)) == ids + [token] else {
                throw SemanticIfPromptError.answerBoundaryShift(letter)
            }
        }
        return SemanticIfEncodedPrompt(ids: ids, answerSlots: slots, promptHash: digest(prompt))
    }

    /// `_slot_ids` in direct.py: each letter must be one exact round-trip token,
    /// and no two letters may share a token.
    static func answerSlotIDs<T: SemanticIfTokenizing>(tokenizer: T, count: Int) throws -> [Int32] {
        var result: [Int32] = []
        for letter in letters.prefix(count) {
            let encoded = tokenizer.encode(String(letter))
            guard encoded.count == 1, tokenizer.decode(encoded) == String(letter) else {
                throw SemanticIfPromptError.invalidAnswerSlot(letter)
            }
            result.append(encoded[0])
        }
        guard Set(result).count == result.count else {
            throw SemanticIfPromptError.answerSlotCollision
        }
        return result
    }

    // MARK: - Hashing (`digest` in core.py)

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Tokenizer seam for `SemanticIfPrompt`. Implementations must match the
/// Hugging Face calls Semif makes: `encode` is `tokenizer.encode(_:,
/// add_special_tokens=False)`, `decode` is `tokenizer.decode(_:)`, and
/// `applyDirectChatTemplate` is `apply_chat_template(messages, tokenize=False,
/// add_generation_prompt=True, enable_thinking=False)` rendered to a string.
protocol SemanticIfTokenizing: Sendable {
    func encode(_ text: String) -> [Int32]
    func decode(_ tokens: [Int32]) -> String
    func applyDirectChatTemplate(_ messages: [SemanticIfMessage]) throws -> String
}

/// One chat message, role + text content (Semif never sends richer content).
struct SemanticIfMessage: Sendable, Equatable {
    enum Role: String, Sendable {
        case system
        case user
    }

    var role: Role
    var content: String
}

/// Result of a successful `encodePrompt`: prompt token ids, the one-token id
/// of each answer letter in option order, and Semif's `prompt_sha256`.
struct SemanticIfEncodedPrompt: Sendable, Equatable {
    var ids: [Int32]
    var answerSlots: [Int32]
    var promptHash: String
}

/// One decision row. `state` keeps its JSON value (string, object, or array)
/// with object key order preserved, exactly as Python's dict does. Public so
/// the parity harness (issue #13) can load fixture rows from another module.
public struct SemanticIfDecision: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public var id: String
        public var description: String

        public init(id: String, description: String) {
            self.id = id
            self.description = description
        }
    }

    public var id: String
    public var state: SemanticIfJSON
    public var question: String
    public var options: [Option]

    public init(id: String, state: SemanticIfJSON, question: String, options: [Option]) {
        self.id = id
        self.state = state
        self.question = question
        self.options = options
    }

    /// Decodes one parsed JSONL row, performing validate_row's structural
    /// checks (fields present, `id`/`question` strings, options a list of
    /// `{id, description}` string pairs) and then the semantic checks.
    public init(json: SemanticIfJSON) throws {
        guard case .object(let fields) = json else {
            throw SemanticIfPromptError.malformedJSON("Row must be a JSON object")
        }
        func field(_ name: String) -> SemanticIfJSON? {
            fields.first(where: { $0.0 == name })?.1
        }
        let required = ["id", "state", "question", "options"]
        let missing = required.filter { field($0) == nil }.sorted()
        guard missing.isEmpty else {
            throw SemanticIfPromptError.missingFields(missing)
        }
        guard case .string(let id) = field("id"), case .string(let question) = field("question") else {
            throw SemanticIfPromptError.invalidIDOrQuestion
        }
        guard case .array(let optionValues) = field("options") else {
            throw SemanticIfPromptError.invalidOptionCount
        }
        var options: [Option] = []
        for value in optionValues {
            guard case .object(let optionFields) = value,
                  let optionID = optionFields.first(where: { $0.0 == "id" })?.1,
                  case .string(let optionIDString) = optionID,
                  let description = optionFields.first(where: { $0.0 == "description" })?.1,
                  case .string(let descriptionString) = description
            else {
                throw SemanticIfPromptError.invalidOption
            }
            options.append(Option(id: optionIDString, description: descriptionString))
        }
        self.init(id: id, state: field("state") ?? .null, question: question, options: options)
        try SemanticIfPrompt.validate(self)
    }
}

/// Rejection reasons, mirroring the ValueError messages Semif raises. A row
/// that hits any of these is excluded; scores are never approximated.
enum SemanticIfPromptError: Error, Equatable {
    case missingFields([String])
    case invalidIDOrQuestion
    case invalidState
    case nonFiniteState
    case invalidOptionCount
    case invalidOption
    case duplicateOptionIDs
    case inputTokensExceedLimit(rowID: String, count: Int, maxTokens: Int)
    case invalidAnswerSlot(Character)
    case answerSlotCollision
    case answerBoundaryShift(Character)
    case emptyMessages
    case unsupportedMessageShape
    case malformedJSON(String)

    var message: String {
        switch self {
        case .missingFields(let names):
            return "Row is missing fields: \(names)"
        case .invalidIDOrQuestion:
            return "id and question must be nonempty strings"
        case .invalidState:
            return "state must be a nonempty string, object, or array"
        case .nonFiniteState:
            return "state must be finite JSON-compatible data"
        case .invalidOptionCount:
            return "options must contain 2-16 entries"
        case .invalidOption:
            return "Each option needs string id and description fields"
        case .duplicateOptionIDs:
            return "Option IDs must be unique"
        case .inputTokensExceedLimit(let rowID, let count, let maxTokens):
            return "Row \(rowID): \(count) input tokens exceed limit \(maxTokens); no truncation allowed"
        case .invalidAnswerSlot(let letter):
            return "Answer slot '\(letter)' is not one exact round-trip token"
        case .answerSlotCollision:
            return "Answer-slot tokens collide"
        case .answerBoundaryShift(let letter):
            return "Answer boundary changes tokenization for slot \(letter)"
        case .emptyMessages:
            return "No messages provided."
        case .unsupportedMessageShape:
            return "Only a leading system message followed by user messages is supported"
        case .malformedJSON(let detail):
            return detail
        }
    }
}

/// Ordered, Python-`json`-compatible JSON value. Object key order is document
/// order, and integers stay distinct from doubles, so `pythonDumped` is
/// byte-identical to `json.dumps(value, ensure_ascii=False)`. Public so the
/// parity harness (issue #13) can parse Semif's recorded result rows.
public enum SemanticIfJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([SemanticIfJSON])
    case object([(String, SemanticIfJSON)])

    public static func == (lhs: SemanticIfJSON, rhs: SemanticIfJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.integer(let a), .integer(let b)):
            return a == b
        case (.double(let a), .double(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default:
            return false
        }
    }

    var isFiniteJSON: Bool {
        switch self {
        case .double(let value):
            return value.isFinite
        case .array(let items):
            return items.allSatisfy(\.isFiniteJSON)
        case .object(let fields):
            return fields.allSatisfy { $0.1.isFiniteJSON }
        case .null, .bool, .integer, .string:
            return true
        }
    }

    /// `json.dumps(value, ensure_ascii=False)` with Python's default
    /// separators (", " and ": "). Non-finite doubles render as Python's
    /// `Infinity` / `-Infinity` / `NaN`; `SemanticIfPrompt.validate` rejects
    /// them before this is ever used for a prompt.
    var pythonDumped: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .integer(let value):
            return String(value)
        case .double(let value):
            if value.isNaN { return "NaN" }
            if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
            // Swift's shortest round-trip description matches Python's repr
            // for finite doubles, including the two-digit exponent form.
            return String(describing: value)
        case .string(let value):
            return SemanticIfJSON.escape(value)
        case .array(let items):
            return "[" + items.map(\.pythonDumped).joined(separator: ", ") + "]"
        case .object(let fields):
            return "{" + fields.map { SemanticIfJSON.escape($0.0) + ": " + $0.1.pythonDumped }
                .joined(separator: ", ") + "}"
        }
    }

    /// Python's string escaping with ensure_ascii=False: only quotes,
    /// backslashes, and control characters are escaped; all other Unicode is
    /// emitted raw.
    private static func escape(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Parses one JSON document, preserving object key order like Python's
    /// `json.loads`. Integers that fit Int64 stay integers (Python's ints are
    /// arbitrary precision; wider literals degrade to Double here). Unlike
    /// Python, the non-standard literals NaN/Infinity are rejected up front —
    /// Semif would reject them in validation anyway.
    public static func parse(_ text: String) throws -> SemanticIfJSON {
        var parser = Parser(text: text[...])
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw SemanticIfPromptError.malformedJSON("Trailing content after JSON document")
        }
        return value
    }

    private struct Parser {
        var text: Substring

        var isAtEnd: Bool { text.isEmpty }

        mutating func skipWhitespace() {
            while let first = text.first, first == " " || first == "\t" || first == "\n" || first == "\r" {
                text = text.dropFirst()
            }
        }

        mutating func parseValue() throws -> SemanticIfJSON {
            skipWhitespace()
            guard let first = text.first else {
                throw SemanticIfPromptError.malformedJSON("Unexpected end of JSON")
            }
            switch first {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t":
                try expect("true")
                return .bool(true)
            case "f":
                try expect("false")
                return .bool(false)
            case "n":
                try expect("null")
                return .null
            default:
                return try parseNumber()
            }
        }

        mutating func expect(_ literal: String) throws {
            guard text.hasPrefix(literal) else {
                throw SemanticIfPromptError.malformedJSON("Expected \(literal)")
            }
            text = text.dropFirst(literal.count)
        }

        mutating func take(_ character: Character) throws {
            guard text.first == character else {
                throw SemanticIfPromptError.malformedJSON("Expected '\(character)'")
            }
            text = text.dropFirst()
        }

        mutating func parseObject() throws -> SemanticIfJSON {
            try take("{")
            skipWhitespace()
            var fields: [(String, SemanticIfJSON)] = []
            if text.first == "}" {
                text = text.dropFirst()
                return .object(fields)
            }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try take(":")
                let value = try parseValue()
                fields.append((key, value))
                skipWhitespace()
                if text.first == "}" {
                    text = text.dropFirst()
                    return .object(fields)
                }
                try take(",")
            }
        }

        mutating func parseArray() throws -> SemanticIfJSON {
            try take("[")
            skipWhitespace()
            var items: [SemanticIfJSON] = []
            if text.first == "]" {
                text = text.dropFirst()
                return .array(items)
            }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                if text.first == "]" {
                    text = text.dropFirst()
                    return .array(items)
                }
                try take(",")
            }
        }

        mutating func parseString() throws -> String {
            try take("\"")
            var result = ""
            while let first = text.first {
                text = text.dropFirst()
                switch first {
                case "\"":
                    return result
                case "\\":
                    guard let escaped = text.first else {
                        throw SemanticIfPromptError.malformedJSON("Unterminated escape")
                    }
                    text = text.dropFirst()
                    switch escaped {
                    case "\"": result += "\""
                    case "\\": result += "\\"
                    case "/": result += "/"
                    case "b": result += "\u{08}"
                    case "f": result += "\u{0C}"
                    case "n": result += "\n"
                    case "r": result += "\r"
                    case "t": result += "\t"
                    case "u": result.unicodeScalars.append(try parseUnicodeEscape())
                    default:
                        throw SemanticIfPromptError.malformedJSON("Invalid escape '\\(escaped)'")
                    }
                default:
                    result.append(first)
                }
            }
            throw SemanticIfPromptError.malformedJSON("Unterminated string")
        }

        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let scalar = try parseHexQuad()
            if UTF16.isLeadSurrogate(scalar) {
                guard text.hasPrefix("\\u") else {
                    throw SemanticIfPromptError.malformedJSON("Lone surrogate in escape")
                }
                text = text.dropFirst(2)
                let trail = try parseHexQuad()
                guard UTF16.isTrailSurrogate(trail) else {
                    throw SemanticIfPromptError.malformedJSON("Lone surrogate in escape")
                }
                let combined = 0x1_0000 + ((UInt32(scalar) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else {
                    throw SemanticIfPromptError.malformedJSON("Invalid Unicode escape")
                }
                return scalar
            }
            guard let value = Unicode.Scalar(scalar) else {
                throw SemanticIfPromptError.malformedJSON("Invalid Unicode escape")
            }
            return value
        }

        mutating func parseHexQuad() throws -> UTF16.CodeUnit {
            guard text.count >= 4, let value = UInt32(text.prefix(4), radix: 16) else {
                throw SemanticIfPromptError.malformedJSON("Invalid Unicode escape")
            }
            text = text.dropFirst(4)
            return UTF16.CodeUnit(value)
        }

        mutating func parseNumber() throws -> SemanticIfJSON {
            var length = 0
            var isDouble = false
            for character in text {
                if character == "." || character == "e" || character == "E" {
                    isDouble = true
                }
                guard character == "-" || character == "+" || character == "."
                    || character == "e" || character == "E" || character.isNumber
                else { break }
                length += 1
            }
            guard length > 0 else {
                throw SemanticIfPromptError.malformedJSON("Invalid number")
            }
            let literal = String(text.prefix(length))
            text = text.dropFirst(length)
            if !isDouble, let integer = Int64(literal) {
                return .integer(integer)
            }
            guard let double = Double(literal) else {
                throw SemanticIfPromptError.malformedJSON("Invalid number '\(literal)'")
            }
            return .double(double)
        }
    }
}

private extension String {
    /// Jinja's `|trim`: strip leading/trailing whitespace as the chat template does.
    var trimmedForTemplate: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// From apple/: swiftc -swift-version 6 ShortReel/Models/*.swift ShortReel/Services/DeviceHost.swift ShortReel/Services/DevicePrompts/{WarmUpPlaybook,DeviceWorkflow,DevicePromptPlanner,DevicePromptPlan}.swift Tests/KeyboardTypingTests.swift -o /tmp/shortreel-keyboard-tests && /tmp/shortreel-keyboard-tests
import Foundation

@main @MainActor
struct KeyboardTypingTests {
    enum Failure: Error { case transport, assertion(String) }

    static func main() async throws {
        var typed = ""
        var pauses: [Double] = []
        var useUpper = false
        let text = "A a, 7👩🏽‍💻!"
        try await KeyboardTyping.run(text, typeCharacter: { typed.append($0) }, sleep: { pauses.append($0) }, random: {
            useUpper.toggle()
            return useUpper ? $0.upperBound : $0.lowerBound
        })
        precondition(typed == text, "Typing changed characters, punctuation, case, or spaces")
        precondition(pauses.count == text.count - 1, "Unexpected initial or final pause")
        precondition(Set(pauses).count > 1, "Typing cadence is fixed")
        precondition(pauses[1] >= 0.18 && pauses[3] >= 0.22, "Missing pauses at word and punctuation boundaries")

        typed = ""; pauses = []
        try await KeyboardTyping.run("", typeCharacter: { typed.append($0) }, sleep: { pauses.append($0) })
        precondition(typed.isEmpty && pauses.isEmpty)

        typed = ""
        do {
            try await KeyboardTyping.run("abc", typeCharacter: {
                if $0 == "b" { throw Failure.transport }
                typed.append($0)
            }, sleep: { _ in })
            throw Failure.assertion("Transport failure swallowed")
        } catch Failure.transport { }
        precondition(typed == "a", "Typed after a transport failure")

        typed = ""
        do {
            try await KeyboardTyping.run("abc", typeCharacter: { typed.append($0) }, sleep: { _ in throw CancellationError() })
            throw Failure.assertion("Cancelled pause was ignored")
        } catch is CancellationError { }
        precondition(typed == "a", "Typed after a cancelled pause")

        let task = Task { @MainActor in
            var characters = ""
            do {
                try await KeyboardTyping.run("abc", typeCharacter: {
                    characters.append($0)
                    withUnsafeCurrentTask { $0?.cancel() }
                }, sleep: { _ in })
                throw Failure.assertion("Task cancellation was ignored")
            } catch is CancellationError { }
            return characters
        }
        let cancelledText = try await task.value
        precondition(cancelledText == "a", "Sent more keys after Stop")
        print("Keyboard typing tests passed: literal characters, varied pauses, empty input, transport failure, and cancellation.")
    }
}

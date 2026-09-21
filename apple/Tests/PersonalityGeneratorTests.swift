// From apple/: swiftc -swift-version 6 ShortReel/Services/PersonalityGenerator.swift Tests/PersonalityGeneratorTests.swift -o /tmp/shortreel-personality-tests && /tmp/shortreel-personality-tests
import Foundation

@main
struct PersonalityGeneratorTests {
    enum Failure: Error { case assertion(String), unavailable }

    static func main() async throws {
        let brief = String(repeating: "👩🏽‍💻", count: 160)
        let result = try await PersonalityGenerator.generate(brief: brief, network: "TikTok") { prompt, instructions, schema in
            let input = try JSONSerialization.jsonObject(with: Data(prompt.utf8)) as! [String: String]
            guard input["brief"] == brief, input["network"] == "TikTok",
                  instructions.contains("third person"),
                  let fields = try JSONSerialization.jsonObject(with: schema) as? [String: Any],
                  fields["required"] as? [String] == ["personality"] else {
                throw Failure.assertion("Missing brief, network, or output contract")
            }
            return Data(#"{"personality":"  A curious, direct creator.  "}"#.utf8)
        }
        guard result == "A curious, direct creator." else { throw Failure.assertion("Response not normalized") }

        for invalid in ["", " \n ", String(repeating: "a", count: 161)] {
            do {
                _ = try await PersonalityGenerator.generate(brief: invalid, network: "X") { _, _, _ in
                    throw Failure.assertion("Invalid brief reached the provider")
                }
                throw Failure.assertion("Invalid brief accepted")
            } catch PersonalityGenerator.GenerationError.invalidBrief { }
        }

        for data in [Data("not JSON".utf8), Data(#"{"personality":"  "}"#.utf8), Data(#"{"other":"wrong"}"#.utf8),
                     try JSONSerialization.data(withJSONObject: ["personality": String(repeating: "a", count: 2_001)]),
                     Data(repeating: 32, count: 16_385)] {
            do {
                _ = try await PersonalityGenerator.generate(brief: "Photographer", network: "Instagram") { _, _, _ in data }
                throw Failure.assertion("Invalid response accepted")
            } catch PersonalityGenerator.GenerationError.invalidResponse { }
        }

        do {
            _ = try await PersonalityGenerator.generate(brief: "Photographer", network: "YouTube") { _, _, _ in
                throw Failure.unavailable
            }
            throw Failure.assertion("Provider error swallowed")
        } catch Failure.unavailable { }

        let task = Task {
            try await PersonalityGenerator.generate(brief: "Photographer", network: "Instagram") { _, _, _ in
                // Simulate a provider that returns after cancellation anyway.
                try? await Task.sleep(for: .milliseconds(50))
                return Data(#"{"personality":"Late result"}"#.utf8)
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            throw Failure.assertion("Cancelled generation returned a personality")
        } catch is CancellationError { }
        print("Personality generator tests passed: Unicode limit, request context, response validation, provider errors, and cancellation.")
    }
}

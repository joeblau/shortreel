import XCTest

final class ShortReelRunnerServerTests: XCTestCase {
    private let server = RunnerServer()

    override func setUp() async throws {
        executionTimeAllowance = 86_400
        try await server.start()
    }

    func testServerParksForSession() {
        let parked = expectation(description: "ShortReelRunner server parks for the session lifetime")
        wait(for: [parked], timeout: 86_400)
    }
}

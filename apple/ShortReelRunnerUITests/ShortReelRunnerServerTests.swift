import XCTest

/// The driver lifetime. Launching this test session is what starts the
/// driver: the FlyingFox server lives inside the test process, and parking
/// the single test keeps the session — and therefore testmanagerd and the
/// XCTest channel — alive until the Mac kills it (go-ios runxctest).
final class ShortReelRunnerServerTests: XCTestCase {
    private let server = RunnerServer()

    override func setUp() async throws {
        // The default 10-minute allowance would kill the parked driver.
        executionTimeAllowance = 86_400
        try await server.start()
    }

    func testServerParksForSession() {
        // Never fulfilled by design.
        let parked = expectation(description: "ShortReelRunner server parks for the session lifetime")
        wait(for: [parked], timeout: 86_400)
    }
}

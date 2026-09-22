import Foundation

// From apple/: swiftc -swift-version 6 ShortReel/Services/DevicePrompts/SemanticIfScorerState.swift Tests/SemanticIfScorerStateTests.swift -o /tmp/shortreel-semif-state-tests && /tmp/shortreel-semif-state-tests
@main
enum SemanticIfScorerStateTests {
    enum Failure: Error { case assertion(String) }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    static func main() throws {
        // Every state maps to menu copy.
        try expect(SemanticIfScorerState.disabled.menuStatus == "Off", "disabled status")
        try expect(SemanticIfScorerState.idle.menuStatus == "Not loaded", "idle status")
        try expect(SemanticIfScorerState.loading.menuStatus == "Loading…", "loading status")
        try expect(SemanticIfScorerState.ready.menuStatus == "Ready", "ready status")
        try expect(SemanticIfScorerState.failed("boom").menuStatus == "Failed to load", "failed status")

        // Warm is offered only when a load can start: idle, or retry after failure.
        try expect(SemanticIfScorerState.idle.canWarm, "idle can warm")
        try expect(SemanticIfScorerState.failed("boom").canWarm, "failed can warm (retry)")
        try expect(!SemanticIfScorerState.disabled.canWarm, "disabled never warms")
        try expect(!SemanticIfScorerState.loading.canWarm, "loading is already warming")
        try expect(!SemanticIfScorerState.ready.canWarm, "ready has nothing to load")

        // Only a load failure speaks up in the Stage panel; the user's own
        // off/idle choice stays quiet and never blocks a run.
        try expect(SemanticIfScorerState.disabled.localChecksOffNotice == nil, "disabled is silent")
        try expect(SemanticIfScorerState.idle.localChecksOffNotice == nil, "idle is silent")
        try expect(SemanticIfScorerState.loading.localChecksOffNotice == nil, "loading is silent")
        try expect(SemanticIfScorerState.ready.localChecksOffNotice == nil, "ready is silent")
        let notice = SemanticIfScorerState.failed("checkpoint missing").localChecksOffNotice
        try expect(notice?.contains("checkpoint missing") == true, "failure notice carries the reason")
        try expect(notice?.contains("planner") == true, "failure notice says runs still work")

        print("SemanticIfScorerStateTests: all passed")
    }
}

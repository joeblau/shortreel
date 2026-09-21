import Foundation

/// Emits a linear pointer drag, then a distinct button-up report immediately
/// after the final movement unless an endpoint hold was explicitly requested.
@MainActor
enum HIDPointerDrag {
    static func run(from start: NormalizedPoint, to end: NormalizedPoint,
                    duration: Double, pressDuration: Double, holdDuration: Double,
                    send: (Bool, NormalizedPoint) throws -> Void,
                    sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws {
        var pressed = false
        var lastPoint = start
        defer { if pressed { try? send(false, lastPoint) } }
        try Task.checkCancellation()
        try send(false, start)
        try await sleep(0.08)
        try Task.checkCancellation()
        try send(true, start)
        pressed = true
        if pressDuration > 0 { try await sleep(pressDuration) }
        let steps = max(4, Int(ceil(duration / 0.016)))
        for step in 1...steps {
            try await sleep(duration / Double(steps))
            try Task.checkCancellation()
            let fraction = Double(step) / Double(steps)
            let point = NormalizedPoint(x: start.x + (end.x - start.x) * fraction,
                                        y: start.y + (end.y - start.y) * fraction)
            try send(true, point)
            lastPoint = point
        }
        if holdDuration > 0 { try await sleep(holdDuration) }
        try Task.checkCancellation()
        // Keep the final movement pressed so AssistiveTouch receives it as a
        // drag update, followed by button-up with no sleep/deceleration.
        try send(false, end)
        pressed = false
    }
}

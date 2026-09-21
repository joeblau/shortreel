import Foundation

// swiftc -swift-version 6 ShortReel/Models/*.swift ShortReel/Services/DeviceHost.swift ShortReel/Services/BluetoothHID/HIDPointerDrag.swift Tests/HIDPointerDragTests.swift -o /tmp/sr-pointer-drag-tests
@main @MainActor
struct HIDPointerDragTests {
    enum Failure: Error { case assertion(String), transport }
    struct Report { let down: Bool; let point: NormalizedPoint; let time: Double }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    static func main() async throws {
        let start = NormalizedPoint(x: 0.4, y: 0.65), end = NormalizedPoint(x: 0.4, y: 0.02)
        var clock = 0.0
        var reports: [Report] = []
        try await HIDPointerDrag.run(from: start, to: end, duration: 0.16, pressDuration: 0, holdDuration: 0,
            send: { reports.append(.init(down: $0, point: $1, time: clock)) }, sleep: { clock += $0 })
        let release = reports.last!, finalMovement = reports[reports.count - 2], preceding = reports[reports.count - 3]
        try expect(!reports[0].down && reports[0].point == start && reports[1].down, "Pointer must reposition released before pressing")
        try expect(!release.down && abs(release.point.y - end.y) < 1e-9, "Flick did not release at its endpoint")
        try expect(finalMovement.down && preceding.down && preceding.point.y > finalMovement.point.y, "Final movement must remain pressed")
        try expect(finalMovement.time == release.time, "Flick paused before releasing")
        try expect(reports.filter { !$0.down }.count == 2, "Flick must emit one button-up after moving")
        try expect(abs(release.time - reports[1].time - 0.16) < 1e-9, "Flick gained an initial or final pause")
        let lastSpeed = (preceding.point.y - finalMovement.point.y) / (finalMovement.time - preceding.time)
        try expect(abs(lastSpeed - (start.y - end.y) / 0.16) < 1e-8, "Motion decelerated before release")

        reports = []; clock = 0
        try await HIDPointerDrag.run(from: start, to: end, duration: 0.3, pressDuration: 0.1, holdDuration: 0.9,
            send: { reports.append(.init(down: $0, point: $1, time: clock)) }, sleep: { clock += $0 })
        let held = reports[reports.count - 2], heldRelease = reports.last!
        try expect(held.down && !heldRelease.down && abs(held.point.y - heldRelease.point.y) < 1e-9, "Explicit endpoint hold was lost")
        try expect(abs(heldRelease.time - held.time - 0.9) < 1e-9, "Explicit endpoint hold duration changed")

        reports = []; clock = 0
        let task = Task { @MainActor in
            try await HIDPointerDrag.run(from: start, to: end, duration: 0.16, pressDuration: 0, holdDuration: 0,
                send: { reports.append(.init(down: $0, point: $1, time: clock)) }, sleep: { delay in
                    clock += delay
                    if clock > 0.12 { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        do { try await task.value; throw Failure.assertion("Cancelled flick completed") }
        catch is CancellationError {}
        try expect(reports.last?.down == false && reports.last!.point.y > end.y, "Cancellation left the pointer pressed or continued motion")

        reports = []; clock = 0
        do {
            try await HIDPointerDrag.run(from: start, to: end, duration: 0.16, pressDuration: 0, holdDuration: 0,
                send: { down, point in
                    if down && point.y < start.y - 0.1 { throw Failure.transport }
                    reports.append(.init(down: down, point: point, time: clock))
                }, sleep: { clock += $0 })
            throw Failure.assertion("Transport error was swallowed")
        } catch Failure.transport {}
        try expect(reports.last?.down == false, "Transport failure left the pointer pressed")
        print("Pointer drag tests passed: moving release, constant speed, explicit hold, cancellation, transport failure")
    }
}

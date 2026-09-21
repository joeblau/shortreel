import Foundation
import OSLog
import MLX

private let log = Logger(subsystem: "com.joeblau.shortreel", category: "MLXWarmUp")

/// Compiles MLX's Metal shaders on a background task at launch so the first
/// model warm-up decision does not pay the ~7 s first-compile cost. The model
/// itself is intentionally not loaded here (see issue #10).
@MainActor
enum MLXWarmUp {
    private static var warmTask: Task<Void, Never>?

    /// Starts the warm task once. Safe to call repeatedly; never blocks the caller.
    static func prewarm() {
        guard warmTask == nil else { return }
        warmTask = Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            do {
                try Task.checkCancellation()
                warmMetalShaders()
                try Task.checkCancellation()
            } catch {
                log.info("MLX warm-up cancelled")
                return
            }
            log.info("MLX Metal shader warm-up finished in \(ContinuousClock.now - start, privacy: .public)")
        }
    }

    static func cancel() {
        warmTask?.cancel()
        warmTask = nil
    }

    /// Runs one small matmul and forces evaluation, which triggers Metal
    /// shader compilation without touching the network or model weights.
    private nonisolated static func warmMetalShaders() {
        let size = 512
        let a = MLXRandom.uniform(0 ..< 1, [size, size])
        let b = MLXRandom.uniform(0 ..< 1, [size, size])
        // Reading a scalar back forces evaluation and blocks until the
        // GPU work — including shader compilation — has finished.
        _ = matmul(a, b)[0, 0].item(Float.self)
    }
}

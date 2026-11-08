import Foundation

/// Protection against work that never finishes (corrupt file, decoder or framework stuck).
///
/// Image decoders, Vision and AVFoundation are synchronous and cannot be interrupted: a call that
/// hangs would freeze a whole background pass until the app is restarted. Here each item gets a time
/// limit; past it, the item is reported as `nil` and the pass moves on (the stuck thread is abandoned).
enum Watchdog {
    /// Runs `work` on every item, at most `width` at a time, each limited to `timeout` seconds.
    /// The result array keeps the item order; `nil` = timed out.
    static func map<Item, Result>(_ items: [Item], width: Int = 4, timeout: Double,
                                  _ work: @escaping (Item) -> Result) async -> [Result?] {
        var results = [Result?](repeating: nil, count: items.count)
        guard !items.isEmpty else { return results }
        await withTaskGroup(of: (Int, Result?).self) { group in
            var next = 0
            func launch() {
                let i = next, item = items[i]
                next += 1
                group.addTask { (i, await withTimeout(timeout) { work(item) }) }
            }
            for _ in 0..<min(width, items.count) { launch() }
            while let (i, r) = await group.next() {
                results[i] = r
                if next < items.count { launch() }
            }
        }
        return results
    }

    /// Runs `work` on a background thread; returns nil if it has not finished after `seconds`.
    static func withTimeout<T>(_ seconds: Double, qos: DispatchQoS.QoSClass = .utility,
                               _ work: @escaping () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            DispatchQueue.global(qos: qos).async {
                let value = work()
                if once.claim() { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Lets exactly one of two competitors resume a continuation.
    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

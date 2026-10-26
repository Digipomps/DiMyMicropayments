import Foundation

/// FIFO, instance-scoped serialization for runtime operations that suspend.
///
/// `GeneralCell` readiness serializes binding installation, but registered
/// intercepts may execute concurrently. Runtime wrappers use this gate to keep
/// lazy actor creation, mutation, and the synchronous Codable mirror within one
/// logical operation.
actor DiMyAsyncOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

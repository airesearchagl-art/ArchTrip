import Foundation

/// Awaits a callback-based operation with a hard deadline. At the deadline the caller
/// resumes with `AccountError.timedOut` straight away, without waiting for the
/// callback; a callback that arrives later is ignored. (A task group cannot give this
/// guarantee: it always waits for every child, including a callback that never fires.)
nonisolated enum BoundedWait {
    static func run(timeout: Duration, _ operation: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        let gate = OneShot()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.arm(continuation)
            let timer = Task.detached {
                try? await Task.sleep(for: timeout)
                gate.finish(.failure(AccountError.timedOut))
            }
            operation { error in
                timer.cancel()
                gate.finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }
}

/// Resumes a continuation at most once; later results are dropped.
nonisolated final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func arm(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Returns false when the continuation was already resumed (or never armed).
    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}

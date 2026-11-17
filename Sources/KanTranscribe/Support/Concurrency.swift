import Foundation

/// A "stop" flag shared between a Swift task and code that can't see Task cancellation
/// (whisper.cpp's abort callback, loops on a dispatch queue). Thread-safe.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    /// Throws `CancellationError` once cancelled.
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Runs blocking work (whisper.cpp, VAD, clustering) on one dedicated serial queue, so long C calls
/// never occupy Swift's cooperative thread pool and everything submitted through one worker is
/// confined to a single thread at a time. Cancelling the awaiting task sets the work's
/// `CancellationFlag`; the work decides where to honour it.
final class SerialWorker: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func run<T>(_ body: @escaping (CancellationFlag) throws -> T) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                    if flag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Result { try body(flag) })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

/// A FIFO async mutex. `run` holds it across suspension points (unlike actor isolation, which is
/// reentrant). Waiting is not cancellable; holders are expected to finish or throw promptly.
actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    nonisolated func run<T>(_ body: () async throws -> T) async throws -> T {
        await lock()
        do {
            let value = try await body()
            await unlock()
            return value
        } catch {
            await unlock()
            throw error
        }
    }
}

/// Wraps a value that isn't `Sendable` but is handed to exactly one other task, which is its only
/// user from then on (FluidAudio's diarizer objects).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

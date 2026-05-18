import Foundation

/// Minimal single-flight mutex for `async` code. Serializes concurrent
/// callers FIFO via an internal Task chain — when one block is running,
/// the next call awaits the previous Task before claiming the slot.
///
/// Used by [IdentifyService] + [LogoutService] for the same purpose
/// Android uses `kotlinx.coroutines.sync.Mutex` for: ensure two
/// concurrent identify/logout calls can't race on credential mutations.
///
/// Swift's stdlib has no built-in async mutex on the iOS 13 floor
/// (`OSAllocatedUnfairLock` arrived in iOS 16). An `actor` would work for
/// state isolation but requires every public surface caller to be
/// `async`; we want the SDK to stay Foundation-only and the public
/// surface to stay non-async. A serial DispatchQueue can't await an
/// async closure cleanly, so we model the queue as a chain of Tasks.
internal final class AsyncMutex: @unchecked Sendable {

    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    /// Monotonically incremented slot id — used to detect "am I still the
    /// tail" without an identity comparison on `Task` (which is a value
    /// type and doesn't support `===`).
    private var nextSlotId: UInt64 = 0
    private var tailSlotId: UInt64 = 0

    init() {}

    /// Run `body` exclusively — concurrent callers serialize FIFO.
    /// Returns whatever `body` returns.
    func withLock<T>(_ body: @Sendable () async -> T) async -> T {
        // Splice ourselves onto the tail of the wait chain.
        let waitFor: Task<Void, Never>?
        let signal = SignalBox()
        let mySlotId: UInt64

        // Create the Task that "represents" our slot. We don't actually
        // run `body` inside it — we just need a handle the NEXT waiter
        // can await. Body runs inline on the caller's task so we keep
        // the right priority + cancellation context.
        let resolveTask: Task<Void, Never> = Task {
            await signal.wait()
        }
        lock.lock()
        waitFor = tail
        tail = resolveTask
        nextSlotId += 1
        mySlotId = nextSlotId
        tailSlotId = mySlotId
        lock.unlock()

        // Wait for the previous waiter to complete (if any).
        if let waitFor = waitFor {
            await waitFor.value
        }

        let result = await body()
        signal.fire()
        // Help the tail collapse: if we are still the tail, clear it.
        lock.lock()
        if tailSlotId == mySlotId {
            tail = nil
        }
        lock.unlock()
        return result
    }
}

/// One-shot signal — `wait()` blocks until `fire()` is called. Used by
/// [AsyncMutex] to release the next FIFO waiter. Implemented via a
/// CheckedContinuation so we don't pull in any extra dependencies.
private final class SignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired: Bool = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                c.resume()
                return
            }
            continuation = c
            lock.unlock()
        }
    }
}

import Foundation
import Synchronization

/// A thread-safe store of values computed once per key. Concurrent requests
/// for one key wait for the first computation instead of repeating it.
public final class OnceCache: Sendable {
    final class Entry: @unchecked Sendable {
        let lock = NSLock()
        var value: (any Sendable)?
        /// Set once loaded: a value may itself be nil (an optional `T`), and
        /// `nil as? T` succeeds for optional `T`. Atomic, so asking whether
        /// a value is ready never waits for one that is loading.
        let isLoaded = Atomic<Bool>(false)
    }

    private let entries = Mutex<[String: Entry]>([:])

    public init() {}

    public func value<T: Sendable>(_ key: String, _ load: () throws -> T) rethrows -> T {
        let entry = entries.withLock { dict in
            if let e = dict[key] { return e }
            let e = Entry()
            dict[key] = e
            return e
        }
        entry.lock.lock()
        defer { entry.lock.unlock() }
        if entry.isLoaded.load(ordering: .acquiring) {
            if let value = entry.value as? T { return value }
            if entry.value == nil, let none = Optional<any Sendable>.none as? T { return none }
        }
        let value = try load()
        entry.value = value
        entry.isLoaded.store(true, ordering: .releasing)
        return value
    }

    /// Whether `key` is loaded. Never waits for a value still loading.
    public func contains(_ key: String) -> Bool {
        entries.withLock { $0[key] }?.isLoaded.load(ordering: .acquiring) ?? false
    }

    public func removeAll() {
        entries.withLock { $0.removeAll() }
    }
}

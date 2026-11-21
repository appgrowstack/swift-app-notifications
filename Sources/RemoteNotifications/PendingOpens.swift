import Foundation

/// Where opened deliveries that could not be reported yet are kept between launches.
///
/// ``NotificationCenterDelegate`` adds a `send_id` when `reportOpened` throws and removes it once a
/// later report succeeds. ``UserDefaultsPendingOpenStore`` is the real one; tests pass
/// ``InMemoryPendingOpenStore``.
public protocol PendingOpenStore: Sendable {
    /// The `send_id`s still to report, oldest first.
    func load() -> [String]
    func save(_ sendIds: [String])
}

/// Keeps the `send_id`s still to report in `UserDefaults`.
public struct UserDefaultsPendingOpenStore: PendingOpenStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameters:
    ///   - defaults: The defaults to keep them in
    ///   - prefix: Put in front of the key, the same as ``UserDefaultsRegistrationStore``
    public init(defaults: UserDefaults = .standard, prefix: String = "RemoteNotifications.") {
        self.defaults = defaults
        self.key = prefix + "pendingOpens"
    }

    public func load() -> [String] { defaults.stringArray(forKey: key) ?? [] }

    public func save(_ sendIds: [String]) {
        if sendIds.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(sendIds, forKey: key) }
    }
}

/// Keeps nothing past the process.
public final class InMemoryPendingOpenStore: PendingOpenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var sendIds: [String]

    public init(sendIds: [String] = []) { self.sendIds = sendIds }

    public func load() -> [String] { lock.withLock { sendIds } }
    public func save(_ sendIds: [String]) { lock.withLock { self.sendIds = sendIds } }
}

/// The queue over a ``PendingOpenStore``: no duplicates, at most `limit` (the oldest go first),
/// and one retry at a time.
final class PendingOpens: @unchecked Sendable {
    private let lock = NSLock()
    private let store: any PendingOpenStore
    private let limit: Int
    private var retrying = false

    init(store: any PendingOpenStore, limit: Int) {
        self.store = store
        self.limit = max(1, limit)
    }

    var sendIds: [String] { lock.withLock { store.load() } }

    func add(_ sendId: String) {
        lock.withLock {
            var ids = store.load().filter { $0 != sendId }
            ids.append(sendId)
            store.save(Array(ids.suffix(limit)))
        }
    }

    func remove(_ sendId: String) {
        lock.withLock {
            let ids = store.load()
            if ids.contains(sendId) { store.save(ids.filter { $0 != sendId }) }
        }
    }

    /// `false` when a retry is already running.
    func beginRetry() -> Bool {
        lock.withLock {
            if retrying { return false }
            retrying = true
            return true
        }
    }

    func endRetry() { lock.withLock { retrying = false } }
}

import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// A `UNUserNotificationCenterDelegate` that shows notifications while the app is open, hands
/// taps to the app, and reports each opened delivery.
///
/// Set it as the center's delegate **before `application(_:didFinishLaunchingWithOptions:)`
/// returns**, or the tap that launched the app is never delivered. The center holds its delegate
/// weakly, so keep a reference:
///
/// ```swift
/// let notifications = NotificationCenterDelegate(
///     reportOpened: { sendId in try await api.reportOpened(sendId) },
///     onOpen: { open in router.pendingRoute = open.route }
/// )
/// UNUserNotificationCenter.current().delegate = notifications
/// ```
///
/// When a notification is opened, `onOpen` is called first, on the main actor, and then
/// `reportOpened` with the payload's `send_id` if it has one. A dismissal
/// (`UNNotificationDismissActionIdentifier`) is neither.
///
/// When `reportOpened` throws, the `send_id` is kept in `pendingOpens` (on the device, at most
/// `pendingLimit`, oldest dropped first) and reported again: each time the app becomes active, after
/// the next report that succeeds, and whenever the app calls ``retryPendingOpens()``. It leaves the
/// queue only when `reportOpened` returns, so `reportOpened` should throw only for what is worth
/// sending again (no connection, 429, 5xx) and return for an answer that will never change.
///
/// A tap can launch the app before any view exists. Have `onOpen` store the route somewhere a
/// view reads when it appears rather than navigate directly.
public final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {

    private let keys: PayloadKeys
    private let foregroundPresentation: UNNotificationPresentationOptions
    private let reportOpened: @Sendable (String) async throws -> Void
    private let onOpen: @MainActor @Sendable (NotificationOpen) -> Void
    private let onFailure: @MainActor @Sendable (any Error) -> Void
    private let pending: PendingOpens
    nonisolated(unsafe) private var activeObserver: (any NSObjectProtocol)?

    /// How many unreported `send_id`s are kept by default.
    public static let defaultPendingLimit = 20

    /// - Parameters:
    ///   - foregroundPresentation: How a notification that arrives while the app is in the
    ///     foreground is shown. Pass `[]` to show nothing
    ///   - keys: Where `send_id` and `route` are in the payload
    ///   - reportOpened: Tells the app's server a delivery was opened
    ///   - onFailure: Told each time `reportOpened` throws. The `send_id` stays in `pendingOpens`
    ///     and is reported again later
    ///   - pendingOpens: Where unreported `send_id`s are kept between launches
    ///   - pendingLimit: How many of them are kept (the oldest are dropped first)
    ///   - onOpen: Receives each opened notification, including its route
    public init(
        foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound],
        keys: PayloadKeys = .standard,
        reportOpened: @escaping @Sendable (String) async throws -> Void,
        onFailure: @escaping @MainActor @Sendable (any Error) -> Void = { _ in },
        pendingOpens: any PendingOpenStore = UserDefaultsPendingOpenStore(),
        pendingLimit: Int = NotificationCenterDelegate.defaultPendingLimit,
        onOpen: @escaping @MainActor @Sendable (NotificationOpen) -> Void
    ) {
        self.foregroundPresentation = foregroundPresentation
        self.keys = keys
        self.reportOpened = reportOpened
        self.onFailure = onFailure
        self.pending = PendingOpens(store: pendingOpens, limit: pendingLimit)
        self.onOpen = onOpen
        super.init()
        #if canImport(UIKit) && !os(watchOS)
        // Becoming active covers both a cold launch and coming back to the foreground.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.retryPendingOpens() }
        }
        #endif
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    /// The `send_id`s that could not be reported yet, oldest first.
    public var pendingSendIds: [String] { pending.sendIds }

    /// Reports the opened deliveries kept after a failure, oldest first, and stops at the first that
    /// fails again. Called when the app becomes active; call it yourself after the connection comes
    /// back if you know of it. A call while another is running returns at once.
    @MainActor
    public func retryPendingOpens() async {
        guard pending.beginRetry() else { return }
        defer { pending.endRetry() }
        for sendId in pending.sendIds {
            do {
                try await reportOpened(sendId)
                pending.remove(sendId)
            } catch {
                onFailure(error)
                return
            }
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(foregroundPresentation)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let open = NotificationOpen(
            userInfo: response.notification.request.content.userInfo,
            actionIdentifier: response.actionIdentifier,
            keys: keys
        )
        let completion = Completion(completionHandler)
        Task { @MainActor in
            guard let sendId = deliver(open) else { return completion() }
            completion()
            await report(sendId)
        }
    }

    /// Hands an open to the app, and returns the delivery to report, if any.
    @MainActor
    func deliver(_ open: NotificationOpen) -> String? {
        guard open.actionIdentifier != UNNotificationDismissActionIdentifier else { return nil }
        onOpen(open)
        return open.sendId
    }

    @MainActor
    func report(_ sendId: String) async {
        do {
            try await reportOpened(sendId)
        } catch {
            pending.add(sendId)
            onFailure(error)
            return
        }
        pending.remove(sendId)
        // The connection works now: send what an earlier failure left behind.
        if !pending.sendIds.isEmpty { await retryPendingOpens() }
    }

    @MainActor
    func receive(_ open: NotificationOpen) async {
        guard let sendId = deliver(open) else { return }
        await report(sendId)
    }
}

/// The system's completion handler, carried to the main actor.
///
/// UserNotifications does not mark it `@Sendable`, but it is documented as callable from any
/// thread, and it is called exactly once.
private struct Completion: @unchecked Sendable {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func callAsFunction() { body() }
}

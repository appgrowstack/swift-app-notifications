import Foundation
import Testing
import UserNotifications
@testable import RemoteNotifications

actor OpenLog {
    var reported: [String] = []
    func report(_ id: String) { reported.append(id) }
}

@Suite("通知を押されたとき")
@MainActor
struct NotificationCenterDelegateTests {

    @Test("アプリに route を渡してから、send_id を開いたとして知らせる")
    func deliversThenReports() async {
        let log = OpenLog()
        var opened: [NotificationOpen] = []
        let delegate = NotificationCenterDelegate(
            reportOpened: { await log.report($0) },
            onOpen: { opened.append($0) }
        )

        await delegate.receive(NotificationOpen(sendId: "snd_1", route: "items/42",
                                                actionIdentifier: UNNotificationDefaultActionIdentifier))

        #expect(opened.map(\.route) == ["items/42"])
        #expect(await log.reported == ["snd_1"])
    }

    @Test("send_id が無ければ route だけ渡し、何も知らせない")
    func noSendIdNoReport() async {
        let log = OpenLog()
        var opened: [NotificationOpen] = []
        let delegate = NotificationCenterDelegate(reportOpened: { await log.report($0) },
                                                  onOpen: { opened.append($0) })

        await delegate.receive(NotificationOpen(sendId: nil, route: "home", actionIdentifier: "a"))

        #expect(opened.count == 1)
        #expect(await log.reported.isEmpty)
    }

    @Test("消しただけ（dismiss）は開いたことにしない")
    func dismissIsIgnored() async {
        let log = OpenLog()
        var opened: [NotificationOpen] = []
        let delegate = NotificationCenterDelegate(reportOpened: { await log.report($0) },
                                                  onOpen: { opened.append($0) })

        await delegate.receive(NotificationOpen(sendId: "snd_1", route: "x",
                                                actionIdentifier: UNNotificationDismissActionIdentifier))

        #expect(opened.isEmpty)
        #expect(await log.reported.isEmpty)
    }

    @Test("知らせるのに失敗したら onFailure に届く")
    func reportFailureIsSurfaced() async {
        var failures = 0
        let delegate = NotificationCenterDelegate(reportOpened: { _ in throw SendError() },
                                                  onFailure: { _ in failures += 1 },
                                                  pendingOpens: InMemoryPendingOpenStore(),
                                                  onOpen: { _ in })
        await delegate.receive(NotificationOpen(sendId: "snd_1", route: nil, actionIdentifier: "a"))
        #expect(failures == 1)
    }

}

/// A server that fails while `down` is set and records what it accepted.
actor FlakyServer {
    var down = true
    var accepted: [String] = []
    var calls = 0
    func set(down: Bool) { self.down = down }
    func report(_ id: String) throws {
        calls += 1
        if down { throw SendError() }
        accepted.append(id)
    }
}

@Suite("知らせられなかった開いた記録")
@MainActor
struct PendingOpenTests {

    private func delegate(_ server: FlakyServer, store: InMemoryPendingOpenStore, limit: Int = 20) -> NotificationCenterDelegate {
        NotificationCenterDelegate(reportOpened: { try await server.report($0) },
                                   pendingOpens: store, pendingLimit: limit, onOpen: { _ in })
    }

    private func open(_ id: String) -> NotificationOpen {
        NotificationOpen(sendId: id, route: nil, actionIdentifier: UNNotificationDefaultActionIdentifier)
    }

    @Test("失敗した send_id は端末に残り、送り直して届いたら消える")
    func failedOpenIsKeptAndRetried() async {
        let server = FlakyServer()
        let store = InMemoryPendingOpenStore()
        let notifications = delegate(server, store: store)

        await notifications.receive(open("snd_1"))
        #expect(store.load() == ["snd_1"])
        #expect(notifications.pendingSendIds == ["snd_1"])

        await server.set(down: false)
        await notifications.retryPendingOpens()

        #expect(await server.accepted == ["snd_1"])
        #expect(store.load().isEmpty)
    }

    @Test("前の起動で残った物は、新しい delegate でも送り直す")
    func survivesRelaunch() async {
        let server = FlakyServer()
        await server.set(down: false)
        let store = InMemoryPendingOpenStore(sendIds: ["snd_old"])

        await delegate(server, store: store).retryPendingOpens()

        #expect(await server.accepted == ["snd_old"])
        #expect(store.load().isEmpty)
    }

    @Test("次の開いた記録が届いたら、残っていた物も続けて送る")
    func successFlushesTheQueue() async {
        let server = FlakyServer()
        let store = InMemoryPendingOpenStore()
        let notifications = delegate(server, store: store)

        await notifications.receive(open("snd_1"))
        await server.set(down: false)
        await notifications.receive(open("snd_2"))

        #expect(await server.accepted == ["snd_2", "snd_1"])
        #expect(store.load().isEmpty)
    }

    @Test("同じ send_id は1つだけ・上限を超えたら古い物から捨てる")
    func dedupedAndCapped() async {
        let server = FlakyServer()
        let store = InMemoryPendingOpenStore()
        let notifications = delegate(server, store: store, limit: 2)

        await notifications.receive(open("snd_1"))
        await notifications.receive(open("snd_1"))
        #expect(store.load() == ["snd_1"])

        await notifications.receive(open("snd_2"))
        await notifications.receive(open("snd_3"))
        #expect(store.load() == ["snd_2", "snd_3"])
    }

    @Test("送り直しも失敗したら、そこで止めて残りを残す")
    func retryStopsAtFailure() async {
        let server = FlakyServer()
        let store = InMemoryPendingOpenStore(sendIds: ["snd_1", "snd_2"])
        var failures = 0
        let notifications = NotificationCenterDelegate(reportOpened: { try await server.report($0) },
                                                       onFailure: { _ in failures += 1 },
                                                       pendingOpens: store, onOpen: { _ in })

        await notifications.retryPendingOpens()

        #expect(await server.calls == 1)
        #expect(failures == 1)
        #expect(store.load() == ["snd_1", "snd_2"])
    }

    @Test("UserDefaults に残し、空になったらキーを消す")
    func userDefaultsStore() {
        let suite = "PendingOpenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPendingOpenStore(defaults: defaults)

        store.save(["snd_1", "snd_2"])
        #expect(UserDefaultsPendingOpenStore(defaults: defaults).load() == ["snd_1", "snd_2"])

        store.save([])
        #expect(defaults.object(forKey: "RemoteNotifications.pendingOpens") == nil)
    }
}

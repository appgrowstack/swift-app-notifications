# swift-app-notifications

iOSとmacOSのリモート通知の端末側（許可・APNsのデバイストークン・タップ）を扱う。サーバーとのやり取りはアプリが受け持つ。

[English](README.md) | 日本語

## 機能

- 通知の許可を読む・求める（provisionalも選べる）
- デバイストークンを取り、APNsの環境・タイムゾーン・言語・アプリのバージョン・許可の状態と一緒に渡す
- 通知を許可していない端末も、最後に持っていたトークンと一緒に知らせる。サーバーは届かない端末を数えられる
- トークンをどのアカウントで登録したかを覚える。別のアカウントにサインインしたら同じトークンを送り直してサーバーに移させ、サインアウトしたらサーバーに外させる
- 前回サーバーが受け付けた登録から何も変わっていなければ、次の起動の後でも送らない
- 通知がタップされたら、payloadの`route`をアプリに渡し、`send_id`を知らせる
- URLを持たない。登録の送り先と、開かれた通知の知らせ先は、アプリがクロージャで渡す
- Swift 6のstrict concurrencyに対応する。判断の部分はフェイクを渡してMacの`swift test`で試せる

### `send`が受け取る物

`send`は`DeviceRegistration`を受け取る。`Codable`で、`{"token","apnsEnv","tz","locale","appVersion","authorization"}`の形に書き出す。

| プロパティ | 例 | 説明 |
|---|---|---|
| `token` | `"a1b2…"` | 小文字の16進数。一度ももらっていない端末は`nil` |
| `apnsEnvironment` | `.production` | `DEBUG`では`.sandbox`、それ以外は`.production`。`environment:`で変えられる |
| `timeZone` | `"Asia/Tokyo"` | IANAの識別子 |
| `locale` | `"ja-JP"` | BCP 47。アプリを表示している言語 |
| `appVersion` | `"2.4.0"` | `CFBundleShortVersionString` |
| `authorization` | `.authorized` | ほかに`.denied`・`.notDetermined`・`.provisional`・`.ephemeral` |

### アカウント

APNsのトークンはアプリのインストールに付く。サインインしている人には付かない。

| いつ | 呼ぶ物 | サーバーに届く物 |
|---|---|---|
| 誰がサインインしているか分かったとき（起動のたび・サインインの後・アカウントを切り替えた後） | `signIn(account:)` | 前回トークンを登録したアカウントと違えば、登録をもう一度 |
| 匿名のアカウントを連携し、idが変わらないとき | 同じidで`signIn(account:)` | 何も届かない |
| サインアウトするとき | セッションを終える前に`signOut()` | `unregister(token)`。投げたら次の更新でもう一度試す |
| サーバーがアカウントと端末を消したとき | `forgetAccount()` | 何も届かない |

`signIn(account:)`を呼ぶまでは何も登録しない。

### 通知を開いたとき

payloadは`aps`の横に`send_id`と`route`を持つ。先に`onOpen`がメインアクターで呼ばれ、次に`reportOpened`が`send_id`と一緒に呼ばれる。通知を消したときはどちらも呼ばれない。キーの名前は`PayloadKeys`で変えられる。

### テスト

システムに触れるのは`NotificationPermission`・`RemoteNotificationRegistering`・`RegistrationStore`の3つだけ。この3つのフェイクと、タイムゾーンと言語を決めた`context:`を渡せば、全部の流れがシミュレーターなしの`swift test`で動く。`InMemoryRegistrationStore`はプロセスが終わると何も残さない。

## はじめに

```swift
import RemoteNotifications
import SwiftUI
import UserNotifications

@MainActor @Observable
final class Router {
    var pendingRoute: String?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    let router = Router()
    let registration = NotificationRegistration(
        send: { registration in print("register", registration) },  // send it to your server
        unregister: { token in print("unregister", token) }
    )
    lazy var notifications = NotificationCenterDelegate(
        reportOpened: { sendId in print("opened", sendId) },
        onOpen: { [router] open in router.pendingRoute = open.route }
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Before returning, or the tap that launched the app is lost.
        UNUserNotificationCenter.current().delegate = notifications
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registration.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        registration.didFailToRegisterForRemoteNotifications(error: error)
    }
}

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Button("Allow notifications") {
                Task { try await appDelegate.registration.requestAuthorization() }
            }
            .environment(appDelegate.router)
            .task { await appDelegate.registration.signIn(account: "user-1") }  // your user id
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await appDelegate.registration.refresh() } }
        }
    }
}
```

### サーバーにつなぐ

このパッケージは単体で使えます。サーバーにつなぐときは、このパッケージで送り先を書く代わりに、コネクターのパッケージ [swift-appgrowstack](https://github.com/appgrowstack/swift-appgrowstack) の対応するtrait（SwiftPMのtraits）を有効にします。

### Firebaseを使うアプリ

Firebaseは標準でアプリのデリゲートをswizzleする。そのままだと`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`が呼ばれない。Info.plistに次を足す。

```xml
<key>FirebaseAppDelegateProxyEnabled</key>
<false/>
```

## ドキュメント

- [APIのドキュメント（DocCのカタログ）](Sources/RemoteNotifications/Documentation.docc/RemoteNotifications.md)
- [変更履歴](CHANGELOG.md)

## 入れ方

`Package.swift`に足す。

```swift
dependencies: [
    .package(url: "https://github.com/appgrowstack/swift-app-notifications.git", .upToNextMinor(from: "0.2.2"))
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "RemoteNotifications", package: "swift-app-notifications")
        ]
    )
]
```

Xcodeなら`File > Add Package Dependencies...`で`https://github.com/appgrowstack/swift-app-notifications.git`を入れる。

## 動く環境

- iOS 17.0以上・macOS 14.0以上
- Swift 6.0以上
- アプリのターゲットにPush NotificationsのCapability

## ライセンス

MIT。[LICENSE](LICENSE)を見る。

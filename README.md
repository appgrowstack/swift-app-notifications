# swift-app-notifications

The device side of remote notifications on iOS and macOS (permission, the APNs device token and taps), with the server left to the app.

English | [Japanese](README.ja.md)

## Features

- Reads and asks for the notification permission, provisional included
- Gets the device token and reports it with the APNs environment, time zone, language, app version and permission
- Reports devices that do not allow notifications too, with the last token they had, so the server can count who it cannot reach
- Knows which account the token is registered for: signing in to another account sends the same token again so the server moves it, and signing out asks the server to drop it
- Sends nothing when nothing has changed since the last registration the server accepted, across launches
- On a tap, hands the payload's `route` to the app and reports its `send_id`
- Never learns a URL: where a registration goes and where an open is reported are closures the app passes in
- Swift 6 strict concurrency; the decision logic runs under `swift test` on a Mac with fakes

### What `send` receives

`send` receives a `DeviceRegistration`. It is `Codable` and encodes as `{"token","apnsEnv","tz","locale","appVersion","authorization"}`.

| Property | Example | Notes |
|---|---|---|
| `token` | `"a1b2…"` | Lowercase hex. `nil` if the device has never been given one |
| `apnsEnvironment` | `.production` | `.sandbox` under `DEBUG`, `.production` otherwise. Pass `environment:` to override |
| `timeZone` | `"Asia/Tokyo"` | IANA identifier |
| `locale` | `"ja-JP"` | BCP 47, in the language the app is shown in |
| `appVersion` | `"2.4.0"` | `CFBundleShortVersionString` |
| `authorization` | `.authorized` | Also `.denied`, `.notDetermined`, `.provisional` and `.ephemeral` |

### Accounts

An APNs token belongs to the app's installation, not to the person signed in.

| When | Call | What reaches the server |
|---|---|---|
| The session is known (every launch, after sign-in, after an account switch) | `signIn(account:)` | The registration again, when the account differs from the one the token was last registered for |
| An anonymous account is linked and keeps its id | `signIn(account:)` with the same id | Nothing |
| Signing out | `signOut()`, before ending the session | `unregister(token)`. If it throws, it is retried on the next refresh |
| The server deleted the account and its devices | `forgetAccount()` | Nothing |

Until `signIn(account:)` is called, nothing is registered.

### Opening a notification

The payload carries `send_id` and `route` beside `aps`. `onOpen` runs first, on the main actor, then `reportOpened` with the `send_id`. A dismissal is neither. The key names can be changed with `PayloadKeys`.

### Testing

The system is reached only through `NotificationPermission`, `RemoteNotificationRegistering` and `RegistrationStore`. Pass fakes of the three, and `context:` for a fixed time zone and language, and the whole flow runs under `swift test` without a simulator. `InMemoryRegistrationStore` keeps nothing past the process.

## Quick Start

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

### Connecting to appgrowstack

This package works on its own with any server. Apps that use appgrowstack do not wire the server here: enable the matching trait of [swift-appgrowstack](https://github.com/appgrowstack/swift-appgrowstack) (SwiftPM traits), which connects this package to it.

### Apps that use Firebase

Firebase swizzles the app delegate by default, and with it in place `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` is never called. Add this to Info.plist:

```xml
<key>FirebaseAppDelegateProxyEnabled</key>
<false/>
```

## Documentation

- [API documentation (DocC catalog)](Sources/RemoteNotifications/Documentation.docc/RemoteNotifications.md)
- [Changelog](CHANGELOG.md)

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/appgrowstack/swift-app-notifications.git", .upToNextMinor(from: "0.2.1"))
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

Or in Xcode, `File > Add Package Dependencies...` with `https://github.com/appgrowstack/swift-app-notifications.git`.

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.0+
- The Push Notifications capability on the app target

## License

MIT. See [LICENSE](LICENSE).

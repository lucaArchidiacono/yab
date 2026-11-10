import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private let contentBlocker = ContentBlocker(now: SceneDelegate.clock)
    private let siteData = SiteDataManager()
    private let forgetter = SiteDataForgetter()
    private lazy var siteInfo = SiteInfoStore { [siteData] host in
        await siteData.site(containing: host)
    }
    private lazy var tabs = TabManager(
        contentBlocker: Self.isContentBlockingDisabled ? nil : contentBlocker,
        forgetter: forgetter,
        siteInfo: siteInfo
    )

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        // Tests run inside the app. They make their own browsers, and the real one would
        // only build filter lists and load pages in the background.
        window.rootViewController = Self.isRunningTests ? UIViewController() : BrowserViewController(tabs: tabs)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard !Self.isRunningTests else { return }
        // Picture the shown tab before anything else, then make sure nothing is lost
        // if iOS ends the app while it is away.
        tabs.captureSnapshotOfShownTab()
        tabs.lockHackerMode()
        tabs.saveSession()
        // Installing new rules briefly blocks the main thread, so update filter lists
        // while the browser is out of sight.
        runInBackground(named: "Update filter lists") { [contentBlocker] in
            await contentBlocker.updateIfDue()
        }
    }

    /// Runs `work`, asking iOS for time to finish it after the app leaves the screen.
    /// If that time runs out, `work` is cancelled.
    private func runInBackground(named name: String, _ work: @escaping () async -> Void) {
        let task = Task { await work() }
        let assertion = BackgroundAssertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            task.cancel()
            assertion.end()
        }
        Task {
            await task.value
            assertion.end()
        }
    }

    private static var clock: () -> Date {
        #if DEBUG
        // Launch with `-YABDebugClockOffsetDays 5` to make filter lists look five days older.
        let offset = UserDefaults.standard.double(forKey: "YABDebugClockOffsetDays") * 24 * 60 * 60
        return { Date().addingTimeInterval(offset) }
        #else
        return { Date() }
        #endif
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var isContentBlockingDisabled: Bool {
        #if DEBUG
        // Launch with `-YABDisableContentBlocking YES` to compare pages without blocking.
        UserDefaults.standard.bool(forKey: "YABDisableContentBlocking")
        #else
        false
        #endif
    }
}

private final class BackgroundAssertion {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

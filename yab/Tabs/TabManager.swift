import Foundation
import os
import UIKit
import WebKit

/// Runs both tab groups: normal mode and hacker mode.
///
/// **Normal tabs are never lost.** Their history, scroll positions and a picture of how
/// they last looked are saved, and they come back after the app is ended.
///
/// **Hacker tabs are never written to disk**, and hacker mode is locked behind Face ID,
/// Touch ID or the passcode whenever it is left or the app goes to the background.
///
/// **Only a few tabs keep a live web view**: the shown one and the most recently used.
/// The others are suspended to save memory and woken from their history when shown,
/// with their last picture on top until the page is back.
///
/// **Before a page opens**, tracking redirects are skipped, `http` is upgraded to HTTPS
/// and the Global Privacy Control signal is added. Blocking can be switched off per site.
final class TabManager {
    private static let logger = Logger(subsystem: "ch.archiluc.yab", category: "TabManager")

    let normalTabs: TabGroup
    let hackerTabs: TabGroup
    /// The mode being shown.
    private(set) var mode: BrowsingMode = .normal
    /// Called whenever tabs open or close, the selection changes or hacker mode locks.
    var onChange: (() -> Void)?
    let maximumLiveTabs: Int

    private let hackerLock: HackerModeLock
    private let contentBlocker: ContentBlocker?
    private let forgetter: SiteDataForgetter
    private let siteInfo: SiteInfoStore?
    private let store: TabStore
    private let configure: (WKWebViewConfiguration) -> Void
    private let now: () -> Date

    /// Normal tabs whose history changed since the last save.
    private var unsavedTabs: Set<UUID> = []
    private var scheduledSave: Task<Void, Never>?
    private var scheduledSnapshot: Task<Void, Never>?
    private var memoryWarningObserver: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - contentBlocker: `nil` turns content blocking off, for debugging.
    ///   - maximumLiveTabs: How many tabs keep a web view, the shown one included.
    ///   - upgradesLocalHostsToHTTPS: Also try HTTPS for `localhost`, for tests.
    ///   - configure: Last changes to each web view's configuration, for tests.
    init(
        contentBlocker: ContentBlocker?,
        forgetter: SiteDataForgetter,
        siteInfo: SiteInfoStore?,
        hackerLock: HackerModeLock = HackerModeLock(),
        normalDataStore: WKWebsiteDataStore = .default(),
        store: TabStore = TabStore(),
        blockingSwitchURL: URL = URL.applicationSupportDirectory.appending(path: "sites-without-blocking.json"),
        maximumLiveTabs: Int = 4,
        upgradesLocalHostsToHTTPS: Bool = false,
        configure: @escaping (WKWebViewConfiguration) -> Void = { _ in },
        now: @escaping () -> Date = { Date() }
    ) {
        normalTabs = TabGroup(
            mode: .normal,
            dataStore: normalDataStore,
            blockingSwitch: SiteBlockingSwitch(fileURL: blockingSwitchURL),
            httpsUpgrader: HTTPSUpgrader(upgradesLocalHosts: upgradesLocalHostsToHTTPS)
        )
        hackerTabs = TabGroup(
            mode: .hacker,
            dataStore: forgetter.store,
            blockingSwitch: SiteBlockingSwitch(fileURL: nil),
            httpsUpgrader: HTTPSUpgrader(upgradesLocalHosts: upgradesLocalHostsToHTTPS)
        )
        self.hackerLock = hackerLock
        self.contentBlocker = contentBlocker
        self.forgetter = forgetter
        self.siteInfo = siteInfo
        self.store = store
        self.maximumLiveTabs = max(1, maximumLiveTabs)
        self.configure = configure
        self.now = now
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendHiddenTabs() }
        }
    }

    // MARK: - What is shown

    func group(for mode: BrowsingMode) -> TabGroup {
        mode == .normal ? normalTabs : hackerTabs
    }

    var allTabs: [Tab] {
        normalTabs.tabs + hackerTabs.tabs
    }

    /// The selected tab of the mode being shown, even while hacker mode is locked.
    var selectedTab: Tab? {
        group(for: mode).selectedTab
    }

    /// The tab to put on screen: `nil` while hacker mode is locked.
    var shownTab: Tab? {
        mode == .hacker && hackerLock.isLocked ? nil : selectedTab
    }

    var isHackerModeLocked: Bool {
        hackerLock.isLocked
    }

    // MARK: - Hacker mode

    /// Asks the owner to authenticate, then shows hacker mode.
    @discardableResult
    func enterHackerMode() async -> Bool {
        guard await hackerLock.unlock() else { return false }
        allowHackerMedia()
        show(.hacker)
        return true
    }

    /// Shows normal mode and locks hacker mode behind it.
    func leaveHackerMode() {
        guard mode == .hacker else { return }
        lockHackerTabs()
        show(.normal)
    }

    /// Hides hacker mode until the owner authenticates, for when the app goes to the background.
    func lockHackerMode() {
        guard !hackerLock.isLocked else { return }
        lockHackerTabs()
        onChange?()
    }

    @discardableResult
    func unlockHackerMode() async -> Bool {
        let wasLocked = hackerLock.isLocked
        let unlocked = await hackerLock.unlock()
        if unlocked, wasLocked {
            onChange?()
        }
        if unlocked {
            allowHackerMedia()
        }
        return unlocked
    }

    /// Locks hacker mode and silences it. Nothing from hacker mode plays while it is
    /// locked, or can be started again from the lock screen.
    private func lockHackerTabs() {
        hackerLock.lock()
        for tab in hackerTabs.tabs {
            tab.webView?.pauseAllMediaPlayback()
            tab.webView?.setAllMediaPlaybackSuspended(true)
        }
    }

    /// Lets hacker pages play again once unlocked. Paused media stays paused.
    private func allowHackerMedia() {
        for tab in hackerTabs.tabs {
            tab.webView?.setAllMediaPlaybackSuspended(false)
        }
    }

    // MARK: - Tabs

    /// Opens a tab in the given mode, or the shown one, and shows it.
    /// Returns `nil` for a hacker tab while hacker mode is locked.
    @discardableResult
    func newTab(in mode: BrowsingMode? = nil, url: URL? = nil) -> Tab? {
        let mode = mode ?? self.mode
        if mode == .hacker, hackerLock.isLocked { return nil }
        let tab = Tab(mode: mode, lastActive: now())
        tab.delegate = self
        group(for: mode).append(tab)
        if let url {
            tab.load(url)
        }
        select(tab)
        return tab
    }

    /// Shows a tab, switching to its mode. Selecting a normal tab locks hacker mode;
    /// a hacker tab cannot be selected while hacker mode is locked.
    @discardableResult
    func select(_ tab: Tab) -> Bool {
        let group = group(for: tab.mode)
        guard group.contains(tab), !(tab.mode == .hacker && hackerLock.isLocked) else { return false }
        if let shown = shownTab, shown !== tab {
            captureSnapshot(of: shown)
        }
        if tab.mode == .normal, mode == .hacker {
            lockHackerTabs()
        }
        mode = tab.mode
        group.select(tab)
        tab.lastActive = now()
        wake(tab)
        suspendLeastRecentlyUsedTabs()
        changed(tab)
        return true
    }

    func close(_ tab: Tab) {
        let group = group(for: tab.mode)
        guard group.contains(tab) else { return }
        let wasSelected = group.selectedTab === tab
        group.remove(tab)
        tab.suspend()
        switch tab.mode {
        case .hacker:
            forgetter.tabDidClose(tab.id)
        case .normal:
            unsavedTabs.remove(tab.id)
            store.removeTab(tab.id)
        }
        if wasSelected, tab.mode == mode, let next = group.selectedTab {
            next.lastActive = now()
            wake(next)
        }
        changed(tab)
    }

    // MARK: - Sites without HTTPS

    /// Opens a site without working HTTPS over `http` after all, once the owner saw the
    /// warning and agreed. Its other pages open without asking until the app quits.
    func continueInsecurely(in tab: Tab) {
        guard case .insecureConnection(let url) = tab.loadProblem else { return }
        group(for: tab.mode).httpsUpgrader.allowHTTP(for: url)
        tab.load(url)
    }

    // MARK: - Blocking per site

    /// Whether ads and trackers are blocked on the site a tab shows.
    func isBlockingEnabled(forSiteOf tab: Tab) -> Bool {
        guard let host = tab.url?.host() else { return true }
        return group(for: tab.mode).blockingSwitch.isBlockingEnabled(on: host)
    }

    /// Switches blocking on or off for the site a tab shows, and reloads it.
    /// Each group remembers this separately; hacker mode only until the app quits.
    func setBlocking(_ enabled: Bool, forSiteOf tab: Tab) {
        guard let host = tab.url?.host() else { return }
        group(for: tab.mode).blockingSwitch.setBlocking(enabled, on: host)
        if let controller = tab.webView?.configuration.userContentController {
            installContent(forHostname: host, in: controller, mode: tab.mode)
        }
        tab.reload()
        onChange?()
    }

    /// Content blocking, scriptlets and privacy signals for a page about to load.
    private func installContent(forHostname host: String, in controller: WKUserContentController, mode: BrowsingMode) {
        let blocking = group(for: mode).blockingSwitch.isBlockingEnabled(on: host)
        contentBlocker?.setBlocking(blocking, in: controller)
        controller.removeAllUserScripts()
        controller.addUserScript(GlobalPrivacyControl.userScript)
        // Hacker mode stops its sound when it locks, as the app leaves the screen.
        if mode == .normal {
            controller.addUserScript(BackgroundPlayback.userScript)
        }
        if blocking {
            for script in contentBlocker?.scriptlets(forHostname: host) ?? [] {
                controller.addUserScript(script)
            }
        }
    }

    private func show(_ mode: BrowsingMode) {
        if let shown = shownTab {
            captureSnapshot(of: shown)
        }
        self.mode = mode
        if let tab = selectedTab {
            tab.lastActive = now()
            wake(tab)
            suspendLeastRecentlyUsedTabs()
        }
        onChange?()
    }

    private func isSelected(_ tab: Tab) -> Bool {
        group(for: tab.mode).selectedTab === tab
    }

    private func changed(_ tab: Tab) {
        if tab.mode == .normal {
            scheduleSave()
        }
        onChange?()
    }

    // MARK: - Live web views

    /// Gives a suspended tab a web view again, showing its last picture until the page is back.
    private func wake(_ tab: Tab) {
        guard !tab.isLive else { return }
        if tab.mode == .normal {
            if tab.history == nil {
                tab.restore(history: store.history(for: tab.id))
            }
            if tab.history != nil || tab.url != nil, let snapshot = store.snapshot(for: tab.id) {
                tab.view.showSnapshot(snapshot)
            }
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = group(for: tab.mode).dataStore
        // Like Safari: videos play inside the page when it asks for it (`playsinline`),
        // as YouTube's mobile site does, instead of always going full screen.
        configuration.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        configuration.userContentController = controller
        configure(configuration)
        tab.wake(with: WKWebView(frame: .zero, configuration: configuration))

        if let contentBlocker {
            // Pages wait for the rules, so none is ever shown unfiltered.
            Task {
                await contentBlocker.attach(to: controller)
                tab.webViewIsReady()
            }
        } else {
            tab.webViewIsReady()
        }
    }

    private func suspend(_ tab: Tab) {
        guard tab.isLive else { return }
        tab.suspend()
        if tab.mode == .normal {
            unsavedTabs.insert(tab.id)
            scheduleSave()
        }
    }

    /// Keeps only the most recently used tabs live. The selected tab always stays.
    private func suspendLeastRecentlyUsedTabs() {
        let live = allTabs.filter(\.isLive).sorted { $0.lastActive > $1.lastActive }
        suspendUnlessPlaying(live.dropFirst(maximumLiveTabs).filter { $0 !== selectedTab })
    }

    /// On memory pressure, everything but the selected tab gives its web view up.
    func suspendHiddenTabs() {
        suspendUnlessPlaying(allTabs.filter { $0.isLive && $0 !== selectedTab })
    }

    /// Suspends tabs, except those playing something: music goes on while browsing in
    /// other tabs. WebKit knows what plays in every frame, so it is asked.
    private func suspendUnlessPlaying(_ tabs: [Tab]) {
        for tab in tabs {
            guard let webView = tab.webView else { continue }
            let lastActive = tab.lastActive
            webView.requestMediaPlaybackState { [weak self] state in
                // Still the same web view, and not used again while WebKit answered.
                guard let self, state != .playing, tab.webView === webView,
                      tab.lastActive == lastActive, tab !== self.selectedTab else { return }
                self.suspend(tab)
            }
        }
    }

    // MARK: - Pictures

    /// Saves how a normal tab looks right now, to show while it loads again later.
    /// Hacker tabs are never pictured.
    func captureSnapshot(of tab: Tab) {
        guard tab.mode == .normal, let webView = tab.webView, webView.url != nil, !tab.view.isShowingSnapshot else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, let image else { return }
            Task {
                await self.store.saveSnapshot(image, for: tab.id)
                self.removeOldSnapshots()
            }
        }
    }

    func captureSnapshotOfShownTab() {
        if let tab = shownTab {
            captureSnapshot(of: tab)
        }
    }

    private func removeOldSnapshots() {
        let recent = normalTabs.tabs.sorted { $0.lastActive > $1.lastActive }.prefix(TabStore.snapshotLimit)
        store.removeSnapshots(except: Set(recent.map(\.id)))
    }

    // MARK: - Saving normal tabs

    /// Brings back the normal tabs of the last session. Only the selected one loads now.
    func restoreSession() {
        guard let index = store.loadIndex() else { return }
        for entry in index.tabs where normalTabs.tab(withID: entry.id) == nil {
            let tab = Tab(id: entry.id, mode: .normal, url: entry.url, title: entry.title, lastActive: entry.lastActive)
            tab.delegate = self
            normalTabs.append(tab)
        }
        if let selected = index.selectedTabID.flatMap(normalTabs.tab(withID:)) ?? normalTabs.tabs.last {
            select(selected)
        }
    }

    /// Writes the tab list and every changed history now.
    func saveSession() {
        scheduledSave?.cancel()
        scheduledSave = nil
        for tab in normalTabs.tabs where tab.isLive {
            tab.updateHistory()
            unsavedTabs.insert(tab.id)
        }
        for id in unsavedTabs {
            if let history = normalTabs.tab(withID: id)?.history {
                store.saveHistory(history, for: id)
            }
        }
        unsavedTabs = []
        store.save(TabStore.Index(
            tabs: normalTabs.tabs.map { TabStore.Entry(id: $0.id, url: $0.url, title: $0.title, lastActive: $0.lastActive) },
            selectedTabID: normalTabs.selectedTab?.id
        ))
    }

    /// Saves a moment later, so a burst of changes is written once.
    private func scheduleSave() {
        scheduledSave?.cancel()
        scheduledSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }
}

extension TabManager: TabDelegate {
    func tab(_ tab: Tab, decisionFor request: URLRequest, type: WKNavigationType) -> MainFrameDecision {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              (request.httpMethod ?? "GET") == "GET",
              // Going back, forward or reloading must show what was there.
              type != .backForward, type != .reload else { return .allow }

        var destination = url
        if let host = url.host(), group(for: tab.mode).blockingSwitch.isBlockingEnabled(on: host),
           let skipped = contentBlocker?.redirectDestination(of: url) {
            destination = skipped
        }
        switch group(for: tab.mode).httpsUpgrader.decide(destination, in: tab.id) {
        case .proceed:
            break
        case .upgrade(let upgraded):
            destination = upgraded
        case .warn(let insecure):
            return .stop(.insecureConnection(insecure))
        }
        let hasSignal = request.value(forHTTPHeaderField: GlobalPrivacyControl.headerName) != nil
        guard destination != url || !hasSignal else { return .allow }

        var replacement = request
        replacement.url = destination
        replacement.setValue(GlobalPrivacyControl.headerValue, forHTTPHeaderField: GlobalPrivacyControl.headerName)
        return .load(replacement)
    }

    func tab(_ tab: Tab, willNavigateMainFrameTo url: URL) {
        guard let controller = tab.webView?.configuration.userContentController else { return }
        installContent(forHostname: url.host() ?? "", in: controller, mode: tab.mode)
    }

    func tabDidCommitNavigation(_ tab: Tab) {
        group(for: tab.mode).httpsUpgrader.finish(in: tab.id)
    }

    func tab(_ tab: Tab, shouldRetryAfter error: any Error) -> Bool {
        // The site has no working HTTPS: warn before opening it over `http`.
        guard let insecure = group(for: tab.mode).httpsUpgrader.failedUpgrade(in: tab.id, after: error) else { return false }
        Self.logger.info("\(insecure.host() ?? "?", privacy: .public) has no working HTTPS")
        tab.report(.insecureConnection(insecure))
        return true
    }

    func tabDidChangeLoadProblem(_ tab: Tab) {
        onChange?()
    }

    func tabDidChangeSecurity(_ tab: Tab) {
        onChange?()
    }

    func tab(_ tab: Tab, didChangeURL url: URL?) {
        switch tab.mode {
        case .hacker:
            forgetter.tab(tab.id, didShow: url)
        case .normal:
            unsavedTabs.insert(tab.id)
            scheduleSave()
        }
    }

    func tabDidFinishLoading(_ tab: Tab) {
        guard tab.mode == .normal else { return }
        if let host = tab.url?.host() {
            siteInfo?.noteVisit(to: host)
        }
        unsavedTabs.insert(tab.id)
        scheduleSave()
        // Keep the picture of the shown tab fresh, in case the app is ended.
        if tab === shownTab {
            scheduledSnapshot?.cancel()
            scheduledSnapshot = Task { [weak self, weak tab] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let tab, tab === self.shownTab else { return }
                self.captureSnapshot(of: tab)
            }
        }
    }

    func tabWebContentProcessDidTerminate(_ tab: Tab) {
        Self.logger.notice("The page of a \(tab.mode.rawValue, privacy: .public) tab was ended by iOS")
        // Rebuild the tab from its history. The shown tab comes straight back, with its picture on top.
        suspend(tab)
        if tab === selectedTab {
            wake(tab)
        }
    }
}

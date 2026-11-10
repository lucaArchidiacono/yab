import UIKit
import WebKit

/// Shows the shown tab, or the lock in front of hacker mode. The browser's controls
/// come with the theme work; until then this is just the page.
final class BrowserViewController: UIViewController {
    private let tabs: TabManager
    private let hackerCover = HackerModeCover()
    private weak var shownTabView: TabView?
    /// Hacker mode is hidden whenever the app is not in front, so it never shows up in
    /// the app switcher.
    private var isInactive = false

    init(tabs: TabManager) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tabs.onChange = { [weak self] in self?.update() }

        hackerCover.onUnlock = { [weak self] in
            Task { await self?.tabs.unlockHackerMode() }
        }
        hackerCover.onLeave = { [weak self] in
            self?.tabs.leaveHackerMode()
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sceneWillDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneWillEnterForeground), name: UIScene.willEnterForegroundNotification, object: nil)

        tabs.restoreSession()
        openFirstTab()
        update()
    }

    private func openFirstTab() {
        if let startURL = Self.debugStartURL {
            if Self.debugStartsInHackerMode {
                Task {
                    if await tabs.enterHackerMode() {
                        tabs.newTab(in: .hacker, url: startURL)
                    }
                }
            } else {
                tabs.newTab(in: .normal, url: startURL)
            }
        } else if tabs.selectedTab == nil {
            // Replaced by the empty tab screen once there is UI.
            tabs.newTab(in: .normal, url: URL(string: "https://example.com")!)
        }
    }

    private func update() {
        let isHackerModeHidden = tabs.mode == .hacker && (tabs.isHackerModeLocked || isInactive)
        show(isHackerModeHidden ? nil : tabs.shownTab?.view)
        hackerCover.isHidden = !isHackerModeHidden
        if hackerCover.superview == nil {
            pin(hackerCover)
        }
        view.bringSubviewToFront(hackerCover)
    }

    private func show(_ tabView: TabView?) {
        guard tabView !== shownTabView else { return }
        shownTabView?.removeFromSuperview()
        shownTabView = tabView
        if let tabView {
            pin(tabView, toSafeAreaTop: true)
        }
    }

    private func pin(_ subview: UIView, toSafeAreaTop: Bool = false) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: toSafeAreaTop ? view.safeAreaLayoutGuide.topAnchor : view.topAnchor),
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Hiding hacker mode

    @objc private func sceneWillDeactivate() {
        isInactive = true
        update()
    }

    @objc private func sceneDidActivate() {
        isInactive = false
        update()
    }

    /// Back from the background: hacker mode was locked meanwhile, so ask right away.
    /// Only here, not on every activation, as the prompt itself deactivates the app.
    @objc private func sceneWillEnterForeground() {
        guard tabs.mode == .hacker, tabs.isHackerModeLocked else { return }
        Task { await tabs.unlockHackerMode() }
    }

    // MARK: - Debugging

    /// Launch with `-YABStartURL https://…` to open a page while developing,
    /// and add `-YABHackerMode YES` to open it in hacker mode.
    private static var debugStartURL: URL? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "YABStartURL").flatMap(URL.init(string:))
        #else
        nil
        #endif
    }

    private static var debugStartsInHackerMode: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "YABHackerMode")
        #else
        false
        #endif
    }
}

/// What hacker mode shows while locked or while the app is not in front.
/// A placeholder until themes draw their own.
final class HackerModeCover: UIView {
    var onUnlock: (() -> Void)?
    var onLeave: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = .green
        lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .bold)

        let title = UILabel()
        title.text = "Hacker mode is locked"
        title.textColor = .green
        title.font = .monospacedSystemFont(ofSize: 17, weight: .bold)

        var unlockStyle = UIButton.Configuration.filled()
        unlockStyle.title = "Unlock"
        unlockStyle.baseBackgroundColor = .green
        unlockStyle.baseForegroundColor = .black
        let unlock = UIButton(configuration: unlockStyle, primaryAction: UIAction { [weak self] _ in self?.onUnlock?() })

        var leaveStyle = UIButton.Configuration.plain()
        leaveStyle.title = "Back to normal mode"
        leaveStyle.baseForegroundColor = .green
        let leave = UIButton(configuration: leaveStyle, primaryAction: UIAction { [weak self] _ in self?.onLeave?() })

        let stack = UIStackView(arrangedSubviews: [lock, title, unlock, leave])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

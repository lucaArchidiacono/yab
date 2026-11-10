import Foundation
import WebKit

nonisolated enum BrowsingMode: String, Codable, Sendable {
    /// Everything is kept, and can be cleaned up by hand.
    case normal
    /// yab's private mode: a site's data lives only while a tab shows the site.
    case hacker
}

/// Why a page could not be shown, for the screen shown instead.
nonisolated enum LoadProblem: Equatable, Sendable {
    /// A filter list blocks the page, for example a known malware site.
    case blocked(URL)
    /// There is no internet connection.
    case offline(URL)
    /// The site has no working HTTPS. It opens over this `http` address only once the
    /// owner agrees, after a warning.
    case insecureConnection(URL)

    init?(_ error: any Error) {
        let error = error as NSError
        guard let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return nil }

        if error.domain == "WebKitErrorDomain", error.code == Self.blockedByContentBlocker {
            self = .blocked(url)
        } else if error.domain == NSURLErrorDomain, Self.offlineCodes.contains(error.code) {
            self = .offline(url)
        } else {
            return nil
        }
    }

    /// WebKit's error for loads stopped by a content rule list.
    static let blockedByContentBlocker = 104

    private static let offlineCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
    ]
}

/// How safe the connection to the shown page is, for the address bar.
nonisolated enum PageSecurity: Equatable, Sendable {
    /// HTTPS, with everything on the page loaded securely.
    case secure
    /// `http`, or HTTPS with parts of the page loaded insecurely. Others on the network
    /// can read and change it.
    case notSecure
}

/// What to do with a page about to open in the main frame.
enum MainFrameDecision {
    case allow
    /// Open this request instead: to skip a tracking redirect, upgrade to HTTPS or add a
    /// privacy signal.
    case load(URLRequest)
    /// Do not open it, and show why.
    case stop(LoadProblem)
}

protocol TabDelegate: AnyObject {
    func tab(_ tab: Tab, decisionFor request: URLRequest, type: WKNavigationType) -> MainFrameDecision
    /// The main frame is about to load `url`. Anything that must be in place before the
    /// page's own scripts run happens here.
    func tab(_ tab: Tab, willNavigateMainFrameTo url: URL)
    func tabDidCommitNavigation(_ tab: Tab)
    /// A page failed to load. Return `true` if another attempt was started.
    func tab(_ tab: Tab, shouldRetryAfter error: any Error) -> Bool
    func tabDidChangeLoadProblem(_ tab: Tab)
    func tabDidChangeSecurity(_ tab: Tab)
    func tab(_ tab: Tab, didChangeURL url: URL?)
    func tabDidFinishLoading(_ tab: Tab)
    /// iOS ended the process showing the page, usually to free memory.
    func tabWebContentProcessDidTerminate(_ tab: Tab)
}

/// One tab. Its back/forward history is what matters; the web view showing it is
/// temporary. A tab can be suspended to free memory and woken later from its history,
/// with the same pages and scroll positions.
final class Tab: NSObject, Identifiable {
    let id: UUID
    let mode: BrowsingMode
    let view = TabView()
    weak var delegate: (any TabDelegate)?

    private(set) var url: URL?
    private(set) var title: String?
    /// Back/forward history with scroll positions, as of the last page change.
    private(set) var history: Data?
    /// Why the last page could not be shown, until the next one starts loading.
    private(set) var loadProblem: LoadProblem?
    var lastActive: Date

    /// The live page, or `nil` while suspended.
    private(set) var webView: WKWebView?
    private var isReady = false
    /// A page to open once the web view is ready, after restoring the history.
    private var pendingURL: URL?
    private var needsHistoryRestore = false
    /// Replacements in a row without a page loading, to stop endless loops.
    private var replacementsInARow = 0
    private var observations: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), mode: BrowsingMode, url: URL? = nil, title: String? = nil, lastActive: Date = Date()) {
        self.id = id
        self.mode = mode
        self.url = url
        self.title = title
        self.lastActive = lastActive
    }

    var isLive: Bool {
        webView != nil
    }

    /// `nil` for pages that are not on the web, like `about:blank`.
    var security: PageSecurity? {
        guard let webView, let scheme = webView.url?.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https": return webView.hasOnlySecureContent ? .secure : .notSecure
        case "http": return .notSecure
        default: return nil
        }
    }

    /// Shows why a page is not shown, for problems found outside WebKit.
    func report(_ problem: LoadProblem) {
        setLoadProblem(problem)
    }

    /// Opens `url`. A suspended tab opens it when woken, after its history.
    func load(_ url: URL) {
        pendingURL = url
        loadPending()
    }

    func reload() {
        webView?.reload()
    }

    /// Sets the history a suspended tab comes back with, such as one read from disk.
    func restore(history: Data?) {
        guard !isLive else { return }
        self.history = history
    }

    /// Shows the tab's history in `webView`. Pages load once `webViewIsReady()` is called.
    func wake(with webView: WKWebView) {
        guard self.webView == nil else { return }
        self.webView = webView
        isReady = false
        needsHistoryRestore = history != nil
        if !needsHistoryRestore, pendingURL == nil {
            pendingURL = url
        }

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.webViewURLDidChange() }
            },
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    if let title = self?.webView?.title, !title.isEmpty { self?.title = title }
                }
            },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.delegate?.tabDidChangeSecurity(self)
                }
            },
        ]
        view.install(webView)
    }

    func webViewIsReady() {
        isReady = true
        loadPending()
    }

    /// Frees the web view. The history keeps everything needed to bring the tab back.
    func suspend() {
        guard let webView else { return }
        updateHistory()
        observations = []
        webView.navigationDelegate = nil
        webView.stopLoading()
        view.removeWebView()
        self.webView = nil
        isReady = false
    }

    /// Reads the current history from the web view.
    func updateHistory() {
        if let state = webView?.interactionState as? Data {
            history = state
        }
    }

    private func loadPending() {
        guard isReady, let webView else { return }
        if needsHistoryRestore, let history {
            needsHistoryRestore = false
            webView.interactionState = history
        }
        if let pendingURL {
            self.pendingURL = nil
            webView.load(URLRequest(url: pendingURL))
        }
    }

    private func webViewURLDidChange() {
        guard let webView else { return }
        if let url = webView.url {
            self.url = url
        }
        updateHistory()
        delegate?.tab(self, didChangeURL: webView.url)
    }

    private func setLoadProblem(_ problem: LoadProblem?) {
        guard problem != loadProblem else { return }
        loadProblem = problem
        delegate?.tabDidChangeLoadProblem(self)
    }
}

extension Tab: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        switch delegate?.tab(self, decisionFor: navigationAction.request, type: navigationAction.navigationType) ?? .allow {
        case .load(let replacement) where replacementsInARow < 5:
            replacementsInARow += 1
            decisionHandler(.cancel)
            webView.load(replacement)
        case .stop(let problem):
            replacementsInARow = 0
            decisionHandler(.cancel)
            setLoadProblem(problem)
        case .allow, .load:
            delegate?.tab(self, willNavigateMainFrameTo: url)
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setLoadProblem(nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        replacementsInARow = 0
        delegate?.tabDidCommitNavigation(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateHistory()
        view.hideSnapshot()
        delegate?.tabDidFinishLoading(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        view.hideSnapshot()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        view.hideSnapshot()
        if delegate?.tab(self, shouldRetryAfter: error) == true { return }
        replacementsInARow = 0
        setLoadProblem(LoadProblem(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        delegate?.tabWebContentProcessDidTerminate(self)
    }
}

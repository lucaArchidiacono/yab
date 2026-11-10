import Foundation
import Testing
import UIKit
import WebKit
@testable import yab

/// Serves a page and tiny images for the `yabtest` scheme, recording every request.
/// Content blocking applies to custom schemes too, so this tests blocking without a network.
@MainActor
final class TestSchemeHandler: NSObject, WKURLSchemeHandler {
    var html: String
    private(set) var requestedURLs: [String] = []

    init(html: String) {
        self.html = html
    }

    func reset() {
        requestedURLs = []
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        requestedURLs.append(url.absoluteString)

        let isPage = url.pathExtension == "html"
        // A 1x1 transparent GIF.
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let body = isPage ? Data(html.utf8) : gif
        let response = URLResponse(url: url, mimeType: isPage ? "text/html" : "image/gif", expectedContentLength: body.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// A web view that serves `yabtest://` pages from a `TestSchemeHandler`.
@MainActor
final class TestBrowser {
    let server: TestSchemeHandler
    let webView: WKWebView
    private let navigation = NavigationWaiter()
    private var window: UIWindow?

    init(html: String, dataStore: WKWebsiteDataStore? = nil) {
        server = TestSchemeHandler(html: html)
        let configuration = WKWebViewConfiguration()
        if let dataStore {
            configuration.websiteDataStore = dataStore
        }
        configuration.setURLSchemeHandler(server, forURLScheme: "yabtest")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        webView.navigationDelegate = navigation
    }

    /// Puts the web view in a visible window. Pages only render, and run
    /// `requestAnimationFrame` callbacks, when they are on screen.
    func showOnScreen() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = webView.frame
        window.addSubview(webView)
        window.isHidden = false
        self.window = window
    }

    /// Called when the main frame is about to navigate, like the app's navigation delegate.
    var willNavigateMainFrame: ((URL) -> Void)? {
        get { navigation.willNavigateMainFrame }
        set { navigation.willNavigateMainFrame = newValue }
    }

    func load(_ url: String = "yabtest://site.example/index.html") async throws {
        webView.load(URLRequest(url: URL(string: url)!))
        try await navigation.waitUntilFinished()
    }

    func evaluate(_ javaScript: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(javaScript, arguments: [:], contentWorld: .page)
    }

    /// Polls `condition`, a JavaScript function body returning a boolean, until it is true.
    func waitUntil(_ condition: String, timeout: Duration = .seconds(3)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await evaluate(condition) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func display(of selector: String) async throws -> String? {
        try await webView.callAsyncJavaScript(
            "return getComputedStyle(document.querySelector(selector)).display",
            arguments: ["selector": selector],
            contentWorld: .page
        ) as? String
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    var willNavigateMainFrame: ((URL) -> Void)?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url {
            willNavigateMainFrame?(url)
        }
        decisionHandler(.allow)
    }

    func waitUntilFinished() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Polls an asynchronous condition until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

/// A content blocker with a single trusted test list and uBlock Origin's real scriptlets,
/// in temporary folders.
@MainActor
func makeTestContentBlocker(filters: String) throws -> ContentBlocker {
    let directory = FileManager.default.temporaryDirectory.appending(path: "yab-blocker-\(UUID().uuidString)")
    let locations = ContentBlocker.Locations(bundled: directory.appending(path: "bundled"), storage: directory.appending(path: "storage"))
    try FileManager.default.createDirectory(at: locations.bundled, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: try #require(Bundle.main.url(forResource: "ubo-scriptlets", withExtension: "json")),
        to: locations.scriptletLibraryURL
    )
    let list = FilterList(identifier: "test", name: "Test", resourceName: "test", isTrusted: true, updateURLs: [])
    try "! Title: Test\n\(filters)".write(to: locations.bundledURL(for: list), atomically: true, encoding: .utf8)
    return ContentBlocker(
        filterLists: [list],
        store: try #require(WKContentRuleListStore(url: directory.appending(path: "store"))),
        defaults: try #require(UserDefaults(suiteName: "yab-tests-\(UUID().uuidString)")),
        locations: locations,
        fetch: { _ in throw URLError(.notConnectedToInternet) }
    )
}

/// A visible window to put views in. Pages only render, and can be pictured,
/// when on screen.
@MainActor
final class TestScreen {
    private let window: UIWindow

    init() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.isHidden = false
    }

    func show(_ view: UIView) {
        clear()
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        view.layoutIfNeeded()
    }

    /// Shows nothing, as when the app leaves the screen: pages become hidden.
    func clear() {
        window.subviews.forEach { $0.removeFromSuperview() }
    }
}

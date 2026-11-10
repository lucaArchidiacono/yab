import Foundation
import Testing
import WebKit
@testable import yab

/// The real uBlock Origin scriptlets shipped in the app.
private let library: ScriptletLibrary = {
    let url = Bundle.main.url(forResource: "ubo-scriptlets", withExtension: "json")!
    return try! ScriptletLibrary(contentsOf: url)
}()

struct ScriptletArgumentTests {
    @Test(arguments: [
        ("set, foo, true", ["set", "foo", "true"]),
        ("set,foo,true", ["set", "foo", "true"]),
        ("  set ,  foo  , true  ", ["set", "foo", "true"]),
        (#"acs, document.write, "a, b""#, ["acs", "document.write", "a, b"]),
        (#"acs, eval, 'it\'s'"#, ["acs", "eval", "it's"]),
        (#"rmnt, script, a\, b"#, ["rmnt", "script", "a, b"]),
        ("ra, , div", ["ra", "", "div"]),
        ("nostif, /ad|block/, 500", ["nostif", "/ad|block/", "500"]),
        ("set, a, b,", ["set", "a", "b"]),
        ("", []),
    ])
    func splitsLikeUBlockOrigin(text: String, expected: [String]) {
        #expect(ScriptletArguments.split(Substring(text)) == expected)
    }
}

struct ScriptletFilterTests {
    func parse(_ line: String, trusted: Bool = true) -> Result<ScriptletFilterParser.Filter, FilterSkipReason> {
        let split = CosmeticFilterParser.split(Substring(line))!
        return ScriptletFilterParser.parse(
            domains: split.domains,
            body: split.body,
            isException: split.separator == .hideException,
            isTrusted: trusted,
            library: library
        )
    }

    @Test func aliasesResolveToCanonicalNames() throws {
        let filter = try parse("example.com,google.*,~www.example.com##+js(set, ads, false)").get()
        #expect(filter.call == ["set-constant.js", "ads", "false"])
        #expect(filter.hostnames == ["example.com", "google.*"])
        #expect(filter.excludedHostnames == ["www.example.com"])
        #expect(!filter.isException)
    }

    @Test func unknownScriptletsAreSkipped() {
        #expect(parse("example.com##+js(no-such-thing)") == .failure(.unknownScriptlet))
    }

    @Test func trustedScriptletsNeedATrustedList() throws {
        #expect(parse("example.com##+js(trusted-set-cookie, a, b)", trusted: false) == .failure(.untrustedScriptlet))
        #expect(try parse("example.com##+js(trusted-set-cookie, a, b)", trusted: true).get().call.first == "trusted-set-cookie.js")
    }

    @Test func scriptletsNeedHostnamesUnlessTheyAreExceptions() throws {
        #expect(parse("##+js(set, ads, false)") == .failure(.invalid))
        #expect(try parse("#@#+js(set, ads, false)").get().hostnames.isEmpty)
    }

    @Test func emptyExceptionTurnsOffEverything() throws {
        let filter = try parse("example.com#@#+js()").get()
        #expect(filter.call.isEmpty)
        #expect(filter.isException)
    }
}

struct ScriptletIndexTests {
    func index(_ filters: String) -> ScriptletIndex {
        FilterListConverter(scriptletLibrary: library).convert(filters, isTrusted: true).scriptlets
    }

    @Test func lookupKeysFollowUBlockOrigin() {
        let keys = ScriptletIndex.lookupKeys(forHostname: "www.example.co.uk")
        #expect(Array(keys.prefix(4)) == ["www.example.co.uk", "example.co.uk", "co.uk", "uk"])
        #expect(keys.contains("example.*"))
        #expect(keys.contains("example.co.*"))
    }

    @Test func parentDomainsAndEntitiesApply() {
        let scriptlets = index("""
            example.com##+js(set, a, 1)
            google.*##+js(set, b, 2)
            """)
        #expect(scriptlets.calls(forHostname: "news.example.com") == [["set-constant.js", "a", "1"]])
        #expect(scriptlets.calls(forHostname: "www.google.co.uk") == [["set-constant.js", "b", "2"]])
        #expect(scriptlets.calls(forHostname: "example.org").isEmpty)
    }

    @Test func excludedHostnamesAndExceptionsWin() {
        let scriptlets = index("""
            example.com,~shop.example.com##+js(set, a, 1)
            example.com##+js(set, b, 2)
            news.example.com#@#+js(set, b, 2)
            """)
        #expect(scriptlets.calls(forHostname: "shop.example.com") == [["set-constant.js", "b", "2"]])
        #expect(scriptlets.calls(forHostname: "news.example.com") == [["set-constant.js", "a", "1"]])
    }

    @Test func exceptionsApplyAcrossLists() {
        let output = FilterListConverter(scriptletLibrary: library).convert([
            .init(text: "example.com##+js(set, a, 1)", isTrusted: true),
            .init(text: "example.com#@#+js(set, a, 1)", isTrusted: true),
        ])
        #expect(output.scriptlets.calls(forHostname: "example.com").isEmpty)
    }

    @Test func emptyExceptionTurnsOffAllScriptletsForSite() {
        let scriptlets = index("""
            example.com##+js(set, a, 1)
            example.com##+js(aopr, b)
            www.example.com#@#+js()
            """)
        #expect(scriptlets.calls(forHostname: "www.example.com").isEmpty)
        #expect(scriptlets.calls(forHostname: "example.com").count == 2)
    }

    @Test func globalExceptionTurnsOffScriptletEverywhere() {
        let scriptlets = index("""
            example.com##+js(set, a, 1)
            #@#+js(set, a, 1)
            """)
        #expect(scriptlets.calls(forHostname: "example.com").isEmpty)
    }

    @Test func survivesEncoding() throws {
        let scriptlets = index("example.com##+js(set, a, 1)")
        let decoded = try JSONDecoder().decode(ScriptletIndex.self, from: JSONEncoder().encode(scriptlets))
        #expect(decoded == scriptlets)
    }
}

struct ScriptletLibraryTests {
    @Test func scriptDeclaresDependenciesOnceAndGuardsHostname() throws {
        let code = try #require(library.script(
            for: [["set-constant.js", "a", "1"], ["set-constant.js", "b", "2"]],
            world: .main,
            hostname: "example.com"
        ))
        #expect(code.contains(#"if ( hostname !== "example.com" ) { return; }"#))
        #expect(code.components(separatedBy: "function safeSelf(").count == 2)
        #expect(code.contains(#"try { setConstant("a", "1"); } catch { }"#))
        #expect(code.contains(#"try { setConstant("b", "2"); } catch { }"#))
    }

    @Test func worldsAreSeparate() {
        // remove-class runs in an isolated world, set-constant in the page's.
        let calls = [["set-constant.js", "a", "1"], ["remove-class.js", "ad"]]
        let main = library.script(for: calls, world: .main, hostname: "example.com")
        let isolated = library.script(for: calls, world: .isolated, hostname: "example.com")
        #expect(main?.contains("removeClass(") == false)
        #expect(main?.contains("setConstant(") == true)
        #expect(isolated?.contains("removeClass(") == true)
        #expect(isolated?.contains("setConstant(") == false)
    }
}

/// Scriptlets running in WebKit, installed the way the browser does it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ScriptletInjectionTests {
    @Test func scriptletsRunBeforePageScriptsOnMatchingSitesOnly() async throws {
        let blocker = try makeTestContentBlocker(filters: """
            site.example##+js(set, yabTest, 42)
            site.example##+js(rc, ad, .box)
            """)
        // The page records what it saw before any scriptlet could tidy up after it.
        let browser = TestBrowser(html: """
            <html><head><script>document.title = String(window.yabTest);</script></head>
            <body><div class="box ad">Box</div></body></html>
            """)
        try browser.showOnScreen()
        let controller = browser.webView.configuration.userContentController
        await blocker.attach(to: controller)
        browser.willNavigateMainFrame = { url in
            controller.removeAllUserScripts()
            blocker.scriptlets(forHostname: url.host() ?? "").forEach(controller.addUserScript)
        }

        try await browser.load("yabtest://site.example/index.html")
        #expect(try await browser.evaluate("return document.title") as? String == "42")
        // remove-class runs in an isolated world once the page is idle.
        #expect(try await browser.waitUntil("return !document.querySelector('.box').classList.contains('ad')"))

        try await browser.load("yabtest://other.example/index.html")
        #expect(try await browser.evaluate("return document.title") as? String == "undefined")
        #expect(try await !browser.waitUntil("return !document.querySelector('.box').classList.contains('ad')", timeout: .milliseconds(500)))

        try await browser.load("yabtest://site.example/again.html")
        #expect(try await browser.evaluate("return document.title") as? String == "42")
    }

    /// Over http, a navigation to another site moves the page into a new web process.
    /// Scriptlets installed while deciding on the navigation must still reach it.
    @Test func scriptletsSurviveNavigationToAnotherSite() async throws {
        let server = try await LocalHTTPServer(html: """
            <html><head><script>document.title = String(window.yabTest);</script></head><body></body></html>
            """)
        let blocker = try makeTestContentBlocker(filters: "localhost##+js(set, yabTest, 1)\n127.0.0.1##+js(set, yabTest, 2)")
        let browser = TestBrowser(html: "")
        let controller = browser.webView.configuration.userContentController
        await blocker.attach(to: controller)
        browser.willNavigateMainFrame = { url in
            controller.removeAllUserScripts()
            blocker.scriptlets(forHostname: url.host() ?? "").forEach(controller.addUserScript)
        }

        for (host, expected) in [("localhost", "1"), ("127.0.0.1", "2"), ("localhost", "1")] {
            try await browser.load("http://\(host):\(server.port)/")
            #expect(try await browser.evaluate("return document.title") as? String == expected, "\(host)")
        }
    }
}

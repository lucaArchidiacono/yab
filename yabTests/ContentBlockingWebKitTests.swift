import Foundation
import Testing
import WebKit
@testable import yab

/// Runs converted rules through WebKit itself.
@MainActor
@Suite(.serialized)
struct ContentBlockingWebKitTests {
    let store: WKContentRuleListStore

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "yab-rule-lists-\(UUID().uuidString)")
        store = try #require(WKContentRuleListStore(url: directory))
    }

    /// WebKit rejects a whole list if a single rule is invalid, so the bundled lists must compile.
    @Test(.timeLimit(.minutes(5)))
    func bundledListsCompile() async throws {
        let library = try ScriptletLibrary(contentsOf: try #require(Bundle.main.url(forResource: "ubo-scriptlets", withExtension: "json")))
        var inputs: [FilterListConverter.Input] = []
        for list in FilterList.bundled {
            let url = try #require(Bundle.main.url(forResource: list.resourceName, withExtension: "txt"))
            inputs.append(.init(text: try String(contentsOf: url, encoding: .utf8), isTrusted: list.isTrusted))
        }

        let start = ContinuousClock.now
        let output = FilterListConverter(scriptletLibrary: library).convert(inputs)
        let ruleLists = output.ruleLists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let jsons = try ruleLists.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let converted = ContinuousClock.now
        print("[Bundled] \(output.report). Split into \(ruleLists.map(\.count)) rules. Converted in \(start.duration(to: converted)).")

        for (index, json) in jsons.enumerated() {
            // WebKit parses the JSON on the main thread before compiling in the background.
            let compileStart = ContinuousClock.now
            var mainThreadTime: Duration = .zero
            let ruleList: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
                store.compileContentRuleList(forIdentifier: "bundled-\(index)", encodedContentRuleList: json) { ruleList, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ruleList)
                    }
                }
                mainThreadTime = compileStart.duration(to: .now)
            }
            print("[Bundled] List \(index + 1): JSON \(json.utf8.count / 1024) KB, compiled in \(compileStart.duration(to: .now)), main thread blocked for \(mainThreadTime).")
            #expect(ruleList != nil)
        }

        #expect(ruleLists.allSatisfy { $0.count <= FilterListConverter.maximumRuleCount })
        #expect(output.report.scriptletFilterCount > 5_000)
        // Most filters should survive conversion.
        #expect(Double(output.report.skippedFilterCount) < Double(output.report.filterCount) * 0.1)
    }

    /// Badware and malicious site lists block navigation to a site, not just its requests.
    @Test(.timeLimit(.minutes(1)))
    func blocksNavigationToBlockedSites() async throws {
        let source = try FilterListSource(data: Data("# Title: Sites\nmalware.example".utf8), origin: .bundled, format: .blockedSites)
        let encoded = try await ContentBlocker.encodeRules(from: source.text)
        let ruleList: WKContentRuleList? = try await store.compileContentRuleList(forIdentifier: "sites", encodedContentRuleList: encoded.json)

        let browser = TestBrowser(html: "<html><body>Hello</body></html>")
        browser.webView.configuration.userContentController.add(try #require(ruleList))

        await #expect(throws: (any Error).self) {
            try await browser.load("yabtest://malware.example/index.html")
        }
        #expect(!browser.server.requestedURLs.contains("yabtest://malware.example/index.html"))

        try await browser.load("yabtest://fine.example/index.html")
        #expect(browser.server.requestedURLs.contains("yabtest://fine.example/index.html"))
    }

    @Test(.timeLimit(.minutes(1)))
    func blocksRequestsAndHidesElements() async throws {
        let filters = """
            ||ads.example^
            @@||ads.example/allowed.gif
            site.example##.site-ad
            ##.generic-ad
            other.example##.content
            """
        let encoded = try await ContentBlocker.encodeRules(from: filters)
        let ruleList: WKContentRuleList? = try await store.compileContentRuleList(forIdentifier: "behavior", encodedContentRuleList: encoded.json)

        let browser = TestBrowser(html: """
            <html><body>
            <div class="site-ad">Ad</div>
            <div class="generic-ad">Ad</div>
            <div class="content">Hello</div>
            <img src="yabtest://ads.example/banner.gif">
            <img src="yabtest://ads.example/allowed.gif">
            <img src="yabtest://cdn.example/logo.gif">
            </body></html>
            """)
        browser.webView.configuration.userContentController.add(try #require(ruleList))
        try await browser.load()

        #expect(browser.server.requestedURLs.contains("yabtest://cdn.example/logo.gif"))
        #expect(browser.server.requestedURLs.contains("yabtest://ads.example/allowed.gif"))
        #expect(!browser.server.requestedURLs.contains("yabtest://ads.example/banner.gif"))

        #expect(try await browser.display(of: ".site-ad") == "none")
        #expect(try await browser.display(of: ".generic-ad") == "none")
        #expect(try await browser.display(of: ".content") == "block")
    }
}

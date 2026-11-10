import Testing
@testable import yab

struct NetworkFilterTests {
    typealias Rule = ContentBlockerRule
    let anchor = URLFilterTranslator.domainAnchor
    let defaultTypes = NetworkFilterParser.defaultResourceTypes.sorted()

    func rules(_ text: String) -> [Rule] {
        FilterListConverter().convert(text).rules
    }

    func report(_ text: String) -> FilterListConverter.Report {
        FilterListConverter().convert(text).report
    }

    @Test func domainAnchorWithSeparator() {
        #expect(rules("||ads.example.com^") == [
            Rule(trigger: .init(urlFilter: anchor + #"ads\.example\.com[/:]"#, resourceType: defaultTypes), action: .block),
        ])
    }

    @Test(arguments: [
        ("/banner/*/img^", #"/banner/.*/img([^a-zA-Z0-9_.%-].*)?$"#),
        ("|https://example.com/ads|", #"^https://example\.com/ads$"#),
        ("&ad_type=*", #"&ad_type="#),
        ("*/ads/*", #"/ads/"#),
        ("||ads.example^*/track?", URLFilterTranslator.domainAnchor + #"ads\.example[/:].*/track\?"#),
        ("||cdn.example/a+b(c)", URLFilterTranslator.domainAnchor + #"cdn\.example/a\+b\(c\)"#),
    ])
    func patternTranslation(pattern: String, expected: String) {
        #expect(rules(pattern).first?.trigger.urlFilter == expected)
    }

    @Test func optionsBecomeTriggerConditions() {
        let rule = rules("||tracker.example^$third-party,script,domain=news.example|~shop.news.example").first
        #expect(rule?.trigger.loadType == [.thirdParty])
        #expect(rule?.trigger.resourceType == [.script])
        #expect(rule?.trigger.ifDomain == ["*news.example"])
        #expect(rule?.trigger.unlessDomain == nil)
    }

    @Test func excludedDomainsAloneBecomeUnlessDomain() {
        let rule = rules("||tracker.example^$domain=~news.example").first
        #expect(rule?.trigger.unlessDomain == ["*news.example"])
    }

    @Test func negatedResourceTypes() {
        let rule = rules("||cdn.example^$~image,~script").first
        #expect(rule?.trigger.resourceType == defaultTypes.filter { $0 != .image && $0 != .script })
    }

    @Test func defaultTypesUseRawShorthand() {
        #expect(rules("||cdn.example^").first?.trigger.resourceType?.contains(.raw) == true)
        #expect(rules("||cdn.example^$xhr,websocket,ping,other").first?.trigger.resourceType == [.raw])
    }

    @Test func excludingPartOfRawExpandsIt() {
        let types = rules("||cdn.example^$~xmlhttprequest").first?.trigger.resourceType ?? []
        #expect(!types.contains(.raw))
        #expect(!types.contains(.fetch))
        #expect(types.contains(.websocket) && types.contains(.ping) && types.contains(.other))
        #expect(types.contains(.script))
    }

    @Test func matchCase() {
        #expect(rules("/Banner.$match-case").first?.trigger.urlFilterIsCaseSensitive == true)
    }

    @Test func exceptionsComeAfterBlocks() {
        let output = rules("""
            @@||cdn.example^$script
            ||cdn.example^
            """)
        #expect(output.map(\.action.type) == [.block, .ignorePreviousRules])
        #expect(output.last?.trigger.resourceType == [.script])
    }

    @Test func importantBlocksOverrideExceptions() {
        let output = rules("""
            ||a.example^$important
            @@||a.example^
            ||b.example^
            """)
        #expect(output.map(\.action.type) == [.block, .ignorePreviousRules, .block])
        #expect(output.map(\.trigger.urlFilter) == [
            anchor + #"b\.example[/:]"#,
            anchor + #"a\.example[/:]"#,
            anchor + #"a\.example[/:]"#,
        ])
    }

    @Test func documentExceptionTurnsOffFilteringForSite() {
        let output = rules("""
            @@||example.com^$document
            ||ads.example^
            """)
        #expect(output.last == Rule(trigger: .init(urlFilter: ".*", ifDomain: ["*example.com"]), action: .ignorePreviousRules))
    }

    @Test func badfilterRemovesFilter() {
        let result = FilterListConverter().convert("""
            ||ads.example^$script,third-party
            ||ads.example^$third-party,script,badfilter
            ||other.example^
            """)
        #expect(result.rules.count == 1)
        #expect(result.report.skipped[.overridden] == 1)
    }

    @Test(arguments: [
        ("||ads.example^$redirect=noop.js", FilterSkipReason.unsupportedOption),
        ("||ads.example^$removeparam=utm_source", .unsupportedOption),
        ("||ads.example^$object", .unsupportedOption),
        ("/ads(foo|bar)/", .unsupportedRegex),
        (#"/ad\s+banner/"#, .unsupportedRegex),
        ("/a{2}/", .unsupportedRegex),
        ("||ads.example^$domain=google.*", .unsupportedDomain),
        ("*$third-party", .invalid),
    ])
    func unsupportedFiltersAreSkipped(filter: String, reason: FilterSkipReason) {
        let result = FilterListConverter().convert(filter)
        #expect(result.rules.isEmpty)
        #expect(result.report.skipped[reason] == 1)
    }

    @Test(arguments: [
        ("/ads[0-9]+\\.js/", #"ads[0-9]+\.js"#),
        (#"/\d+x\d+\.gif/"#, #"[0-9]+x[0-9]+\.gif"#),
        (#"/^https?:\/\/[a-z]+\.example\//"#, #"^https?:\/\/[a-z]+\.example\/"#),
        ("/track(?:ing)?\\.js$/", #"track(?:ing)?\.js$"#),
    ])
    func supportedRegexesPassThrough(filter: String, expected: String) {
        #expect(rules(filter).first?.trigger.urlFilter == expected)
    }

    @Test func preprocessorDirectives() {
        let output = rules("""
            !#if env_firefox
            ||firefox.example^
            !#else
            ||other.example^
            !#endif
            !#if env_safari && !env_mv3
            ||safari.example^
            !#endif
            """)
        #expect(output.map(\.trigger.urlFilter) == [
            anchor + #"other\.example[/:]"#,
            anchor + #"safari\.example[/:]"#,
        ])
    }

    @Test func exceptionsApplyAcrossLists() {
        let output = FilterListConverter().convert([
            .init(text: "||ads.example^", isTrusted: false),
            .init(text: "@@||ads.example/allowed.js", isTrusted: true),
        ])
        #expect(output.rules.map(\.action.type) == [.block, .ignorePreviousRules])
    }

    @Test func duplicatesAcrossListsAreRemoved() {
        let output = FilterListConverter().convert([
            .init(text: "||ads.example^", isTrusted: false),
            .init(text: "||ads.example^", isTrusted: true),
        ])
        #expect(output.rules.count == 1)
    }

    @Test func largeRuleSetsAreSplitWithExceptionsInEveryList() {
        let blocks = (1...5).map { "||ads\($0).example^" }.joined(separator: "\n")
        let output = FilterListConverter().convert(blocks + "\n@@||ads1.example/ok\n@@||ads2.example/ok")

        let lists = output.ruleLists(maximumRuleCount: 5)
        #expect(lists.map(\.count) == [5, 4])
        for list in lists {
            #expect(list.suffix(2).allSatisfy { $0.action.type == .ignorePreviousRules })
        }
        #expect(lists.joined().count(where: { $0.action.type == .block }) == 5)
    }

    @Test func commentsAndHeadersAreIgnored() {
        let result = report("""
            [Adblock Plus 2.0]
            ! Title: Test

            ||ads.example^
            """)
        #expect(result.filterCount == 1)
        #expect(result.ruleCount == 1)
    }
}

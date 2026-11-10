import Testing
@testable import yab

struct CosmeticFilterTests {
    typealias Rule = ContentBlockerRule

    func rules(_ text: String) -> [Rule] {
        FilterListConverter().convert(text).rules
    }

    @Test func genericHiding() {
        #expect(rules("##.ad-banner") == [
            Rule(trigger: .init(urlFilter: ".*"), action: .hide(".ad-banner")),
        ])
    }

    @Test func siteSpecificHiding() {
        #expect(rules("example.com,~shop.example.com##.promo") == [
            Rule(trigger: .init(urlFilter: ".*", ifDomain: ["*example.com"]), action: .hide(".promo")),
        ])
    }

    @Test func domainsAreLowercased() {
        #expect(rules("Example.COM##.x").first?.trigger.ifDomain == ["*example.com"])
    }

    @Test func genericHidingWithExcludedDomain() {
        #expect(rules("~example.com##.sponsored").first?.trigger.unlessDomain == ["*example.com"])
    }

    @Test func exceptionExcludesDomainFromGenericRule() {
        let output = rules("""
            ##.ad
            news.example#@#.ad
            """)
        #expect(output == [Rule(trigger: .init(urlFilter: ".*", unlessDomain: ["*news.example"]), action: .hide(".ad"))])
    }

    @Test func exceptionEverywhereRemovesRule() {
        let result = FilterListConverter().convert("""
            #@#.gone
            ##.gone
            example.com##.gone
            """)
        #expect(result.rules.isEmpty)
        #expect(result.report.skipped[.overridden] == 2)
    }

    @Test func abpHasBecomesNativeHas() {
        #expect(rules("example.com#?#div:-abp-has(> .ad)").first?.action == .hide("div:has(> .ad)"))
    }

    @Test(arguments: [
        ("example.com##div:has-text(Sponsored)", FilterSkipReason.proceduralCosmetic),
        ("example.com#?#div:-abp-contains(Ad)", .proceduralCosmetic),
        ("example.com##.ad:style(height: 0)", .proceduralCosmetic),
        ("example.com##+js(set-constant, x, 1)", .scriptlet),
        ("example.com##^script:has-text(ad)", .htmlFilter),
        ("example.com#$#.ad { display: none }", .unsupportedCosmetic),
        ("google.*##.ad", .unsupportedDomain),
    ])
    func unsupportedCosmeticFiltersAreSkipped(filter: String, reason: FilterSkipReason) {
        let result = FilterListConverter().convert(filter)
        #expect(result.rules.isEmpty)
        #expect(result.report.skipped[reason] == 1)
    }

    @Test func networkFilterWithHashIsNotCosmetic() {
        let rule = rules("||example.com/#ad").first
        #expect(rule?.action == .block)
    }

    @Test func cosmeticExceptionsAreOrderedAroundCosmeticRules() {
        let output = rules("""
            @@||example.com^$generichide
            ##.generic
            example.com##.specific
            @@||other.example^$elemhide
            """)
        #expect(output.map(\.action.type) == [.cssDisplayNone, .ignorePreviousRules, .cssDisplayNone, .ignorePreviousRules])
        #expect(output[1].trigger.resourceType == [.childDocument, .topDocument])
    }
}

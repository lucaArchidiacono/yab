import Foundation

/// Why a filter could not be turned into a WebKit rule or scriptlet.
nonisolated enum FilterSkipReason: String, Error, Sendable, CaseIterable {
    /// `##+js(...)` scriptlet injection, when converting without a scriptlet library.
    case scriptlet
    /// A scriptlet uBlock Origin's library does not have.
    case unknownScriptlet = "unknown-scriptlet"
    /// A powerful scriptlet used by a list we do not trust with it.
    case untrustedScriptlet = "untrusted-scriptlet"
    /// A powerful option, like `$urlskip`, used by a list we do not trust with it.
    case untrustedOption = "untrusted-option"
    /// `##^` HTML filtering.
    case htmlFilter = "html-filter"
    /// Cosmetic filters that need JavaScript, such as `:has-text()` or `:upward()`.
    case proceduralCosmetic = "procedural-cosmetic"
    /// Other cosmetic syntax such as CSS or JavaScript injection.
    case unsupportedCosmetic = "unsupported-cosmetic"
    /// Options WebKit cannot express, such as `$redirect` or `$removeparam`.
    case unsupportedOption = "unsupported-option"
    /// Regular expressions using features WebKit's URL filters lack.
    case unsupportedRegex = "unsupported-regex"
    /// Domain conditions WebKit cannot express, such as `google.*`.
    case unsupportedDomain = "unsupported-domain"
    case nonASCII = "non-ascii"
    /// Malformed, or so broad it would block everything.
    case invalid
    /// Disabled by a `$badfilter` or `#@#` exception filter.
    case overridden
}

/// Converts Adblock Plus / uBlock Origin filter lists into WebKit content blocker rules
/// and an index of scriptlets.
///
/// All lists are converted together, like uBlock Origin's single filtering engine, so an
/// exception in one list (say, uBlock filters – Unbreak) cancels a block from another
/// (say, EasyList).
///
/// WebKit's `ignore-previous-rules` cancels every earlier matching rule in the same list,
/// so rules are ordered:
/// generic cosmetic → `$generichide` exceptions → site-specific cosmetic →
/// `$elemhide` exceptions → blocks → exceptions → `$important` blocks → `$document` exceptions.
nonisolated struct FilterListConverter {
    /// Bump whenever the output changes, so cached compiled rule lists are rebuilt.
    static let version = 4

    /// WebKit refuses to compile lists with more rules than this.
    static let maximumRuleCount = 150_000

    struct Input: Sendable {
        var text: String
        /// Trusted lists, like uBlock Origin's own, may use scriptlets that require trust.
        var isTrusted: Bool
    }

    struct Output: Sendable {
        var scriptlets: ScriptletIndex
        var redirectSkips: RedirectSkipIndex
        var report: Report
        fileprivate var sections: Sections

        /// All rules as one list.
        var rules: [ContentBlockerRule] {
            sections.assembled(generic: sections.genericHiding, specific: sections.specificHiding, blocks: sections.blocks, important: sections.importantBlocks)
        }

        /// The rules split into lists WebKit accepts. Exceptions only cancel rules in their
        /// own list, so every list repeats all exceptions.
        func ruleLists(maximumRuleCount: Int = FilterListConverter.maximumRuleCount) -> [[ContentBlockerRule]] {
            sections.split(maximumRuleCount: maximumRuleCount)
        }
    }

    struct Report: Sendable, CustomStringConvertible {
        var filterCount = 0
        var ruleCount = 0
        var scriptletFilterCount = 0
        var redirectSkipFilterCount = 0
        var skipped: [FilterSkipReason: Int] = [:]

        var skippedFilterCount: Int { skipped.values.reduce(0, +) }

        var description: String {
            let reasons = skipped
                .sorted { $0.value > $1.value }
                .map { "\($0.key.rawValue): \($0.value)" }
                .joined(separator: ", ")
            var text = "\(filterCount) filters → \(ruleCount) rules, \(scriptletFilterCount) scriptlet filters and \(redirectSkipFilterCount) redirect skips, \(skippedFilterCount) skipped"
            if !reasons.isEmpty { text += " (\(reasons))" }
            return text
        }
    }

    /// Without a library, scriptlet filters are skipped.
    var scriptletLibrary: ScriptletLibrary?

    init(scriptletLibrary: ScriptletLibrary? = nil) {
        self.scriptletLibrary = scriptletLibrary
    }

    func convert(_ text: String, isTrusted: Bool = false) -> Output {
        convert([Input(text: text, isTrusted: isTrusted)])
    }

    func convert(_ inputs: [Input]) -> Output {
        var collector = Collector(scriptletLibrary: scriptletLibrary)

        for input in inputs {
            var preprocessor = Preprocessor()
            for rawLine in input.text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingWhitespace()
                if line.isEmpty || line.hasPrefix("[") { continue }
                if line.hasPrefix("!") {
                    if line.hasPrefix("!#") { preprocessor.handle(line) }
                    continue
                }
                guard preprocessor.isActive else { continue }

                collector.report.filterCount += 1
                if let cosmetic = CosmeticFilterParser.split(line) {
                    collector.addCosmetic(cosmetic, isTrusted: input.isTrusted)
                } else {
                    collector.addNetwork(line, isTrusted: input.isTrusted)
                }
            }
        }

        return collector.finish()
    }
}

// MARK: - Rule sections

/// Rules grouped by their place in the WebKit order.
nonisolated struct Sections: Sendable {
    var genericHiding: [ContentBlockerRule] = []
    var generichideExceptions: [ContentBlockerRule] = []
    var specificHiding: [ContentBlockerRule] = []
    var elemhideExceptions: [ContentBlockerRule] = []
    var blocks: [ContentBlockerRule] = []
    var exceptions: [ContentBlockerRule] = []
    var importantBlocks: [ContentBlockerRule] = []
    var documentExceptions: [ContentBlockerRule] = []

    var count: Int {
        genericHiding.count + generichideExceptions.count + specificHiding.count + elemhideExceptions.count
            + blocks.count + exceptions.count + importantBlocks.count + documentExceptions.count
    }

    /// One list in WebKit order, with every exception and the given share of the other rules.
    func assembled(
        generic: some Collection<ContentBlockerRule>,
        specific: some Collection<ContentBlockerRule>,
        blocks: some Collection<ContentBlockerRule>,
        important: some Collection<ContentBlockerRule>
    ) -> [ContentBlockerRule] {
        var rules: [ContentBlockerRule] = []
        rules += generic
        rules += generichideExceptions
        rules += specific
        rules += elemhideExceptions
        rules += blocks
        rules += exceptions
        rules += important
        rules += documentExceptions
        return rules
    }

    /// Splits the rules into as few lists as fit, of similar size.
    func split(maximumRuleCount: Int) -> [[ContentBlockerRule]] {
        let exceptionCount = generichideExceptions.count + elemhideExceptions.count + exceptions.count + documentExceptions.count
        let splittable = [genericHiding, specificHiding, blocks, importantBlocks]
        let splittableCount = splittable.reduce(0) { $0 + $1.count }
        guard splittableCount + exceptionCount > 0 else { return [] }

        let capacity = maximumRuleCount - exceptionCount
        precondition(capacity > 0, "Exceptions alone exceed WebKit's rule limit")
        let listCount = max(1, (splittableCount + capacity - 1) / capacity)
        let perList = (splittableCount + listCount - 1) / listCount

        // Walk through the splittable rules in order, giving each list the next `perList`.
        var lists: [[ContentBlockerRule]] = []
        var section = 0
        var offset = 0
        for _ in 0..<listCount {
            var shares: [[ContentBlockerRule]] = [[], [], [], []]
            var remaining = perList
            while remaining > 0, section < splittable.count {
                let rules = splittable[section]
                let taken = min(remaining, rules.count - offset)
                shares[section] += rules[offset..<(offset + taken)]
                remaining -= taken
                offset += taken
                if offset == rules.count {
                    section += 1
                    offset = 0
                }
            }
            lists.append(assembled(generic: shares[0], specific: shares[1], blocks: shares[2], important: shares[3]))
        }
        return lists
    }
}

// MARK: - Collecting rules in WebKit order

private nonisolated struct Collector {
    var report = FilterListConverter.Report()
    let scriptletLibrary: ScriptletLibrary?

    private var genericCosmetic: [CosmeticFilterParser.Filter] = []
    private var specificCosmetic: [CosmeticFilterParser.Filter] = []
    private var cosmeticExceptions: [String: CosmeticException] = [:]
    private var scriptlets = ScriptletIndex.Builder()
    private var redirectSkips = RedirectSkipIndex()

    private var buckets: [NetworkFilterParser.Bucket: [(key: String, rule: ContentBlockerRule)]] = [:]
    private var badfilterKeys: Set<String> = []

    private struct CosmeticException {
        var everywhere = false
        var domains: Set<String> = []
    }

    init(scriptletLibrary: ScriptletLibrary?) {
        self.scriptletLibrary = scriptletLibrary
    }

    mutating func addCosmetic(_ split: CosmeticFilterParser.Split, isTrusted: Bool) {
        if split.body.trimmingWhitespace().hasPrefix("+js("), split.separator == .hide || split.separator == .hideException {
            addScriptlet(split, isTrusted: isTrusted)
            return
        }
        switch CosmeticFilterParser.parse(split) {
        case .failure(let reason):
            skip(reason)
        case .success(let filter) where filter.isException:
            var exception = cosmeticExceptions[filter.selector, default: CosmeticException()]
            if filter.domains.includes.isEmpty {
                exception.everywhere = true
            } else {
                exception.domains.formUnion(filter.domains.includes)
            }
            cosmeticExceptions[filter.selector] = exception
        case .success(let filter) where filter.domains.includes.isEmpty:
            genericCosmetic.append(filter)
        case .success(let filter):
            specificCosmetic.append(filter)
        }
    }

    private mutating func addScriptlet(_ split: CosmeticFilterParser.Split, isTrusted: Bool) {
        guard let scriptletLibrary else {
            skip(.scriptlet)
            return
        }
        let result = ScriptletFilterParser.parse(
            domains: split.domains,
            body: split.body,
            isException: split.separator == .hideException,
            isTrusted: isTrusted,
            library: scriptletLibrary
        )
        switch result {
        case .failure(let reason):
            skip(reason)
        case .success(let filter):
            scriptlets.add(filter)
            report.scriptletFilterCount += 1
        }
    }

    mutating func addNetwork(_ line: Substring, isTrusted: Bool) {
        switch NetworkFilterParser.parse(line) {
        case .failure(let reason):
            skip(reason)
        case .success(let filter) where filter.isBadfilter:
            badfilterKeys.insert(filter.key)
        case .success(let filter) where filter.redirectSkip != nil:
            // Like uBlock Origin, only trusted lists may send people elsewhere.
            guard isTrusted, let skip = filter.redirectSkip else {
                self.skip(.untrustedOption)
                return
            }
            if skip.isException {
                redirectSkips.exceptions.append(skip.rule)
            } else {
                redirectSkips.skips.append(skip.rule)
            }
            report.redirectSkipFilterCount += 1
        case .success(let filter):
            for (bucket, rule) in filter.rules {
                buckets[bucket, default: []].append((filter.key, rule))
            }
        }
    }

    mutating func finish() -> FilterListConverter.Output {
        var sections = Sections()

        for filter in genericCosmetic {
            let exception = cosmeticExceptions[filter.selector]
            if exception?.everywhere == true {
                skip(.overridden)
                continue
            }
            let unless = Set(filter.domains.excludes).union(exception?.domains ?? [])
            sections.genericHiding.append(ContentBlockerRule(
                trigger: .init(urlFilter: ".*", unlessDomain: unless.isEmpty ? nil : unless.sorted().map { "*" + $0 }),
                action: .hide(filter.selector)
            ))
        }

        for filter in specificCosmetic {
            let exception = cosmeticExceptions[filter.selector]
            let domains = filter.domains.includes.filter { !(exception?.domains.contains($0) ?? false) }
            if exception?.everywhere == true || domains.isEmpty {
                skip(.overridden)
                continue
            }
            sections.specificHiding.append(ContentBlockerRule(
                trigger: .init(urlFilter: ".*", ifDomain: domains.map { "*" + $0 }),
                action: .hide(filter.selector)
            ))
        }

        let overriddenCount = buckets.values.joined().count(where: { badfilterKeys.contains($0.key) })
        if overriddenCount > 0 { report.skipped[.overridden, default: 0] += overriddenCount }

        func rules(in bucket: NetworkFilterParser.Bucket) -> [ContentBlockerRule] {
            buckets[bucket, default: []].compactMap { entry in
                badfilterKeys.contains(entry.key) ? nil : entry.rule
            }
        }
        sections.generichideExceptions = rules(in: .generichideException)
        sections.elemhideExceptions = rules(in: .elemhideException)
        sections.blocks = rules(in: .block)
        sections.exceptions = rules(in: .exception)
        sections.importantBlocks = rules(in: .importantBlock)
        sections.documentExceptions = rules(in: .documentException)

        // Lists overlap, and WebKit gains nothing from the same rule twice in a section.
        // (Across sections a repeat matters: an `$important` block must stay after exceptions.)
        func unique(_ rules: [ContentBlockerRule]) -> [ContentBlockerRule] {
            var seen = Set<ContentBlockerRule>()
            return rules.filter { seen.insert($0).inserted }
        }
        sections.genericHiding = unique(sections.genericHiding)
        sections.generichideExceptions = unique(sections.generichideExceptions)
        sections.specificHiding = unique(sections.specificHiding)
        sections.elemhideExceptions = unique(sections.elemhideExceptions)
        sections.blocks = unique(sections.blocks)
        sections.exceptions = unique(sections.exceptions)
        sections.importantBlocks = unique(sections.importantBlocks)
        sections.documentExceptions = unique(sections.documentExceptions)

        report.ruleCount = sections.count
        return FilterListConverter.Output(scriptlets: scriptlets.build(), redirectSkips: redirectSkips, report: report, sections: sections)
    }

    private mutating func skip(_ reason: FilterSkipReason) {
        report.skipped[reason, default: 0] += 1
    }
}

// MARK: - `!#if` preprocessor directives

/// Evaluates uBlock Origin's `!#if` / `!#else` / `!#endif` directives.
nonisolated struct Preprocessor {
    /// Conditions that are true for yab. Everything else, like `env_firefox`, is false.
    static let trueConditions: Set<String> = ["ext_ublock", "env_safari", "env_mobile", "cap_user_stylesheet"]

    private struct Block {
        var parentIsActive: Bool
        var condition: Bool
        var isActive: Bool
    }

    private var blocks: [Block] = []

    var isActive: Bool { blocks.last?.isActive ?? true }

    mutating func handle(_ line: Substring) {
        if line.hasPrefix("!#if ") {
            let condition = Self.evaluate(line.dropFirst(5))
            blocks.append(Block(parentIsActive: isActive, condition: condition, isActive: isActive && condition))
        } else if line.hasPrefix("!#else"), var block = blocks.popLast() {
            block.isActive = block.parentIsActive && !block.condition
            blocks.append(block)
        } else if line.hasPrefix("!#endif") {
            _ = blocks.popLast()
        }
    }

    /// Evaluates expressions like `env_safari && !(env_mv3 || ext_ubol)`.
    static func evaluate(_ expression: Substring) -> Bool {
        var parser = ExpressionParser(tokens: tokenize(expression))
        return parser.parseOr()
    }

    private static func tokenize(_ expression: Substring) -> [String] {
        var tokens: [String] = []
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if character.isWhitespace {
                index = expression.index(after: index)
            } else if character == "!" || character == "(" || character == ")" {
                tokens.append(String(character))
                index = expression.index(after: index)
            } else if character == "&" || character == "|" {
                let next = expression.index(after: index)
                let end = next < expression.endIndex && expression[next] == character ? expression.index(after: next) : next
                tokens.append(String(expression[index..<end]))
                index = end
            } else {
                let end = expression[index...].firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? expression.endIndex
                if end == index {
                    tokens.append(String(character))
                    index = expression.index(after: index)
                } else {
                    tokens.append(String(expression[index..<end]))
                    index = end
                }
            }
        }
        return tokens
    }

    private struct ExpressionParser {
        let tokens: [String]
        var position = 0

        mutating func parseOr() -> Bool {
            var value = parseAnd()
            while peek() == "||" {
                position += 1
                let rhs = parseAnd()
                value = value || rhs
            }
            return value
        }

        mutating func parseAnd() -> Bool {
            var value = parseUnary()
            while peek() == "&&" {
                position += 1
                let rhs = parseUnary()
                value = value && rhs
            }
            return value
        }

        mutating func parseUnary() -> Bool {
            guard let token = peek() else { return false }
            position += 1
            switch token {
            case "!":
                return !parseUnary()
            case "(":
                let value = parseOr()
                if peek() == ")" { position += 1 }
                return value
            default:
                return Preprocessor.trueConditions.contains(token)
            }
        }

        func peek() -> String? {
            position < tokens.count ? tokens[position] : nil
        }
    }
}

// MARK: - Helpers

nonisolated extension Substring {
    func trimmingWhitespace() -> Substring {
        guard let start = firstIndex(where: { !$0.isWhitespace }) else { return self[endIndex...] }
        let end = lastIndex(where: { !$0.isWhitespace })!
        return self[start...end]
    }
}

/// A parsed `domain=a.com|~b.com` option or `a.com,~b.com##` cosmetic prefix.
nonisolated struct DomainList: Sendable {
    var includes: [String] = []
    var excludes: [String] = []
    /// True when an included domain was dropped because WebKit cannot express it.
    var droppedIncludes = false

    static func parse(_ text: Substring, separator: Character) -> DomainList {
        var list = DomainList()
        for rawEntry in text.split(separator: separator) {
            var entry = rawEntry.trimmingWhitespace()
            let isExcluded = entry.hasPrefix("~")
            if isExcluded { entry = entry.dropFirst() }
            if entry.hasPrefix("*.") { entry = entry.dropFirst(2) }

            // WebKit wants lowercase ASCII (punycode). Entities like `google.*` and
            // regular-expression domains cannot be expressed.
            let domain = entry.lowercased()
            let isValid = !domain.isEmpty && domain.utf8.allSatisfy { byte in
                (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || byte == 0x2D || byte == 0x5F
            }
            guard isValid else {
                if !isExcluded { list.droppedIncludes = true }
                continue
            }
            if isExcluded {
                list.excludes.append(domain)
            } else {
                list.includes.append(domain)
            }
        }
        return list
    }
}

import Foundation

/// Parses network filters such as `||ads.example.com^$third-party` into WebKit rules.
nonisolated enum NetworkFilterParser {
    typealias ResourceType = ContentBlockerRule.ResourceType

    /// Where a rule goes in the output. See `FilterListConverter` for the order.
    enum Bucket: Hashable {
        case generichideException
        case elemhideException
        case block
        case exception
        case importantBlock
        case documentException
    }

    struct Filter {
        /// Identifies the filter for `$badfilter`: the pattern plus its sorted options.
        var key: String
        var isBadfilter: Bool
        var rules: [(Bucket, ContentBlockerRule)]
        /// A `$urlskip` filter, which yab applies itself instead of WebKit.
        var redirectSkip: RedirectSkip?
    }

    /// `||tracker.example/out?$doc,urlskip=?url`: where a tracking link really goes.
    struct RedirectSkip {
        var rule: RedirectSkipIndex.Rule
        var isException: Bool
    }

    /// What a filter applies to when it names no resource types. Like Adblock Plus,
    /// this excludes top-level pages and popups.
    static let defaultResourceTypes: Set<ResourceType> = [
        .childDocument, .image, .styleSheet, .script, .font, .media, .svgDocument, .raw,
    ]

    /// The types WebKit's `raw` stands for.
    private static let rawTypes: Set<ResourceType> = [.fetch, .websocket, .ping, .other]

    /// Applies `~type` exclusions and writes the result as compactly as possible.
    /// Every rule repeats its types, so this keeps the JSON WebKit parses small.
    static func resolveTypes(included: Set<ResourceType>, excluded: Set<ResourceType>) -> Set<ResourceType> {
        var types = included.isEmpty ? defaultResourceTypes : included
        if types.contains(.raw), !excluded.isDisjoint(with: rawTypes) {
            types.remove(.raw)
            types.formUnion(rawTypes)
        }
        types.subtract(excluded)
        if types.isSuperset(of: rawTypes) {
            types.subtract(rawTypes)
            types.insert(.raw)
        }
        return types
    }

    private static let resourceTypeOptions: [String: ResourceType] = [
        "script": .script,
        "image": .image,
        "stylesheet": .styleSheet,
        "css": .styleSheet,
        "font": .font,
        "media": .media,
        "xmlhttprequest": .fetch,
        "xhr": .fetch,
        "subdocument": .childDocument,
        "frame": .childDocument,
        "ping": .ping,
        "beacon": .ping,
        "websocket": .websocket,
        "other": .other,
        "popup": .popup,
        "document": .topDocument,
        "doc": .topDocument,
    ]

    /// Resource types WebKit has no equivalent for.
    private static let unsupportedResourceTypes: Set<String> = [
        "object", "object-subrequest", "webrtc", "popunder", "inline-script", "inline-font",
    ]

    private struct Options {
        var loadType: ContentBlockerRule.LoadType?
        var isCaseSensitive = false
        var isImportant = false
        var isBadfilter = false
        var domains = DomainList()
        var includedTypes: Set<ResourceType> = []
        var excludedTypes: Set<ResourceType> = []
        var namesUnsupportedType = false
        var elemhide = false
        var generichide = false
        /// The steps of `$urlskip=…`, or empty for `@@…$urlskip`.
        var urlskip: String?
        var normalized: [String] = []
    }

    static func parse(_ line: Substring) -> Result<Filter, FilterSkipReason> {
        var body = line
        let isException = body.hasPrefix("@@")
        if isException { body = body.dropFirst(2) }

        var pattern = body
        var optionsText: Substring = ""
        if let dollar = body.lastIndex(of: "$") {
            let next = body.index(after: dollar)
            if next < body.endIndex, body[next] == "~" || body[next].isLetter || body[next].isNumber {
                pattern = body[..<dollar]
                optionsText = body[next...]
            }
        }

        let options: Options
        switch parseOptions(optionsText) {
        case .success(let parsed): options = parsed
        case .failure(let reason): return .failure(reason)
        }

        let key = (isException ? "@@" : "") + pattern + "$" + options.normalized.sorted().joined(separator: ",")
        if options.isBadfilter {
            return .success(Filter(key: key, isBadfilter: true, rules: []))
        }

        if options.domains.includes.isEmpty, options.domains.droppedIncludes {
            return .failure(.unsupportedDomain)
        }

        let urlFilter: String
        switch URLFilterTranslator.translate(pattern) {
        case .success(let translated): urlFilter = translated
        case .failure(let reason): return .failure(reason)
        }

        if let steps = options.urlskip {
            // yab skips redirects of pages being opened, the case these filters are written for.
            let onlyOtherTypes = !options.includedTypes.isEmpty && !options.includedTypes.contains(.topDocument)
            guard !onlyOtherTypes, options.domains.includes.isEmpty, options.domains.excludes.isEmpty else {
                return .failure(.unsupportedOption)
            }
            let rule = RedirectSkipIndex.Rule(
                urlFilter: urlFilter,
                isCaseSensitive: options.isCaseSensitive,
                steps: steps.split(separator: " ").map(String.init)
            )
            guard isException || !rule.steps.isEmpty else { return .failure(.invalid) }
            return .success(Filter(key: key, isBadfilter: false, rules: [], redirectSkip: RedirectSkip(rule: rule, isException: isException)))
        }

        var includedDomains: [String]?
        var excludedDomains: [String]?
        if !options.domains.includes.isEmpty {
            // WebKit allows only one domain condition per rule, so exclusions next to
            // inclusions (`domain=a.com|~b.a.com`) are dropped.
            includedDomains = options.domains.includes.map { "*" + $0 }
        } else if !options.domains.excludes.isEmpty {
            excludedDomains = options.domains.excludes.map { "*" + $0 }
        }

        func trigger(urlFilter: String, types: Set<ResourceType>?) -> ContentBlockerRule.Trigger {
            ContentBlockerRule.Trigger(
                urlFilter: urlFilter,
                urlFilterIsCaseSensitive: options.isCaseSensitive ? true : nil,
                resourceType: types.map { $0.sorted() },
                loadType: options.loadType.map { [$0] },
                ifDomain: includedDomains,
                unlessDomain: excludedDomains
            )
        }

        let types = resolveTypes(included: options.includedTypes, excluded: options.excludedTypes)

        var rules: [(Bucket, ContentBlockerRule)] = []

        if isException {
            if options.includedTypes.contains(.topDocument) {
                // `@@||example.com^$document` turns off all filtering on matching pages.
                guard options.domains.includes.isEmpty, options.domains.excludes.isEmpty else {
                    return .failure(.unsupportedOption)
                }
                let pageTrigger: ContentBlockerRule.Trigger
                if let domain = URLFilterTranslator.plainDomain(of: pattern) {
                    pageTrigger = .init(urlFilter: ".*", ifDomain: ["*" + domain])
                } else {
                    pageTrigger = .init(urlFilter: ".*", ifTopURL: [urlFilter])
                }
                return .success(Filter(key: key, isBadfilter: false, rules: [(.documentException, ContentBlockerRule(trigger: pageTrigger, action: .ignorePreviousRules))]))
            }

            let pageTypes: Set<ResourceType> = [.topDocument, .childDocument]
            if options.elemhide {
                rules.append((.elemhideException, ContentBlockerRule(trigger: trigger(urlFilter: urlFilter, types: pageTypes), action: .ignorePreviousRules)))
            } else if options.generichide {
                rules.append((.generichideException, ContentBlockerRule(trigger: trigger(urlFilter: urlFilter, types: pageTypes), action: .ignorePreviousRules)))
            }
            let isCosmeticOnly = (options.elemhide || options.generichide) && options.includedTypes.isEmpty
            if !isCosmeticOnly {
                if types.isEmpty { return .failure(options.namesUnsupportedType ? .unsupportedOption : .invalid) }
                rules.append((.exception, ContentBlockerRule(trigger: trigger(urlFilter: urlFilter, types: types), action: .ignorePreviousRules)))
            }
        } else {
            if options.elemhide || options.generichide { return .failure(.invalid) }
            if options.includedTypes.isEmpty, options.namesUnsupportedType { return .failure(.unsupportedOption) }
            if types.isEmpty { return .failure(.invalid) }
            // Never block every request everywhere because of a stray `*` or empty pattern.
            if urlFilter == ".*", includedDomains == nil { return .failure(.invalid) }
            let bucket: Bucket = options.isImportant ? .importantBlock : .block
            rules.append((bucket, ContentBlockerRule(trigger: trigger(urlFilter: urlFilter, types: types), action: .block)))
        }

        return .success(Filter(key: key, isBadfilter: false, rules: rules))
    }

    private static func parseOptions(_ text: Substring) -> Result<Options, FilterSkipReason> {
        var options = Options()
        guard !text.isEmpty else { return .success(options) }

        for rawOption in text.split(separator: ",") {
            var option = rawOption.trimmingWhitespace()
            let isNegated = option.hasPrefix("~")
            if isNegated { option = option.dropFirst() }

            let name: String
            var value: Substring?
            if let equals = option.firstIndex(of: "=") {
                name = option[..<equals].lowercased()
                value = option[option.index(after: equals)...]
            } else {
                name = option.lowercased()
            }

            if name != "badfilter" {
                options.normalized.append(String(rawOption))
            }

            switch name {
            case "third-party", "3p":
                options.loadType = isNegated ? .firstParty : .thirdParty
            case "first-party", "1p":
                options.loadType = isNegated ? .thirdParty : .firstParty
            case "match-case":
                options.isCaseSensitive = !isNegated
            case "important":
                options.isImportant = true
            case "badfilter":
                options.isBadfilter = true
            case "domain", "from":
                guard let value, !isNegated else { return .failure(.unsupportedOption) }
                options.domains = DomainList.parse(value, separator: "|")
            case "elemhide", "ehide":
                options.elemhide = true
            case "generichide", "ghide":
                options.generichide = true
            case "all":
                options.includedTypes.formUnion(ResourceType.allCases)
            case "urlskip":
                options.urlskip = value.map(String.init) ?? ""
            default:
                if let type = resourceTypeOptions[name] {
                    if isNegated {
                        options.excludedTypes.insert(type)
                    } else {
                        options.includedTypes.insert(type)
                    }
                } else if unsupportedResourceTypes.contains(name) {
                    if !isNegated { options.namesUnsupportedType = true }
                } else {
                    // $redirect, $removeparam, $csp, $header, ... need more than WebKit offers.
                    return .failure(.unsupportedOption)
                }
            }
        }
        return .success(options)
    }
}

/// Translates Adblock Plus URL patterns into the regular expression subset WebKit accepts:
/// no `|` alternation, no `{n}` counts, no `\d`-style classes, `^` only at the start
/// and `$` only at the end, ASCII only. Matching is case-insensitive by default.
nonisolated enum URLFilterTranslator {
    /// What `||` turns into: any scheme, then optionally any subdomains.
    static let domainAnchor = #"^[a-z][a-z0-9+.-]*://([^/]*\.)?"#

    /// What `^` turns into: one character that cannot be part of a URL token.
    static let separator = "[^a-zA-Z0-9_.%-]"

    private static let specialCharacters: Set<Character> = ["\\", ".", "+", "?", "(", ")", "[", "]", "{", "}", "$", "|"]

    static func translate(_ pattern: Substring) -> Result<String, FilterSkipReason> {
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            return translateRegex(pattern.dropFirst().dropLast())
        }
        guard pattern.allSatisfy(\.isASCII) else { return .failure(.nonASCII) }

        var source = pattern
        var output = ""
        // True while we are still inside the host name after `||`.
        var inHost = false

        if source.hasPrefix("||") {
            source = source.dropFirst(2)
            output = domainAnchor
            inHost = true
        } else if source.hasPrefix("|") {
            source = source.dropFirst()
            output = "^"
        }

        var anchoredEnd = false
        if source.hasSuffix("|") {
            source = source.dropLast()
            anchoredEnd = true
        }

        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            let isLast = source.index(after: index) == source.endIndex

            switch character {
            case "*":
                if !output.hasSuffix(".*") || output.hasSuffix("\\.*") { output += ".*" }
                inHost = false
            case "^":
                if inHost {
                    // A host name is always followed by a port or a path.
                    output += "[/:]"
                } else if isLast {
                    // `^` also matches the end of the URL.
                    output += anchoredEnd ? separator + "?" : "(\(separator).*)?$"
                } else {
                    output += separator
                }
                inHost = false
            default:
                if specialCharacters.contains(character) {
                    output.append("\\")
                }
                output.append(character)
                if inHost, !(character.isLetter || character.isNumber || character == "." || character == "-" || character == "_") {
                    inHost = false
                }
            }
            index = source.index(after: index)
        }

        if anchoredEnd, !output.hasSuffix("$") {
            output += "$"
        }
        // URL filters are unanchored, so leading and trailing wildcards are redundant.
        if output.hasPrefix(".*") {
            output.removeFirst(2)
        }
        if output.hasSuffix(".*"), !output.hasSuffix("\\.*") {
            output.removeLast(2)
        }
        return .success(output.isEmpty ? ".*" : output)
    }

    /// The domain in `||example.com^` or `||example.com`, if the pattern is nothing more.
    static func plainDomain(of pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var domain = pattern.dropFirst(2)
        if domain.hasSuffix("^") || domain.hasSuffix("/") { domain = domain.dropLast() }
        let lowercased = domain.lowercased()
        let isPlain = !lowercased.isEmpty && lowercased.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || byte == 0x2D
        }
        return isPlain ? lowercased : nil
    }

    /// Passes `/regex/` filters through when WebKit can handle them.
    private static func translateRegex(_ regex: Substring) -> Result<String, FilterSkipReason> {
        guard regex.allSatisfy(\.isASCII) else { return .failure(.nonASCII) }

        var output = ""
        var inClass = false
        var index = regex.startIndex

        while index < regex.endIndex {
            let character = regex[index]
            let next = regex.index(after: index)

            switch character {
            case "\\":
                guard next < regex.endIndex else { return .failure(.unsupportedRegex) }
                let escaped = regex[next]
                switch escaped {
                case "d":
                    output += inClass ? "0-9" : "[0-9]"
                case "w":
                    output += inClass ? "a-zA-Z0-9_" : "[a-zA-Z0-9_]"
                case _ where escaped.isLetter || escaped.isNumber:
                    // \s, \b, \D, \x41, A, back references, ...
                    return .failure(.unsupportedRegex)
                default:
                    output.append(character)
                    output.append(escaped)
                }
                index = regex.index(after: next)
                continue
            case "[" where !inClass:
                inClass = true
            case "]" where inClass:
                inClass = false
            case "|" where !inClass, "{" where !inClass:
                return .failure(.unsupportedRegex)
            case "(" where !inClass:
                if next < regex.endIndex, regex[next] == "?" {
                    // Only non-capturing groups; no lookarounds.
                    let afterQuestionMark = regex.index(after: next)
                    guard afterQuestionMark < regex.endIndex, regex[afterQuestionMark] == ":" else {
                        return .failure(.unsupportedRegex)
                    }
                }
            case "^" where !inClass:
                if index != regex.startIndex { return .failure(.unsupportedRegex) }
            case "$" where !inClass:
                if next != regex.endIndex { return .failure(.unsupportedRegex) }
            default:
                break
            }
            output.append(character)
            index = next
        }

        return inClass || output.isEmpty ? .failure(.unsupportedRegex) : .success(output)
    }
}

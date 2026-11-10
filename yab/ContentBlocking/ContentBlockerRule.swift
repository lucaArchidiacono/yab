import Foundation

/// One rule in WebKit's content blocker JSON format.
///
/// See WebKit's `ContentExtensionParser.cpp` for the accepted keys. Only one of
/// `if-domain`, `unless-domain` and `if-top-url` may be set on a trigger.
nonisolated struct ContentBlockerRule: Encodable, Hashable, Sendable {
    var trigger: Trigger
    var action: Action

    struct Trigger: Encodable, Hashable, Sendable {
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        var resourceType: [ResourceType]?
        var loadType: [LoadType]?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var ifTopURL: [String]?

        init(
            urlFilter: String,
            urlFilterIsCaseSensitive: Bool? = nil,
            resourceType: [ResourceType]? = nil,
            loadType: [LoadType]? = nil,
            ifDomain: [String]? = nil,
            unlessDomain: [String]? = nil,
            ifTopURL: [String]? = nil
        ) {
            self.urlFilter = urlFilter
            self.urlFilterIsCaseSensitive = urlFilterIsCaseSensitive
            self.resourceType = resourceType
            self.loadType = loadType
            self.ifDomain = ifDomain
            self.unlessDomain = unlessDomain
            self.ifTopURL = ifTopURL
        }

        private enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case ifTopURL = "if-top-url"
        }
    }

    struct Action: Encodable, Hashable, Sendable {
        var type: ActionType
        var selector: String?

        static let block = Action(type: .block)
        static let ignorePreviousRules = Action(type: .ignorePreviousRules)

        static func hide(_ selector: String) -> Action {
            Action(type: .cssDisplayNone, selector: selector)
        }
    }

    enum ActionType: String, Encodable, Sendable {
        case block
        case cssDisplayNone = "css-display-none"
        case ignorePreviousRules = "ignore-previous-rules"
    }

    enum ResourceType: String, Encodable, Sendable, CaseIterable, Comparable {
        case topDocument = "top-document"
        case childDocument = "child-document"
        case image
        case styleSheet = "style-sheet"
        case script
        case font
        case media
        case svgDocument = "svg-document"
        case fetch
        case websocket
        case ping
        case other
        /// Shorthand for `fetch`, `websocket`, `ping` and `other`.
        case raw
        case popup

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum LoadType: String, Encodable, Sendable {
        case firstParty = "first-party"
        case thirdParty = "third-party"
    }
}

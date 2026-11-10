import Foundation

/// uBlock Origin's scriptlets, as extracted by `Scripts/generate-scriptlets.mjs`.
///
/// A scriptlet is a small function that runs inside a page before the page's own scripts,
/// to defuse anti-adblock checks, trackers and the like.
nonisolated struct ScriptletLibrary: Sendable {
    enum World: String, Decodable, Sendable {
        /// The page's own JavaScript world, so scriptlets can patch what the page sees.
        case main = "MAIN"
        /// A separate world that only shares the DOM with the page.
        case isolated = "ISOLATED"
    }

    struct Resource: Decodable, Sendable {
        /// `set-constant.js` for scriptlets, `safe-self.fn` for helpers.
        var name: String
        var aliases: [String]
        /// The name `code` declares.
        var function: String
        var dependencies: [String]
        var world: World
        /// Only lists we trust may use these, as they can do almost anything to a page.
        var requiresTrust: Bool
        /// A function or class declaration.
        var code: String
    }

    private struct File: Decodable {
        var source: String
        var resources: [Resource]
    }

    /// For example `uBlock Origin 1.76.0`.
    let source: String
    private let resources: [String: Resource]
    private let aliases: [String: String]

    init(source: String, resources: [Resource]) {
        self.source = source
        self.resources = Dictionary(resources.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var aliases: [String: String] = [:]
        for resource in resources {
            for alias in resource.aliases { aliases[alias] = resource.name }
        }
        self.aliases = aliases
    }

    init(contentsOf url: URL) throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        self.init(source: file.source, resources: file.resources)
    }

    /// The scriptlet a filter names, as in `set`, `set.js` or `set-constant.js`.
    func scriptlet(named token: String) -> Resource? {
        let name = token.hasSuffix(".js") ? token : token + ".js"
        return resources[aliases[name] ?? name]
    }

    /// JavaScript running `calls` (scriptlet names followed by arguments) that belong in `world`,
    /// or `nil` if there are none. It only acts in frames whose hostname is `hostname`.
    func script(for calls: [[String]], world: World, hostname: String) -> String? {
        var declarations: [String: String] = [:]
        var invocations: [String] = []

        for call in calls {
            guard let name = call.first, let scriptlet = resources[name], scriptlet.world == world else { continue }
            declare(scriptlet, in: &declarations)
            let arguments = call.dropFirst().map(Self.javaScriptString).joined(separator: ", ")
            invocations.append("try { \(scriptlet.function)(\(arguments)); } catch { }")
        }
        guard !invocations.isEmpty else { return nil }

        // Like uBlock Origin: everything is declared first, sorted so classes come before
        // the functions that use them, then the scriptlets run in order.
        let code = declarations.values.sorted()
        return """
            (function yabScriptlets() {
            let hostname = '';
            try { hostname = new URL(self.origin).hostname; } catch { }
            if ( hostname !== \(Self.javaScriptString(hostname)) ) { return; }
            const scriptletGlobals = {};
            \(code.joined(separator: "\n\n"))
            \(invocations.joined(separator: "\n"))
            })();
            """
    }

    private func declare(_ resource: Resource, in declarations: inout [String: String]) {
        var pending = [resource]
        while let next = pending.popLast() {
            guard declarations[next.name] == nil else { continue }
            declarations[next.name] = next.code
            pending += next.dependencies.compactMap { resources[$0] }
        }
    }

    /// A JavaScript string literal. JSON strings are valid JavaScript strings.
    private static func javaScriptString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(value)) ?? Data(#""""#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

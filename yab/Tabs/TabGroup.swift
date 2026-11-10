import Foundation
import WebKit

/// A pool of tabs that share where their data lives and what they remember about sites.
/// Normal mode and hacker mode each have one, and every tab, with its web view, belongs
/// to exactly one of them. Nothing learned in one group shows up in the other.
final class TabGroup {
    let mode: BrowsingMode
    /// Where this group's pages keep cookies and storage.
    let dataStore: WKWebsiteDataStore
    /// Sites where blocking is switched off.
    let blockingSwitch: SiteBlockingSwitch
    /// Sites known to work only over `http`.
    let httpsUpgrader: HTTPSUpgrader
    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: Tab?

    init(mode: BrowsingMode, dataStore: WKWebsiteDataStore, blockingSwitch: SiteBlockingSwitch, httpsUpgrader: HTTPSUpgrader = HTTPSUpgrader()) {
        self.mode = mode
        self.dataStore = dataStore
        self.blockingSwitch = blockingSwitch
        self.httpsUpgrader = httpsUpgrader
    }

    func tab(withID id: UUID) -> Tab? {
        tabs.first { $0.id == id }
    }

    func contains(_ tab: Tab) -> Bool {
        tabs.contains(tab)
    }

    func append(_ tab: Tab) {
        precondition(tab.mode == mode, "A \(tab.mode) tab cannot join the \(mode) group")
        tabs.append(tab)
    }

    func select(_ tab: Tab) {
        precondition(contains(tab))
        selectedTab = tab
    }

    /// Removes a tab. If it was selected, its neighbor is selected instead, as in a tab strip.
    func remove(_ tab: Tab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if selectedTab === tab {
            selectedTab = index > 0 ? tabs[index - 1] : tabs.first
        }
    }
}

import Foundation
import Testing
import WebKit
@testable import yab

/// Sound going on with the app off screen. Media does not really play inside the test
/// runner, so most tests send the page the events WebKit would.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BackgroundPlaybackTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "playback-\(UUID().uuidString)")
    let authentication = FakeAuthentication()
    let screen = TestScreen()
    let server = TestSchemeHandler(html: "<html><body><audio id=\"a\"></audio></body></html>")

    func makeTabs() -> TabManager {
        TabManager(
            contentBlocker: nil,
            forgetter: SiteDataForgetter(gracePeriod: .milliseconds(300)),
            siteInfo: nil,
            hackerLock: authentication.makeLock(),
            normalDataStore: .nonPersistent(),
            store: TabStore(directory: directory),
            blockingSwitchURL: directory.appending(path: "sites-without-blocking.json"),
            configure: { [server] configuration in
                configuration.setURLSchemeHandler(server, forURLScheme: "yabtest")
                // Lets the tests start playback without a finger on the screen.
                configuration.mediaTypesRequiringUserActionForPlayback = []
            }
        )
    }

    /// Runs `javaScript` as the page sees things, or with `world: .defaultClient` as they
    /// really are.
    func evaluate(_ javaScript: String, in tab: Tab, world: WKContentWorld = .page) async -> Any? {
        try? await tab.webView?.callAsyncJavaScript(javaScript, arguments: [:], contentWorld: world)
    }

    func send(_ event: String, in tab: Tab) async {
        _ = await evaluate("document.getElementById('a').dispatchEvent(new Event('\(event)'))", in: tab)
    }

    /// A tab on screen with a page whose audio has started.
    func playingTab(in tabs: TabManager, mode: BrowsingMode = .normal) async throws -> Tab {
        let tab = try #require(tabs.newTab(in: mode, url: URL(string: "yabtest://music.example/index.html")!))
        screen.show(tab.view)
        #expect(await eventually { await evaluate("return document.getElementById('a') !== null && document.visibilityState", in: tab) as? String == "visible" })
        await send("play", in: tab)
        return tab
    }

    func leaveScreen(_ tab: Tab) async {
        screen.clear()
        #expect(await eventually { await evaluate("return document.hidden", in: tab, world: .defaultClient) as? Bool == true })
    }

    @Test func aPagePlayingSoundStaysVisibleAndThePauseFromLeavingIsUndone() async throws {
        let tabs = makeTabs()
        let tab = try await playingTab(in: tabs)
        await leaveScreen(tab)
        #expect(await evaluate("return document.hidden", in: tab) as? Bool == false)
        #expect(await evaluate("return document.visibilityState", in: tab) as? String == "visible")

        // WebKit pauses as the app leaves the screen; the page plays on.
        await send("pause", in: tab)
        #expect(await eventually { await evaluate("return document.getElementById('a').paused", in: tab) as? Bool == false })

        // A pause by the page itself stays, and the page now sees it is hidden.
        _ = await evaluate("document.getElementById('a').pause()", in: tab)
        #expect(await eventually { await evaluate("return document.hidden", in: tab) as? Bool == true })
        #expect(await evaluate("return document.getElementById('a').paused", in: tab) as? Bool == true)
    }

    @Test func aPauseLongAfterLeavingIsRespected() async throws {
        let tabs = makeTabs()
        let tab = try await playingTab(in: tabs)
        await leaveScreen(tab)

        // Like the pause button on the lock screen, a while later.
        try await Task.sleep(for: .milliseconds(BackgroundPlayback.leavingScreenWindow + 500))
        await send("pause", in: tab)
        #expect(await eventually { await evaluate("return document.hidden", in: tab) as? Bool == true })
        #expect(await evaluate("return document.getElementById('a').paused", in: tab) as? Bool == true)
    }

    @Test func silentMediaDoesNotKeepThePageVisible() async throws {
        let tabs = makeTabs()
        let tab = try #require(tabs.newTab(url: URL(string: "yabtest://music.example/index.html")!))
        screen.show(tab.view)
        #expect(await eventually { await evaluate("return document.getElementById('a') !== null", in: tab) as? Bool == true })
        _ = await evaluate("document.getElementById('a').muted = true", in: tab)
        await send("play", in: tab)
        await leaveScreen(tab)
        #expect(await evaluate("return document.hidden", in: tab) as? Bool == true)
    }

    @Test func hackerTabsDoNotPlayOn() async throws {
        let tabs = makeTabs()
        #expect(await tabs.enterHackerMode())
        let tab = try await playingTab(in: tabs, mode: .hacker)
        await leaveScreen(tab)
        #expect(await evaluate("return document.hidden", in: tab) as? Bool == true)
    }

    @Test func aTabPlayingSoundIsNotSuspended() async throws {
        let tabs = makeTabs()
        let music = try #require(tabs.newTab(url: URL(string: "yabtest://music.example/index.html")!))
        screen.show(music.view)
        #expect(await eventually { await evaluate("return document.getElementById('a') !== null", in: music) as? Bool == true })
        // One second of silence, looped: real media, with nothing to hear.
        let started = await evaluate("""
            const rate = 8000;
            const bytes = new Uint8Array(44 + rate);
            const view = new DataView(bytes.buffer);
            const text = (offset, string) => [...string].forEach((c, i) => bytes[offset + i] = c.charCodeAt(0));
            text(0, 'RIFF'); view.setUint32(4, 36 + rate, true); text(8, 'WAVE');
            text(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
            view.setUint32(24, rate, true); view.setUint32(28, rate, true); view.setUint16(32, 1, true); view.setUint16(34, 8, true);
            text(36, 'data'); view.setUint32(40, rate, true); bytes.fill(128, 44);
            const audio = document.getElementById('a');
            audio.loop = true;
            audio.src = URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }));
            await audio.play();
            return !audio.paused;
            """, in: music)
        #expect(started as? Bool == true)
        #expect(await eventually { await music.webView?.requestMediaPlaybackState() == .playing })

        let other = try #require(tabs.newTab(url: URL(string: "yabtest://other.example/index.html")!))
        screen.show(other.view)
        let quiet = try #require(tabs.newTab(url: URL(string: "yabtest://quiet.example/index.html")!))
        tabs.select(quiet)
        tabs.select(other)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(await eventually { !quiet.isLive })
        // WebKit answers for each tab separately; give the music tab's answer time to arrive.
        try await Task.sleep(for: .milliseconds(500))
        #expect(music.isLive)
        #expect(other.isLive)
    }
}

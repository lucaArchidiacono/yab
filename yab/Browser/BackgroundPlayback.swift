import WebKit

/// Keeps sound playing when the app leaves the screen or the phone locks, as with music
/// or a YouTube video you only listen to.
///
/// Two things stop it otherwise:
/// - **WebKit** pauses video with sound when the app goes to the background. It lets the
///   page start it again right after, but nothing does.
/// - **Sites** like YouTube pause themselves when the page is hidden.
///
/// So while a page plays sound, it keeps seeing itself as visible, and a pause that
/// comes with the app leaving the screen is undone. Every other pause is respected: one
/// by the page, its own pause button, or the lock screen, headphones and calls.
///
/// The app also needs the `audio` background mode, in `Config/yab-Info.plist`.
enum BackgroundPlayback {
    static let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// How long a pause and the page being hidden may be apart to count as the app
    /// leaving the screen. WebKit reports the two separately, in either order.
    static let leavingScreenWindow = 2_000

    private static let source = """
        (() => {
            const documentPrototype = Document.prototype;
            const visibilityState = Object.getOwnPropertyDescriptor(documentPrototype, 'visibilityState');
            const hidden = Object.getOwnPropertyDescriptor(documentPrototype, 'hidden');
            if (!visibilityState?.get || !hidden?.get) return;
            const isHidden = () => hidden.get.call(document);
            const play = HTMLMediaElement.prototype.play;
            const pause = HTMLMediaElement.prototype.pause;
            const maximumGap = \(leavingScreenWindow);

            // Media playing sound that the page has not paused itself.
            const playing = new Set();
            // Paused by the page itself: never undone.
            const pausedByPage = new WeakSet();
            // Paused by the browser while the page was visible: undone if it is hidden soon after.
            const pausedBeforeHiding = new Set();
            let seenHidden = isHidden();
            let hiddenAt = 0;

            const keepsVisible = () => {
                for (const media of playing) {
                    if (!media.isConnected) playing.delete(media);
                }
                return playing.size > 0;
            };

            Object.defineProperty(documentPrototype, 'visibilityState', {
                ...visibilityState,
                get() { return this === document && keepsVisible() ? 'visible' : visibilityState.get.call(this); },
            });
            Object.defineProperty(documentPrototype, 'hidden', {
                ...hidden,
                get() { return this === document && keepsVisible() ? false : hidden.get.call(this); },
            });

            HTMLMediaElement.prototype.pause = function () {
                pausedByPage.add(this);
                return pause.call(this);
            };

            const resume = (media) => {
                if (!media.isConnected || media.ended) {
                    playing.delete(media);
                    return;
                }
                play.call(media).catch(() => playing.delete(media));
            };

            const isAudible = (media) => !media.muted && media.volume > 0;

            const listen = (type, handler) => {
                window.addEventListener(type, (event) => {
                    if (event.target instanceof HTMLMediaElement) handler(event.target);
                }, true);
            };

            listen('play', (media) => {
                pausedByPage.delete(media);
                pausedBeforeHiding.delete(media);
                if (isAudible(media)) playing.add(media);
            });

            listen('volumechange', (media) => {
                if (!isAudible(media)) {
                    playing.delete(media);
                } else if (!media.paused) {
                    playing.add(media);
                }
            });

            listen('pause', (media) => {
                if (!playing.has(media)) return;
                if (pausedByPage.has(media) || media.ended) {
                    playing.delete(media);
                    return;
                }
                if (!isHidden()) {
                    pausedBeforeHiding.add(media);
                    setTimeout(() => {
                        if (pausedBeforeHiding.delete(media)) playing.delete(media);
                    }, maximumGap);
                } else if (!seenHidden || Date.now() - hiddenAt < maximumGap) {
                    // Hidden this very moment: the app is leaving the screen.
                    resume(media);
                } else {
                    // Paused long after hiding: from the lock screen, headphones or a call.
                    playing.delete(media);
                }
            });

            listen('ended', (media) => playing.delete(media));

            window.addEventListener('visibilitychange', (event) => {
                if (event.target !== document) return;
                const nowHidden = isHidden();
                if (nowHidden && !seenHidden) {
                    hiddenAt = Date.now();
                    for (const media of pausedBeforeHiding) resume(media);
                    pausedBeforeHiding.clear();
                }
                seenHidden = nowHidden;
                // The page never saw itself hidden, so it hears of no change.
                if (keepsVisible()) event.stopImmediatePropagation();
            }, true);
        })();
        """
}

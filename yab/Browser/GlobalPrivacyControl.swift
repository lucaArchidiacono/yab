import WebKit

/// Global Privacy Control: tells sites not to sell or share your data. In some places,
/// like California and the EU, sites are legally bound to honor it.
///
/// Page requests carry the `Sec-GPC: 1` header, and every frame sees
/// `navigator.globalPrivacyControl == true`. WebKit does not let apps add headers to the
/// other requests a page makes, so those carry the signal through `navigator` only.
enum GlobalPrivacyControl {
    static let headerName = "Sec-GPC"
    static let headerValue = "1"

    static let userScript = WKUserScript(
        source: """
            (() => {
                try {
                    Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', {
                        get: () => true,
                        configurable: true,
                        enumerable: true,
                    });
                } catch { }
            })();
            """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
    )
}

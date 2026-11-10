import UIKit
import WebKit

/// What a tab shows: its page, with the last picture of it on top while the page loads
/// again, so coming back to a tab feels instant.
final class TabView: UIView {
    private let snapshotView = UIImageView()
    private weak var webView: WKWebView?
    /// Tells a finished fade-out whether a newer picture took its place meanwhile.
    private var snapshotGeneration = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        clipsToBounds = true
        snapshotView.contentMode = .scaleAspectFill
        snapshotView.clipsToBounds = true
        snapshotView.isHidden = true
        addPinned(snapshotView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isShowingSnapshot: Bool {
        !snapshotView.isHidden
    }

    func install(_ webView: WKWebView) {
        self.webView?.removeFromSuperview()
        self.webView = webView
        addPinned(webView, below: snapshotView)
    }

    func removeWebView() {
        webView?.removeFromSuperview()
        webView = nil
    }

    func showSnapshot(_ image: UIImage) {
        snapshotGeneration += 1
        snapshotView.layer.removeAllAnimations()
        snapshotView.image = image
        snapshotView.alpha = 1
        snapshotView.isHidden = false
    }

    /// Fades the picture out, once the page underneath has loaded.
    func hideSnapshot() {
        guard isShowingSnapshot else { return }
        let generation = snapshotGeneration
        UIView.animate(withDuration: 0.2) {
            self.snapshotView.alpha = 0
        } completion: { _ in
            guard generation == self.snapshotGeneration else { return }
            self.snapshotView.isHidden = true
            self.snapshotView.image = nil
        }
    }

    private func addPinned(_ view: UIView, below sibling: UIView? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let sibling {
            insertSubview(view, belowSubview: sibling)
        } else {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

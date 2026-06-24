//
//  DetailBrowserViewController.swift
//  NetNewsWire
//
//  An in-app web browser that replaces the article detail pane when the user
//  opens a link. Owns its own clean WKWebView. Navigation controls live in the
//  window toolbar (see MainWindowController); this view shows the page and a
//  small current-URL overlay in the bottom-right corner.
//

import AppKit
@preconcurrency import WebKit

extension Notification.Name {
	static let DetailBrowserNavigationStateDidChange = Notification.Name("DetailBrowserNavigationStateDidChange")
}

@MainActor protocol DetailBrowserViewControllerDelegate: AnyObject {
	/// The user asked to return to the article (Esc).
	func detailBrowserViewControllerDidRequestArticle(_ controller: DetailBrowserViewController)
}

final class DetailBrowserViewController: NSViewController {

	weak var delegate: DetailBrowserViewControllerDelegate?

	private var webView: WKWebView!
	private let urlLabel = NSTextField(labelWithString: "")
	private var urlContainer: NSView!
	private var observations: [NSKeyValueObservation] = []

	var canGoBack: Bool { webView?.canGoBack ?? false }
	var canGoForward: Bool { webView?.canGoForward ?? false }
	var pageTitle: String? {
		let title = webView?.title
		return (title?.isEmpty ?? true) ? nil : title
	}

	override func loadView() {
		let configuration = WKWebViewConfiguration()
		webView = WKWebView(frame: .zero, configuration: configuration)
		webView.navigationDelegate = self
		webView.translatesAutoresizingMaskIntoConstraints = false
		// Use WebKit's default Safari user agent rather than NetNewsWire's
		// feed-reader UA so sites serve their normal browser layout.

		let container = NSView()
		container.addSubview(webView)

		let overlay = makeURLOverlay()
		container.addSubview(overlay)

		NSLayoutConstraint.activate([
			webView.topAnchor.constraint(equalTo: container.topAnchor),
			webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

			overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
			overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
			overlay.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.7)
		])

		view = container

		observeWebView()
	}

	// MARK: - API

	func load(_ url: URL) {
		webView.load(URLRequest(url: url))
		setURLText(url.absoluteString)
	}

	func focusWebView() {
		view.window?.makeFirstResponder(webView)
	}

	func stopMediaPlayback() {
		webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(m => m.pause());", completionHandler: nil)
	}

	func goBack() { webView.goBack() }
	func goForward() { webView.goForward() }
	func reload() { webView.reload() }

	func openInDefaultBrowser() {
		guard let url = webView.url else { return }
		Browser.open(url.absoluteString, invertPreference: false)
	}

	override func cancelOperation(_ sender: Any?) {
		// Esc returns to the article.
		delegate?.detailBrowserViewControllerDidRequestArticle(self)
	}

	// MARK: - Private

	private func makeURLOverlay() -> NSView {
		urlLabel.lineBreakMode = .byTruncatingTail
		urlLabel.textColor = .secondaryLabelColor
		urlLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		urlLabel.translatesAutoresizingMaskIntoConstraints = false
		// Let a long URL truncate instead of forcing the overlay — and through
		// the width≤0.7×container constraint, the pane and window — to grow.
		urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		urlLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

		let box = NSVisualEffectView()
		box.material = .hudWindow
		box.blendingMode = .withinWindow
		box.state = .active
		box.wantsLayer = true
		box.layer?.cornerRadius = 4
		box.translatesAutoresizingMaskIntoConstraints = false
		box.addSubview(urlLabel)

		NSLayoutConstraint.activate([
			urlLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
			urlLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
			urlLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
			urlLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8)
		])

		urlContainer = box
		box.isHidden = true
		return box
	}

	private func setURLText(_ text: String?) {
		let value = text ?? ""
		urlLabel.stringValue = value
		urlContainer?.isHidden = value.isEmpty
	}

	private func observeWebView() {
		observations = [
			webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
				Task { @MainActor in self?.postNavigationStateChange() }
			},
			webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
				Task { @MainActor in self?.postNavigationStateChange() }
			},
			webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
				Task { @MainActor in self?.setURLText(webView.url?.absoluteString) }
			},
			webView.observe(\.title, options: [.new]) { [weak self] _, _ in
				Task { @MainActor in self?.postNavigationStateChange() }
			}
		]
	}

	private func postNavigationStateChange() {
		NotificationCenter.default.post(name: .DetailBrowserNavigationStateDidChange, object: self)
	}
}

// MARK: - WKNavigationDelegate

extension DetailBrowserViewController: WKNavigationDelegate {

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		showError(error)
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		showError(error)
	}

	private func showError(_ error: Error) {
		let nsError = error as NSError
		if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
			return
		}
		if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
			return
		}

		let message = nsError.localizedDescription
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
		let html = "<body style=\"font: -apple-system; color: #888; padding: 2em;\">Could not load this page.<br><br>\(message)</body>"
		webView.loadHTMLString(html, baseURL: nil)
	}
}

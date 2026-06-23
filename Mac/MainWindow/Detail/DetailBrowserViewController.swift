//
//  DetailBrowserViewController.swift
//  NetNewsWire
//
//  An in-app web browser that replaces the article detail pane when the user
//  clicks an in-content link. Owns its own clean WKWebView and a small toolbar.
//

import AppKit
@preconcurrency import WebKit
import RSWeb

@MainActor protocol DetailBrowserViewControllerDelegate: AnyObject {
	/// The user asked to return to the article (back button or Esc).
	func detailBrowserViewControllerDidRequestArticle(_ controller: DetailBrowserViewController)
}

final class DetailBrowserViewController: NSViewController {

	weak var delegate: DetailBrowserViewControllerDelegate?

	private var webView: WKWebView!
	private let addressField = NSTextField(labelWithString: "")
	private let articleButton = NSButton()
	private let backButton = NSButton()
	private let forwardButton = NSButton()
	private let reloadButton = NSButton()
	private let safariButton = NSButton()

	private var observations: [NSKeyValueObservation] = []

	override func loadView() {
		let configuration = WKWebViewConfiguration()
		webView = WKWebView(frame: .zero, configuration: configuration)
		webView.navigationDelegate = self
		webView.translatesAutoresizingMaskIntoConstraints = false
		if let userAgent = UserAgent.fromInfoPlist() {
			webView.customUserAgent = userAgent
		}

		let toolbar = makeToolbar()

		let container = NSView()
		container.addSubview(toolbar)
		container.addSubview(webView)

		toolbar.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			toolbar.topAnchor.constraint(equalTo: container.topAnchor),
			toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

			webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
			webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
		])

		view = container

		observeWebView()
		updateButtonStates()
	}

	// MARK: - API

	func load(_ url: URL) {
		webView.load(URLRequest(url: url))
		addressField.stringValue = url.absoluteString
	}

	func stopMediaPlayback() {
		webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(m => m.pause());", completionHandler: nil)
	}

	// MARK: - Actions

	@objc private func goToArticle(_ sender: Any?) {
		delegate?.detailBrowserViewControllerDidRequestArticle(self)
	}

	@objc private func goBack(_ sender: Any?) { webView.goBack() }
	@objc private func goForward(_ sender: Any?) { webView.goForward() }
	@objc private func reload(_ sender: Any?) { webView.reload() }

	@objc private func openInSafari(_ sender: Any?) {
		guard let url = webView.url else { return }
		Browser.open(url.absoluteString, invertPreference: false)
	}

	override func cancelOperation(_ sender: Any?) {
		// Esc returns to the article.
		delegate?.detailBrowserViewControllerDidRequestArticle(self)
	}

	// MARK: - Private

	private func makeToolbar() -> NSView {
		configure(articleButton, symbol: "chevron.left", title: "Article", action: #selector(goToArticle(_:)))
		configure(backButton, symbol: "chevron.backward", title: "Back", action: #selector(goBack(_:)))
		configure(forwardButton, symbol: "chevron.forward", title: "Forward", action: #selector(goForward(_:)))
		configure(reloadButton, symbol: "arrow.clockwise", title: "Reload", action: #selector(reload(_:)))
		configure(safariButton, symbol: "safari", title: "Open in Safari", action: #selector(openInSafari(_:)))

		addressField.lineBreakMode = .byTruncatingTail
		addressField.textColor = .secondaryLabelColor
		addressField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
		addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let stack = NSStackView(views: [articleButton, backButton, forwardButton, reloadButton, addressField, safariButton])
		stack.orientation = .horizontal
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
		stack.translatesAutoresizingMaskIntoConstraints = false
		return stack
	}

	private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
		button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
		button.imagePosition = .imageOnly
		button.bezelStyle = .texturedRounded
		button.toolTip = title
		button.target = self
		button.action = action
		button.setContentHuggingPriority(.required, for: .horizontal)
	}

	private func observeWebView() {
		observations = [
			webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
				Task { @MainActor in self?.updateButtonStates() }
			},
			webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
				Task { @MainActor in self?.updateButtonStates() }
			},
			webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
				Task { @MainActor in
					if let url = webView.url { self?.addressField.stringValue = url.absoluteString }
				}
			}
		]
	}

	private func updateButtonStates() {
		backButton.isEnabled = webView.canGoBack
		forwardButton.isEnabled = webView.canGoForward
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
		// Cancelled and frame-interrupted navigations are routine (e.g. the user
		// clicks a second link before the first commits, or a redirect supersedes
		// an in-flight load) and must not replace a good page with an error.
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

//
//  ArticleExtractor.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 9/18/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import Foundation
import WebKit
import RSWeb

public enum ArticleExtractorState: Sendable {
	case ready
	case processing
	case failedToParse
	case complete
	case cancelled
}

@MainActor protocol ArticleExtractorDelegate {
	func articleExtractionDidFail(with: Error)
	func articleExtractionDidComplete(extractedArticle: ExtractedArticle)
}

@MainActor final class ArticleExtractor: NSObject {

	let articleLink: String
	let delegate: ArticleExtractorDelegate
	var article: ExtractedArticle?
	var state = ArticleExtractorState.ready

	private let url: URL
	private var webView: WKWebView?
	private var timeoutTask: Task<Void, Never>?
	private static let timeout: TimeInterval = 30

	public init?(_ articleLink: String, delegate: ArticleExtractorDelegate) {
		self.articleLink = articleLink
		self.delegate = delegate
		guard let url = URL(string: articleLink), url.scheme == "http" || url.scheme == "https" else {
			return nil
		}
		self.url = url
		super.init()
	}

	public func process() {
		state = .processing

		let configuration = WKWebViewConfiguration()
		// Use the app's shared, persistent cookie store so a logged-in session
		// (e.g. a paywall login made in the in-app browser) carries into
		// extraction and Readability sees the full article, not the free sample.
		configuration.websiteDataStore = .default()
		let userScript = WKUserScript(source: ReadabilityResource.javaScript,
									  injectionTime: .atDocumentEnd,
									  forMainFrameOnly: true)
		configuration.userContentController.addUserScript(userScript)

		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
		webView.navigationDelegate = self
		if let userAgent = UserAgent.fromInfoPlist() {
			webView.customUserAgent = userAgent
		}
		self.webView = webView

		timeoutTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
			guard let self, self.state == .processing else { return }
			self.fail(with: URLError(.timedOut))
		}

		webView.load(URLRequest(url: url))
	}

	public func cancel() {
		state = .cancelled
		teardown()
	}

	// MARK: - Private

	private func teardown() {
		timeoutTask?.cancel()
		timeoutTask = nil
		webView?.navigationDelegate = nil
		webView?.stopLoading()
		webView = nil
	}

	private func fail(with error: Error) {
		guard state == .processing else { return }
		state = .failedToParse
		teardown()
		delegate.articleExtractionDidFail(with: error)
	}

	private func complete(_ extracted: ExtractedArticle) {
		guard state == .processing else { return }
		state = .complete
		article = extracted
		teardown()
		delegate.articleExtractionDidComplete(extractedArticle: extracted)
	}

	private func runReadability() {
		let host = url.host ?? ""
		let selectors = Self.baseJunkSelectors + Self.siteJunkSelectors(forHost: host)
		let selectorsJSON = (try? JSONSerialization.data(withJSONObject: selectors))
			.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
		let contentSelector = Self.siteContentSelector(forHost: host)
		let contentJSON = contentSelector.map { "\"\($0)\"" } ?? "null"

		let js = Self.extractionJavaScript(selectorsJSON: selectorsJSON, contentSelectorJSON: contentJSON)
		webView?.evaluateJavaScript(js) { [weak self] result, _ in
			Task { @MainActor in
				guard let self else { return }
				guard let jsonString = result as? String,
					  let data = jsonString.data(using: .utf8),
					  let parsed = try? JSONDecoder().decode(ReadabilityResult.self, from: data),
					  let content = parsed.content, !content.isEmpty else {
					self.fail(with: URLError(.cannotDecodeContentData))
					return
				}
				self.complete(parsed.extractedArticle(url: self.articleLink))
			}
		}
	}

	/// Chrome that Readability's generic scoring sometimes mistakes for the
	/// article: scripts, navigation, consent managers, modals, banners.
	nonisolated static let baseJunkSelectors = [
		"script", "style", "noscript", "template", "iframe",
		"nav",
		"dialog", "[aria-modal=\"true\"]",
		"[role=\"navigation\"]", "[role=\"banner\"]", "[role=\"dialog\"]",
		"[id*=\"cookie\" i]", "[class*=\"cookie\" i]",
		"[id*=\"consent\" i]", "[class*=\"consent\" i]",
		"[id*=\"gdpr\" i]", "[class*=\"gdpr\" i]",
		"[id*=\"onetrust\" i]", "[class*=\"onetrust\" i]",
		"[id*=\"didomi\" i]", "[class*=\"didomi\" i]",
		"[id*=\"sp_message\" i]", "[class*=\"sp-message\" i]",
		"[class*=\"newsletter\" i]", "[class*=\"paywall\" i]"
	]

	/// Extra chrome selectors for sites whose markup defeats the generic list.
	nonisolated static func siteJunkSelectors(forHost host: String) -> [String] {
		let host = host.lowercased()
		if host == "lemonde.fr" || host.hasSuffix(".lemonde.fr") {
			return [".ds-header", ".ds-burger-popin", ".ds-footer"]
		}
		return []
	}

	/// Some sites bury the article in chrome that blocklisting can't reliably
	/// remove (e.g. paywalled pages where stripping the menu leaves too little
	/// for Readability's scoring). For those we whitelist the known article
	/// container and run Readability on just that subtree. Mirrors the per-site
	/// custom extractors the old Mercury parser shipped.
	nonisolated static func siteContentSelector(forHost host: String) -> String? {
		let host = host.lowercased()
		if host == "lemonde.fr" || host.hasSuffix(".lemonde.fr") {
			return "article.article__content"
		}
		if host == "mediapart.fr" || host.hasSuffix(".mediapart.fr") {
			// Mediapart names the article body `paywall-restricted-content`, which the
			// generic paywall junk rule would otherwise strip. Whitelist it directly.
			return ".news__body__center__article"
		}
		return nil
	}

	/// Tries, in order: the whitelisted article container (if known), then a copy
	/// of the page with junk stripped, then the untouched page. So a site rule can
	/// only help, never make a site worse.
	nonisolated private static func extractionJavaScript(selectorsJSON: String, contentSelectorJSON: String) -> String {
		"""
		(function() {
			var JUNK = \(selectorsJSON);
			var CONTENT = \(contentSelectorJSON);

			function parse(doc) {
				try { return new Readability(doc, { charThreshold: 200 }).parse(); }
				catch (error) { return null; }
			}
			function hasContent(article) {
				return !!(article && article.content && article.textContent && article.textContent.trim().length > 0);
			}

			try {
				// 1. Whitelist: isolate the known article container.
				if (CONTENT) {
					var node = document.querySelector(CONTENT);
					if (node) {
						var isolated = document.cloneNode(true);
						isolated.body.innerHTML = node.outerHTML;
						var whitelisted = parse(isolated);
						if (hasContent(whitelisted)) { return JSON.stringify(whitelisted); }
					}
				}

				// 2. Blocklist: strip junk and let Readability score the rest.
				var cleaned = document.cloneNode(true);
				try {
					cleaned.querySelectorAll(JUNK.join(",")).forEach(function(node) {
						if (node && node.parentNode) { node.parentNode.removeChild(node); }
					});
				} catch (selectorError) { /* a bad selector shouldn't abort extraction */ }
				var article = parse(cleaned);
				if (hasContent(article)) { return JSON.stringify(article); }

				// 3. Fall back to the untouched page.
				var fallback = parse(document.cloneNode(true));
				return hasContent(fallback) ? JSON.stringify(fallback) : null;
			} catch (error) {
				return null;
			}
		})()
		"""
	}
}

extension ArticleExtractor: WKNavigationDelegate {

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		runReadability()
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		if (error as NSError).code == NSURLErrorCancelled { return }
		fail(with: error)
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		if (error as NSError).code == NSURLErrorCancelled { return }
		fail(with: error)
	}
}

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
	private var parsedDocumentTask: Task<Void, Never>?
	private static let timeout: TimeInterval = 30

	/// How long a page gets to finish loading once its HTML has been parsed.
	/// The article is in the document by then. What's still loading is images,
	/// ads, and trackers. On a network that can't reach their hosts, those can
	/// hold up the page's load event until after `timeout` has passed.
	private static let parsedDocumentGracePeriod: TimeInterval = 3
	private static let documentParsedMessageName = "nnwDocumentParsed"

	public init?(_ articleLink: String, delegate: ArticleExtractorDelegate) {
		self.articleLink = articleLink
		self.delegate = delegate
		guard let url = URL(string: articleLink), url.scheme == "http" || url.scheme == "https" else {
			return nil
		}
		self.url = Self.extractionURL(for: url)
		super.init()
	}

	/// Some sites serve a JavaScript-heavy page that Readability can't parse, but
	/// also publish a static equivalent. Rewrite to that before loading.
	nonisolated static func extractionURL(for url: URL) -> URL {
		guard let host = url.host?.lowercased() else {
			return url
		}

		// Naver Blog desktop URLs render through a SPA shell with no article markup.
		// The mobile site serves the post as static HTML.
		if host == "blog.naver.com" {
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
			components?.host = "m.blog.naver.com"
			components?.query = nil
			if let mobileURL = components?.url {
				return mobileURL
			}
		}

		return url
	}

	public func process() {
		state = .processing

		let configuration = WKWebViewConfiguration()
		// Use the app's shared, persistent cookie store so a logged-in session
		// (e.g. a paywall login made in the in-app browser) carries into
		// extraction and Readability sees the full article, not the free sample.
		configuration.websiteDataStore = .default()
		// Identify the app by appending to WebKit's native User-Agent rather than
		// replacing it. Overriding `customUserAgent` with our bare UA drops the
		// browser-engine token ("AppleWebKit … KHTML, like Gecko"); sites fronted by
		// a CDN/WAF (e.g. motorsport.com behind CloudFront) then return a 403 error
		// page, which WKWebView loads as a successful navigation, so Readability finds
		// no article and extraction fails. `applicationNameForUserAgent` keeps the
		// browser token, so the request isn't blocked.
		if let userAgent = UserAgent.fromInfoPlist() {
			configuration.applicationNameForUserAgent = userAgent
		}
		let userScript = WKUserScript(source: ReadabilityResource.javaScript,
									  injectionTime: .atDocumentEnd,
									  forMainFrameOnly: true)
		configuration.userContentController.addUserScript(userScript)

		// Tells us when the page's HTML has been parsed, which can be long
		// before the page finishes loading. See documentDidParse().
		let documentParsedScript = WKUserScript(source: "window.webkit.messageHandlers.\(Self.documentParsedMessageName).postMessage(true);",
												injectionTime: .atDocumentEnd,
												forMainFrameOnly: true)
		configuration.userContentController.addUserScript(documentParsedScript)
		configuration.userContentController.add(DocumentParsedMessageHandler(self), name: Self.documentParsedMessageName)

		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
		webView.navigationDelegate = self
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
		parsedDocumentTask?.cancel()
		parsedDocumentTask = nil
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

	/// The page's HTML has been parsed. Give the rest of the page a moment to
	/// finish loading, since scripts may still be filling in the article. After
	/// that, stop waiting for it: extract from what's there, and keep trying
	/// until Readability finds an article, the page finishes loading, or the
	/// extractor times out.
	fileprivate func documentDidParse() {
		guard state == .processing else {
			return
		}

		parsedDocumentTask?.cancel()
		parsedDocumentTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: UInt64(Self.parsedDocumentGracePeriod * 1_000_000_000))
				guard let self, !Task.isCancelled, self.state == .processing else {
					return
				}
				self.runReadability(isFinalAttempt: false)
			}
		}
	}

	/// - Parameter isFinalAttempt: Whether finding no article counts as failure.
	///   True once the page has finished loading. False while it's still loading,
	///   when the article may simply not be there yet.
	private func runReadability(isFinalAttempt: Bool) {
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
					if isFinalAttempt {
						self.fail(with: URLError(.cannotDecodeContentData))
					}
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
		if host == "arstechnica.com" || host.hasSuffix(".arstechnica.com") {
			// Ars buries ads, a newsletter "interlude", a sign-in overlay, and the
			// previous/next-story navigation inside its .post-content article body.
			return [".ad", ".ad-wrapper", ".ars-interlude-container", ".sign-in-panel", ".post-navigation"]
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
		if host == "lesechos.fr" || host.hasSuffix(".lesechos.fr") {
			// Les Echos names the article body `post-paywall`, which the generic
			// paywall junk rule would strip before Readability sees it. Whitelist
			// it directly, as with Mediapart above.
			return ".post-paywall"
		}
		if host == "arstechnica.com" || host.hasSuffix(".arstechnica.com") {
			// Ars splits a multi-page article into one .post-content block per page,
			// all inside the main <article>. Matching every block (and concatenating
			// them) reassembles the whole story while dropping the comment picks,
			// related cards, and rail ads around it.
			return ".post-content"
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
			function stripJunk(doc, keep) {
				if (!JUNK.length) { return; }
				try {
					doc.querySelectorAll(JUNK.join(",")).forEach(function(node) {
						if (node && node.parentNode && (!keep || keep.indexOf(node) === -1)) {
							node.parentNode.removeChild(node);
						}
					});
				} catch (selectorError) { /* a bad selector shouldn't abort extraction */ }
			}

			try {
				// 1. Whitelist: isolate the known article container(s), then strip the
				// junk (ads, newsletters) that sits inside. Some sites (e.g. Ars Technica)
				// split one article across several matching containers — one per page — so
				// concatenate every match, not just the first.
				if (CONTENT) {
					var nodes = document.querySelectorAll(CONTENT);
					if (nodes.length) {
						var html = "";
						nodes.forEach(function(node) { html += node.outerHTML; });
						var isolated = document.cloneNode(true);
						isolated.body.innerHTML = html;
						// Strip junk inside the container(s), but never the containers
						// themselves: a site may name its article body with a class our
						// generic junk list matches (e.g. Mediapart's
						// paywall-restricted-content).
						var keep = Array.prototype.slice.call(isolated.body.children);
						stripJunk(isolated, keep);
						var whitelisted = parse(isolated);
						if (hasContent(whitelisted)) { return JSON.stringify(whitelisted); }
					}
				}

				// 2. Blocklist: strip junk and let Readability score the rest.
				var cleaned = document.cloneNode(true);
				stripJunk(cleaned);
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
		runReadability(isFinalAttempt: true)
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

/// WKUserContentController retains its message handlers. Forwarding through
/// this keeps it from retaining the extractor, so an extractor that's dropped
/// without being cancelled still goes away.
@MainActor private final class DocumentParsedMessageHandler: NSObject, WKScriptMessageHandler {

	private weak var extractor: ArticleExtractor?

	init(_ extractor: ArticleExtractor) {
		self.extractor = extractor
	}

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		guard message.frameInfo.isMainFrame else {
			return
		}
		extractor?.documentDidParse()
	}
}

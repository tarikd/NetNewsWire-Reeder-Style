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
		// Extraction shouldn't read or write the app's shared cookie store.
		configuration.websiteDataStore = .nonPersistent()
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
		let js = "(function(){try{var a=new Readability(document.cloneNode(true)).parse();return a?JSON.stringify(a):null;}catch(e){return null;}})()"
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

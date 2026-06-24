# Offline Reader View (Mozilla Readability) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the Feedbin/Mercury hosted parser in `ArticleExtractor` with Mozilla `Readability.js` running locally in an offscreen `WKWebView`, so Reader View works in any build with no API keys.

**Architecture:** Vendor `Readability.js` as a base64 Swift constant (compiled in — avoids resource-copy issues with this project's file-system-synchronized Xcode groups). `ArticleExtractor` loads the article URL in a hidden `WKWebView`, injects Readability via a `WKUserScript`, runs `new Readability(document.cloneNode(true)).parse()` on `didFinish`, and maps the JSON to the existing `ExtractedArticle`. The extractor's public surface (`init?`, `process()`, `cancel()`, `state`, delegate) is unchanged, so Mac and iOS callers are untouched.

**Tech Stack:** Swift, WebKit (`WKWebView`), XCTest. Shared code in `Shared/Article Extractor/`. Files are target members by folder (synchronized groups) — no `project.pbxproj` edits.

**Design doc:** `docs/plans/2026-06-24-offline-readability-extractor-design.md`

**Branch:** `feature/offline-reader-view` (off `main`; independent of the in-app-webview PR).

**Build / test commands (signing disabled):**
- Build: `xcodebuild build -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- Test: `xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS' -only-testing:NetNewsWireTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`

**Git rule:** No AI/Claude/Co-Authored-By attribution in any commit message.

**Current facts (verified):**
- `Shared/Article Extractor/ArticleExtractor.swift`: `@MainActor final class ArticleExtractor` with `init?(_ articleLink:delegate:)`, `process()`, `cancel()`, `state`, `ArticleExtractorState`. Today it hits `extract.feedbin.com`.
- `ExtractedArticle` (`Shared/Article Extractor/ExtractedArticle.swift`): `struct ... Codable, Equatable` with `let` fields `title, author, datePublished, dek, leadImageURL, content, nextPageURL, url, domain, excerpt, wordCount, direction, totalPages, renderedPages`. It has the implicit internal memberwise initializer (nothing else constructs it today).
- `ArticleRenderer` only reads `extractedArticle.content` and `.url`.
- Callers (Mac `MainWindowController`, iOS `WebViewController`): `ArticleExtractor(link, delegate:)`, `.process()`, `.cancel()`, and `ArticleExtractorDelegate` (`articleExtractionDidComplete(extractedArticle:)`, `articleExtractionDidFail(with:)`).

---

## Task 1: Vendor Readability.js as a base64 Swift constant

**Files:**
- Create: `Shared/Article Extractor/ReadabilityResource.swift`
- Test: `Tests/NetNewsWireTests/ReadabilityResourceTests.swift`

**Step 1: Fetch the library and confirm it.**

```bash
cd /Users/tarik/Code/NetNewsWire
curl -fsSL https://raw.githubusercontent.com/mozilla/readability/0.5.0/Readability.js -o /tmp/Readability.js
grep -c "Readability" /tmp/Readability.js   # expect > 0
wc -c /tmp/Readability.js                    # expect ~100KB
```
Pin tag `0.5.0` (a known release). If the fetch is blocked, STOP and ask. Keep Mozilla's Apache-2.0 license header (it's at the top of the file — preserve it in the vendored data).

**Step 2: Write the failing test.**

Create `Tests/NetNewsWireTests/ReadabilityResourceTests.swift`:

```swift
import XCTest
@testable import NetNewsWire

final class ReadabilityResourceTests: XCTestCase {

	func testJavaScriptDecodesAndDefinesReadability() {
		let js = ReadabilityResource.javaScript
		XCTAssertGreaterThan(js.count, 1000)
		// The library declares the Readability constructor.
		XCTAssertTrue(js.contains("Readability"))
		XCTAssertTrue(js.contains("parse"))
	}
}
```

**Step 3: Run it — expect FAIL** (`ReadabilityResource` not in scope).
`xcodebuild test ... -only-testing:NetNewsWireTests/ReadabilityResourceTests ...`

**Step 4: Generate the Swift constant.**

Base64-encode the JS and write the file (base64 avoids all string-escaping problems):

```bash
B64=$(base64 < /tmp/Readability.js | tr -d '\n')
cat > "Shared/Article Extractor/ReadabilityResource.swift" <<EOF
//
//  ReadabilityResource.swift
//  NetNewsWire
//
//  Mozilla Readability (https://github.com/mozilla/readability), v0.5.0,
//  licensed Apache-2.0. Embedded as base64 to inject into the extractor's
//  WKWebView without a bundled resource.
//

import Foundation

enum ReadabilityResource {

	/// The Readability.js library source, decoded from the embedded base64.
	static let javaScript: String = {
		guard let data = Data(base64Encoded: base64Encoded),
			  let source = String(data: data, encoding: .utf8) else {
			assertionFailure("Readability.js failed to decode")
			return ""
		}
		return source
	}()

	private static let base64Encoded = "${B64}"
}
EOF
```

**Step 5: Run the test — expect PASS.**

**Step 6: Commit.**
```bash
git add "Shared/Article Extractor/ReadabilityResource.swift" Tests/NetNewsWireTests/ReadabilityResourceTests.swift
git commit -m "Embed Mozilla Readability library for local article extraction"
```

---

## Task 2: Readability result model + mapping to ExtractedArticle (TDD)

**Files:**
- Create: `Shared/Article Extractor/ReadabilityResult.swift`
- Test: `Tests/NetNewsWireTests/ReadabilityResultTests.swift`

**Step 1: Write the failing test.**

Create `Tests/NetNewsWireTests/ReadabilityResultTests.swift`:

```swift
import XCTest
@testable import NetNewsWire

final class ReadabilityResultTests: XCTestCase {

	private func decode(_ json: String) throws -> ReadabilityResult {
		try JSONDecoder().decode(ReadabilityResult.self, from: Data(json.utf8))
	}

	func testMapsCoreFields() throws {
		let json = """
		{"title":"Hello","byline":"Jane Doe","content":"<p>Hi</p>","textContent":"Hi there friend","excerpt":"A summary","siteName":"Example","dir":"ltr","lang":"en","length":15}
		"""
		let result = try decode(json)
		let extracted = result.extractedArticle(url: "https://example.com/post")

		XCTAssertEqual(extracted.title, "Hello")
		XCTAssertEqual(extracted.author, "Jane Doe")
		XCTAssertEqual(extracted.content, "<p>Hi</p>")
		XCTAssertEqual(extracted.excerpt, "A summary")
		XCTAssertEqual(extracted.dek, "A summary")
		XCTAssertEqual(extracted.domain, "Example")
		XCTAssertEqual(extracted.direction, "ltr")
		XCTAssertEqual(extracted.url, "https://example.com/post")
		XCTAssertEqual(extracted.wordCount, 3)               // "Hi there friend"
	}

	func testMissingOptionalFieldsBecomeNil() throws {
		let json = #"{"content":"<p>x</p>"}"#
		let result = try decode(json)
		let extracted = result.extractedArticle(url: "https://example.com")

		XCTAssertEqual(extracted.content, "<p>x</p>")
		XCTAssertNil(extracted.author)
		XCTAssertNil(extracted.title)
		XCTAssertNil(extracted.leadImageURL)
		XCTAssertNil(extracted.datePublished)
	}

	func testNilContentWhenAbsent() throws {
		let result = try decode("{}")
		XCTAssertNil(result.content)
	}
}
```

**Step 2: Run it — expect FAIL.**

**Step 3: Implement.**

Create `Shared/Article Extractor/ReadabilityResult.swift`:

```swift
//
//  ReadabilityResult.swift
//  NetNewsWire
//
//  Decoded output of Mozilla Readability's parse(), mapped to ExtractedArticle.
//

import Foundation

struct ReadabilityResult: Codable {
	let title: String?
	let byline: String?
	let content: String?
	let textContent: String?
	let excerpt: String?
	let siteName: String?
	let dir: String?
	let lang: String?
	let length: Int?
}

extension ReadabilityResult {

	func extractedArticle(url: String) -> ExtractedArticle {
		let words = textContent?
			.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
			.count
		return ExtractedArticle(
			title: title,
			author: byline,
			datePublished: nil,
			dek: excerpt,
			leadImageURL: nil,
			content: content,
			nextPageURL: nil,
			url: url,
			domain: siteName,
			excerpt: excerpt,
			wordCount: words,
			direction: dir,
			totalPages: nil,
			renderedPages: nil
		)
	}
}
```

> If the compiler reports the `ExtractedArticle` memberwise initializer is inaccessible, add an explicit `init` to `ExtractedArticle.swift` with the same parameters (internal). Confirm by building.

**Step 4: Run the test — expect PASS (3 tests).**

**Step 5: Commit.**
```bash
git add "Shared/Article Extractor/ReadabilityResult.swift" Tests/NetNewsWireTests/ReadabilityResultTests.swift
git commit -m "Map Readability output to the extracted-article model"
```

---

## Task 3: Rewrite ArticleExtractor to run Readability in a WKWebView

**Files:**
- Modify: `Shared/Article Extractor/ArticleExtractor.swift`

Keep the public surface identical. Replace the Feedbin/URLSession internals with an offscreen `WKWebView`.

**Step 1: Replace the file body** with this implementation (preserve the existing header comment):

```swift
import Foundation
import WebKit
import Account

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

	init?(_ articleLink: String, delegate: ArticleExtractorDelegate) {
		self.articleLink = articleLink
		self.delegate = delegate
		guard let url = URL(string: articleLink), url.scheme == "http" || url.scheme == "https" else {
			return nil
		}
		self.url = url
		super.init()
	}

	func process() {
		state = .processing

		let configuration = WKWebViewConfiguration()
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

	func cancel() {
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
```

Notes for the implementer:
- `ArticleExtractor` becomes an `NSObject` subclass (required to be a `WKNavigationDelegate`). Callers don't care.
- Remove the old `Secrets` import and `import RSCore`/HMAC usage if now unused. Keep `import Account` only if still needed (it was imported before — verify it still compiles; drop it if unused).
- `UserAgent.fromInfoPlist()` lives in `RSWeb`; add `import RSWeb` if needed.
- Do not add the web view to any view hierarchy. A non-zero frame is set to help layout-dependent pages.

**Step 2: Build** (both that the module compiles): `xcodebuild build ...`. Expect `** BUILD SUCCEEDED **`. Fix compile errors only in this file (and the optional `ExtractedArticle` init from Task 2). If the `evaluateJavaScript` returns the value differently and a fix changes specified behavior, STOP and ask.

**Step 3: Run the full unit suite** — expect pass (the Readability* tests plus existing).

**Step 4: Commit.**
```bash
git add "Shared/Article Extractor/ArticleExtractor.swift" "Shared/Article Extractor/ExtractedArticle.swift"
git commit -m "Extract articles locally with Readability instead of the hosted parser"
```

---

## Task 4: Manual verification + final review

Build and run the Mac app (`/tmp/nnw-dd`, 7.1b6). With an On My Mac feed:
1. Open an article whose feed shows only a **summary/truncated** body.
2. Click the **Reader View** toolbar button (left of Share).
3. **Expected:** after a moment, the full cleaned article text appears — with **no API keys** and no Feedbin call. (Previously this did nothing.)
4. Toggle it off → returns to the original article.
5. Try an article whose link is a normal web page → full text extracts.
6. Try a bogus/unreachable link → Reader View fails gracefully (original article stays, no crash).
7. Confirm normal (non-reader) reading and link-clicking are unaffected.

Optionally confirm on iOS Simulator if convenient (shared code path).

Document results. Then dispatch a final whole-branch review and finish the branch.

---

## Notes for the implementer
- Files are target members by folder — no `project.pbxproj` edits. `ReadabilityResource.swift`, `ReadabilityResult.swift` live in `Shared/Article Extractor/` (already in both app targets); the tests in `Tests/NetNewsWireTests/`.
- The base64 string in `ReadabilityResource.swift` will be large (~140KB on one line). That's fine for the Swift compiler.
- An offscreen `WKWebView` (not in a window) loads and runs JS on modern WebKit. If `didFinish` does not fire in manual testing, the fallback is to add the web view to the window offscreen — flag it, don't guess.
- Keep the extractor's behavior on failure identical to today: `articleExtractionDidFail` → the UI keeps the original article.

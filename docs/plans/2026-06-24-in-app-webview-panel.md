# In-App Web View Panel Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** On macOS, clicking an in-content link loads the page in an in-app web view that replaces the article detail pane (with back-to-article, web back/forward, reload, address, and Open-in-Safari controls), instead of opening Safari.

**Architecture:** Add a self-contained `DetailBrowserViewController` (its own `WKWebView` + a programmatic toolbar). Intercept link clicks at the existing bottleneck in `DetailWebViewController.decidePolicyFor`, route through a pure decision function, and have `DetailViewController` swap the detail container's `contentView` between the article web view and the browser view. The article web view (and its scroll position) is never touched.

**Tech Stack:** AppKit, WebKit (`WKWebView`), Swift, XCTest. Xcode project `NetNewsWire.xcodeproj`, scheme `NetNewsWire`, test target `NetNewsWireTests`.

**Design doc:** `docs/plans/2026-06-24-in-app-webview-panel-design.md`

**Build / test commands (run from repo root):**
- Build: `xcodebuild build -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS'`
- Test: `xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS' -only-testing:NetNewsWireTests`

> Note on Xcode targets: new `.swift` files must be added to the `NetNewsWire` (Mac) app target. The decision-logic file must ALSO be added to the `NetNewsWireTests` target so tests can see it. Adding files to targets requires editing the project in Xcode (or with a tool that edits `project.pbxproj`). After creating a file, confirm target membership before building.

---

## Task 1: Pure link-routing decision function (TDD)

The one piece of logic worth unit-testing: given a URL and the click's modifier flags, decide in-app panel vs. external browser.

**Files:**
- Create: `Mac/MainWindow/Detail/LinkOpenDecision.swift`
- Test: `Tests/NetNewsWireTests/LinkOpenDecisionTests.swift`

**Step 1: Write the failing test**

Create `Tests/NetNewsWireTests/LinkOpenDecisionTests.swift`:

```swift
import XCTest
import AppKit
@testable import NetNewsWire

final class LinkOpenDecisionTests: XCTestCase {

	func testHTTPSPlainClickOpensInApp() {
		let url = URL(string: "https://example.com")!
		XCTAssertEqual(LinkOpenDecider.destination(for: url, modifierFlags: []), .inAppBrowser)
	}

	func testHTTPPlainClickOpensInApp() {
		let url = URL(string: "http://example.com")!
		XCTAssertEqual(LinkOpenDecider.destination(for: url, modifierFlags: []), .inAppBrowser)
	}

	func testCommandClickForcesExternal() {
		let url = URL(string: "https://example.com")!
		XCTAssertEqual(LinkOpenDecider.destination(for: url, modifierFlags: .command), .externalBrowser)
	}

	func testShiftClickForcesExternal() {
		let url = URL(string: "https://example.com")!
		XCTAssertEqual(LinkOpenDecider.destination(for: url, modifierFlags: .shift), .externalBrowser)
	}

	func testMailtoOpensExternal() {
		let url = URL(string: "mailto:someone@example.com")!
		XCTAssertEqual(LinkOpenDecider.destination(for: url, modifierFlags: []), .externalBrowser)
	}

	func testCustomSchemeOpensExternal() {
		let url = URL(string: "ftp://files.example.com")!
		XCTAssertEqual(LinkOpenDecider.destination(for: url, modifierFlags: []), .externalBrowser)
	}
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS' -only-testing:NetNewsWireTests/LinkOpenDecisionTests`
Expected: FAIL — `LinkOpenDecider` / `cannot find ... in scope` (type doesn't exist yet).

**Step 3: Write minimal implementation**

Create `Mac/MainWindow/Detail/LinkOpenDecision.swift`:

```swift
//
//  LinkOpenDecision.swift
//  NetNewsWire
//
//  Decides whether an in-content link click loads in the in-app web view
//  panel or hands off to the external browser.
//

import AppKit

enum LinkOpenDestination: Equatable {
	case inAppBrowser
	case externalBrowser
}

enum LinkOpenDecider {

	/// Plain clicks on http(s) links load in the in-app panel. Holding shift or
	/// command (the existing "invert open-in-browser" gesture) forces the
	/// external browser, as do non-http(s) schemes (mailto:, etc.).
	static func destination(for url: URL, modifierFlags: NSEvent.ModifierFlags) -> LinkOpenDestination {
		if modifierFlags.contains(.shift) || modifierFlags.contains(.command) {
			return .externalBrowser
		}
		guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			return .externalBrowser
		}
		return .inAppBrowser
	}
}
```

Add `LinkOpenDecision.swift` to both the `NetNewsWire` app target and the `NetNewsWireTests` target.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS' -only-testing:NetNewsWireTests/LinkOpenDecisionTests`
Expected: PASS (6 tests).

**Step 5: Commit**

```bash
git add Mac/MainWindow/Detail/LinkOpenDecision.swift Tests/NetNewsWireTests/LinkOpenDecisionTests.swift NetNewsWire.xcodeproj/project.pbxproj
git commit -m "Add link-routing decision for in-app vs external browser"
```

---

## Task 2: The browser view controller

A self-contained `WKWebView` + toolbar. No xib — built programmatically.

**Files:**
- Create: `Mac/MainWindow/Detail/DetailBrowserViewController.swift`

**Step 1: Create the file**

```swift
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
		if let userAgent = UserAgent.fromInfoPlist() {
			// match the article web view's UA handling
		}
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
		let message = error.localizedDescription
		let html = "<body style=\"font: -apple-system; color: #888; padding: 2em;\">Could not load this page.<br><br>\(message)</body>"
		webView.loadHTMLString(html, baseURL: nil)
	}
}
```

**Step 2: Add to target & build**

Add `DetailBrowserViewController.swift` to the `NetNewsWire` app target.
Run: `xcodebuild build -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add Mac/MainWindow/Detail/DetailBrowserViewController.swift NetNewsWire.xcodeproj/project.pbxproj
git commit -m "Add in-app browser view controller for the detail pane"
```

---

## Task 3: Route link clicks to the delegate

**Files:**
- Modify: `Mac/MainWindow/Detail/DetailWebViewController.swift`

**Step 1: Add the delegate method**

In the `DetailWebViewControllerDelegate` protocol (around line 16), add:

```swift
	func openInAppBrowser(_: DetailWebViewController, url: URL)
```

**Step 2: Route `.linkActivated` through the decision**

Replace the body of `webView(_:decidePolicyFor:decisionHandler:)` (around line 205) so the link case becomes:

```swift
		if navigationAction.navigationType == .linkActivated {
			if let url = navigationAction.request.url {
				switch LinkOpenDecider.destination(for: url, modifierFlags: navigationAction.modifierFlags) {
				case .inAppBrowser:
					delegate?.openInAppBrowser(self, url: url)
				case .externalBrowser:
					self.openInBrowser(url, flags: navigationAction.modifierFlags)
				}
			}
			decisionHandler(.cancel)
			return
		}
```

**Step 3: Route the `window.open` path the same way**

In `webView(_:createWebViewWith:...)` (around line 244), replace the `openInBrowser` call:

```swift
		if let url = navigationAction.request.url {
			switch LinkOpenDecider.destination(for: url, modifierFlags: navigationAction.modifierFlags) {
			case .inAppBrowser:
				delegate?.openInAppBrowser(self, url: url)
			case .externalBrowser:
				self.openInBrowser(url, flags: navigationAction.modifierFlags)
			}
		}
		return nil
```

**Step 4: Build**

Run: `xcodebuild build -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS'`
Expected: FAIL — `DetailViewController` does not yet conform to the new protocol method. That's expected; Task 4 fixes it. (If you prefer a green build between tasks, do Task 4 before building.)

**Step 5: Commit (with Task 4)** — commit Tasks 3 and 4 together so the build stays green.

---

## Task 4: Orchestrate the swap in `DetailViewController`

**Files:**
- Modify: `Mac/MainWindow/Detail/DetailViewController.swift`

**Step 1: Add browser state**

Add stored properties near the other web view controllers (around line 29):

```swift
	private lazy var browserViewController: DetailBrowserViewController = {
		let controller = DetailBrowserViewController()
		controller.delegate = self
		return controller
	}()

	private var isShowingBrowser = false
```

**Step 2: Dismiss the browser whenever the article context changes**

In `setState(_:mode:)` (around line 77), dismiss first:

```swift
	func setState(_ state: DetailState, mode: TimelineSourceMode) {
		dismissBrowserIfNeeded()
		switch mode {
		case .regular:
			detailStateForRegular = state
		case .search:
			detailStateForSearch = state
		}
	}
```

Also call `dismissBrowserIfNeeded()` at the top of `showDetail(for:)` and `createNewWebViewsAndRestoreState()`.

**Step 3: Implement the protocol method + helpers**

In the `DetailWebViewControllerDelegate` extension (around line 122), add:

```swift
	func openInAppBrowser(_ detailWebViewController: DetailWebViewController, url: URL) {
		guard detailWebViewController === currentWebViewController else {
			return
		}
		statusBarView.mouseoverLink = nil
		browserViewController.load(url)
		containerView.contentView = browserViewController.view
		isShowingBrowser = true
	}
```

Add a new extension conforming to the browser delegate:

```swift
extension DetailViewController: DetailBrowserViewControllerDelegate {

	func detailBrowserViewControllerDidRequestArticle(_ controller: DetailBrowserViewController) {
		dismissBrowserIfNeeded()
	}
}
```

In the private extension (around line 141), add:

```swift
	func dismissBrowserIfNeeded() {
		guard isShowingBrowser else {
			return
		}
		isShowingBrowser = false
		browserViewController.stopMediaPlayback()
		containerView.contentView = currentWebViewController.view
	}
```

> Note: `containerView.contentView`'s `didSet` no-ops when assigned the same view, and `currentWebViewController`'s `didSet` only updates `contentView` when it changes — so after the browser is dismissed, the article view is restored explicitly here.

**Step 4: Build**

Run: `xcodebuild build -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

**Step 5: Run the unit tests**

Run: `xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination 'platform=macOS' -only-testing:NetNewsWireTests/LinkOpenDecisionTests`
Expected: PASS.

**Step 6: Commit**

```bash
git add Mac/MainWindow/Detail/DetailWebViewController.swift Mac/MainWindow/Detail/DetailViewController.swift
git commit -m "Open in-content links in the in-app browser panel"
```

---

## Task 5: Manual verification

Build and run the Mac app, open an article with links, and confirm:

1. Plain-click an in-content link → it loads in the panel (not Safari).
2. Click links within the loaded page → **back**/**forward** enable and work.
3. **Reload** reloads the page; the address field shows the current URL.
4. **Open in Safari** hands the current URL to the default browser.
5. **‹ Article** (and **Esc**) returns to the article at its previous scroll position.
6. Selecting a different article while browsing auto-dismisses the panel.
7. ⌘-click / shift-click a link → still opens in the external browser.
8. A `mailto:` link → opens the mail client (external), not the panel.
9. A broken URL → shows the in-panel error state, not a blank trap.

Document the result. If all pass, the feature is complete.

---

## Notes for the implementer

- **Xcode target membership is the most common failure here.** A new file that compiles in isolation will still cause "cannot find type in scope" if it isn't a member of the right target. After creating each `.swift` file, verify membership (`NetNewsWire` for both new files; `NetNewsWireTests` additionally for `LinkOpenDecision.swift`).
- `UserAgent.fromInfoPlist()` is the same helper the article web view uses; reuse it so pages get NNW's user agent.
- Keep the toolbar programmatic — editing `MainWindow.storyboard`/xibs for this is unnecessary scope.

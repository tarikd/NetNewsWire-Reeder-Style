//
//  DetailViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/26/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import WebKit
import RSCore
import Articles
import RSWeb

enum DetailState: Equatable {
	case noSelection
	case multipleSelection
	case loading
	case article(Article, CGFloat?)
	case extracted(Article, ExtractedArticle, CGFloat?)
}

@MainActor protocol DetailViewControllerDelegate: AnyObject {
	func detailViewController(_: DetailViewController, didRequestInAppBrowserFor url: URL)
	func detailViewControllerDidRequestArticle(_: DetailViewController)
}

final class DetailViewController: NSViewController, WKUIDelegate {

	@IBOutlet var containerView: DetailContainerView!
	@IBOutlet var statusBarView: DetailStatusBarView!

	private lazy var regularWebViewController = createWebViewController()
	private var searchWebViewController: DetailWebViewController?

	private var browserViewController: DetailBrowserViewController?
	private var isShowingBrowser = false

	weak var delegate: DetailViewControllerDelegate?

	var windowState: DetailWindowState {
		currentWebViewController.windowState
	}

	private var currentWebViewController: DetailWebViewController! {
		didSet {
			let webview = currentWebViewController.view
			if containerView.contentView === webview {
				return
			}
			statusBarView.mouseoverLink = nil
			containerView.contentView = webview
		}
	}

	private var currentSourceMode: TimelineSourceMode = .regular {
		didSet {
			currentWebViewController = webViewController(for: currentSourceMode)
		}
	}

	private var detailStateForRegular: DetailState = .noSelection {
		didSet {
			webViewController(for: .regular).state = detailStateForRegular
		}
	}

	private var detailStateForSearch: DetailState = .noSelection {
		didSet {
			webViewController(for: .search).state = detailStateForSearch
		}
	}

	private var isArticleContentJavascriptEnabled = AppDefaults.shared.isArticleContentJavascriptEnabled

	override func viewDidLoad() {
		currentWebViewController = regularWebViewController
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?.userDefaultsDidChange()
			}
		}
	}

	// MARK: - API

	func setState(_ state: DetailState, mode: TimelineSourceMode) {
		dismissBrowserIfNeeded()
		switch mode {
		case .regular:
			detailStateForRegular = state
		case .search:
			detailStateForSearch = state
		}
	}

	func showDetail(for mode: TimelineSourceMode) {
		dismissBrowserIfNeeded()
		currentSourceMode = mode
	}

	func stopMediaPlayback() {
		currentWebViewController.stopMediaPlayback()
	}

	func canScrollDown() async -> Bool {
		await currentWebViewController.canScrollDown()
	}

	func canScrollUp() async -> Bool {
		await currentWebViewController.canScrollUp()
	}

	override func scrollPageDown(_ sender: Any?) {
		currentWebViewController.scrollPageDown(sender)
	}

	override func scrollPageUp(_ sender: Any?) {
		currentWebViewController.scrollPageUp(sender)
	}

	// MARK: - Navigation

	func focus() {
		guard let window = currentWebViewController.webView.window else {
			return
		}
		window.makeFirstResponderUnlessDescendantIsFirstResponder(currentWebViewController.webView)
	}
}

// MARK: - DetailWebViewControllerDelegate

extension DetailViewController: DetailWebViewControllerDelegate {

	func mouseDidEnter(_ detailWebViewController: DetailWebViewController, link: String) {
		guard !link.isEmpty, detailWebViewController === currentWebViewController else {
			return
		}
		statusBarView.mouseoverLink = link
	}

	func mouseDidExit(_ detailWebViewController: DetailWebViewController) {
		guard detailWebViewController === currentWebViewController else {
			return
		}
		statusBarView.mouseoverLink = nil
	}

	func openInAppBrowser(_ detailWebViewController: DetailWebViewController, url: URL) {
		guard detailWebViewController === currentWebViewController else {
			return
		}
		delegate?.detailViewController(self, didRequestInAppBrowserFor: url)
	}

	func detailWebViewController(_ detailWebViewController: DetailWebViewController, didSwipeWithDeltaX deltaX: CGFloat) {
		switch SwipeDecider.action(deltaX: deltaX, isBrowsing: isShowingBrowser) {
		case .openWeb:
			if let url = detailWebViewController.currentArticleURL {
				delegate?.detailViewController(self, didRequestInAppBrowserFor: url)
			}
		case .returnToArticle:
			if let delegate {
				delegate.detailViewControllerDidRequestArticle(self)
			} else {
				dismissBrowser()
			}
		case .ignore:
			break
		}
	}
}

// MARK: - Browser

extension DetailViewController {

	var isBrowsing: Bool { isShowingBrowser }
	var browserCanGoBack: Bool { browserViewController?.canGoBack ?? false }
	var browserCanGoForward: Bool { browserViewController?.canGoForward ?? false }
	func browserGoBack() { browserViewController?.goBack() }
	func browserGoForward() { browserViewController?.goForward() }
	func browserReload() { browserViewController?.reload() }
	func browserOpenInDefaultBrowser() { browserViewController?.openInDefaultBrowser() }

	func showBrowser(url: URL) {
		statusBarView.mouseoverLink = nil
		let controller = DetailBrowserViewController()
		controller.delegate = self
		browserViewController = controller
		containerView.contentView = controller.view   // realize the view before load
		controller.load(url)
		controller.focusWebView()
		isShowingBrowser = true
	}

	func dismissBrowser() {
		guard isShowingBrowser else {
			return
		}
		isShowingBrowser = false
		browserViewController?.stopMediaPlayback()
		browserViewController = nil
		containerView.contentView = currentWebViewController.view
		focus()
	}
}

// MARK: - DetailBrowserViewControllerDelegate

extension DetailViewController: DetailBrowserViewControllerDelegate {

	func detailBrowserViewControllerDidRequestArticle(_ controller: DetailBrowserViewController) {
		if let delegate {
			delegate.detailViewControllerDidRequestArticle(self)
		} else {
			dismissBrowser()
		}
	}
}

// MARK: - Private

private extension DetailViewController {

	func dismissBrowserIfNeeded() {
		guard isShowingBrowser else {
			return
		}
		if let delegate {
			delegate.detailViewControllerDidRequestArticle(self)
		} else {
			dismissBrowser()
		}
	}

	func createWebViewController() -> DetailWebViewController {
		let controller = DetailWebViewController()
		controller.delegate = self
		controller.state = .noSelection
		return controller
	}

	func webViewController(for mode: TimelineSourceMode) -> DetailWebViewController {
		switch mode {
		case .regular:
			return regularWebViewController
		case .search:
			if searchWebViewController == nil {
				searchWebViewController = createWebViewController()
			}
			return searchWebViewController!
		}
	}

	func userDefaultsDidChange() {
		if AppDefaults.shared.isArticleContentJavascriptEnabled != isArticleContentJavascriptEnabled {
			isArticleContentJavascriptEnabled = AppDefaults.shared.isArticleContentJavascriptEnabled
			createNewWebViewsAndRestoreState()
		}
	}

	func createNewWebViewsAndRestoreState() {
		dismissBrowserIfNeeded()

		regularWebViewController = createWebViewController()
		currentWebViewController = regularWebViewController
		regularWebViewController.state = detailStateForRegular

		searchWebViewController = nil

		if currentSourceMode == .search {
			searchWebViewController = createWebViewController()
			currentWebViewController = searchWebViewController
			searchWebViewController!.state = detailStateForSearch
		}
	}
}

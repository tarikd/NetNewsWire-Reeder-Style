//
//  DetailStateExtractionFailureTests.swift
//  NetNewsWire
//
//  Tests for what the detail pane shows once Reader View extraction fails.
//

import Articles
import Foundation
import XCTest

@testable import NetNewsWire

@MainActor final class DetailStateExtractionFailureTests: XCTestCase {

	func testLoadingFallsBackToTheFeedArticle() {
		let article = makeArticle("1")
		XCTAssertEqual(DetailState.loading.afterExtractionFailure(for: article, scrollY: 120), .article(article, 120))
	}

	func testArticleAlreadyShowingIsLeftAlone() {
		let article = makeArticle("1")
		let state = DetailState.article(article, 300)
		XCTAssertEqual(state.afterExtractionFailure(for: article, scrollY: nil), state)
	}

	func testStatesWithoutASingleArticleAreLeftAlone() {
		let article = makeArticle("1")
		XCTAssertEqual(DetailState.noSelection.afterExtractionFailure(for: article, scrollY: nil), .noSelection)
		XCTAssertEqual(DetailState.multipleSelection.afterExtractionFailure(for: article, scrollY: nil), .multipleSelection)
	}
}

@MainActor private func makeArticle(_ articleID: String) -> Article {
	let date = Date()
	return Article(accountID: "test-account",
				   articleID: articleID,
				   feedID: "feed",
				   uniqueID: articleID,
				   title: nil,
				   contentHTML: nil,
				   contentText: nil,
				   markdown: nil,
				   url: nil,
				   externalURL: nil,
				   summary: nil,
				   imageURL: nil,
				   thumbnailURL: nil,
				   datePublished: date,
				   dateModified: nil,
				   authors: nil,
				   attachments: nil,
				   status: ArticleStatus(articleID: articleID, read: false, starred: false, dateArrived: date))
}

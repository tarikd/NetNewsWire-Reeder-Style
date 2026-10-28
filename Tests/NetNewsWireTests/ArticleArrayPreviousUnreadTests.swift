//
//  ArticleArrayPreviousUnreadTests.swift
//  NetNewsWire
//
//  Tests for rowOfPreviousUnreadArticle.
//

import Articles
import Foundation
import XCTest

@testable import NetNewsWire

@MainActor final class ArticleArrayPreviousUnreadTests: XCTestCase {

	func testEmptyArrayReturnsNil() {
		let articles: ArticleArray = []
		XCTAssertNil(articles.rowOfPreviousUnreadArticle(0))
	}

	func testNoPreviousUnreadWhenAtFirstRow() {
		let articles = [makeArticle("1", read: false), makeArticle("2", read: false)]
		// Starting at row 0, there is nothing before it.
		XCTAssertNil(articles.rowOfPreviousUnreadArticle(0))
	}

	func testFindsNearestUnreadAboveSelection() {
		let articles = [
			makeArticle("0", read: false),
			makeArticle("1", read: true),
			makeArticle("2", read: false),
			makeArticle("3", read: true)
		]
		// Selected row 3: nearest unread above is row 2.
		XCTAssertEqual(articles.rowOfPreviousUnreadArticle(3), 2)
	}

	func testSkipsReadArticlesGoingBackward() {
		let articles = [
			makeArticle("0", read: false),
			makeArticle("1", read: true),
			makeArticle("2", read: true),
			makeArticle("3", read: true)
		]
		// Selected row 3: skips read rows 2 and 1, lands on unread row 0.
		XCTAssertEqual(articles.rowOfPreviousUnreadArticle(3), 0)
	}

	func testReturnsNilWhenAllPreviousAreRead() {
		let articles = [
			makeArticle("0", read: true),
			makeArticle("1", read: true),
			makeArticle("2", read: false)
		]
		// Selected row 2: everything above is read, so no previous unread.
		XCTAssertNil(articles.rowOfPreviousUnreadArticle(2))
	}

	func testDoesNotWrapAround() {
		let articles = [
			makeArticle("0", read: true),
			makeArticle("1", read: true),
			makeArticle("2", read: false),
			makeArticle("3", read: false)
		]
		// Selected row 1: only row 0 is above and it is read; the unread rows
		// below (2, 3) must not be reached.
		XCTAssertNil(articles.rowOfPreviousUnreadArticle(1))
	}

	func testSelectedRowBeyondCountClampsToCount() {
		let articles = [
			makeArticle("0", read: false),
			makeArticle("1", read: true)
		]
		// No selection (-1) behaves like nothing-before, returns nil.
		XCTAssertNil(articles.rowOfPreviousUnreadArticle(-1))
		// A selection at/after the end searches from the last row backward.
		XCTAssertEqual(articles.rowOfPreviousUnreadArticle(articles.count), 0)
	}

}

// MARK: - Helpers

@MainActor private func makeArticle(_ articleID: String, read: Bool) -> Article {
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
				   status: ArticleStatus(articleID: articleID, read: read, starred: false, dateArrived: date))
}

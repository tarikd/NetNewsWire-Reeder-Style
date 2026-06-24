import XCTest
@testable import NetNewsWire

final class ArticleExtractorSiteRulesTests: XCTestCase {

	func testLeMondeHasJunkAndContentSelectors() {
		XCTAssertTrue(ArticleExtractor.siteJunkSelectors(forHost: "www.lemonde.fr").contains(".ds-burger-popin"))
		XCTAssertEqual(ArticleExtractor.siteContentSelector(forHost: "www.lemonde.fr"), "article.article__content")
	}

	func testLeMondeRulesAreCaseInsensitiveAndApexHost() {
		XCTAssertFalse(ArticleExtractor.siteJunkSelectors(forHost: "LeMonde.fr").isEmpty)
		XCTAssertNotNil(ArticleExtractor.siteContentSelector(forHost: "lemonde.fr"))
	}

	func testUnknownHostHasNoSiteRules() {
		XCTAssertTrue(ArticleExtractor.siteJunkSelectors(forHost: "www.yabiladi.com").isEmpty)
		XCTAssertNil(ArticleExtractor.siteContentSelector(forHost: "www.yabiladi.com"))
	}

	func testBaseJunkSelectorsCoverConsentAndNav() {
		XCTAssertTrue(ArticleExtractor.baseJunkSelectors.contains("nav"))
		XCTAssertTrue(ArticleExtractor.baseJunkSelectors.contains(where: { $0.contains("consent") }))
	}
}

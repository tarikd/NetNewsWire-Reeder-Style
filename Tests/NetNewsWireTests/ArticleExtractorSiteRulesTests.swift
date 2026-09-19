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

	func testMediapartIsolatesArticleContainer() {
		XCTAssertEqual(ArticleExtractor.siteContentSelector(forHost: "www.mediapart.fr"), ".news__body__center__article")
	}

	func testLesEchosIsolatesArticleContainerDespitePaywallJunkRule() {
		// `.post-paywall` matches the generic [class*="paywall"] junk selector, so
		// without a whitelist entry the article body is stripped before Readability
		// scores the page.
		XCTAssertEqual(ArticleExtractor.siteContentSelector(forHost: "www.lesechos.fr"), ".post-paywall")
		XCTAssertEqual(ArticleExtractor.siteContentSelector(forHost: "lesechos.fr"), ".post-paywall")
	}

	func testArsTechnicaIsolatesPostContentAndStripsInBodyJunk() {
		XCTAssertEqual(ArticleExtractor.siteContentSelector(forHost: "arstechnica.com"), ".post-content")
		let junk = ArticleExtractor.siteJunkSelectors(forHost: "www.arstechnica.com")
		XCTAssertTrue(junk.contains(".ars-interlude-container"))
		XCTAssertTrue(junk.contains(".ad"))
		XCTAssertTrue(junk.contains(".post-navigation"))
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

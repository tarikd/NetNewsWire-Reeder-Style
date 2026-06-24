import XCTest
@testable import NetNewsWire

final class ReadabilityResourceTests: XCTestCase {

	func testJavaScriptDecodesAndDefinesReadability() {
		let js = ReadabilityResource.javaScript
		XCTAssertGreaterThan(js.count, 1000)
		XCTAssertTrue(js.contains("Readability"))
		XCTAssertTrue(js.contains("parse"))
	}
}

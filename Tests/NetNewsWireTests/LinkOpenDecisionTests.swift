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

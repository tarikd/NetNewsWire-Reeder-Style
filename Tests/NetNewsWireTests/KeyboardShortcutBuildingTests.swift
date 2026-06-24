import XCTest
import RSCore
@testable import NetNewsWire

final class KeyboardShortcutBuildingTests: XCTestCase {
	func testBuildShortcutFromKey() {
		let key = KeyboardKey(integerValue: Int(Character("n").asciiValue!), shiftKeyDown: false, optionKeyDown: false, commandKeyDown: true, controlKeyDown: false)
		let shortcut = KeyboardShortcut(key: key, actionString: "nextUnread:")
		XCTAssertEqual(shortcut.actionString, "nextUnread:")
		XCTAssertEqual(shortcut.key, key)
		XCTAssertTrue(key.commandKeyDown)
	}
}

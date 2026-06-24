import XCTest
import RSCore
@testable import NetNewsWire

@MainActor
final class KeyboardShortcutStorePersistenceTests: XCTestCase {

	private let suiteName = "KeyboardShortcutStoreTests"

	// Fresh defaults isolated to a throwaway suite, so .standard is never touched.
	private func makeDefaults() -> UserDefaults {
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return defaults
	}

	private func cleanUp(_ defaults: UserDefaults) {
		defaults.removePersistentDomain(forName: suiteName)
	}

	private func key(_ i: Int) -> KeyboardKey {
		KeyboardKey(integerValue: i, shiftKeyDown: false, optionKeyDown: false, commandKeyDown: false, controlKeyDown: false)
	}

	// Pick a real action from the global plist defaults to exercise the persisted path.
	private func firstGlobalAction(_ store: KeyboardShortcutStore) -> String? {
		store.commands(for: .global).first?.action
	}

	func testSetBindingPersistsAndReloads() throws {
		let defaults = makeDefaults()
		defer { cleanUp(defaults) }
		let store = KeyboardShortcutStore(userDefaults: defaults)

		let action = try XCTUnwrap(firstGlobalAction(store))
		store.setBinding(key(106 /* j */), forAction: action, in: .global)   // must not crash
		// Reload via a fresh store on the same defaults.
		let reloaded = KeyboardShortcutStore(userDefaults: defaults)
		let cmd = reloaded.commands(for: .global).first { $0.action == action }
		XCTAssertEqual(cmd?.currentKey, key(106))
	}

	func testClearBindingPersistsUnboundWithoutCrash() throws {
		let defaults = makeDefaults()
		defer { cleanUp(defaults) }
		let store = KeyboardShortcutStore(userDefaults: defaults)

		let action = try XCTUnwrap(firstGlobalAction(store))
		store.clearBinding(forAction: action, in: .global)   // must NOT crash (was NSNull)
		let reloaded = KeyboardShortcutStore(userDefaults: defaults)
		let cmd = reloaded.commands(for: .global).first { $0.action == action }
		XCTAssertNil(cmd?.currentKey)   // explicitly unbound, not the default
	}

	func testRestoreDefaultsClearsOverrides() throws {
		let defaults = makeDefaults()
		defer { cleanUp(defaults) }
		let store = KeyboardShortcutStore(userDefaults: defaults)

		let action = try XCTUnwrap(firstGlobalAction(store))
		store.clearBinding(forAction: action, in: .global)
		store.restoreDefaults()
		let cmd = store.commands(for: .global).first { $0.action == action }
		XCTAssertNotNil(cmd?.currentKey)   // back to a default binding
	}
}

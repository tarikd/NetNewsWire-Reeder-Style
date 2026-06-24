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

	func testSetBindingResolvesCrossContextConflict() throws {
		let defaults = makeDefaults()
		defer { cleanUp(defaults) }
		let store = KeyboardShortcutStore(userDefaults: defaults)

		let globalAction = try XCTUnwrap(firstGlobalAction(store))
		let timelineAction = try XCTUnwrap(store.commands(for: .timeline).first?.action)

		// Bind a key in .global, then steal the SAME key for a .timeline action.
		store.setBinding(key(106 /* j */), forAction: globalAction, in: .global)
		let reassigned = store.setBinding(key(106), forAction: timelineAction, in: .timeline)

		// The global binding must have been unbound, and the user told about the reassignment.
		XCTAssertNotNil(reassigned)
		let globalCmd = store.commands(for: .global).first { $0.action == globalAction }
		XCTAssertNil(globalCmd?.currentKey)
		let timelineCmd = store.commands(for: .timeline).first { $0.action == timelineAction }
		XCTAssertEqual(timelineCmd?.currentKey, key(106))
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

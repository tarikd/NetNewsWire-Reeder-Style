//
//  SidebarKeyboardDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 12/19/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import AppKit
import RSCore

@objc final class SidebarKeyboardDelegate: NSObject, KeyboardDelegate {

	@IBOutlet var sidebarViewController: SidebarViewController?

	func keydown(_ event: NSEvent, in view: NSView) -> Bool {

		if MainWindowKeyboardHandler.shared.keydown(event, in: view) {
			return true
		}

		let key = KeyboardKey(with: event)
		let shortcuts = KeyboardShortcutStore.shared.effectiveShortcuts(for: .sidebar)
		if let matchingShortcut = KeyboardShortcut.findMatchingShortcut(in: shortcuts, key: key) {
			matchingShortcut.perform(with: view)
			return true
		}

		// Fall through to article-list navigation so commands like "Select Next
		// Article" work right after picking a feed, while the sidebar still has focus.
		return MainWindowKeyboardHandler.shared.timelineFallthrough(event, in: view)
	}
}

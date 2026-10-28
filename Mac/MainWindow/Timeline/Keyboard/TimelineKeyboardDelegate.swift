//
//  TimelineKeyboardDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 12/19/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import AppKit
import RSCore

// Doesn’t have any shortcuts of its own — they’re all in MainWindowKeyboardHandler.

@objc final class TimelineKeyboardDelegate: NSObject, KeyboardDelegate {

	func keydown(_ event: NSEvent, in view: NSView) -> Bool {

		if MainWindowKeyboardHandler.shared.keydown(event, in: view) {
			return true
		}

		let key = KeyboardKey(with: event)
		let shortcuts = KeyboardShortcutStore.shared.effectiveShortcuts(for: .timeline)
		guard let matchingShortcut = KeyboardShortcut.findMatchingShortcut(in: shortcuts, key: key) else {
			return false
		}

		matchingShortcut.perform(with: view)
		return true
	}
}

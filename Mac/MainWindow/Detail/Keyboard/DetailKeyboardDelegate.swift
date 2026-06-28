//
//  DetailKeyboardDelegate.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 3/1/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import AppKit
import RSCore

@objc final class DetailKeyboardDelegate: NSObject, KeyboardDelegate {

	func keydown(_ event: NSEvent, in view: NSView) -> Bool {

		if MainWindowKeyboardHandler.shared.keydown(event, in: view) {
			return true
		}

		let key = KeyboardKey(with: event)
		let shortcuts = KeyboardShortcutStore.shared.effectiveShortcuts(for: .detail)
		if let matchingShortcut = KeyboardShortcut.findMatchingShortcut(in: shortcuts, key: key) {
			matchingShortcut.perform(with: view)
			return true
		}

		// Fall through to article-list navigation so commands like "Select Next
		// Article" work while reading an article (the detail view has focus).
		return MainWindowKeyboardHandler.shared.timelineFallthrough(event, in: view)
	}
}

//
//  MainWindowKeyboardHandler.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 12/19/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import AppKit
import RSCore

@MainActor final class MainWindowKeyboardHandler: KeyboardDelegate {
	static let shared = MainWindowKeyboardHandler()

	func keydown(_ event: NSEvent, in view: NSView) -> Bool {
		let key = KeyboardKey(with: event)
		let shortcuts = KeyboardShortcutStore.shared.effectiveShortcuts(for: .global)
		guard let matchingShortcut = KeyboardShortcut.findMatchingShortcut(in: shortcuts, key: key) else {
			return false
		}

		matchingShortcut.perform(with: view)
		return true
	}

	/// Dispatches Timeline-context shortcuts even when the timeline isn't the first
	/// responder, so article-list navigation (e.g. Select Next Article) works no
	/// matter which pane has focus. Arrow keys are skipped so each pane keeps its
	/// own native arrow behavior (sidebar feed navigation, article scrolling).
	/// Other contexts call this after checking their own shortcuts.
	func timelineFallthrough(_ event: NSEvent, in view: NSView) -> Bool {
		let key = KeyboardKey(with: event)
		guard !key.isArrowKey else {
			return false
		}
		let shortcuts = KeyboardShortcutStore.shared.effectiveShortcuts(for: .timeline)
		guard let matchingShortcut = KeyboardShortcut.findMatchingShortcut(in: shortcuts, key: key) else {
			return false
		}
		matchingShortcut.perform(with: view)
		return true
	}
}

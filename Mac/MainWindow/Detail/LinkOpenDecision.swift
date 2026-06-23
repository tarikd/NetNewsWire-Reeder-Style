//
//  LinkOpenDecision.swift
//  NetNewsWire
//
//  Decides whether an in-content link click loads in the in-app web view
//  panel or hands off to the external browser.
//

import AppKit

enum LinkOpenDestination: Equatable {
	case inAppBrowser
	case externalBrowser
}

enum LinkOpenDecider {

	/// Plain clicks on http(s) links load in the in-app panel. Holding shift or
	/// command (the existing "invert open-in-browser" gesture) forces the
	/// external browser, as do non-http(s) schemes (mailto:, etc.).
	static func destination(for url: URL, modifierFlags: NSEvent.ModifierFlags) -> LinkOpenDestination {
		if modifierFlags.contains(.shift) || modifierFlags.contains(.command) {
			return .externalBrowser
		}
		guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			return .externalBrowser
		}
		return .inAppBrowser
	}
}

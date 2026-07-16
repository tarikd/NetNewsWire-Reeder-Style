//
//  EditableFocusTracker.swift
//  NetNewsWire
//
//  Tracks whether an editable element (text field, textarea, or contentEditable)
//  inside a web view currently has focus, so keyboard shortcuts don't fire while
//  the user is typing into a form field on a page.
//

import Foundation
import WebKit

enum EditableFocusTracker {

	/// Script-message name a page uses to report editable-focus changes.
	/// The message body is a `Bool`: `true` when an editable element has focus.
	static let messageName = "editableFocusStateDidChange"

	/// A user script that reports (via `messageName`) whether an editable element
	/// currently has focus. Injected into all frames so forms embedded in
	/// subframes (comments, logins) are handled too.
	@MainActor static func userScript() -> WKUserScript {
		WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
	}

	private static let source = """
	(function() {
		var messageHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editableFocusStateDidChange;
		if (!messageHandler) {
			return;
		}

		function isEditableElement(element) {
			if (!element) {
				return false;
			}
			if (element.isContentEditable) {
				return true;
			}
			var tagName = element.tagName;
			if (tagName === "TEXTAREA") {
				return true;
			}
			if (tagName === "INPUT") {
				var type = (element.type || "text").toLowerCase();
				var nonEditableTypes = ["button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"];
				return nonEditableTypes.indexOf(type) === -1;
			}
			return false;
		}

		function isFrameElement(element) {
			if (!element) {
				return false;
			}
			var tagName = element.tagName;
			return tagName === "IFRAME" || tagName === "FRAME";
		}

		document.addEventListener("focusin", function(event) {
			// Focus entering a subframe: that frame's own script is authoritative.
			if (isFrameElement(event.target)) {
				return;
			}
			messageHandler.postMessage(isEditableElement(event.target));
		}, true);

		document.addEventListener("focusout", function(event) {
			// relatedTarget is where focus is heading; null means focus left this
			// document. Let the destination (e.g. a subframe) report its own state.
			if (isFrameElement(event.relatedTarget)) {
				return;
			}
			messageHandler.postMessage(isEditableElement(event.relatedTarget));
		}, true);
	})();
	"""
}

/// Weakly wraps a `WKScriptMessageHandler` so a user-content controller doesn't
/// create a retain cycle with the view controller that owns the web view.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {

	private weak var handler: WKScriptMessageHandler?

	init(_ handler: WKScriptMessageHandler) {
		self.handler = handler
	}

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		handler?.userContentController(userContentController, didReceive: message)
	}
}

//
//  TimelineScrollView.swift
//  NetNewsWire
//
//  Created by NetNewsWire on 7/11/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import AppKit

/// The timeline must never magnify. With a very tall document view (a feed with
/// many articles), live-resizing the timeline pane — for example when the detail
/// webview opens or closes — can make AppKit engage a bogus, asymmetric
/// magnification on the scroll view. That renders the whole timeline hugely
/// stretched and distorted even though the fonts and row heights are unchanged.
///
/// `allowsMagnification` only gates user pinch gestures, so it does not prevent
/// this internal path. This subclass hard-pins magnification to 1.0: it refuses
/// any attempt to change it and re-asserts 1.0 on every layout pass.
final class TimelineScrollView: NSScrollView {

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		pinMagnification()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		pinMagnification()
	}

	override var magnification: CGFloat {
		get {
			return super.magnification
		}
		set {
			// The timeline must never magnify: pin every requested value to 1.0.
			if newValue != 1.0 {
				super.magnification = 1.0
			} else {
				super.magnification = newValue
			}
		}
	}

	override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
		super.setMagnification(1.0, centeredAt: point)
	}

	override func magnify(with event: NSEvent) {
		// Ignore pinch magnification entirely.
	}

	override func smartMagnify(with event: NSEvent) {
		// Ignore two-finger double-tap magnification entirely.
	}

	override func tile() {
		pinMagnification()
		super.tile()
	}

	private func pinMagnification() {
		if super.allowsMagnification {
			super.allowsMagnification = false
		}
		if super.magnification != 1.0 {
			super.magnification = 1.0
		}
	}
}

//
//  MarkAllAsReadConfirmationView.swift
//  NetNewsWire
//
//  A banner that slides down over the top of the timeline column to confirm a
//  "mark all as read" action. Cancel is the default choice, so an accidental
//  Return or Esc never wipes the list.
//

import AppKit

final class MarkAllAsReadConfirmationView: NSVisualEffectView {

	private let confirmHandler: () -> Void
	private let cancelHandler: () -> Void

	init(confirmHandler: @escaping () -> Void, cancelHandler: @escaping () -> Void) {
		self.confirmHandler = confirmHandler
		self.cancelHandler = cancelHandler
		super.init(frame: .zero)
		setUpView()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var acceptsFirstResponder: Bool {
		return true
	}

	// Esc cancels.
	override func cancelOperation(_ sender: Any?) {
		cancelHandler()
	}

	private func setUpView() {
		translatesAutoresizingMaskIntoConstraints = false
		material = .headerView
		blendingMode = .withinWindow
		state = .active

		let label = NSTextField(labelWithString: NSLocalizedString("Mark all as read?", comment: "Mark all as read confirmation prompt"))
		label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		label.translatesAutoresizingMaskIntoConstraints = false

		let confirmButton = NSButton(title: NSLocalizedString("Mark All as Read", comment: "Mark All as Read"), target: self, action: #selector(confirm(_:)))
		confirmButton.bezelStyle = .rounded
		confirmButton.translatesAutoresizingMaskIntoConstraints = false

		let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Cancel"), target: self, action: #selector(cancel(_:)))
		cancelButton.bezelStyle = .rounded
		cancelButton.keyEquivalent = "\r" // Default button — Return cancels, the safe choice.
		cancelButton.translatesAutoresizingMaskIntoConstraints = false

		let buttonStack = NSStackView(views: [confirmButton, cancelButton])
		buttonStack.orientation = .horizontal
		buttonStack.spacing = 8
		buttonStack.translatesAutoresizingMaskIntoConstraints = false

		let border = NSBox()
		border.boxType = .separator
		border.translatesAutoresizingMaskIntoConstraints = false

		addSubview(label)
		addSubview(buttonStack)
		addSubview(border)

		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
			label.centerYAnchor.constraint(equalTo: centerYAnchor),

			buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
			buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
			buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),

			border.leadingAnchor.constraint(equalTo: leadingAnchor),
			border.trailingAnchor.constraint(equalTo: trailingAnchor),
			border.bottomAnchor.constraint(equalTo: bottomAnchor),
			border.heightAnchor.constraint(equalToConstant: 1)
		])
	}

	@objc private func confirm(_ sender: Any?) {
		confirmHandler()
	}

	@objc private func cancel(_ sender: Any?) {
		cancelHandler()
	}
}

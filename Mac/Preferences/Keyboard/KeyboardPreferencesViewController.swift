//
//  KeyboardPreferencesViewController.swift
//  NetNewsWire
//
//  Programmatic preferences pane that lists reading/navigation commands in a tab
//  per context and lets the user remap, clear, or restore keyboard shortcuts.
//

import AppKit
import RSCore

/// A top-anchored document view for the scroll views (AppKit views are
/// bottom-anchored by default, which pinned the rows to the bottom).
private final class FlippedView: NSView {
	override var isFlipped: Bool { true }
}

@MainActor final class KeyboardPreferencesViewController: NSViewController {

	private let store = KeyboardShortcutStore.shared
	private let tabView = NSTabView()
	private let statusLabel = NSTextField(labelWithString: "")
	private nonisolated(unsafe) var changeObserver: NSObjectProtocol?

	// The vertical stack of rows for each context, keyed so we can rebuild any tab.
	private var rowStacks: [KeyboardShortcutStore.Context: NSStackView] = [:]

	private let titleColumnWidth = CGFloat(220.0)
	private let preferredWidth = CGFloat(512.0)

	deinit {
		if let changeObserver {
			NotificationCenter.default.removeObserver(changeObserver)
		}
	}

	override func loadView() {
		let rootView = NSView(frame: NSRect(x: 0, y: 0, width: preferredWidth, height: 480.0))

		tabView.translatesAutoresizingMaskIntoConstraints = false
		for context in KeyboardShortcutStore.Context.allCases {
			tabView.addTabViewItem(makeTab(for: context))
		}

		statusLabel.translatesAutoresizingMaskIntoConstraints = false
		statusLabel.textColor = .secondaryLabelColor
		statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		statusLabel.lineBreakMode = .byTruncatingTail
		statusLabel.stringValue = ""

		let restoreButton = NSButton(title: NSLocalizedString("Restore Defaults", comment: "Keyboard preferences"),
									 target: self,
									 action: #selector(restoreDefaults(_:)))
		restoreButton.bezelStyle = .rounded
		restoreButton.translatesAutoresizingMaskIntoConstraints = false

		let bottomBar = NSStackView(views: [statusLabel, NSView(), restoreButton])
		bottomBar.orientation = .horizontal
		bottomBar.alignment = .centerY
		bottomBar.spacing = 8.0
		bottomBar.translatesAutoresizingMaskIntoConstraints = false

		rootView.addSubview(tabView)
		rootView.addSubview(bottomBar)

		NSLayoutConstraint.activate([
			tabView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12.0),
			tabView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12.0),
			tabView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12.0),

			bottomBar.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 8.0),
			bottomBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20.0),
			bottomBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20.0),
			bottomBar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16.0)
		])

		self.view = rootView

		changeObserver = NotificationCenter.default.addObserver(forName: KeyboardShortcutStore.didChangeNotification,
																object: nil,
																queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.reload()
			}
		}

		reload()
	}

	// MARK: - Tabs

	private func makeTab(for context: KeyboardShortcutStore.Context) -> NSTabViewItem {
		let scrollView = NSScrollView()
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = false
		scrollView.autohidesScrollers = true

		let rowStack = NSStackView()
		rowStack.orientation = .vertical
		rowStack.alignment = .leading
		rowStack.spacing = 6.0
		rowStack.translatesAutoresizingMaskIntoConstraints = false
		rowStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
		rowStacks[context] = rowStack

		let documentView = FlippedView()   // flipped so rows lay out from the top, not the bottom
		documentView.translatesAutoresizingMaskIntoConstraints = false
		documentView.addSubview(rowStack)
		scrollView.documentView = documentView

		// The tab item's view must size itself to the tab. A plain NSView using
		// autoresizing fills the tab content rect; the scroll view is then pinned
		// inside it with constraints. (Putting the scroll view directly as the
		// item view with translatesAutoresizingMaskIntoConstraints = false left it
		// zero-sized on tabs that aren't shown first.)
		let container = NSView(frame: NSRect(x: 0, y: 0, width: preferredWidth, height: 440.0))
		container.autoresizingMask = [.width, .height]
		container.addSubview(scrollView)

		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: container.topAnchor),
			scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

			documentView.topAnchor.constraint(equalTo: rowStack.topAnchor),
			documentView.bottomAnchor.constraint(equalTo: rowStack.bottomAnchor),
			documentView.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor),
			documentView.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor),
			documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
		])

		let item = NSTabViewItem(identifier: context.rawValue)
		item.label = context.displayName
		item.view = container
		return item
	}

	// MARK: - Actions

	@objc private func restoreDefaults(_ sender: Any?) {
		clearStatus()
		store.restoreDefaults()
		reload()
	}

	@objc private func clearBinding(_ sender: NSButton) {
		guard let identifier = sender.identifier?.rawValue,
			  let (context, action) = decode(identifier) else { return }
		clearStatus()
		store.clearBinding(forAction: action, in: context)
		reload()
	}

	/// Show a small warning (beep + orange note) when a binding took a key from
	/// another command; otherwise clear the status line.
	private func showConflict(_ reassignedTitle: String?) {
		guard let reassignedTitle else {
			statusLabel.stringValue = ""
			return
		}
		NSSound.beep()
		let format = NSLocalizedString("⚠ Reassigned from “%@”", comment: "Keyboard preferences conflict")
		statusLabel.textColor = .systemOrange
		statusLabel.stringValue = String(format: format, reassignedTitle)
	}

	private func clearStatus() {
		statusLabel.textColor = .secondaryLabelColor
		statusLabel.stringValue = ""
	}

	// MARK: - Building rows

	private func reload() {
		for context in KeyboardShortcutStore.Context.allCases {
			guard let rowStack = rowStacks[context] else { continue }

			for view in rowStack.arrangedSubviews {
				rowStack.removeArrangedSubview(view)
				view.removeFromSuperview()
			}

			for command in dedupedCommands(for: context) {
				rowStack.addArrangedSubview(makeRow(for: command, in: context))
			}
		}
	}

	// Dedupe by action, keeping the first command per action.
	private func dedupedCommands(for context: KeyboardShortcutStore.Context) -> [KeyboardShortcutStore.Command] {
		var seen = Set<String>()
		var result = [KeyboardShortcutStore.Command]()
		for command in store.commands(for: context) where !seen.contains(command.action) {
			seen.insert(command.action)
			result.append(command)
		}
		return result
	}

	private func makeRow(for command: KeyboardShortcutStore.Command,
						 in context: KeyboardShortcutStore.Context) -> NSView {
		let titleLabel = NSTextField(labelWithString: command.title)
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.translatesAutoresizingMaskIntoConstraints = false
		titleLabel.widthAnchor.constraint(equalToConstant: titleColumnWidth).isActive = true

		let recorder = ShortcutRecorderView()
		recorder.translatesAutoresizingMaskIntoConstraints = false
		recorder.key = command.currentKey
		let action = command.action
		recorder.onRecord = { [weak self] key in
			guard let self else { return }
			let reassigned = self.store.setBinding(key, forAction: action, in: context)
			self.showConflict(reassigned)
			self.reload()
		}

		let clearButton = NSButton(title: "✕", target: self, action: #selector(clearBinding(_:)))
		clearButton.bezelStyle = .inline
		clearButton.isBordered = false
		clearButton.identifier = NSUserInterfaceItemIdentifier(encode(context: context, action: command.action))
		clearButton.translatesAutoresizingMaskIntoConstraints = false
		clearButton.toolTip = NSLocalizedString("Clear shortcut", comment: "Keyboard preferences")

		let row = NSStackView(views: [titleLabel, recorder, clearButton])
		row.orientation = .horizontal
		row.alignment = .centerY
		row.spacing = 8.0
		return row
	}

	// MARK: - Identifier encoding for the clear button

	private func encode(context: KeyboardShortcutStore.Context, action: String) -> String {
		return "\(context.rawValue)\t\(action)"
	}

	private func decode(_ identifier: String) -> (KeyboardShortcutStore.Context, String)? {
		let parts = identifier.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
		guard parts.count == 2, let context = KeyboardShortcutStore.Context(rawValue: String(parts[0])) else {
			return nil
		}
		return (context, String(parts[1]))
	}
}

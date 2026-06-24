import AppKit
import RSCore

@MainActor final class KeyboardShortcutStore {

	static let shared = KeyboardShortcutStore()

	private let userDefaults: UserDefaults

	init(userDefaults: UserDefaults = .standard) {
		self.userDefaults = userDefaults
	}

	enum Context: String, CaseIterable {
		case global, sidebar, timeline, detail
		var plistName: String {
			switch self {
			case .global: return "GlobalKeyboardShortcuts"
			case .sidebar: return "SidebarKeyboardShortcuts"
			case .timeline: return "TimelineKeyboardShortcuts"
			case .detail: return "DetailKeyboardShortcuts"
			}
		}
		var displayName: String {
			switch self {
			case .global: return NSLocalizedString("Everywhere", comment: "Keyboard context")
			case .sidebar: return NSLocalizedString("Sidebar", comment: "Keyboard context")
			case .timeline: return NSLocalizedString("Timeline", comment: "Keyboard context")
			case .detail: return NSLocalizedString("Article", comment: "Keyboard context")
			}
		}
	}

	struct Command: Equatable {
		let title: String
		let action: String
		let defaultKey: KeyboardKey
		var currentKey: KeyboardKey?   // nil == unbound
	}

	static let didChangeNotification = Notification.Name("KeyboardShortcutsDidChange")
	private static let defaultsKey = "userKeyboardShortcuts"

	private var cache: [Context: [Command]] = [:]

	// PURE: present key (even nil value) means user override; absent means default.
	nonisolated static func mergedCommands(defaults: [Command], overrides: [String: KeyboardKey??]) -> [Command] {
		defaults.map { d in
			var c = d
			if let override = overrides[d.action] {
				c.currentKey = override ?? nil
			}
			return c
		}
	}

	// PURE: which other command currently holds `key` (must be unbound when reassigning).
	nonisolated static func conflictingAction(for key: KeyboardKey, assigningTo action: String, in commands: [Command]) -> String? {
		for c in commands where c.action != action {
			if c.currentKey == key { return c.action }
		}
		return nil
	}

	// PURE: which contexts share the dispatch path with `context`, so a key bound in one
	// shadows the same key in the others. .global is checked everywhere; every other context
	// is checked alongside .global but not alongside its siblings.
	nonisolated static func relevantConflictContexts(for context: Context) -> [Context] {
		context == .global ? Context.allCases : [context, .global]
	}

	func commands(for context: Context) -> [Command] {
		if let cached = cache[context] { return cached }
		let defaults = Self.loadDefaults(for: context)
		let overrides = loadOverrides(for: context)
		let merged = Self.mergedCommands(defaults: defaults, overrides: overrides)
		cache[context] = merged
		return merged
	}

	func effectiveShortcuts(for context: Context) -> Set<KeyboardShortcut> {
		Set(commands(for: context).compactMap { c in c.currentKey.map { KeyboardShortcut(key: $0, actionString: c.action) } })
	}

	@discardableResult
	func setBinding(_ key: KeyboardKey, forAction action: String, in context: Context) -> String? {
		var reassignedTitle: String?
		for otherContext in Self.relevantConflictContexts(for: context) {
			let excludedAction = (otherContext == context) ? action : nil   // don't unbind the command we're assigning
			for c in commands(for: otherContext) where c.action != excludedAction {
				if c.currentKey == key {
					writeOverride(.some(nil), forAction: c.action, in: otherContext)   // unbind the conflicting command
					reassignedTitle = (otherContext == context) ? c.title : "\(c.title) (\(otherContext.displayName))"
				}
			}
		}
		writeOverride(.some(key), forAction: action, in: context)
		invalidateAndNotify()
		return reassignedTitle
	}

	func clearBinding(forAction action: String, in context: Context) {
		writeOverride(.some(nil), forAction: action, in: context)
		invalidateAndNotify()
	}

	func restoreDefaults() {
		userDefaults.removeObject(forKey: Self.defaultsKey)
		invalidateAndNotify()
	}

	// MARK: - Private

	private static func loadDefaults(for context: Context) -> [Command] {
		guard let path = Bundle.main.path(forResource: context.plistName, ofType: "plist"),
			  let raw = NSArray(contentsOfFile: path) as? [[String: Any]] else { return [] }
		return raw.compactMap { dict in
			guard let action = dict["action"] as? String, let key = KeyboardKey(dictionary: dict) else { return nil }
			let title = (dict["title"] as? String) ?? action
			return Command(title: title, action: action, defaultKey: key, currentKey: key)
		}
	}

	// Returns [action: KeyboardKey?] where a present nil means "unbound".
	private func loadOverrides(for context: Context) -> [String: KeyboardKey??] {
		guard let all = userDefaults.dictionary(forKey: Self.defaultsKey),
			  let contextDict = all[context.rawValue] as? [String: Any] else { return [:] }
		var result: [String: KeyboardKey??] = [:]
		for (action, value) in contextDict {
			if let keyDict = value as? [String: Any], let key = KeyboardKeyCoder.key(from: keyDict) {
				result[action] = .some(key)
			} else {
				result[action] = .some(nil)   // NSNull / anything else == unbound
			}
		}
		return result
	}

	private func writeOverride(_ value: KeyboardKey??, forAction action: String, in context: Context) {
		var all = userDefaults.dictionary(forKey: Self.defaultsKey) ?? [:]
		var contextDict = (all[context.rawValue] as? [String: Any]) ?? [:]
		switch value {
		case .some(.some(let key)):
			contextDict[action] = KeyboardKeyCoder.dictionary(from: key)
		default:
			contextDict[action] = ["unbound": true]
		}
		all[context.rawValue] = contextDict
		userDefaults.set(all, forKey: Self.defaultsKey)
	}

	private func invalidateAndNotify() {
		cache.removeAll()
		NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
	}
}

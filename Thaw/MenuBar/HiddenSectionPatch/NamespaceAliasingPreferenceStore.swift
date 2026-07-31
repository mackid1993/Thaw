//
//  NamespaceAliasingPreferenceStore.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import MenuBarModel

/// Reconciles the namespaces macOS uses in `TrailingItemPreferredPositions`
/// with the bundle identifiers Thaw keys items by.
///
/// macOS 27 stores every status item's position under
/// `status:<namespace>::<autosaveName>`. For most apps `<namespace>` is the
/// bundle identifier, but MenuBarAgent falls back to the **process name** for
/// helpers whose bundle it cannot resolve. iStat Menus is the case in point:
/// its menu bar helper lives in `~/Library/Application Support/`, so macOS
/// files its five items under `iStat Menus Menubar`, while
/// `NSRunningApplication` reports `com.bjango.istatmenus.status`. Every key
/// Thaw builds for those items therefore addresses nothing, the position write
/// silently misses, and the move falls through to the synthetic drag path.
///
/// The naive fix — making the item's namespace the process name — is wrong.
/// `MenuBarItemTag.Namespace.description` is consumed *as a bundle identifier*
/// (unsupported-item matching in `MenuBarSectionController`, hotkey binding in
/// `HotkeysSettingsPane`, the `com.apple.` system-item test in
/// `MenuBarItemTag`), and it is a component of `uniqueIdentifier`, which keys
/// persisted section assignments, custom names and the image cache. Changing
/// it renames items out from under all of that.
///
/// So the translation belongs at the storage boundary instead: keys are
/// rewritten to bundle-identifier form on the way in and back to the form macOS
/// actually reads on the way out. Items keep their real bundle identity, and
/// the position layer sees keys it can match.
///
/// The alias map is derived from what is present, never hardcoded: an app is
/// aliased only when the store contains no keys under its bundle identifier but
/// does contain keys under its process or localized name. That covers any app
/// macOS files this way, not just iStat Menus.
final class NamespaceAliasingPreferenceStore: RuntimePreferenceProviding {
    private static let diagLog = DiagLog(category: "NamespaceAliasing")
    private static let prefix = "status:"

    private let wrapped: RuntimePreferenceProviding

    init(wrapping wrapped: RuntimePreferenceProviding) {
        self.wrapped = wrapped
    }

    // MARK: Key surgery

    /// Splits `status:<namespace>::<autosaveName>`.
    ///
    /// The `::` separator is located rather than splitting on every colon,
    /// because a namespace can itself contain one — process names do.
    private static func split(_ key: String) -> (namespace: String, autosave: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let body = key.dropFirst(prefix.count)
        guard let separator = body.range(of: "::") else { return nil }
        return (
            String(body[body.startIndex ..< separator.lowerBound]),
            String(body[separator.upperBound...])
        )
    }

    private static func join(namespace: String, autosave: String) -> String {
        "\(prefix)\(namespace)::\(autosave)"
    }

    /// Builds `systemNamespace -> bundleIdentifier` from the keys present.
    ///
    /// Requires a *positive* signal both ways: the app must have no keys under
    /// its bundle identifier, and must have keys under a name it is actually
    /// running as. Anything ambiguous is left alone — a wrong alias would
    /// rewrite one app's positions onto another's.
    @MainActor
    private static func aliasMap(for positions: [String: Int]) -> [String: String] {
        var namespaces = Set<String>()
        for key in positions.keys {
            if let parts = split(key) {
                namespaces.insert(parts.namespace)
            }
        }
        guard !namespaces.isEmpty else { return [:] }

        var map = [String: String]()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            guard !namespaces.contains(bundleID) else { continue }

            let candidates = [
                app.localizedName,
                app.executableURL?.deletingPathExtension().lastPathComponent,
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != bundleID }

            guard let alias = candidates.first(where: { namespaces.contains($0) }) else { continue }
            // Never let two apps claim the same system namespace.
            guard map[alias] == nil else {
                diagLog.debug("ambiguous alias '\(alias)'; leaving untranslated")
                map[alias] = nil
                continue
            }
            map[alias] = bundleID
        }
        return map
    }

    private static func rewrite(_ positions: [String: Int], mapping: [String: String]) -> [String: Int] {
        guard !mapping.isEmpty else { return positions }
        var result = [String: Int]()
        result.reserveCapacity(positions.count)
        for (key, value) in positions {
            guard let parts = split(key), let replacement = mapping[parts.namespace] else {
                result[key] = value
                continue
            }
            result[join(namespace: replacement, autosave: parts.autosave)] = value
        }
        return result
    }

    // MARK: RuntimePreferenceProviding

    var hasHiddenItems: Bool { wrapped.hasHiddenItems }

    func readPositions() -> [String: Int] {
        let raw = wrapped.readPositions()
        let map = MainActor.assumeIsolated { Self.aliasMap(for: raw) }
        guard !map.isEmpty else { return raw }
        Self.diagLog.debug("aliasing on read: \(map.map { "\($0.key)->\($0.value)" }.sorted().joined(separator: ", "))")
        return Self.rewrite(raw, mapping: map)
    }

    func writePositions(_ dict: [String: Int]) {
        // Derive from the untranslated store, then invert: the caller hands us
        // bundle-identifier keys and macOS only reads the aliased ones.
        let raw = wrapped.readPositions()
        let map = MainActor.assumeIsolated { Self.aliasMap(for: raw) }
        guard !map.isEmpty else {
            wrapped.writePositions(dict)
            return
        }
        var inverse = [String: String]()
        for (alias, bundleID) in map {
            inverse[bundleID] = alias
        }
        wrapped.writePositions(Self.rewrite(dict, mapping: inverse))
    }

    func restoreAll() {
        wrapped.restoreAll()
    }

    @discardableResult
    func hideItems(_ items: [MenuBarItem]) -> Set<String> {
        wrapped.hideItems(items)
    }

    @discardableResult
    func showItems(_ items: [MenuBarItem], allItems: [MenuBarItem]) -> Set<String> {
        wrapped.showItems(items, allItems: allItems)
    }

    @discardableResult
    func lockVisiblePositions(visibleItemKeys: Set<String>, allItems: [MenuBarItem]) -> Set<String> {
        wrapped.lockVisiblePositions(visibleItemKeys: visibleItemKeys, allItems: allItems)
    }
}

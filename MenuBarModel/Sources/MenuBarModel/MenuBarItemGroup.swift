//
//  MenuBarItemGroup.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under GNU GPLv3

import Foundation

/// A user-defined group of menu bar items, spanning one or more applications.
///
/// Bundle grouping (see ``MenuBarItemGrouping/groups(in:)``) already gives a
/// multi-item app one movable cluster in Layout. A *user group* makes that
/// behavior explicit and can extend it across apps: whatever the user puts in
/// one group moves and hides as a single unit.
///
/// Membership is by **bundle namespace**, not by individual item. That is the
/// granularity shown by the Add App editor and, more importantly, a bundle
/// identifier is stable across relaunches while a per-item identity may not
/// be. Every live item actually published by a selected app is discovered at
/// runtime; no iStat module names or user configuration are assumed.
public struct MenuBarItemGroup: Codable, Equatable, Sendable, Identifiable {
    /// The group's stable identity. Survives renames and membership edits.
    public let id: UUID

    /// The user-visible name of the group.
    public var name: String

    /// The bundle namespaces that belong to this group, in the order the user
    /// added them.
    ///
    /// Stored as raw strings rather than ``MenuBarItemTag/Namespace`` values so
    /// the persisted form is plain JSON that survives changes to the namespace
    /// enum's cases.
    public var bundleIdentifiers: [String]

    /// Whether the group is collapsed to one pocket in Thaw's Layout editor.
    ///
    /// This is presentation metadata only. It never replaces, resizes, hides,
    /// or intercepts the native status items supplied by the owning apps.
    public var isCollapsed: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifiers: [String] = [],
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.isCollapsed = isCollapsed
    }

    /// The group's members as namespaces.
    public var namespaces: [MenuBarItemTag.Namespace] {
        bundleIdentifiers.map { .string($0) }
    }

    /// Whether `namespace` is a member of this group.
    ///
    /// Compared canonically, so a group named after an app still claims that
    /// app's items when they arrive under an alternate spelling of its
    /// namespace.
    public func contains(_ namespace: MenuBarItemTag.Namespace) -> Bool {
        let canonical = MenuBarItemTag.canonicalNamespace(namespace)
        return namespaces.contains { MenuBarItemTag.canonicalNamespace($0) == canonical }
    }

    /// Adds `bundleIdentifier` to the group, ignoring duplicates.
    public mutating func insert(_ bundleIdentifier: String) {
        guard !bundleIdentifiers.contains(bundleIdentifier) else {
            return
        }
        bundleIdentifiers.append(bundleIdentifier)
    }

    /// Removes `bundleIdentifier` from the group.
    public mutating func remove(_ bundleIdentifier: String) {
        bundleIdentifiers.removeAll { $0 == bundleIdentifier }
    }

    // Decoded field-by-field so a stored group written by an older build — one
    // that predates a field added later — still loads instead of throwing away
    // the user's whole group list.
    private enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifiers, isCollapsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        bundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .bundleIdentifiers) ?? []
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
}

public extension [MenuBarItemGroup] {
    /// The group that claims `namespace`, or `nil` when it is ungrouped.
    ///
    /// A namespace can appear in at most one group: the first that names it
    /// wins, matching ``MenuBarItemGrouping/groups(in:userGroups:)``.
    func group(claiming namespace: MenuBarItemTag.Namespace) -> MenuBarItemGroup? {
        first { $0.contains(namespace) }
    }
}

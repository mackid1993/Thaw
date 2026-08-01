//
//  MenuBarItemGroupCoordinator.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under GNU GPLv3

import Foundation
import MenuBarModel

/// Resolves ``MenuBarItemGroup`` definitions against the live menu bar, and
/// performs the group-level layout actions the settings UI offers.
///
/// The coordinator deliberately owns no state and writes no preferences:
/// group definitions live in `AdvancedSettings.itemGroups`, while section
/// assignments remain exclusively under the layout editor's control.
@MainActor
enum MenuBarItemGroupCoordinator {
    /// An application that can be put into a group, as offered by the picker.
    struct Candidate: Identifiable, Equatable {
        /// The bundle identifier — the membership key of a group.
        let bundleIdentifier: String
        /// The name to show the user.
        let name: String
        /// How many menu bar items the app currently vends.
        let itemCount: Int

        var id: String { bundleIdentifier }
    }

    /// The applications currently on the menu bar that are eligible for
    /// grouping, sorted by name.
    ///
    /// Only groupable items count (see ``MenuBarItemGrouping/isGroupable(_:)``),
    /// which excludes system modules, Thaw's own control items, layout anchors,
    /// and anything whose namespace is not a bundle string.
    static func candidates(in itemManager: MenuBarItemManager) -> [Candidate] {
        var namesByBundle = [String: String]()
        var countsByBundle = [String: Int]()

        for item in itemManager.itemCache.managedItems {
            // Canonical: an app whose items arrive under two spellings of its
            // namespace must be offered once, under the name a group can
            // actually claim it by.
            guard MenuBarItemGrouping.isGroupable(item.tag),
                  case let .string(bundleIdentifier) =
                  MenuBarItemTag.canonicalNamespace(item.tag.namespace)
            else {
                continue
            }
            countsByBundle[bundleIdentifier, default: 0] += 1
            // The app name, not the item name: membership is per app, so
            // "iStat Menus" is the honest label for a bundle vending five
            // items with five different titles.
            if namesByBundle[bundleIdentifier] == nil {
                namesByBundle[bundleIdentifier] = item.sourceApplication?.localizedName
                    ?? item.owningApplication?.localizedName
                    ?? item.displayName
            }
        }

        return countsByBundle
            .map { bundleIdentifier, count in
                Candidate(
                    bundleIdentifier: bundleIdentifier,
                    name: namesByBundle[bundleIdentifier] ?? bundleIdentifier,
                    itemCount: count
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// The live items belonging to `group`, in group order: bundles in the
    /// order the user added them, and each bundle's items in menu bar order.
    ///
    /// The first element is the group's *leader* — the item that stays put when
    /// the group is collapsed.
    static func members(
        of group: MenuBarItemGroup,
        in itemManager: MenuBarItemManager
    ) -> [MenuBarItem] {
        let managed = itemManager.itemCache.managedItems
        return group.bundleIdentifiers.flatMap { bundleIdentifier in
            let wanted = MenuBarItemTag.canonicalNamespace(.string(bundleIdentifier))
            return managed.filter { item in
                MenuBarItemGrouping.isGroupable(item.tag)
                    && MenuBarItemTag.canonicalNamespace(item.tag.namespace) == wanted
            }
        }
    }

    /// Repairs a partially split authored group by assigning every live member
    /// to the section that already contains the largest number of its members.
    /// This is intentionally section-only: Bjango keeps ownership of rendering,
    /// updating, and click handling for every native status item.
    static func reconcileSections(
        groups: [MenuBarItemGroup],
        in itemManager: MenuBarItemManager,
        controller: MenuBarSectionController
    ) {
        for group in groups {
            let groupMembers = members(of: group, in: itemManager)
            guard groupMembers.count >= 2 else { continue }

            let counts = Dictionary(grouping: groupMembers) {
                controller.authoredSection(for: $0.uniqueIdentifier)
            }.mapValues(\.count)
            let firstSection = controller.authoredSection(
                for: groupMembers[0].uniqueIdentifier
            )
            let target = counts.max { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key != firstSection && rhs.key == firstSection
                }
                return lhs.value < rhs.value
            }?.key ?? firstSection

            guard groupMembers.contains(where: {
                controller.authoredSection(for: $0.uniqueIdentifier) != target
            }) else {
                continue
            }
            controller.setSection(target, items: groupMembers)
        }
    }

}

//
//  MenuBarItemGrouping.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Groups menu bar items that belong to the same application so the layout UI
/// can present them as a movable cluster.
///
/// A *group* is the set of two or more groupable items in a section that share a
/// bundle namespace — **regardless of whether they are currently adjacent**. The
/// invariant the UI enforces is "every bundle with multiple items stays
/// together": the group handle gathers all members and moves them as one block,
/// so even items that start scattered are pulled into one contiguous cluster.
///
/// The type is intentionally pure and tag-driven so the grouping rules can be
/// unit-tested without a live menu bar, `AppState`, or AppKit view tree.
public enum MenuBarItemGrouping {
    /// A set of items within an ordered sequence that move and hide as one.
    public struct Group: Equatable, Sendable {
        /// What holds the members together.
        public enum Identity: Hashable, Sendable {
            /// Every item of one bundle — the implicit cluster Thaw presents
            /// for a multi-item app in Layout.
            case bundle(MenuBarItemTag.Namespace)
            /// A ``MenuBarItemGroup`` the user defined, spanning one or more
            /// bundles.
            case user(UUID)
        }

        /// What holds the members together.
        public let identity: Identity
        /// The indices of the members within the source array, ascending. The
        /// members are not necessarily contiguous.
        public let memberIndices: [Int]

        public init(identity: Identity, memberIndices: [Int]) {
            self.identity = identity
            self.memberIndices = memberIndices
        }

        public init(namespace: MenuBarItemTag.Namespace, memberIndices: [Int]) {
            self.init(identity: .bundle(namespace), memberIndices: memberIndices)
        }

        /// The shared bundle namespace of the members, or `nil` for a
        /// user-defined group (whose members may span several bundles).
        public var namespace: MenuBarItemTag.Namespace? {
            guard case let .bundle(namespace) = identity else {
                return nil
            }
            return namespace
        }

        /// The identifier of the user-defined group behind this cluster, or
        /// `nil` when it is an implicit bundle group.
        public var userGroupID: UUID? {
            guard case let .user(id) = identity else {
                return nil
            }
            return id
        }

        /// The number of items in the group.
        public var count: Int { memberIndices.count }

        /// The half-open span from the first to the last member. Used for
        /// drawing the cluster background and placing the group handle; may
        /// enclose non-member items when the group is not yet contiguous.
        public var range: Range<Int> {
            guard let first = memberIndices.first, let last = memberIndices.last else {
                return 0 ..< 0
            }
            return first ..< (last + 1)
        }
    }

    /// Whether an item is eligible to participate in bundle grouping.
    ///
    /// Only genuine third-party applications group. Excluded:
    /// - System items and the menu-bar hosting namespace (Clock, Wi-Fi, …),
    ///   which would otherwise collapse every Apple module into one giant group.
    /// - Thaw's own control items.
    /// - Fixed layout anchors and any non-movable item.
    /// - Items whose namespace is not a bundle string (UUID / null clones).
    public static func isGroupable(_ tag: MenuBarItemTag) -> Bool {
        guard tag.namespace.isString else { return false }
        guard !tag.isSystemItem else { return false }
        guard !tag.namespace.isMenuBarHostingNamespace else { return false }
        guard !tag.isThawOwnedNamespace else { return false }
        guard !tag.isLayoutAnchoredSystemItem else { return false }
        return tag.isMovable
    }

    /// Detects the bundle groups (two or more same-bundle groupable items) in a
    /// tag sequence, in left-to-right order of each bundle's first member.
    ///
    /// Membership is by bundle namespace only — items need **not** be adjacent.
    /// Every groupable item sharing a namespace with at least one sibling is a
    /// member of that bundle's single group, so a bundle's items are never split
    /// across two groups. Non-groupable items (system, Thaw, anchored,
    /// non-movable, non-string namespaces) are never members.
    public static func groups(in tags: [MenuBarItemTag]) -> [Group] {
        groups(in: tags, userGroups: [])
    }

    /// Detects the clusters in a tag sequence, honoring the user's own group
    /// definitions on top of the implicit same-bundle grouping.
    ///
    /// A namespace named by a user group is served by that group and never also
    /// forms a bundle group, so no item is ever a member of two clusters. A
    /// namespace claimed by more than one user group belongs to the first that
    /// names it. Every other rule matches ``groups(in:)``: members need not be
    /// adjacent, non-groupable items are never members, and a cluster needs at
    /// least two members to exist — which is why a user group naming two
    /// single-item apps is a group, while one naming a single single-item app
    /// is not.
    ///
    /// Clusters are returned in left-to-right order of their first member.
    public static func groups(in tags: [MenuBarItemTag], userGroups: [MenuBarItemGroup]) -> [Group] {
        var indicesByNamespace = [MenuBarItemTag.Namespace: [Int]]()
        var firstSeen = [MenuBarItemTag.Namespace: Int]()

        for (index, tag) in tags.enumerated() {
            guard isGroupable(tag) else { continue }
            // Canonical: an app whose items arrive under two spellings of its
            // namespace would otherwise be counted as two apps, and neither
            // half would reach the two members a cluster needs.
            let namespace = MenuBarItemTag.canonicalNamespace(tag.namespace)
            indicesByNamespace[namespace, default: []].append(index)
            if firstSeen[namespace] == nil {
                firstSeen[namespace] = index
            }
        }

        // Resolve user groups first; the namespaces they claim are then off
        // limits to bundle grouping.
        var claimedNamespaces = Set<MenuBarItemTag.Namespace>()
        var resolved = [Group]()

        for userGroup in userGroups {
            var members = [Int]()
            for namespace in userGroup.namespaces.map(MenuBarItemTag.canonicalNamespace) {
                guard !claimedNamespaces.contains(namespace),
                      let indices = indicesByNamespace[namespace]
                else {
                    continue
                }
                claimedNamespaces.insert(namespace)
                members.append(contentsOf: indices)
            }
            guard members.count >= 2 else {
                // A group with fewer than two items present on the bar has
                // nothing to hold together right now. Its claim is still
                // recorded above so those namespaces do not fall back to
                // bundle grouping and quietly contradict the user's intent.
                continue
            }
            resolved.append(Group(identity: .user(userGroup.id), memberIndices: members.sorted()))
        }

        for (namespace, indices) in indicesByNamespace {
            guard !claimedNamespaces.contains(namespace), indices.count >= 2 else {
                continue
            }
            resolved.append(Group(namespace: namespace, memberIndices: indices))
        }

        // Each index belongs to exactly one cluster, so first members are
        // distinct and this ordering is total — no dictionary iteration order
        // leaks into the result.
        return resolved.sorted { ($0.memberIndices.first ?? 0) < ($1.memberIndices.first ?? 0) }
    }

    /// The group containing the item at `index`, if that item is part of one.
    public static func group(containing index: Int, in tags: [MenuBarItemTag]) -> Group? {
        group(containing: index, in: tags, userGroups: [])
    }

    /// The group containing the item at `index`, if that item is part of one,
    /// honoring the user's own group definitions.
    public static func group(
        containing index: Int,
        in tags: [MenuBarItemTag],
        userGroups: [MenuBarItemGroup]
    ) -> Group? {
        groups(in: tags, userGroups: userGroups).first { $0.memberIndices.contains(index) }
    }

    /// Gathers the elements at `memberIndices` into one ordered block at a
    /// drop cursor expressed in the original array's index space.
    ///
    /// Unlike ``moveBlock(_:sourceRange:toIndexInOriginal:)``, members may be
    /// scattered. This is the primitive used when any item inside a group
    /// pocket is dragged: every member is removed, their relative order is
    /// preserved, and the complete block is inserted at the cursor.
    public static func moveMembers<Element>(
        _ elements: [Element],
        memberIndices: [Int],
        toIndexInOriginal destinationIndex: Int
    ) -> [Element] {
        let memberIndices = Array(Set(memberIndices))
            .filter { elements.indices.contains($0) }
            .sorted()
        guard !memberIndices.isEmpty else { return elements }

        let indexSet = Set(memberIndices)
        let members = memberIndices.map { elements[$0] }
        var remainder = elements.enumerated()
            .filter { !indexSet.contains($0.offset) }
            .map(\.element)
        let removedBefore = memberIndices.lazy.filter { $0 < destinationIndex }.count
        let insertionIndex = (destinationIndex - removedBefore)
            .clamped(to: 0 ... remainder.count)
        remainder.insert(contentsOf: members, at: insertionIndex)
        return remainder
    }

    /// Moves the block of elements at `sourceRange` so it begins at
    /// `destinationIndex`, expressed in the *original* array's index space.
    ///
    /// `destinationIndex` is where the block's first element should land
    /// relative to the untouched array (the same convention as a drop cursor).
    /// The block's internal order is preserved. Returns the reordered array.
    ///
    /// This is the block-move primitive behind "move the whole group": callers
    /// resolve a group's `range` and a drop position, then apply it to their
    /// ordered identifier/item array.
    public static func moveBlock<Element>(
        _ elements: [Element],
        sourceRange: Range<Int>,
        toIndexInOriginal destinationIndex: Int
    ) -> [Element] {
        guard !sourceRange.isEmpty,
              sourceRange.lowerBound >= 0,
              sourceRange.upperBound <= elements.count
        else {
            return elements
        }
        let block = Array(elements[sourceRange])
        var remainder = elements
        remainder.removeSubrange(sourceRange)

        // Translate the destination from original-array space into remainder
        // space by discounting the removed elements whose original index sits
        // before the destination.
        let removedBefore = max(0, min(destinationIndex, sourceRange.upperBound) - sourceRange.lowerBound)
        let insertionIndex = (destinationIndex - removedBefore)
            .clamped(to: 0 ... remainder.count)

        remainder.insert(contentsOf: block, at: insertionIndex)
        return remainder
    }
}

//
//  MenuBarItemGroupingTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under GNU GPLv3

import Foundation
@testable import MenuBarModel
import Testing

@Suite("Menu bar item grouping")
struct MenuBarItemGroupingTests {
    private func tag(_ bundle: String, _ title: String, instance: Int = 0) -> MenuBarItemTag {
        MenuBarItemTag(namespace: .string(bundle), title: title, windowID: nil, instanceIndex: instance)
    }

    // MARK: Groupability

    @Test
    func thirdPartyItemsAreGroupable() {
        #expect(MenuBarItemGrouping.isGroupable(tag("com.example.app", "Item-0")))
    }

    @Test
    func systemAndThawItemsAreNotGroupable() {
        // Every MenuBarAgent module shares one namespace — must never group.
        #expect(!MenuBarItemGrouping.isGroupable(MenuBarItemTag(namespace: .menuBarAgent, title: "Clock")))
        #expect(!MenuBarItemGrouping.isGroupable(MenuBarItemTag(namespace: .menuBarAgent, title: "WiFi")))
        // Thaw's own control item.
        #expect(!MenuBarItemGrouping.isGroupable(MenuBarItemTag.visibleControlItem))
        // UUID / clone namespaces are not bundle strings.
        #expect(!MenuBarItemGrouping.isGroupable(MenuBarItemTag(namespace: .uuid(.init()), title: "x")))
    }

    // MARK: Group detection

    @Test
    func detectsContiguousSameBundleRun() {
        let tags = [
            tag("com.a", "1"),
            tag("com.a", "2"),
            tag("com.a", "3"),
            tag("com.b", "1"),
        ]
        let groups = MenuBarItemGrouping.groups(in: tags)
        #expect(groups.count == 1)
        #expect(groups.first?.namespace == .string("com.a"))
        #expect(groups.first?.memberIndices == [0, 1, 2])
        #expect(groups.first?.range == 0 ..< 3)
    }

    @Test
    func singleItemBundlesDoNotFormGroups() {
        let tags = [tag("com.a", "1"), tag("com.b", "1"), tag("com.c", "1")]
        #expect(MenuBarItemGrouping.groups(in: tags).isEmpty)
    }

    @Test
    func nonContiguousSameBundleItemsGroupByBundle() {
        // Grouping is by bundle, not adjacency: A and A group across B so the
        // whole bundle can be gathered and moved together.
        let tags = [tag("com.a", "1"), tag("com.b", "1"), tag("com.a", "2")]
        let groups = MenuBarItemGrouping.groups(in: tags)
        #expect(groups.count == 1)
        #expect(groups.first?.namespace == .string("com.a"))
        #expect(groups.first?.memberIndices == [0, 2])
    }

    @Test
    func systemItemBetweenMembersDoesNotBreakTheBundle() {
        // A non-groupable system item between two members does not split the
        // bundle — the two A's still form one group (and the Clock is not a member).
        let tags = [
            tag("com.a", "1"),
            MenuBarItemTag(namespace: .menuBarAgent, title: "Clock"),
            tag("com.a", "2"),
        ]
        let groups = MenuBarItemGrouping.groups(in: tags)
        #expect(groups.count == 1)
        #expect(groups.first?.memberIndices == [0, 2])
    }

    @Test
    func detectsMultipleGroups() {
        let tags = [
            tag("com.a", "1"), tag("com.a", "2"),
            tag("com.b", "1"),
            tag("com.c", "1"), tag("com.c", "2"), tag("com.c", "3"),
        ]
        let groups = MenuBarItemGrouping.groups(in: tags)
        #expect(groups.count == 2)
        #expect(groups[0].memberIndices == [0, 1])
        #expect(groups[1].memberIndices == [3, 4, 5])
    }

    @Test
    func groupsOrderedByFirstMember() {
        // B's first member precedes A's first member, so B's group comes first.
        let tags = [
            tag("com.b", "1"),
            tag("com.a", "1"),
            tag("com.b", "2"),
            tag("com.a", "2"),
        ]
        let groups = MenuBarItemGrouping.groups(in: tags)
        #expect(groups.count == 2)
        #expect(groups[0].namespace == .string("com.b"))
        #expect(groups[0].memberIndices == [0, 2])
        #expect(groups[1].namespace == .string("com.a"))
        #expect(groups[1].memberIndices == [1, 3])
    }

    @Test
    func groupContainingIndexResolvesMembership() {
        let tags = [tag("com.a", "1"), tag("com.a", "2"), tag("com.b", "1")]
        #expect(MenuBarItemGrouping.group(containing: 1, in: tags)?.memberIndices == [0, 1])
        #expect(MenuBarItemGrouping.group(containing: 2, in: tags) == nil)
    }

    // MARK: Block move

    @Test
    func moveBlockForward() {
        // [A1 A2 X Y] move the A-block (0..2) to sit at original index 4 (end).
        let moved = MenuBarItemGrouping.moveBlock(
            ["A1", "A2", "X", "Y"],
            sourceRange: 0 ..< 2,
            toIndexInOriginal: 4
        )
        #expect(moved == ["X", "Y", "A1", "A2"])
    }

    @Test
    func moveBlockBackward() {
        // [X Y A1 A2] move the A-block (2..4) to original index 0 (front).
        let moved = MenuBarItemGrouping.moveBlock(
            ["X", "Y", "A1", "A2"],
            sourceRange: 2 ..< 4,
            toIndexInOriginal: 0
        )
        #expect(moved == ["A1", "A2", "X", "Y"])
    }

    @Test
    func moveBlockIntoMiddle() {
        // [A1 A2 X Y Z] move A-block to original index 3 (between Y and Z... in
        // original space, index 3 is Y): lands before Y's original neighbor.
        let moved = MenuBarItemGrouping.moveBlock(
            ["A1", "A2", "X", "Y", "Z"],
            sourceRange: 0 ..< 2,
            toIndexInOriginal: 3
        )
        #expect(moved == ["X", "A1", "A2", "Y", "Z"])
    }

    @Test
    func moveBlockToSamePositionIsIdentity() {
        let original = ["X", "A1", "A2", "Y"]
        let moved = MenuBarItemGrouping.moveBlock(
            original,
            sourceRange: 1 ..< 3,
            toIndexInOriginal: 1
        )
        #expect(moved == original)
    }

    @Test
    func draggingAnyScatteredMemberGathersTheWholeGroup() {
        let original = ["A1", "X", "A2", "Y", "A3", "Z"]
        let moved = MenuBarItemGrouping.moveMembers(
            original,
            memberIndices: [0, 2, 4],
            toIndexInOriginal: 6
        )
        #expect(moved == ["X", "Y", "Z", "A1", "A2", "A3"])
    }

    @Test
    func gatheringMembersPreservesTheirNativeOrder() {
        let original = ["X", "A1", "Y", "A2", "Z"]
        let moved = MenuBarItemGrouping.moveMembers(
            original,
            memberIndices: [3, 1],
            toIndexInOriginal: 0
        )
        #expect(moved == ["A1", "A2", "X", "Y", "Z"])
    }

    // MARK: User-defined groups

    private func userGroup(_ name: String, _ bundles: [String]) -> MenuBarItemGroup {
        MenuBarItemGroup(name: name, bundleIdentifiers: bundles)
    }

    @Test
    func userGroupJoinsTwoSingleItemBundles() {
        // Neither bundle would group on its own — that is the whole point of a
        // user group.
        let tags = [tag("com.a", "1"), tag("com.x", "1"), tag("com.b", "1")]
        let group = userGroup("test", ["com.a", "com.b"])
        let groups = MenuBarItemGrouping.groups(in: tags, userGroups: [group])
        #expect(groups.count == 1)
        #expect(groups.first?.userGroupID == group.id)
        #expect(groups.first?.namespace == nil)
        #expect(groups.first?.memberIndices == [0, 2])
    }

    @Test
    func userGroupAbsorbsEveryItemOfAMemberBundle() {
        // A bundle joins a group wholesale: macOS cannot hide its items apart,
        // so leaving one behind would be unrepresentable.
        let tags = [
            tag("com.a", "1"),
            tag("com.a", "2"),
            tag("com.b", "1"),
        ]
        let group = userGroup("test", ["com.a", "com.b"])
        let groups = MenuBarItemGrouping.groups(in: tags, userGroups: [group])
        #expect(groups.count == 1)
        #expect(groups.first?.memberIndices == [0, 1, 2])
    }

    @Test
    func userGroupSupersedesTheBundleGroupItClaims() {
        // com.a would form a bundle group; claimed, it must not also appear as
        // one, or its items would belong to two clusters at once.
        let tags = [tag("com.a", "1"), tag("com.a", "2"), tag("com.b", "1"), tag("com.b", "2")]
        let group = userGroup("test", ["com.a"])
        let groups = MenuBarItemGrouping.groups(in: tags, userGroups: [group])
        #expect(groups.count == 2)
        #expect(groups.first?.userGroupID == group.id)
        #expect(groups.first?.memberIndices == [0, 1])
        #expect(groups.last?.namespace == .string("com.b"))
        #expect(groups.last?.memberIndices == [2, 3])
    }

    @Test
    func aNamespaceBelongsToTheFirstGroupThatClaimsIt() {
        let tags = [tag("com.a", "1"), tag("com.b", "1"), tag("com.c", "1")]
        let first = userGroup("first", ["com.a", "com.b"])
        let second = userGroup("second", ["com.b", "com.c"])
        let groups = MenuBarItemGrouping.groups(in: tags, userGroups: [first, second])
        // com.b goes to `first`; `second` is left holding only com.c and so is
        // not a cluster.
        #expect(groups.count == 1)
        #expect(groups.first?.userGroupID == first.id)
        #expect(groups.first?.memberIndices == [0, 1])
    }

    @Test
    func aClaimedNamespaceDoesNotFallBackToBundleGrouping() {
        // `first` claims com.a but cannot form a cluster (only com.a is
        // present, and it is a single item). com.a must still not resurface as
        // a bundle group later — it has two items here, so a fallback would be
        // visible.
        let tags = [tag("com.a", "1"), tag("com.a", "2")]
        let group = userGroup("first", ["com.a"])
        let groups = MenuBarItemGrouping.groups(in: tags, userGroups: [group])
        #expect(groups.count == 1)
        #expect(groups.first?.userGroupID == group.id)
    }

    @Test
    func emptyUserGroupsMatchTheBundleOnlyBehavior() {
        let tags = [tag("com.a", "1"), tag("com.a", "2"), tag("com.b", "1")]
        #expect(
            MenuBarItemGrouping.groups(in: tags, userGroups: []) ==
                MenuBarItemGrouping.groups(in: tags)
        )
    }

    @Test
    func userGroupsNeverCaptureNonGroupableItems() {
        // A user group naming the MenuBarAgent namespace must not collapse
        // every Apple module into itself.
        let tags = [
            MenuBarItemTag(namespace: .menuBarAgent, title: "Clock"),
            MenuBarItemTag(namespace: .menuBarAgent, title: "WiFi"),
            tag("com.a", "1"),
        ]
        let group = userGroup("bad", [MenuBarItemTag.Namespace.menuBarAgent.description, "com.a"])
        #expect(MenuBarItemGrouping.groups(in: tags, userGroups: [group]).isEmpty)
    }

    @Test
    func groupContainingHonorsUserGroups() {
        let tags = [tag("com.a", "1"), tag("com.x", "1"), tag("com.b", "1")]
        let group = userGroup("test", ["com.a", "com.b"])
        #expect(
            MenuBarItemGrouping.group(containing: 2, in: tags, userGroups: [group])?.userGroupID == group.id
        )
        #expect(MenuBarItemGrouping.group(containing: 1, in: tags, userGroups: [group]) == nil)
    }

    @Test
    func groupOrderFollowsTheLeftmostMember() {
        let tags = [tag("com.b", "1"), tag("com.b", "2"), tag("com.a", "1"), tag("com.c", "1")]
        let group = userGroup("test", ["com.a", "com.c"])
        let groups = MenuBarItemGrouping.groups(in: tags, userGroups: [group])
        #expect(groups.map(\.memberIndices) == [[0, 1], [2, 3]])
    }

    // MARK: iStat namespace folding

    private func iStat(_ namespace: String, _ title: String, instance: Int = 0) -> MenuBarItemTag {
        MenuBarItemTag(namespace: .string(namespace), title: title, windowID: nil, instanceIndex: instance)
    }

    private var iStatBundleID: String { MenuBarItemTag.iStatMenusStatusBundleID }
    private var iStatProcessName: String { MenuBarItemTag.iStatMenusStatusProcessName }

    @Test
    func bothSpellingsProduceOneIdentity() {
        // The whole bug in one assertion: the same item arriving under the
        // process name and under the bundle ID must persist under one key, and
        // that key must be the bundle-ID one saved layouts already use.
        let byProcess = iStat(iStatProcessName, "CPU 42°")
        let byBundle = iStat(iStatBundleID, "CPU 17°")
        #expect(byProcess.tagIdentifier == "\(iStatBundleID):CPU #°")
        #expect(byProcess.tagIdentifier == byBundle.tagIdentifier)
        #expect(byProcess.matchesIgnoringWindowID(byBundle))
    }

    @Test
    func liveMetricValuesDoNotChurnTheIdentity() {
        // Identity must not change as the numbers tick, under either spelling.
        for namespace in [iStatBundleID, iStatProcessName] {
            let first = iStat(namespace, "Upload 4 KB/s, Download 6 KB/s")
            let second = iStat(namespace, "Upload 91 KB/s, Download 1.2 MB/s")
            #expect(first.tagIdentifier == second.tagIdentifier)
        }
    }

    @Test
    func instanceIndexSurvivesTheFold() {
        let tag = iStat(iStatProcessName, "CPU 42°", instance: 2)
        #expect(tag.tagIdentifier == "\(iStatBundleID):CPU #°:2")
    }

    @Test
    func persistedIdentifiersMigrateToTheBundleSpelling() {
        // A key written by a build that folded only the title still resolves.
        #expect(
            MenuBarItemTag.canonicalPersistentIdentifier("\(iStatProcessName):CPU 42°")
                == "\(iStatBundleID):CPU #°"
        )
        #expect(
            MenuBarItemTag.canonicalPersistentIdentifier("\(iStatProcessName):CPU #°:2")
                == "\(iStatBundleID):CPU #°:2"
        )
        #expect(
            MenuBarItemTag.canonicalPersistentIdentifier("\(iStatBundleID):CPU #°")
                == "\(iStatBundleID):CPU #°"
        )
    }

    @Test
    func foldingIsScopedToIStat() {
        // No other app's namespace is rewritten, and non-string namespaces are
        // returned untouched.
        #expect(MenuBarItemTag.canonicalNamespace(.string("com.a")) == .string("com.a"))
        #expect(MenuBarItemTag.canonicalNamespace(.null) == .null)
        let uuid = UUID()
        #expect(MenuBarItemTag.canonicalNamespace(.uuid(uuid)) == .uuid(uuid))
        #expect(tag("com.a", "CPU 42°").tagIdentifier == "com.a:CPU 42°")
        #expect(MenuBarItemTag.canonicalPersistentIdentifier("com.a:CPU 42°") == "com.a:CPU 42°")
    }

    @Test
    func itemsSplitAcrossSpellingsStillFormOneCluster() {
        // This is why the group would not stick: keyed on the raw namespace,
        // iStat counted as two apps with one item each, and neither reached the
        // two members a cluster needs.
        let tags = [
            iStat(iStatProcessName, "CPU 42°"),
            tag("com.other", "Item-0"),
            iStat(iStatBundleID, "Memory Pressure 61%"),
        ]
        let groups = MenuBarItemGrouping.groups(in: tags)
        #expect(groups.count == 1)
        #expect(groups.first?.namespace == .string(iStatBundleID))
        #expect(groups.first?.memberIndices == [0, 2])
    }

    @Test
    func aUserGroupClaimsBothSpellings() {
        let tags = [
            iStat(iStatProcessName, "CPU 42°"),
            iStat(iStatBundleID, "Memory Pressure 61%"),
        ]
        let group = MenuBarItemGroup(name: "iStat", bundleIdentifiers: [iStatBundleID])
        let groups = MenuBarItemGrouping.groups(in: tags, userGroups: [group])
        #expect(groups.count == 1)
        #expect(groups.first?.userGroupID == group.id)
        #expect(groups.first?.memberIndices == [0, 1])
        #expect(group.contains(.string(iStatProcessName)))
    }

    // MARK: Group definitions

    @Test
    func groupMembershipEditsAreIdempotent() {
        var group = MenuBarItemGroup(name: "test")
        group.insert("com.a")
        group.insert("com.a")
        group.insert("com.b")
        #expect(group.bundleIdentifiers == ["com.a", "com.b"])
        group.remove("com.a")
        #expect(group.bundleIdentifiers == ["com.b"])
        #expect(group.contains(.string("com.b")))
        #expect(!group.contains(.string("com.a")))
        #expect(!group.contains(.uuid(.init())))
    }

    @Test
    func groupDefinitionsRoundTripThroughJSON() throws {
        let groups = [
            MenuBarItemGroup(name: "test", bundleIdentifiers: ["com.a", "com.b"]),
            MenuBarItemGroup(name: "other", bundleIdentifiers: [], isCollapsed: true),
        ]
        let data = try JSONEncoder().encode(groups)
        #expect(try JSONDecoder().decode([MenuBarItemGroup].self, from: data) == groups)
    }

    @Test
    func groupDefinitionsDecodeWithoutOptionalFields() throws {
        // A payload written before `isCollapsed` existed must still load.
        let json = Data(#"[{"id":"8B1B7F4A-0000-4000-8000-000000000001","name":"test"}]"#.utf8)
        let decoded = try JSONDecoder().decode([MenuBarItemGroup].self, from: json)
        #expect(decoded.count == 1)
        #expect(decoded.first?.name == "test")
        #expect(decoded.first?.bundleIdentifiers.isEmpty == true)
        #expect(decoded.first?.isCollapsed == false)
    }

}

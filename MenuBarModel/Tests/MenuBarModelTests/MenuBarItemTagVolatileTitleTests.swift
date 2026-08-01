//
//  MenuBarItemTagVolatileTitleTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation
@testable import MenuBarModel
import Testing

/// Identity churn regression suite.
///
/// Every string in here was read out of a real
/// `~/Library/Preferences/com.stonerl.Thaw.debug.plist` on 2026-07-31, where
/// `MenuBarItemManager.knownItemIdentifiers` held **three** entries for the one
/// iStat weather item — one per sky condition. With `NewItemsSection = hidden`,
/// an item whose identity churns is re-presented as new and filed straight back
/// into the hidden section, which is what made moving iStat between sections
/// unstable.
@Suite("Volatile menu bar item titles")
struct MenuBarItemTagVolatileTitleTests {
    // The three weather variants observed in `knownItemIdentifiers`, plus a
    // fourth condition that was never seen — the rule has to be open-ended,
    // because the set of sky conditions is not enumerable.
    private static let weatherTitles = [
        "Currently 18° and Partly cloudy. High of 24°. Low of 11°. 20% chance of rain",
        "Currently 18° and Clear. High of 24°. Low of 11°. 0% chance of rain",
        "Currently 17° and Mostly cloudy. High of 24°. Low of 11°. 40% chance of rain",
        "Currently 9° and Thunderstorms. High of 12°. Low of 4°. 90% chance of rain",
    ]

    private func iStatTag(_ title: String, namespace: String = MenuBarItemTag.iStatMenusStatusBundleID) -> MenuBarItemTag {
        MenuBarItemTag(namespace: .string(namespace), title: title)
    }

    // MARK: iStat weather

    @Test
    func weatherConditionDoesNotEnterTheIdentity() {
        let identities = Set(Self.weatherTitles.map {
            MenuBarItemTag.canonicalIStatMetricTitle($0)
        })
        #expect(identities.count == 1, "weather conditions produced \(identities.count) identities: \(identities)")
    }

    @Test
    func weatherIdentityIsStableUnderBothNamespaces() {
        // A weather item arriving under the process name must land on the same
        // identity as one arriving under the bundle ID, or the persisted entry
        // written by one path is invisible to the other.
        let viaBundleID = iStatTag(Self.weatherTitles[0]).tagIdentifier
        let viaProcessName = iStatTag(
            Self.weatherTitles[2],
            namespace: MenuBarItemTag.iStatMenusStatusProcessName
        ).tagIdentifier
        #expect(viaBundleID == viaProcessName)
    }

    @Test
    func storedWeatherIdentifiersMigrateOnRead() {
        // The literal strings sitting in the plist today. They must fold onto
        // the post-fix identity, otherwise existing layouts keep pointing at
        // identities nothing will ever produce again.
        let stored = [
            "com.bjango.istatmenus.status:Currently #° and Partly cloudy. High of #°. Low of #°. #% chance of rain",
            "com.bjango.istatmenus.status:Currently #° and Clear. High of #°. Low of #°. #% chance of rain",
            "com.bjango.istatmenus.status:Currently #° and Mostly cloudy. High of #°. Low of #°. #% chance of rain",
        ]
        let migrated = Set(stored.map(MenuBarItemTag.canonicalPersistentIdentifier))
        #expect(migrated.count == 1, "stored weather keys produced \(migrated.count) identities: \(migrated)")

        // And the migrated key must equal what a live item now produces.
        #expect(migrated.first == iStatTag(Self.weatherTitles[0]).tagIdentifier)
    }

    @Test
    func canonicalPersistentIdentifiersDeduplicatesFoldedWeatherKeys() {
        // `savedSectionOrder` is rewritten through this on save. Three stale
        // weather entries must collapse to one, not leave two dead siblings
        // that re-enter the section as phantom members.
        let folded = MenuBarItemTag.canonicalPersistentIdentifiers([
            "com.bjango.istatmenus.status:Currently #° and Partly cloudy. High of #°. Low of #°. #% chance of rain",
            "com.bjango.istatmenus.status:CPU #%",
            "com.bjango.istatmenus.status:Currently #° and Clear. High of #°. Low of #°. #% chance of rain",
            "com.bjango.istatmenus.status:Currently #° and Mostly cloudy. High of #°. Low of #°. #% chance of rain",
        ])
        #expect(folded.count == 2, "expected weather + CPU, got \(folded)")
    }

    // MARK: iStat metrics that already worked — guard against regression

    @Test
    func metricValuesStillNormalize() {
        #expect(
            MenuBarItemTag.canonicalIStatMetricTitle("CPU 41°") ==
                MenuBarItemTag.canonicalIStatMetricTitle("CPU 8°")
        )
        #expect(
            MenuBarItemTag.canonicalIStatMetricTitle("Memory Pressure 62%") ==
                MenuBarItemTag.canonicalIStatMetricTitle("Memory Pressure 9%")
        )
    }

    @Test
    func networkUnitChangesDoNotChurnIdentity() {
        // The stored key is `Upload # B/s, Download # B/s` while the live item
        // reads `2 KB/s`. A unit change at a magnitude boundary must not mint a
        // new identity.
        let identities = Set(
            [
                "Upload 812 B/s, Download 90 B/s",
                "Upload 4 KB/s, Download 2 KB/s",
                "Upload 1.2 MB/s, Download 30 KB/s",
            ].map(MenuBarItemTag.canonicalIStatMetricTitle)
        )
        #expect(identities.count == 1, "network units produced \(identities.count) identities: \(identities)")
    }

    @Test
    func distinctIStatModulesKeepDistinctIdentities() {
        // Over-collapsing is the opposite failure: five modules folded into one
        // identity would make four of them unaddressable.
        let identities = Set(
            [
                "CPU 8%",
                "CPU 41°",
                "Memory Pressure 62%",
                "Upload 4 KB/s, Download 2 KB/s",
                Self.weatherTitles[0],
            ].map(MenuBarItemTag.canonicalIStatMetricTitle)
        )
        #expect(identities.count == 5, "expected 5 distinct modules, got \(identities)")
    }

    // MARK: KelvinShift

    @Test
    func kelvinShiftTitlesAreLeftAlone() {
        // KelvinShift churns its identity the same way iStat did, and folding it
        // is still the obvious-looking fix. It is not: macOS files this item's
        // *position* under its title, so the live dictionary really does contain
        // `status:com.kelvinshift.app:: 5000K`. Normalizing the title made Thaw
        // write `:: #K` — a key macOS never reads, landing outside the lane,
        // which is the native overflow. Measured at weight 6025 on 2026-07-31
        // and reverted the same hour.
        //
        // This test exists to make the next attempt fail loudly rather than
        // rediscover it in the menu bar.
        let tag = MenuBarItemTag(namespace: .string(MenuBarItemTag.kelvinShiftBundleID), title: " 5000K")
        #expect(tag.tagIdentifier == "com.kelvinshift.app: #K")
        #expect(MenuBarItemTag.volatileTitleNamespaces.contains(MenuBarItemTag.kelvinShiftBundleID))
    }

    @Test
    func kelvinShiftPersistedIdentifiersAreNotRewritten() {
        // Every colour temperature must collapse to one persisted identity,
        // or `savedSectionOrder` accumulates one entry per value (14 were
        // measured on 2026-07-31).
        let folded = Set(["com.kelvinshift.app: 5000K", "com.kelvinshift.app: 2100K"]
            .map(MenuBarItemTag.canonicalPersistentIdentifier))
        #expect(folded.count == 1)
    }

    @Test
    func foldingOnlyAppliesWhereSystemKeysAreTitleIndependent() {
        // The rule that separates the two cases. iStat's position keys are
        // autosave names (`::com.bjango.istatmenus.weather`) and owe nothing to
        // the displayed text, so folding the title cannot fabricate a key.
        for namespace in MenuBarItemTag.volatileTitleNamespaces {
            #expect(
                MenuBarItemTag.iStatMenusNamespaces.contains(namespace)
                    || namespace == MenuBarItemTag.kelvinShiftBundleID,
                "\(namespace) folds titles — confirm its system position keys are not title-derived"
            )
        }
    }

    // MARK: Everything else must be left alone

    @Test
    func unrelatedNamespacesAreNotNormalized() {
        // Numbers are meaningful in ordinary autosave names — `Item-0` and
        // `Item-1` are different items and must never fold together.
        let zero = MenuBarItemTag(namespace: .string("com.example.app"), title: "Item-0")
        let one = MenuBarItemTag(namespace: .string("com.example.app"), title: "Item-1")
        #expect(zero.tagIdentifier != one.tagIdentifier)
        #expect(zero.tagIdentifier == "com.example.app:Item-0")
    }

    @Test
    func unrelatedPersistedIdentifiersPassThroughUnchanged() {
        for identifier in [
            "com.1password.1password:Item-0",
            "com.techsmith.snagit.capturehelper:Snagit",
            "com.apple.MenuBarAgent:com.apple.menuextra.wifi",
            "com.stonerl.Thaw.debug:Thaw.ControlItem.Visible",
        ] {
            #expect(MenuBarItemTag.canonicalPersistentIdentifier(identifier) == identifier)
        }
    }

    @Test
    func instanceIndexSuffixSurvivesFolding() {
        let folded = MenuBarItemTag.canonicalPersistentIdentifier(
            "iStat Menus Menubar:Currently 18° and Clear. High of 24°. Low of 11°. 20% chance of rain:2"
        )
        #expect(folded.hasSuffix(":2"))
        #expect(folded.hasPrefix("\(MenuBarItemTag.iStatMenusStatusBundleID):"))
    }
}

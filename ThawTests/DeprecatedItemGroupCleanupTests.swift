//
//  DeprecatedItemGroupCleanupTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under GNU GPLv3

@testable import Thaw
import XCTest

@MainActor
final class DeprecatedItemGroupCleanupTests: XCTestCase {
    func testDeprecatedProxyIdentifierRequiresThawOwnerAndGroupPrefix() {
        XCTAssertTrue(
            MenuBarItemManager.isDeprecatedItemGroupProxyIdentifier(
                "com.stonerl.Thaw.debug:Thaw.ItemGroup.123.Member.0"
            )
        )
        XCTAssertFalse(
            MenuBarItemManager.isDeprecatedItemGroupProxyIdentifier(
                "com.example.foreign:Thaw.ItemGroup.123.Member.0"
            )
        )
        XCTAssertFalse(
            MenuBarItemManager.isDeprecatedItemGroupProxyIdentifier(
                "com.stonerl.Thaw.debug:Thaw.ControlItem.Visible"
            )
        )
    }

    func testPositionCleanupRemovesOnlyRetiredThawKeys() {
        let currentControl = "status:com.stonerl.Thaw.debug::Thaw.ControlItem.Visible"
        let retiredControl = "status:com.stonerl.Thaw.old::Thaw.ControlItem.Hidden"
        let retiredGroup = "status:com.stonerl.Thaw.debug::Thaw.ItemGroup.123"
        let foreign = "status:com.example.foreign::ItemGroup.123"
        let store = MenuBarSectionControllerTests.FakeRuntimePreferenceStore()
        store.storedPositions = [
            currentControl: 1,
            retiredControl: 2,
            retiredGroup: 3,
            foreign: 4,
        ]

        let removed = store.pruneOrphanedControlItemKeys(
            currentOwners: ["com.stonerl.Thaw.debug"]
        )

        XCTAssertEqual(Set(removed), [retiredControl, retiredGroup])
        XCTAssertEqual(
            store.storedPositions,
            [
                currentControl: 1,
                foreign: 4,
            ]
        )
    }
}

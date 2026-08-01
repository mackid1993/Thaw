//
//  MenuBarLayoutSettingsPane.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import MenuBarModel
import SwiftUI
import ThawCapture

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager
    @State private var isHidingAvailable = true

    private var menuBarManager: MenuBarManager {
        appState.menuBarManager
    }

    /// Whether to show the "hiding unsupported" warning: only relevant on
    /// macOS 27+ (where `sectionController` exists) and only when its backend
    /// reports the private Assessment Mode API is unavailable.
    private var isHidingUnavailable: Bool {
        guard #available(macOS 27, *) else { return false }
        return !isHidingAvailable
    }

    private func syncHidingAvailability() {
        isHidingAvailable = menuBarManager.sectionController?.isHidingAvailable ?? true
    }

    var body: some View {
        let hasScreenRecordingPermission = ScreenCapture.hasCachedScreenRecordingPermission
        let canArrangeLayout = hasScreenRecordingPermission
            && !appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults

        IceForm {
            if !hasScreenRecordingPermission {
                MissingLayoutPermissionView()
            } else if !canArrangeLayout {
                CannotArrangeLayoutView()
            } else {
                LayoutBarsSection(itemManager: itemManager)
            }

            if canArrangeLayout {
                if #available(macOS 27, *) {
                    LayoutItemGroupsSection(
                        settings: appState.settings.advanced,
                        itemManager: itemManager
                    )
                }
            }

            LayoutSectionOptions(
                settings: appState.settings.advanced,
                isHidingUnavailable: isHidingUnavailable
            )
            LayoutIconPreviewControls(settings: appState.settings.advanced)

            if canArrangeLayout {
                if #available(macOS 27, *) {
                    LayoutSystemItemControl(isEnabled: systemItemHidingBinding)
                }
            }

            LayoutAdvancedControls(
                settings: appState.settings.advanced,
                navigationState: appState.navigationState
            )

            if canArrangeLayout {
                LayoutResetControls(
                    itemManager: itemManager,
                    controlItemsDisabled: itemManager.areControlItemsMissing,
                    alwaysHiddenEnabled: appState.settings.advanced.enableAlwaysHiddenSection
                )
            }
        }
        .onAppear {
            appState.imageCache.markSettingsPaneOpened()
            syncHidingAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            menuBarManager.sectionController?.refreshHidingAvailability()
            syncHidingAvailability()
        }
    }

    private var systemItemHidingBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.advanced.enableExperimentalSystemItemHiding },
            set: { newValue in
                appState.settings.advanced.enableExperimentalSystemItemHiding = newValue
                appState.menuBarManager.sectionController?.refresh()
            }
        )
    }
}

struct LayoutIconPreviewControls: View {
    @ObservedObject var settings: AdvancedSettings
    @State private var labelWidth: CGFloat = 0

    private var fpsBinding: Binding<Double> {
        Binding(
            get: {
                let interval = settings.iconRefreshInterval
                return interval > 0 ? (1.0 / interval).rounded() : 0
            },
            set: { settings.iconRefreshInterval = $0 > 0 ? 1.0 / $0 : 0 }
        )
    }

    var body: some View {
        IceSection("Icon previews") {
            LabeledContent {
                IceSlider(value: fpsBinding, in: 0 ... 30, step: 1) {
                    Text(fpsBinding.wrappedValue > 0 ? "\(Int(fpsBinding.wrappedValue)) fps" : "Off")
                }
            } label: {
                Text("Icon refresh rate")
                    .frame(minWidth: labelWidth, alignment: .leading)
                    .onFrameChange { frame in
                        labelWidth = max(labelWidth, frame.width)
                    }
            }
            .annotation("How often animated menu bar icons are refreshed in panels. Higher values are smoother but use more CPU.")
        }
    }
}

private struct LayoutSectionOptions: View {
    @ObservedObject var settings: AdvancedSettings
    let isHidingUnavailable: Bool

    var body: some View {
        IceSection("Sections") {
            if isHidingUnavailable {
                SettingsWarningPill(
                    title: "Hiding unavailable",
                    message: "This macOS build is missing the system capability Thaw needs to hide items. Reordering still works; hiding does not."
                )
            }
            Toggle(
                "Enable the always-hidden section",
                isOn: $settings.enableAlwaysHiddenSection
            )
            IcePicker("Section divider style", selection: $settings.sectionDividerStyle) {
                ForEach(SectionDividerStyle.allCases) { style in
                    Text(style.localized).tag(style)
                }
            }
        }
    }
}

private struct LayoutBarsSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager
    @State private var loadDeadlineReached = false

    private let diagLog = DiagLog(category: "MenuBarLayoutPane")

    private var hasItems: Bool {
        !itemManager.itemCache.managedItems.isEmpty
    }

    var body: some View {
        IceSection {
            Text("Arrange menu bar items")
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag items between sections. Move New Items to choose where future items appear.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Tip: Hold ⌘ Command while dragging an item directly in the menu bar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 20) {
                    ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                        if let menuBarSection = appState.menuBarManager.section(withName: section), menuBarSection.isEnabled {
                            VStack(alignment: .leading) {
                                Text(section.localized)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 8)
                                LayoutBar(imageCache: appState.imageCache, section: section)
                            }
                        }
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18)) { content in
                    content.opacity(hasItems ? 1 : 0.75)
                }
                .allowsHitTesting(hasItems)
                .overlay {
                    if !hasItems {
                        loadingOverlay
                            .transition(layoutTransition)
                    }
                }
            }
        }
        .task(id: hasItems) {
            await loadItemsIfNeeded()
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 8) {
            if loadDeadlineReached {
                VStack(spacing: 4) {
                    if itemManager.areControlItemsMissing {
                        Text("One or more section dividers are hidden by macOS")
                        Text("Check System Settings > Menu Bar and enable \(Constants.displayName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unable to load menu bar items")
                    }
                }
                .transition(layoutTransition)
            } else {
                VStack(spacing: 8) {
                    Text("Loading menu bar items…")
                    ProgressView()
                }
                .transition(layoutTransition)
            }
        }
    }

    private var layoutTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.animation(.easeOut(duration: 0.18))
    }

    private func loadItemsIfNeeded() async {
        loadDeadlineReached = false
        guard !hasItems, ScreenCapture.hasCachedScreenRecordingPermission else { return }

        diagLog.debug("Preloading menu bar layout caches (hasItems=\(self.hasItems), screenRecording=\(ScreenCapture.hasCachedScreenRecordingPermission))")
        async let preloadCaches: Void = preloadLayoutCaches()
        try? await Task.sleep(for: .seconds(3))

        if !Task.isCancelled, !hasItems {
            loadDeadlineReached = true
            diagLog.error("Menu bar layout failed to load items after 3s timeout. cacheItems: \(itemManager.itemCache.managedItems.count), images: \(appState.imageCache.images.count), displayID: \(self.itemManager.itemCache.displayID.map { "\($0)" } ?? "nil")")
        }
        await preloadCaches
    }

    private func preloadLayoutCaches() async {
        await itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
        guard !Task.isCancelled else { return }

        if #available(macOS 27, *) {
            // Fill gaps only so opening Layout cannot overwrite settled
            // Hidden glyphs with native overflow chevron («») crops.
            await appState.imageCache.prewarmConcealedImagesMacOS27(
                sections: [.hidden, .alwaysHidden],
                onlyMissingImages: true
            )
            guard !Task.isCancelled else { return }
        }

        await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
    }
}

/// The "Item groups" editor.
///
/// Thaw already presents a multi-item app as one Layout cluster. A *group*
/// makes that behavior explicit and can extend it across several apps:
/// whatever the user adds moves and hides as one unit.
///
/// Membership is per **app**, matching the Add App UI. A bundle identifier is
/// stable across relaunches, and every live item that app actually publishes
/// is discovered dynamically, so this does not assume a particular iStat
/// configuration.
private struct LayoutItemGroupsSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var settings: AdvancedSettings
    @ObservedObject var itemManager: MenuBarItemManager

    var body: some View {
        // Resolved once per render and handed down. `candidates(in:)` walks the
        // whole item cache, and this pane redraws on every cache update — a
        // lookup per group row, per member row, would be dozens of walks a
        // second while the icon previews tick.
        let candidates = MenuBarItemGroupCoordinator.candidates(in: itemManager)
        let claimed = Set(settings.itemGroups.flatMap(\.bundleIdentifiers))
        // A group's claim is exclusive: an app in two groups would have to be
        // in two places at once, so the picker never offers one twice.
        let unclaimed = candidates.filter { !claimed.contains($0.bundleIdentifier) }
        let names = Dictionary(
            candidates.map { ($0.bundleIdentifier, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        IceSection {
            Text("Item groups")
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if settings.itemGroups.isEmpty {
                    Text("No groups yet. Create one to make several apps' menu bar items move and hide together.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($settings.itemGroups) { $group in
                        groupEditor(for: $group, unclaimed: unclaimed, names: names)
                    }
                }

                HStack {
                    Button("New Group") {
                        settings.itemGroups.append(
                            MenuBarItemGroup(name: String(localized: "New Group"))
                        )
                    }
                    .buttonStyle(.settingsGlass)
                    Spacer()
                }

                Text("Groups keep each app's native menu bar rendering and always move or hide together. Collapse only simplifies the group pocket shown in Layout.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func groupEditor(
        for group: Binding<MenuBarItemGroup>,
        unclaimed: [MenuBarItemGroupCoordinator.Candidate],
        names: [String: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Group name")
                TextField("Group name", text: group.name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button(group.wrappedValue.isCollapsed ? "Expand" : "Collapse") {
                    toggleCollapse(group)
                }
                .buttonStyle(.settingsGlass)
                .disabled(group.wrappedValue.bundleIdentifiers.count < 1)
                Button("Ungroup") {
                    ungroup(group)
                }
                .buttonStyle(.settingsGlass)
            }

            if group.wrappedValue.bundleIdentifiers.isEmpty {
                Text("Add an app to this group.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(group.wrappedValue.bundleIdentifiers, id: \.self) { bundleIdentifier in
                    HStack {
                        // Falls back to the identifier: a group keeps naming an
                        // app after it quits, and the row has to stay editable.
                        Text(names[bundleIdentifier] ?? bundleIdentifier)
                        Spacer()
                        Button {
                            removeMember(bundleIdentifier, from: group)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from group")
                    }
                }
            }

            Menu("Add App") {
                if unclaimed.isEmpty {
                    Text("Every app on the menu bar is already in a group")
                } else {
                    ForEach(unclaimed) { candidate in
                        Button(candidate.name) {
                            addMember(candidate.bundleIdentifier, to: group)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    /// Changes only the Layout pocket presentation. Native app rendering and
    /// Visible/Hidden placement remain untouched.
    private func toggleCollapse(_ group: Binding<MenuBarItemGroup>) {
        group.wrappedValue.isCollapsed.toggle()
    }

    /// Adds an app and immediately repairs any pre-existing split so the new
    /// group starts as one native placement unit.
    private func addMember(_ bundleIdentifier: String, to group: Binding<MenuBarItemGroup>) {
        group.wrappedValue.insert(bundleIdentifier)
        guard let controller = appState.menuBarManager.sectionController else { return }
        MenuBarItemGroupCoordinator.reconcileSections(
            groups: [group.wrappedValue],
            in: itemManager,
            controller: controller
        )
    }

    /// Removes an app from the group.
    ///
    /// Leaves every native item's authored section untouched.
    private func removeMember(_ bundleIdentifier: String, from group: Binding<MenuBarItemGroup>) {
        group.wrappedValue.remove(bundleIdentifier)
    }

    /// Deletes the group.
    ///
    /// Removing grouping must not move the native items between sections.
    private func ungroup(_ group: Binding<MenuBarItemGroup>) {
        let id = group.wrappedValue.id
        settings.itemGroups.removeAll { $0.id == id }
    }
}

@available(macOS 27, *)
private struct LayoutSystemItemControl: View {
    @Binding var isEnabled: Bool

    var body: some View {
        IceSection {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow hiding macOS system items")
                    Text("Allows items such as Clock, Control Center, and Siri to be moved into hidden sections.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Note: When Thaw Bar is off, hidden Clock, Control Center, and Siri stay anchored at the right side of the layout. You can still change whether they are visible or hidden.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LayoutAdvancedControls: View {
    @ObservedObject var settings: AdvancedSettings
    @ObservedObject var navigationState: AppNavigationState
    @State private var isExpanded = false

    var body: some View {
        // Disclosure as a form row (Hotkeys pattern) — not nested mini-sections
        // inside the card, which read as double chrome.
        IceSection {
            DisclosureGroup("Advanced layout controls", isExpanded: $isExpanded) {
                Toggle(
                    "Move items that don't fit into Hidden",
                    isOn: $settings.enableMenuBarItemOverflow
                )
                .annotation(
                    "Move menu bar items from Visible into Hidden when they don't fit beside the notch. Disable to keep the saved profile layout exactly as authored."
                )

                Toggle(
                    "Use LCS sorting on notched displays",
                    isOn: $settings.useLCSSortingOnNotchedDisplays
                )
                .annotation(
                    "Use the faster LCS algorithm for profile sorting on notched displays. It minimises moves but may be less reliable at smaller resolutions."
                )

                if #available(macOS 27, *) {
                    Toggle(
                        "Use app icons instead of live previews",
                        isOn: $settings.alwaysUseAppIconForMenuBarItems
                    )
                    .annotation(
                        "Show each item's app icon in the Thaw Bar and layout editor instead of a live screenshot. Use this if macOS 27's native overflow control bleeds into the captured previews. The real menu bar is unaffected."
                    )

                    LabeledContent("Reorder timeout") {
                        IceSlider(value: $settings.menuBarOrderFulfillmentTimeout, in: 1 ... 15, step: 0.5) {
                            SecondsLabel(value: settings.menuBarOrderFulfillmentTimeout)
                        }
                    }
                    .annotation("How long Thaw waits for macOS to apply a menu bar reorder before continuing with any remaining layout work.")
                }
            }
        }
        .onChange(of: navigationState.requestedSettingsDisclosure, initial: true) { _, _ in
            guard SettingsSearchNavigation.consumeDisclosure(
                .advancedLayoutControls,
                navigationState: navigationState
            ) else { return }
            isExpanded = true
        }
    }
}

private struct LayoutResetControls: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var itemManager: MenuBarItemManager
    let controlItemsDisabled: Bool
    let alwaysHiddenEnabled: Bool

    @State private var isResetting = false
    @State private var isConfirming = false
    @State private var status: ResetStatus?

    var body: some View {
        IceSection {
            Text("Reset menu bar layout")
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Text("Moves every movable item except the \(Constants.displayName) icon to the selected section — just like a fresh install.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Button {
                        isConfirming = true
                    } label: {
                        if isResetting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Reset Layout…")
                        }
                    }
                    .buttonStyle(.settingsGlass)
                    .disabled(isResetting || controlItemsDisabled)
                }

                if isConfirming {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose where to move the menu bar items:")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Visible") { reset(to: .visible) }
                            Button("Hidden") { reset(to: .hidden) }
                            if alwaysHiddenEnabled {
                                Button("Always Hidden") { reset(to: .alwaysHidden) }
                            }
                            Button("Cancel", role: .cancel) { isConfirming = false }
                        }
                        .buttonStyle(.settingsGlass)
                    }
                    .transition(resetTransition)
                }

                if let status {
                    Text(status.message)
                        .font(.footnote)
                        .foregroundStyle(status.isError ? .red : .secondary)
                        .transition(resetTransition)
                }
            }
        }
    }

    private var resetTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.animation(.easeOut(duration: 0.18))
    }

    private func reset(to target: ResetTarget) {
        isConfirming = false
        isResetting = true
        status = nil

        Task { @MainActor in
            do {
                let failures = switch target {
                case .visible: try await itemManager.resetLayoutToVisible()
                case .hidden: try await itemManager.resetLayoutToFreshState()
                case .alwaysHidden: try await itemManager.resetLayoutToAlwaysHidden()
                }
                let newStatus: ResetStatus = failures == 0 ? .success(target) : .partialFailure(failures)
                status = newStatus
                AccessibilityAnnouncements.post(newStatus.message)
            } catch {
                status = .failure(error.localizedDescription)
            }
            isResetting = false
        }
    }

    private enum ResetTarget {
        case visible
        case hidden
        case alwaysHidden
    }

    private enum ResetStatus {
        case success(ResetTarget)
        case partialFailure(Int)
        case failure(String)

        var message: String {
            switch self {
            case .success(.hidden): String(localized: "Layout reset. Items were moved to the Hidden section.")
            case .success(.alwaysHidden): String(localized: "Layout reset. Items were moved to the Always Hidden section.")
            case .success(.visible): String(localized: "Items were moved to the Visible section.")
            case let .partialFailure(count): String(localized: "Reset completed with \(count) items that could not be moved. Check the menu bar and try again if needed.")
            case let .failure(message): String(localized: "Reset failed: \(message)")
            }
        }

        var isError: Bool {
            switch self {
            case .success: false
            case .partialFailure, .failure: true
            }
        }
    }
}

private struct CannotArrangeLayoutView: View {
    var body: some View {
        Text("\(Constants.displayName) cannot arrange menu bar items in automatically hidden menu bars.")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct MissingLayoutPermissionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions.")
                .font(.title2)
            Button("Go to Advanced Settings") {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            }
            .buttonStyle(.link)
        }
    }
}

//
//  LayoutBarContainer.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine
import MenuBarModel
import PlatformRuntimeKit

/// A container for the items in the menu bar layout interface.
final class LayoutBarContainer: NSView {
    private struct GroupDescriptor {
        let memberIndices: [Int]
        let memberIdentifiers: [String]
    }

    /// Visual styling for the background drawn behind a same-bundle cluster.
    private enum GroupChrome {
        static let cornerRadius: CGFloat = 7
        static let horizontalPadding: CGFloat = 2
        static let verticalPadding: CGFloat = 1
        static let fillAlpha: CGFloat = 0.10
        static let strokeAlpha: CGFloat = 0.22
        /// Horizontal space reserved to the left of a cluster for its drag handle.
        static let handleReservation: CGFloat = 15
    }

    /// Temporary diagnostic channel for the Layout-preview investigation.
    private static let layoutTraceLog = DiagLog(category: "LayoutTrace")

    /// The overlay grip views, one per detected cluster.
    private var groupHandleViews = [LayoutBarGroupHandleView]()
    /// Phases for a dragging session.
    enum DraggingPhase {
        case entered, exited, updated, ended
    }

    /// Cached width constraint for the container view.
    private lazy var widthConstraint: NSLayoutConstraint = {
        let constraint = widthAnchor.constraint(equalToConstant: 0)
        constraint.isActive = true
        return constraint
    }()

    /// Cached height constraint for the container view.
    private lazy var heightConstraint: NSLayoutConstraint = {
        let constraint = heightAnchor.constraint(equalToConstant: 0)
        constraint.isActive = true
        return constraint
    }()

    /// The shared app state instance.
    private(set) weak var appState: AppState?

    /// The section whose items are represented.
    let section: MenuBarSection.Name

    /// A Boolean value that indicates whether the container should
    /// animate its next layout pass.
    ///
    /// After each layout pass, this value is reset to `true`.
    var shouldAnimateNextLayoutPass = false

    /// A Boolean value that indicates whether the container can
    /// set its arranged views.
    ///
    /// When this transitions from `false` to `true`, the container
    /// automatically refreshes its arranged views from the current
    /// item cache. This ensures updates that arrived while the flag
    /// was `false` are not lost.
    var canSetArrangedViews = true {
        didSet {
            guard canSetArrangedViews, !oldValue, let appState else {
                return
            }
            // Flag transitioned from false to true. Refresh from
            // current cache to pick up any updates that were missed.
            let items = appState.itemManager.itemCache.managedItems(for: section)
            setArrangedViews(items: items)
        }
    }

    /// The container's arranged views.
    ///
    /// The views are laid out from left to right in the order that they
    /// appear in the array. The ``spacing`` property determines the amount
    /// of space between each view.
    var arrangedViews = [LayoutBarArrangedView]() {
        didSet {
            layoutArrangedViews(oldViews: oldValue)
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var suppressLittleSnitchUnresolvedSlot = false
    /// Full membership keyed by the sole item retained for a collapsed group.
    private var collapsedGroupMembersByRepresentative = [String: [String]]()

    /// Creates a container view with the given app state, section, and spacing.
    ///
    /// - Parameters:
    ///   - appState: The shared app state instance.
    ///   - section: The section whose items are represented.
    init(appState: AppState, section: MenuBarSection.Name) {
        self.appState = appState
        self.section = section
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        unregisterDraggedTypes()
        configureCancellables()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Tracks the last known notch state to avoid redundant badge updates.
    private var lastScreenHasNotch: Bool?

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.CombineLatest4(
                appState.itemManager.$itemCache,
                appState.itemManager.$newItemsPlacement,
                appState.settings.advanced.$enableAlwaysHiddenSection,
                appState.settings.advanced.$enableExperimentalSystemItemHiding
            )
            .sink { [weak self] cache, _, _, _ in
                guard let self else {
                    return
                }
                setArrangedViews(items: cache.managedItems(for: section))
            }
            .store(in: &c)

            // Observe average color changes to update badge appearance
            appState.menuBarManager.$averageColorInfo
                .removeDuplicates()
                .sink { [weak self] colorInfo in
                    guard let self else {
                        return
                    }
                    // Update the color info on the badge view
                    if let badgeView = arrangedViews.first(where: { $0.isNewItemsBadge }) {
                        badgeView.averageColorInfo = colorInfo
                    }
                }
                .store(in: &c)

            // Observe screen parameter changes (moving between displays) to update badge
            NotificationCenter.default
                .publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in
                    guard let self else { return }
                    // Force update badge's color info and redraw when screen changes
                    if let badgeView = arrangedViews.first(where: { $0.isNewItemsBadge }) {
                        badgeView.averageColorInfo = appState.menuBarManager.averageColorInfo
                    }
                }
                .store(in: &c)

            Publishers.Merge(
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification),
                NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: section))
            }
            .store(in: &c)

            NotificationCenter.default
                .publisher(for: .menuBarAgentPositionsDidChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: section))
                }
                .store(in: &c)

            // Editing a group changes which items cluster together, and the
            // cluster chrome and drag handles are rebuilt from the arranged
            // views — so the bar has to be laid out again, not just redrawn.
            appState.settings.advanced.$itemGroups
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: section))
                }
                .store(in: &c)

            // Detect when the Settings window is dragged to a display with a
            // different notch state. NSApplication.didChangeScreenParametersNotification
            // does not fire for window movement between screens, but
            // NSWindow.didChangeScreenNotification does.
            NotificationCenter.default
                .publisher(for: NSWindow.didChangeScreenNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let self,
                          let notifyingWindow = notification.object as? NSWindow,
                          notifyingWindow === self.window
                    else { return }
                    updateBadgeForScreenChange()
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Updates the badge view's color info when the screen changes (notch detection)
    private func updateBadgeForScreenChange() {
        let currentHasNotch = NSScreen.screenWithActiveMenuBar?.hasNotch ?? false
        if lastScreenHasNotch != currentHasNotch {
            lastScreenHasNotch = currentHasNotch
            if let badgeView = arrangedViews.first(where: { $0.isNewItemsBadge }) {
                badgeView.averageColorInfo = appState?.menuBarManager.averageColorInfo
            }
        }
    }

    /// Re-runs layout for the container after one arranged view changed size.
    ///
    /// This avoids subscribing the whole container to every image cache update.
    func itemPreferredSizeDidChange(_ itemView: LayoutBarArrangedView) {
        guard arrangedViews.contains(itemView) else {
            return
        }
        shouldAnimateNextLayoutPass = false
        layoutArrangedViews()
    }

    /// Performs layout of the container's arranged views.
    ///
    /// The container removes from its subviews the views that are included
    /// in the `oldViews` array but not in the the current ``arrangedViews``
    /// array. Views that are found in both arrays, but at different indices
    /// are animated from their old index to their new index.
    ///
    /// - Parameter oldViews: The old value of the container's arranged views.
    ///   Pass `nil` to use the current ``arrangedViews`` array.
    private func layoutArrangedViews(oldViews: [LayoutBarArrangedView]? = nil) {
        defer {
            shouldAnimateNextLayoutPass = true
        }

        let oldViews = oldViews ?? arrangedViews

        // remove views that are no longer part of the arranged views
        for view in oldViews where !arrangedViews.contains(view) {
            view.removeFromSuperview()
            view.hasContainer = false
        }

        // track the running x coordinate for the next view's origin
        var previousMaxX: CGFloat = 0

        // get the max height of all arranged views to calculate the
        // y coordinate of each view's origin
        let maxHeight = arrangedViews.lazy
            .map(\.bounds.height)
            .max() ?? 0

        // Reserve a leading gap before the first member of each cluster so its
        // drag handle has room to sit without overlapping any item.
        let groups = groupDescriptors()
        let groupStarts = Set(groups.compactMap { $0.memberIndices.first })

        for (index, entry) in arrangedViews.enumerated() {
            var view: NSView = entry
            if subviews.contains(entry) {
                // view already exists inside the layout view, but may
                // have moved from its previous location;
                if shouldAnimateNextLayoutPass {
                    // replace the view with its animator proxy
                    view = entry.animator()
                }
            } else {
                // view does not already exist inside the layout view;
                // add it as a subview
                addSubview(entry)
                entry.hasContainer = true
            }

            let originX = previousMaxX + (groupStarts.contains(index) ? GroupChrome.handleReservation : 0)

            // set the view's origin; if the view is an animator proxy,
            // it will animate to the new position; otherwise, it must
            // be a newly added view
            view.setFrameOrigin(
                CGPoint(
                    x: originX,
                    y: (maxHeight / 2) - entry.bounds.midY
                )
            )

            previousMaxX = originX + entry.bounds.width
        }

        // update the width and height constraints using the information
        // collected while iterating
        widthConstraint.constant = previousMaxX
        heightConstraint.constant = maxHeight

        // Position the cluster drag handles in their reserved gaps, and refresh
        // the cluster backgrounds (both are derived from the view frames just set).
        updateGroupHandles(groups: groups)
        needsDisplay = true
    }

    /// Updates the cluster drag-handle overlays to match the current groups.
    ///
    /// Handles are **reused** across layout passes, not recreated. A handle
    /// starts its drag in `mouseDragged`, which AppKit only delivers while the
    /// pressed view is still in the hierarchy — and `canSetArrangedViews` is not
    /// frozen until `draggingSession(_:willBeginAt:)`, i.e. *after* the drag has
    /// already begun. Rebuilding the handles tears the pressed view out of the
    /// window during that gap, and the drag silently never starts.
    ///
    /// The gap is not theoretical: `itemPreferredSizeDidChange` re-runs layout
    /// whenever an item's width changes, and a live-updating item (iStat's CPU
    /// percentage, a network rate) changes width several times a second. The
    /// clusters most worth dragging were the ones that could not be dragged.
    ///
    /// A handle is reusable only when it serves exactly the same members in the
    /// same order; any membership change builds a fresh one, because
    /// `memberIdentifiers` is what the drop handler moves.
    ///
    /// `groups` are member-index lists (members may not be adjacent). One handle
    /// serves the whole cluster and carries every member's identifier, so
    /// dragging it gathers all members — not just a contiguous subset.
    private func updateGroupHandles(groups: [GroupDescriptor]) {
        // A handle the user is pressing must survive this pass untouched.
        // Replacing it removes the pressed view from the window before AppKit
        // delivers `mouseDragged`, and the drag then never begins at all — no
        // drop, no refusal, nothing in the log. With a live-updating member
        // (iStat's CPU percentage changes width several times a second)
        // `itemPreferredSizeDidChange` re-runs layout constantly, so the window
        // for this is effectively always open.
        if groupHandleViews.contains(where: \.isTrackingPress) {
            return
        }

        var reusable = groupHandleViews
        var current = [LayoutBarGroupHandleView]()

        for group in groups {
            let views = group.memberIndices.compactMap { arrangedViews.indices.contains($0) ? arrangedViews[$0] : nil }
            guard let first = views.first else {
                continue
            }
            let memberIdentifiers = group.memberIdentifiers
            guard memberIdentifiers.count >= 2 else {
                continue
            }

            // Reuse on member *set*, not ordered equality. Order here follows
            // on-screen position, and a live-updating member changing width
            // reorders the cluster several times a second — with ordered
            // equality that minted a fresh handle each time, destroying any
            // press in progress. Membership is what the drop handler acts on,
            // so a reordered set is the same handle.
            let handle: LayoutBarGroupHandleView
            if let index = reusable.firstIndex(where: { Set($0.memberIdentifiers) == Set(memberIdentifiers) }) {
                handle = reusable.remove(at: index)
            } else {
                handle = LayoutBarGroupHandleView(
                    sourceContainer: self,
                    sourceSection: section,
                    memberIdentifiers: memberIdentifiers
                )
                addSubview(handle)
            }

            // Keep the grip in front of every item view, on every pass.
            //
            // `addSubview` ran only when a handle was created, but item views are
            // added on later passes and therefore end up above it in the subview
            // list. `hitTest` walks that list in reverse, so wherever the two
            // overlap the item view swallows the mouse-down and the handle never
            // receives `mouseDragged` — the drag simply never begins, with no
            // drop and nothing logged. Re-ordering does not change view identity,
            // so the pressed-handle guard above still holds.
            // Only re-order when it is actually wrong. Doing
            // `removeFromSuperview()` + `addSubview()` unconditionally churned
            // the view hierarchy several times a second on a live bar, which
            // tears the view out from under AppKit's tracking loop mid-press —
            // reported 2026-08-01 as the Layout view freezing on a group drag.
            if subviews.last !== handle {
                addSubview(handle, positioned: .above, relativeTo: nil)
            }

            let size = LayoutBarGroupHandleView.preferredSize(height: first.frame.height)
            handle.setFrameSize(size)
            handle.setFrameOrigin(
                CGPoint(
                    x: first.frame.minX - GroupChrome.handleReservation + ((GroupChrome.handleReservation - size.width) / 2),
                    y: first.frame.midY - (size.height / 2)
                )
            )
            current.append(handle)
        }

        // Whatever went unclaimed no longer describes a cluster in this bar.
        for stale in reusable {
            stale.removeFromSuperview()
        }
        groupHandleViews = current
    }

    /// Snapshots the member views of a cluster into a single drag image.
    ///
    /// Returns the image plus the union rect (in this container's coordinates)
    /// so the caller can align the drag image under the cursor.
    func snapshotCluster(memberIdentifiers: [String]) -> (image: NSImage, rect: NSRect)? {
        let views = arrangedViews.filter { view in
            if case let .item(item) = view.kind {
                return memberIdentifiers.contains(item.uniqueIdentifier)
            }
            return false
        }
        guard let first = views.first else {
            return nil
        }
        let rect = views.dropFirst()
            .reduce(first.frame) { $0.union($1.frame) }
            .insetBy(dx: -GroupChrome.horizontalPadding, dy: -GroupChrome.verticalPadding)
            .intersection(bounds)
        guard !rect.isNull, !rect.isEmpty,
              let rep = bitmapImageRepForCachingDisplay(in: rect)
        else {
            return nil
        }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return (image, rect)
    }

    /// The member-index lists of the arranged views that form each cluster —
    /// same-bundle groups plus the user's own groups. Members may not be
    /// adjacent, so each entry is the full set of member indices, not a
    /// contiguous range.
    ///
    /// Only item views carry a bundle tag; the badge and opaque slots are mapped
    /// to a non-groupable placeholder so they are never members.
    private func groupDescriptors() -> [GroupDescriptor] {
        let tags: [MenuBarItemTag] = arrangedViews.map { view in
            if case let .item(item) = view.kind {
                return item.tag
            }
            return .visibleControlItem
        }
        let userGroups = appState?.settings.advanced.itemGroups ?? []
        // Only user-defined groups get a pocket and a grip.
        //
        // `MenuBarItemGrouping.groups` also returns an implicit `.bundle`
        // cluster for *any* app with two or more items — MenuBarAgent's Wi-Fi /
        // Control Center / Clock, 1Password's two items, and so on. Drawing
        // chrome around those is indistinguishable from a real group to anyone
        // looking at the pane: with one group defined (iStat), every automatic
        // cluster reads as "my group has the wrong items in it". Reported
        // exactly that way on 2026-07-31, repeatedly, while the group's own
        // definition was provably correct in the plist.
        var descriptors = MenuBarItemGrouping.groups(in: tags, userGroups: userGroups)
            .filter { group in
                if case .user = group.identity { return true }
                return false
            }
            .map { group in
            let identifiers = group.memberIndices.compactMap { index -> String? in
                guard arrangedViews.indices.contains(index),
                      case let .item(item) = arrangedViews[index].kind
                else { return nil }
                return item.uniqueIdentifier
            }
            return GroupDescriptor(
                memberIndices: group.memberIndices,
                memberIdentifiers: identifiers
            )
        }
        let representedIdentifiers = Set(descriptors.flatMap(\.memberIdentifiers))
        for (representative, members) in collapsedGroupMembersByRepresentative
            where !representedIdentifiers.contains(representative)
        {
            guard let index = arrangedViews.firstIndex(where: { view in
                guard case let .item(item) = view.kind else { return false }
                return item.uniqueIdentifier == representative
            }) else { continue }
            descriptors.append(
                GroupDescriptor(
                    memberIndices: [index],
                    memberIdentifiers: members
                )
            )
        }
        return descriptors.sorted {
            ($0.memberIndices.first ?? 0) < ($1.memberIndices.first ?? 0)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for group in groupDescriptors() {
            // Re-resolve members by identifier against the *current* arranged
            // views. `memberIndices` are positions captured when the descriptor
            // was built, and this bar re-lays-out several times a second while a
            // live item changes width — so by the time the chrome is drawn those
            // positions can name entirely different views. That is how a group
            // holding only `com.bjango.istatmenus.status` ends up drawing its
            // pocket around Tailscale, Dropbox and Wi-Fi. Identifiers cannot
            // drift; positions can.
            let memberIdentifiers = Set(group.memberIdentifiers)
            let liveIndices = arrangedViews.indices.filter { index in
                guard case let .item(item) = arrangedViews[index].kind else { return false }
                return memberIdentifiers.contains(item.uniqueIdentifier)
            }
            // A bundle's members may be scattered; draw one rounded background
            // per contiguous sub-run so the chrome never encloses foreign items
            // that happen to sit between members. One handle still moves them all.
            for run in Self.contiguousRuns(of: liveIndices) {
                let views = run.compactMap { arrangedViews.indices.contains($0) ? arrangedViews[$0] : nil }
                guard let first = views.first else {
                    continue
                }
                let union = views.dropFirst().reduce(first.frame) { $0.union($1.frame) }
                let rect = union
                    .insetBy(dx: -GroupChrome.horizontalPadding, dy: -GroupChrome.verticalPadding)
                    .intersection(bounds)
                guard !rect.isNull, !rect.isEmpty else {
                    continue
                }
                let path = NSBezierPath(
                    roundedRect: rect,
                    xRadius: GroupChrome.cornerRadius,
                    yRadius: GroupChrome.cornerRadius
                )
                NSColor.secondaryLabelColor.withAlphaComponent(GroupChrome.fillAlpha).setFill()
                path.fill()
                NSColor.separatorColor.withAlphaComponent(GroupChrome.strokeAlpha).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// Splits an ascending index list into its maximal contiguous runs.
    private static func contiguousRuns(of indices: [Int]) -> [[Int]] {
        var runs = [[Int]]()
        for index in indices {
            if var last = runs.last, let tail = last.last, index == tail + 1 {
                last.append(index)
                runs[runs.count - 1] = last
            } else {
                runs.append([index])
            }
        }
        return runs
    }

    /// Sets the container's arranged views with the given items.
    ///
    /// - Note: If the value of the container's ``canSetArrangedViews``
    ///   property is `false`, this function returns early.
    func setArrangedViews(items: [MenuBarItem]?) {
        guard
            let appState,
            canSetArrangedViews
        else {
            return
        }
        guard let items else {
            arrangedViews.removeAll()
            return
        }
        // Present the AUTHORED order, not the AX order.
        //
        // The cache is sorted by live AX position, and for an item macOS is not
        // drawing those positions are frozen at whatever they were before
        // concealment. A committed reorder (`setSectionOrder`) therefore never
        // appeared here: the drop handler wrote the new order, the log showed
        // the commit, and the preview kept rendering the phantom arrangement —
        // "it still doesn't drag by the grip", 2026-08-01, while every commit
        // succeeded. The controller's ordering is the same authority the drop
        // handler writes, so the preview now shows the user's intent and the
        // real bar follows wherever macOS honours the weights.
        let orderedItems = appState.menuBarManager.sectionController?.ordered(items, in: section) ?? items
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIdentifiers = Set(runningApplications.compactMap(\.bundleIdentifier))
        let littleSnitchRunning = runningBundleIdentifiers.contains(
            LayoutOpaqueSlotDescriptor.littleSnitchBundleIdentifier
        )
        suppressLittleSnitchUnresolvedSlot = LayoutOpaqueSlotDescriptor.shouldSuppressUnresolvedSlot(
            in: orderedItems,
            littleSnitchRunning: littleSnitchRunning,
            wasSuppressed: suppressLittleSnitchUnresolvedSlot
        )
        let positions: [String: Int]
        let opaqueSlot: LayoutOpaqueSlotDescriptor?
        if #available(macOS 27, *), section == .visible {
            positions = RuntimePositionStore.currentPositions()
            opaqueSlot = LayoutOpaqueSlotDescriptor.littleSnitch(
                runningBundleIdentifiers: runningBundleIdentifiers,
                positions: positions
            )
        } else {
            positions = [:]
            opaqueSlot = nil
        }
        let layoutItems = LayoutOpaqueSlotDescriptor.itemsForLayout(
            orderedItems,
            suppressUnresolvedSlot: suppressLittleSnitchUnresolvedSlot
        )
        let groupedItems = gatheredGroupPresentation(
            items: layoutItems,
            groups: appState.settings.advanced.itemGroups
        )
        let presentation = collapsedGroupPresentation(
            items: groupedItems,
            groups: appState.settings.advanced.itemGroups
        )
        collapsedGroupMembersByRepresentative = presentation.membersByRepresentative
        let displayedItems = presentation.items

        var newViews = [LayoutBarArrangedView]()
        var claimedViewIdentities = Set<ObjectIdentifier>()
        let itemIdentifiers = displayedItems.map(\.uniqueIdentifier)
        let badgeIndex = appState.itemManager.newItemsBadgeIndex(in: section, itemIdentifiers: itemIdentifiers)
        for item in displayedItems {
            // Identity, not value equality. `MenuBarItem ==` includes `title`
            // and `bounds`, both of which change several times a second for a
            // live item, so a value-based test rebuilt every view on every cache
            // publish — destroying tracking areas, tooltips and any in-flight
            // press, and restarting the layout animation each time. That is the
            // gyrating. The matched view has its `item` refreshed below so it
            // does not stay pinned to the payload it was created with.
            // Each existing view may be claimed at most once. `matchesIdentity`
            // folds canonical namespace and title, so two live orderedItems can match
            // the same view — and appending it twice puts one view object at two
            // positions in `arrangedViews`. That is what produced duplicated
            // icons in the Layout preview (1Password, the Thaw cube, battery,
            // Wi-Fi appearing twice) and a group pocket drawn around the wrong
            // run, since every index-based consumer then disagrees with reality.
            if let existingIndex = arrangedViews.firstIndex(where: { view in
                guard !claimedViewIdentities.contains(ObjectIdentifier(view)) else { return false }
                if case let .item(existingItem) = view.kind {
                    return existingItem.tag.matchesIdentity(of: item.tag)
                }
                return false
            }) {
                let existingView = arrangedViews[existingIndex]
                claimedViewIdentities.insert(ObjectIdentifier(existingView))
                if let itemView = existingView as? LayoutBarItemView {
                    itemView.item = item
                }
                newViews.append(existingView)
            } else {
                let view = LayoutBarItemView(appState: appState, item: item)
                newViews.append(view)
            }
        }

        if #available(macOS 27, *), let opaqueSlot {
            let opaqueView = arrangedViews.first(where: {
                if case let .opaqueSlot(existing) = $0.kind {
                    return existing == opaqueSlot
                }
                return false
            }) ?? LayoutOpaqueSlotView(
                descriptor: opaqueSlot,
                runningApplications: runningApplications
            )
            let insertionIndex = opaqueSlot
                .insertionIndex(in: displayedItems, positions: positions)
                .clamped(to: newViews.startIndex ... newViews.endIndex)
            newViews.insert(opaqueView, at: insertionIndex)
        }
        var newlyCreatedBadgeView: LayoutBarNewItemsBadgeView?
        if let badgeIndex {
            let existingBadgeView = arrangedViews.first(where: { $0.isNewItemsBadge })
            let badgeView = existingBadgeView as? LayoutBarNewItemsBadgeView ?? LayoutBarNewItemsBadgeView()
            if existingBadgeView == nil {
                newlyCreatedBadgeView = badgeView
            }
            badgeView.averageColorInfo = appState.menuBarManager.averageColorInfo
            let opaqueIndex = newViews.firstIndex {
                if case .opaqueSlot = $0.kind {
                    return true
                }
                return false
            }
            let adjustedBadgeIndex = if let opaqueIndex, opaqueIndex < badgeIndex {
                badgeIndex + 1
            } else {
                badgeIndex
            }
            let insertionIndex = adjustedBadgeIndex.clamped(to: newViews.startIndex ... newViews.endIndex)
            newViews.insert(badgeView, at: insertionIndex)
        }
        // `arrangedViews.didSet` runs a full animated layout pass. Assigning an
        // identical array on every cache publish therefore restarted a ~0.25 s
        // implicit animation on every view several times a second, so nothing
        // ever settled. Cache-driven passes also must not animate — only a
        // user-initiated change should.
        guard newViews != arrangedViews else { return }
        shouldAnimateNextLayoutPass = false
        arrangedViews = newViews

        // Temporary instrumentation for the Layout-preview "slivers" bug: one
        // line per publish naming, for every arranged view, its object identity,
        // the tag it is drawing, and the size of the image the cache holds for
        // that tag. Two views reporting the same identity or the same image, or
        // a size that does not match the item's own width, localises the fault
        // to reuse / cache lookup / crop respectively — which four rounds of
        // reasoning failed to separate.
        if section == .visible, let traceState = self.appState {
            let rows = arrangedViews.compactMap { view -> String? in
                guard case let .item(item) = view.kind else { return nil }
                let image = traceState.imageCache.image(for: item.tag)
                let size = image.map { "\(Int($0.scaledSize.width))x\(Int($0.scaledSize.height))" } ?? "nil"
                return "\(UInt(bitPattern: ObjectIdentifier(view).hashValue) % 10000)" +
                    ":\(item.tag.tagIdentifier.suffix(28))" +
                    " w=\(Int(item.bounds.width)) img=\(size)"
            }
            Self.layoutTraceLog.debug("layoutTrace [\(rows.joined(separator: " | "))]")
        }
        newlyCreatedBadgeView?.animateAppearance()
    }

    /// Makes each authored group contiguous in the Layout preview without
    /// changing Bjango's native status-item views or the persisted menu order.
    /// The first member keeps the group's position; later members are gathered
    /// directly behind it so Layout draws one pocket instead of fragments.
    private func gatheredGroupPresentation(
        items: [MenuBarItem],
        groups: [MenuBarItemGroup]
    ) -> [MenuBarItem] {
        var result = items
        for group in groups {
            let members = result.filter { group.contains($0.tag.namespace) }
            guard members.count >= 2,
                  let insertionIndex = result.firstIndex(where: {
                      $0.uniqueIdentifier == members[0].uniqueIdentifier
                  })
            else {
                continue
            }
            let identifiers = Set(members.map(\.uniqueIdentifier))
            result.removeAll { identifiers.contains($0.uniqueIdentifier) }
            result.insert(contentsOf: members, at: insertionIndex)
        }
        return result
    }

    /// Folds every collapsed user group to its first live member in this
    /// section. The retained item is only the editor's visual representative;
    /// its group handle still carries every member identifier for moves.
    private func collapsedGroupPresentation(
        items: [MenuBarItem],
        groups: [MenuBarItemGroup]
    ) -> (items: [MenuBarItem], membersByRepresentative: [String: [String]]) {
        var suppressed = Set<String>()
        var membersByRepresentative = [String: [String]]()

        // A group sitting in the Visible section is always drawn expanded,
        // whatever its collapsed flag says. Collapsing is for the sections the
        // user is not looking at directly — Hidden and Always Hidden, which is
        // what the Thaw Bar shows. On the visible bar the members are the point:
        // they are the live native items, and folding them behind a single
        // representative hides the very thing the section exists to display.
        // Collapse state is preserved, so moving the group back into Hidden
        // restores the pocket.
        guard section != .visible else {
            return (items, membersByRepresentative)
        }

        for group in groups where group.isCollapsed {
            let members = items.filter { group.contains($0.tag.namespace) }
            guard let representative = members.first, members.count >= 2 else { continue }
            let fullMemberIdentifiers = appState.map {
                MenuBarItemGroupCoordinator.members(of: group, in: $0.itemManager)
                    .map(\.uniqueIdentifier)
            } ?? members.map(\.uniqueIdentifier)
            membersByRepresentative[representative.uniqueIdentifier] = fullMemberIdentifiers
            suppressed.formUnion(members.dropFirst().map(\.uniqueIdentifier))
        }

        return (
            items.filter { !suppressed.contains($0.uniqueIdentifier) },
            membersByRepresentative
        )
    }

    /// Updates the positions of the container's arranged views using the
    /// specified dragging information and phase.
    ///
    /// - Parameters:
    ///   - draggingInfo: The dragging information to use to update the
    ///     container's arranged views.
    ///   - phase: The current dragging phase of the container.
    /// - Returns: A dragging operation.
    @discardableResult
    func updateArrangedViewsForDrag(with draggingInfo: NSDraggingInfo, phase: DraggingPhase) -> NSDragOperation {
        guard let sourceView = draggingInfo.draggingSource as? LayoutBarArrangedView else {
            return []
        }
        // Refuse a drag of a reorderable-but-not-hideable denylisted item into
        // a non-visible section: show the no-drop cursor instead of letting it
        // settle, mirroring the rejection in performDragOperation. Visible-section
        // drops (reorders) are always allowed.
        if case let .item(item) = sourceView.kind {
            let experimentalSystemItemHiding = appState?.settings.advanced.enableExperimentalSystemItemHiding ?? false
            if item.tag.isLayoutAnchoredSystemItem,
               sourceView.oldContainerInfo?.container === self,
               !LayoutBarPaddingView.allowsAnchoredSystemItemReordering(appState: appState)
            {
                return []
            }
            if !MenuBarSectionController.canAssign(
                item,
                to: section,
                experimentalSystemItemHiding: experimentalSystemItemHiding
            ) {
                return []
            }
        }
        switch phase {
        case .entered:
            if !arrangedViews.contains(sourceView) {
                shouldAnimateNextLayoutPass = false
            }
            return updateArrangedViewsForDrag(with: draggingInfo, phase: .updated)
        case .exited:
            if let sourceIndex = arrangedViews.firstIndex(of: sourceView) {
                shouldAnimateNextLayoutPass = false
                arrangedViews.remove(at: sourceIndex)
            }
            return .move
        case .updated:
            if
                sourceView.oldContainerInfo == nil,
                let sourceIndex = arrangedViews.firstIndex(of: sourceView)
            {
                sourceView.oldContainerInfo = (self, sourceIndex)
            }
            // updating normally relies on the presence of other arranged views,
            // but if the container is empty, it needs to be handled separately
            guard !arrangedViews.filter(\.isEnabled).isEmpty else {
                arrangedViews.insert(sourceView, at: 0)
                return .move
            }
            // convert dragging location from window coordinates
            let draggingLocation = convert(draggingInfo.draggingLocation, from: nil)
            // When dragging a regular item (not the badge), exclude the badge
            // from being a swap destination. The badge position should only
            // change when the user explicitly drags the badge itself.
            let excludeBadge = !sourceView.isNewItemsBadge
            guard
                let destinationView = arrangedView(nearestTo: draggingLocation.x, excludingBadge: excludeBadge),
                destinationView !== sourceView,
                // don't rearrange if destination is disabled
                destinationView.isEnabled,
                // don't rearrange if in the middle of an animation
                destinationView.layer?.animationKeys() == nil,
                let destinationIndex = arrangedViews.firstIndex(of: destinationView)
            else {
                return .move
            }
            // drag must be near the horizontal center of the destination
            // view to trigger a swap
            let midX = destinationView.frame.midX
            let offset = destinationView.frame.width / 2
            if !((midX - offset) ... (midX + offset)).contains(draggingLocation.x),
               sourceView.oldContainerInfo?.container === self
            {
                return .move
            }
            if let sourceIndex = arrangedViews.firstIndex(of: sourceView) {
                // source view is already inside this container, so move
                // it from its old index to the new one
                var targetIndex = destinationIndex
                if destinationIndex > sourceIndex {
                    targetIndex += 1
                }
                arrangedViews.move(fromOffsets: [sourceIndex], toOffset: targetIndex)
            } else {
                // source view is being dragged from another container,
                // so just insert it
                arrangedViews.insert(sourceView, at: destinationIndex)
            }
            return .move
        case .ended:
            return .move
        }
    }

    /// Returns the nearest arranged view to the given X position within
    /// the coordinate system of the container view.
    ///
    /// The nearest arranged view is defined as the arranged view whose
    /// horizontal center is closest to `xPosition`.
    ///
    /// - Parameters:
    ///   - xPosition: A floating point value representing an X position
    ///     within the coordinate system of the container view.
    ///   - excludingBadge: If `true`, the New Items badge is excluded from
    ///     consideration. Use this when dragging regular items to prevent
    ///     them from swapping with the badge.
    func arrangedView(nearestTo xPosition: CGFloat, excludingBadge: Bool = false) -> LayoutBarArrangedView? {
        let candidates = excludingBadge ? arrangedViews.filter { !$0.isNewItemsBadge } : arrangedViews
        return candidates.min { view1, view2 in
            let distance1 = abs(view1.frame.midX - xPosition)
            let distance2 = abs(view2.frame.midX - xPosition)
            return distance1 < distance2
        }
    }
}

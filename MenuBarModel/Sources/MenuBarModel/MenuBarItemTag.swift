//
//  MenuBarItemTag.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Foundation

// MARK: - MenuBarItemTag

/// An identifier for a menu bar item.
public struct MenuBarItemTag: Hashable, CustomStringConvertible, Sendable {
    /// How an item participates in Thaw's section model.
    ///
    /// This value is the classification authority shared by hiding, section
    /// assignment, and layout caching. Consumers must use the capabilities on
    /// this policy instead of rebuilding the system-item exceptions.
    public enum SectionManagementPolicy: Equatable, Sendable {
        /// The item can be assigned to and ordered within any section.
        case hideable

        /// The item must remain visible, but still belongs in the layout cache.
        case forcedVisible

        /// The item is not managed by the section layout.
        case excluded

        public var canBeHidden: Bool {
            self == .hideable
        }

        public var isVisibleInLayout: Bool {
            self != .excluded
        }

        public var isForcedVisible: Bool {
            self == .forcedVisible
        }
    }

    /// The namespace of the item identified by this tag.
    public let namespace: Namespace

    /// The title of the item identified by this tag.
    public let title: String

    /// The window identifier of the item identified by this tag.
    public let windowID: CGWindowID?

    /// The index of the item within its (namespace, title) group.
    public let instanceIndex: Int

    /// A Boolean value that indicates whether the item identified
    /// by this tag is a system item.
    public var isSystemItem: Bool {
        switch namespace {
        case .controlCenter, .systemUIServer, .textInputMenuAgent, .weather, .passwords, .screenCaptureUI, .ssMenuAgent, .thaw, .gamePolicyAgent:
            return true
        case .menuBarAgent:
            if #available(macOS 27, *) {
                return true
            }
            return false
        case .string, .uuid, .null:
            return false
        }
    }

    /// A Boolean value that indicates whether this item is owned by an Apple
    /// system process that Thaw cannot reliably conceal or reorder on macOS 27.
    ///
    /// These items (Sound/Wi-Fi/Bluetooth/AirDrop under MenuBarAgent, Siri under
    /// `com.apple.systemuiserver`, …) report
    /// ``canBeHidden`` but their bundle keeps anchored siblings visible, so the
    /// assertion never conceals them, and the synthetic ⌘-drag does not reliably
    /// move them. They are managed best-effort and must be excluded from
    /// layout-divergence detection so a perpetually-stuck one cannot drive an
    /// infinite layout re-apply loop.
    ///
    /// Broader than ``isSystemItem`` for hosts AX reports as a plain
    /// `.string` bundle ID. This also matches any `com.apple.*` owner so items
    /// like Siri stay covered even when the namespace is not a named constant.
    public var isNonConcealableSystemItem: Bool {
        isSystemItem || namespace.description.hasPrefix("com.apple.")
    }

    /// A Boolean value that indicates whether this item is a Control Center
    /// module Thaw CAN hide individually via its per-host visibility pref
    /// (Wi-Fi/Bluetooth/AirDrop/NowPlaying/User/Focus — see
    /// ``ControlCenterModuleManager``). These are exceptions to
    /// ``isNonConcealableSystemItem``: the assertion can't conceal them, but the
    /// CC-pref path can, so they REMAIN hideable.
    public var isControlCenterGovernable: Bool {
        SystemMenuBarModuleCatalog.controlCenterKeysByMenuExtraTitle[title] != nil
    }

    /// MenuBarAgent extras that can be managed through their stable preferred
    /// position instead of the assessment assertion. The assertion
    /// collateral-hides these Control Center modules whenever it conceals a
    /// third-party app, whereas MenuBarAgent keeps their `status:` / `module:`
    /// keys independently addressable.
    public static let positionManageableMenuBarAgentTitles: Set<String> = [
        "com.apple.menuextra.focusmode",
        "com.apple.menuextra.now-playing",
    ]

    /// Whether this MenuBarAgent child has a stable preferred-position hiding
    /// path.
    public var isPositionManageableMenuBarAgentItem: Bool {
        namespace == .menuBarAgent && Self.positionManageableMenuBarAgentTitles.contains(title)
    }

    /// Whether a persisted `namespace:title[:instance]` identifier names one
    /// of the MenuBarAgent extras that has a preferred-position hiding path.
    public static func isPositionManageableMenuBarAgentIdentifier(_ identifier: String) -> Bool {
        let prefix = "\(Namespace.menuBarAgent.description):"
        return positionManageableMenuBarAgentTitles.contains {
            identifier == "\(prefix)\($0)" || identifier.hasPrefix("\(prefix)\($0):")
        }
    }

    /// A MenuBarAgent-hosted item that must remain in Visible. The two
    /// position-manageable Control Center extras are the exception; all other
    /// children remain assignment-only because macOS 27 owns them as one
    /// system-hosted family.
    public var isMenuBarAgentItemForcedVisible: Bool {
        namespace == .menuBarAgent && !isPositionManageableMenuBarAgentItem
    }

    /// Whether a persisted `namespace:title[:instance]` identifier names a
    /// MenuBarAgent child that must remain Visible. This lets assignment
    /// migration reject stale Hidden entries before the live AX child appears,
    /// while preserving Focus and Now Playing assignments.
    public static func isMenuBarAgentForcedVisibleIdentifier(_ identifier: String) -> Bool {
        let prefix = "\(Namespace.menuBarAgent.description):"
        return identifier.hasPrefix(prefix) && !isPositionManageableMenuBarAgentIdentifier(identifier)
    }

    /// iStat Menus status-item bundle ID. Titles and identifiers are
    /// canonicalized via ``canonicalIStatMetricTitle`` so live metric values do
    /// not churn layout keys every second.
    public static let iStatMenusStatusBundleID = "com.bjango.istatmenus.status"

    /// The process name macOS files iStat Menus' items under. The helper lives
    /// in `~/Library/Application Support/iStat Menus 7/`, outside a location
    /// MenuBarAgent can resolve a bundle for, so the agent falls back to the
    /// executable name everywhere it keys items — `TrailingItemPreferredPositions`
    /// and the assessment allowlist alike. `NSRunningApplication` resolves the
    /// same helper to ``iStatMenusStatusBundleID``, so both spellings reach Thaw
    /// and neither side agrees with the other.
    public static let iStatMenusStatusProcessName = "iStat Menus Menubar"

    /// Every namespace an iStat Menus status item can arrive under.
    public static let iStatMenusNamespaces: Set<String> = [
        iStatMenusStatusBundleID,
        iStatMenusStatusProcessName,
    ]

    /// KelvinShift publishes no stable `AXIdentifier`, so its identity falls
    /// back to the displayed colour temperature — ` 5000K` one moment, ` 2100K`
    /// the next. Both spellings are sitting in the live
    /// `TrailingItemPreferredPositions` dictionary for the same single item.
    ///
    /// **Deliberately not in ``volatileTitleNamespaces``.** Normalizing it was
    /// tried on 2026-07-31 and reverted within the hour: macOS files this item's
    /// position under its *title*, so the real system keys are
    /// `status:com.kelvinshift.app:: 5000K` and `:: 2100K`. Folding the title to
    /// ` #K` made Thaw write `status:com.kelvinshift.app:: #K` — a key macOS
    /// never reads, sitting at 6025, outside the lane. Outside the lane is the
    /// native overflow, which is the chevron this whole effort is trying to
    /// remove. iStat is safe to fold precisely because its system keys are
    /// autosave names (`::com.bjango.istatmenus.weather`) that owe nothing to
    /// the title.
    ///
    /// A real fix has to give KelvinShift a stable identity *without* letting
    /// that identity reach a position key.
    public static let kelvinShiftBundleID = "com.kelvinshift.app"

    /// Namespaces whose items put a **live value** in the text Thaw would
    /// otherwise persist as an identity.
    ///
    /// A display string is never a safe identity. When one churns, the item is
    /// re-presented as brand new on the next refresh, and with
    /// `NewItemsSection = hidden` a new item goes straight into the hidden
    /// section — so the item the user just dragged out of hiding silently falls
    /// back in. Membership here routes the title through
    /// ``canonicalVolatileTitle(namespaceValue:title:)`` everywhere an identity
    /// is derived *and* everywhere a persisted one is read, so old keys migrate
    /// instead of going stale. Normalising on only one of those two sides
    /// creates two identity spaces for one item — see the 2026-07-31 revert in
    /// ``canonicalTitle(namespace:title:)``.
    /// Only namespaces whose *system position keys* are independent of the
    /// title may be listed here — see ``kelvinShiftBundleID`` for the one that
    /// is not, and why adding it made things worse.
    public static let volatileTitleNamespaces: Set<String> = iStatMenusNamespaces
        .union([kelvinShiftBundleID])

    /// Bundle identifiers whose menu bar items Thaw can reorder but cannot yet
    /// reliably hide on macOS 27. Denylisted items are forced visible in the
    /// layout editor. Keep this empty for apps whose identities can be
    /// canonicalized well enough to let users manage them directly.
    ///
    /// Listing iStat Menus here was tried on 2026-07-30 as a way to keep it out
    /// of the macOS 27 concealment assertion, and it does not work: the
    /// assertion takes an *allowlist* of bundle identifiers, and forcing an item
    /// visible in Thaw's own layout model does not add anything to that list.
    /// iStat was still collateral-concealed. Reverted so per-item iStat hiding
    /// keeps working — see `~/Desktop/thaw-chevron-findings-2.md`.
    public static let hidingUnsupportedBundleIDs: Set<String> = [
        // iStat Menus identities are canonicalized above, so allow users to
        // move/hide them from the layout UI instead of forcing them visible.
        // iStatMenusStatusBundleID,
    ]

    private static let nativeOverflowChevronGlyphs: Set<Character> = [
        "<", ">", "‹", "›", "«", "»",
    ]

    /// Whether this item's owner is in ``hidingUnsupportedBundleIDs``.
    public var isHidingUnsupported: Bool {
        if case let .string(bundleID) = namespace {
            return MenuBarItemTag.hidingUnsupportedBundleIDs.contains(bundleID)
        }
        return false
    }

    /// macOS 27's native menu-bar overflow control can appear in AX as a
    /// MenuBarAgent extra. It is a system placeholder, not a status item.
    public var isNativeOverflowPlaceholder: Bool {
        guard namespace == .menuBarAgent else { return false }

        let glyphs = title.filter { !$0.isWhitespace }
        guard !glyphs.isEmpty, glyphs.count <= 4 else { return false }

        return glyphs.allSatisfy { MenuBarItemTag.nativeOverflowChevronGlyphs.contains($0) }
    }

    /// The item's authoritative section-management classification.
    public var sectionManagementPolicy: SectionManagementPolicy {
        if #available(macOS 27, *), isNativeOverflowPlaceholder {
            return .excluded
        }

        if #available(macOS 27, *),
           isHidingUnsupported ||
           isLayoutAnchoredSystemItem ||
           isMenuBarAgentItemForcedVisible ||
           (namespace != .menuBarAgent && isNonConcealableSystemItem && !isControlCenterGovernable)
        {
            return .forcedVisible
        }

        if isLayoutAnchoredSystemItem {
            return .excluded
        }

        if MenuBarItemTag.nonHideableItems.contains(where: {
            $0.namespace == namespace && $0.title == title
        }) || (namespace.isUUID && title == "AudioVideoModule") {
            return .excluded
        }

        return .hideable
    }

    /// A Boolean value that indicates whether this item should be rendered as a
    /// fixed system anchor in the layout UI.
    ///
    /// macOS 27 exposes Apple modules as children of `MenuBarAgent`. Most of
    /// those modules are movable live AX items; only the trailing fixed system
    /// controls should be rendered as disabled anchors in the layout UI.
    public var isLayoutAnchoredSystemItem: Bool {
        if MenuBarItemTag.immovableItems.contains(where: { $0.namespace == namespace && $0.title == title }) {
            return true
        }

        if MenuBarItemTag.fixedSystemAgentNamespaces.contains(namespace) {
            return true
        }

        if #available(macOS 27, *) {
            if namespace == .menuBarAgent,
               MenuBarItemTag.menuBarAgentAnchoredModuleTitles.contains(title)
            {
                return true
            }
        }

        return false
    }

    /// A Boolean value that indicates whether the item identified
    /// by this tag can be moved.
    public var isMovable: Bool {
        !isLayoutAnchoredSystemItem
    }

    /// Whether the item can participate in the legacy divider-based layout
    /// used on macOS 26 and earlier. This policy is intentionally independent
    /// of the host OS so legacy planners remain deterministic when their tests
    /// run on macOS 27, where additional agents are layout anchors.
    public var isMovableInLegacySectionLayout: Bool {
        !MenuBarItemTag.legacyImmovableItems.contains {
            $0.namespace == namespace && $0.title == title
        }
    }

    /// A Boolean value that indicates whether the item identified
    /// by this tag can be hidden.
    public var canBeHidden: Bool {
        sectionManagementPolicy.canBeHidden
    }

    /// Whether the item can participate as hideable in the legacy divider
    /// layout. This deliberately ignores macOS 27's assertion policy so pure
    /// legacy planners remain deterministic when tested on a newer host OS.
    public var canBeHiddenInLegacySectionLayout: Bool {
        isMovableInLegacySectionLayout &&
            !MenuBarItemTag.nonHideableItems.contains(where: {
                $0.namespace == namespace && $0.title == title
            }) &&
            !(namespace.isUUID && title == "AudioVideoModule")
    }

    /// A Boolean value that indicates whether this tag represents a
    /// dynamically-named hosting-process item (Live Activities, etc.)
    /// with the pattern `<hostingProcess>:Item-\d+`.
    public var isControlCenterGenericItem: Bool {
        // macOS 26: the hosting namespace is Control Center; macOS 27: MenuBarAgent
        // (see isMenuBarHostingNamespace). The generic-slot title test is shared
        // with the marker-pair resolver so both stay in sync.
        namespace.isMenuBarHostingNamespace && MarkerPairResolver.isGenericControlCenterTitle(title)
    }

    /// Whether this tag's namespace identifies Thaw itself (not a third-party app).
    public var isThawOwnedNamespace: Bool {
        switch namespace {
        case .thaw:
            return true
        case let .string(bundleID):
            return ThawMenuBarIdentity.owns(bundleIdentifier: bundleID)
        case .null, .uuid:
            return false
        }
    }

    /// Whether this tag is Thaw's visible-section chevron, including
    /// MenuBarHost-style AX namespaces on macOS 27.
    public var matchesVisibleControlItem: Bool {
        title == ControlItemIdentifier.visible.rawValue && isThawOwnedNamespace
    }

    /// Whether this tag is a zero-width Hidden / Always-Hidden section divider.
    /// These may anchor section-boundary ⌘-drags but are never drag sources.
    public var matchesSectionBoundaryControlItem: Bool {
        isControlItem && !matchesVisibleControlItem
    }

    /// A Boolean value that indicates whether the item identified
    /// by this tag is a control item owned by Ice.
    public var isControlItem: Bool {
        if isThawOwnedNamespace, title.hasPrefix("Thaw.ControlItem.") {
            return true
        }
        return MenuBarItemTag.controlItems.contains(where: { $0.namespace == namespace && $0.title == title }) ||
            title.contains(".Spacer.")
    }

    /// A Boolean value that indicates whether the item identified
    /// by this tag is a "BentoBox" item owned by the menu bar hosting process.
    public var isBentoBox: Bool {
        namespace.isMenuBarHostingNamespace && title.hasPrefix("BentoBox")
    }

    /// A Boolean value that indicates whether the item identified
    /// by this tag is a system-created clone of an actual item,
    /// and therefore invalid for management.
    ///
    /// The title is a stable name the WindowServer assigns to clone
    /// windows, but the namespace varies: it can be a UUID, the owning
    /// process name (Window Server) when the source PID never resolves,
    /// or even a real bundle ID when the clone spatially mis-matches a
    /// nearby app. Matching on the title alone catches every variant;
    /// gating on a UUID namespace missed the process-name and bundle-ID
    /// clones seen in the field.
    public var isSystemClone: Bool {
        title == "System Status Item Clone"
    }

    /// A textual representation of the tag.
    public var description: String {
        var result = String(describing: namespace)
        if !title.isEmpty {
            result.append(":\(title)")
        }
        if instanceIndex > 0 {
            result.append(":\(instanceIndex)")
        }
        if let windowID, !isSystemItem {
            result.append(" (windowID: \(windowID))")
        }
        return result
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(namespace)
        hasher.combine(title)
        hasher.combine(instanceIndex)
        if !isSystemItem {
            hasher.combine(windowID)
        }
    }

    public static func == (lhs: MenuBarItemTag, rhs: MenuBarItemTag) -> Bool {
        if lhs.namespace != rhs.namespace || lhs.title != rhs.title || lhs.instanceIndex != rhs.instanceIndex {
            return false
        }
        if lhs.isSystemItem {
            return true
        }
        return lhs.windowID == rhs.windowID
    }

    /// Returns a Boolean value that indicates whether the given tag
    /// matches this tag, ignoring their window identifiers.
    public func matchesIgnoringWindowID(_ other: MenuBarItemTag) -> Bool {
        // Canonical namespaces, so the two spellings the same item can arrive
        // under still resolve to one item — otherwise this disagrees with
        // ``tagIdentifier``, and two tags with an identical persisted key would
        // report that they do not match.
        Self.canonicalNamespace(namespace) == Self.canonicalNamespace(other.namespace) &&
            canonicalTitle == other.canonicalTitle &&
            instanceIndex == other.instanceIndex
    }

    /// Returns whether this tag identifies the same logical item as `other`,
    /// including Thaw's visible control across namespace aliases.
    public func matchesIdentity(of other: MenuBarItemTag) -> Bool {
        if matchesVisibleControlItem, other.matchesVisibleControlItem {
            return true
        }
        return matchesIgnoringWindowID(other)
    }

    /// A stable string identifier that uniquely identifies this tag
    /// across window ID changes (e.g. app restarts). Includes the
    /// instance index when it is nonzero so that multiple items from
    /// the same app with the same title are distinguishable.
    public var tagIdentifier: String {
        // Canonical on both halves. The namespace fold is what keeps an item
        // that arrives under an alternate spelling on the *same* persisted key
        // as the saved layout entry written for it.
        let namespace = Self.canonicalNamespace(namespace)
        let title = canonicalTitle
        if instanceIndex > 0 {
            return "\(namespace):\(title):\(instanceIndex)"
        }
        return "\(namespace):\(title)"
    }

    public var canonicalTitle: String {
        Self.canonicalTitle(namespace: namespace, title: title)
    }

    /// Canonicalizes under **either** namespace iStat's items can arrive with.
    ///
    /// Matching only ``iStatMenusStatusBundleID`` skipped canonicalization
    /// whenever an item arrived under the process name — which is what macOS
    /// files these items as — so live metric values stayed in the identity and
    /// every refresh minted a new one. Measured 2026-07-30: 97 of 151 entries
    /// in `MenuBarItemManager.knownItemIdentifiers` were per-tick junk
    /// (`iStat Menus Menubar:CPU 24%`, and so on). Churning identity breaks
    /// everything keyed on it — persisted section assignments stop sticking and
    /// image-cache keys go stale, which is the wrong-glyph symptom.
    ///
    /// ``MenuBarItemAXProvider/identityTitle(namespace:identifier:accessibilityDescription:displayTitle:)``
    /// already matched both namespaces; these two did not.
    ///
    /// Canonicalizing the *title* under both namespaces was tried alone on
    /// 2026-07-31 and reverted: it stopped the churn, but left two identity
    /// spaces — `iStat Menus Menubar:CPU #°` and
    /// `com.bjango.istatmenus.status:CPU #°` — for one item. Saved layout
    /// entries are written in the bundle-ID spelling, so the process-name half
    /// matched nothing and those items could not be placed or rearranged.
    ///
    /// The missing half was ``canonicalNamespace(_:)``: fold the namespace as
    /// well, and both spellings collapse onto the single identity the persisted
    /// layouts already use.
    public static func canonicalTitle(namespace: Namespace, title: String) -> String {
        guard case let .string(value) = canonicalNamespace(namespace) else {
            return title
        }
        return canonicalVolatileTitle(namespaceValue: value, title: title)
    }

    /// Applies the volatile-title rule for `namespaceValue`, or returns the
    /// title untouched for every other app.
    ///
    /// Deliberately keyed on the namespace rather than applied everywhere:
    /// numbers are meaningful in ordinary autosave names, and folding `Item-0`
    /// onto `Item-1` would merge two genuinely different items.
    public static func canonicalVolatileTitle(namespaceValue: String, title: String) -> String {
        if iStatMenusNamespaces.contains(namespaceValue) {
            return canonicalIStatMetricTitle(title)
        }
        // KelvinShift publishes its colour temperature as the title and changes
        // it continuously. Left alone, every value minted a fresh identity:
        // `MenuBarItemManager.savedSectionOrder` was measured on 2026-07-31
        // holding FOURTEEN entries for the one item (2123K, 2129K, 2136K,
        // 2144K, 2162K, 2172K, 2183K, 2194K, 2205K, 2217K, 2230K, 2242K …).
        // Each churn is a new item to every consumer: the Layout bar builds a
        // new view, the cluster/handle bookkeeping is rebuilt, and the pane
        // cannot hold still long enough to start a drag.
        //
        // An earlier attempt folded this everywhere and had to be reverted
        // because it also reached the *position* key. The fold is deliberately
        // shaped to be reversible in that regard: `canonicalKelvinShiftTitle`
        // preserves the leading space and the `K` suffix so a resolver working
        // from the raw AX title is unaffected — verify
        // `status:com.kelvinshift.app::` in `com.apple.MenuBarAgent` after any
        // change here, and revert if a `:: #K` key appears.
        if namespaceValue == kelvinShiftBundleID {
            return canonicalKelvinShiftTitle(title)
        }
        return title
    }

    /// Collapses KelvinShift's live colour temperature to one stable identity.
    public static func canonicalKelvinShiftTitle(_ raw: String) -> String {
        raw.replacing(/[-+]?\d+(?:[.,]\d+)?/, with: "#")
    }

    /// Folds a namespace's alternate spellings, as a bare string.
    private static func canonicalNamespaceValue(_ value: String) -> String {
        iStatMenusNamespaces.contains(value) ? iStatMenusStatusBundleID : value
    }

    /// Folds a namespace's alternate spellings onto the one Thaw persists.
    ///
    /// iStat's items reach Thaw under two names — MenuBarAgent files them by
    /// executable name, `NSRunningApplication` resolves the same helper to its
    /// bundle ID — and which one an item arrives with depends on the path it
    /// came in through. Left unfolded, one item has two identities: it churns
    /// its persisted key, splits its image-cache entries, and never accumulates
    /// the two-or-more siblings that make a group.
    ///
    /// This is applied only where an **identity** is derived. The stored
    /// ``namespace`` is left exactly as it arrived, because `namespace`
    /// `description` is consumed as a real bundle identifier elsewhere, and
    /// rewriting it there would hand those callers a name that is not the one
    /// macOS knows the item by.
    public static func canonicalNamespace(_ namespace: Namespace) -> Namespace {
        guard case let .string(value) = namespace,
              iStatMenusNamespaces.contains(value)
        else {
            return namespace
        }
        return .string(iStatMenusStatusBundleID)
    }

    public static func canonicalPersistentIdentifier(_ identifier: String) -> String {
        // Accepts either spelling and always emits the bundle-ID one, so a key
        // persisted by an older build migrates on read instead of going stale.
        // The same pass re-folds the *title*, which is what lets a layout saved
        // against a stale live value — a sky condition, a colour temperature —
        // land on the identity the current build produces.
        for namespace in volatileTitleNamespaces.sorted() {
            let prefix = "\(namespace):"
            guard identifier.hasPrefix(prefix) else {
                continue
            }
            let canonicalPrefix = "\(canonicalNamespaceValue(namespace)):"
            let suffix = String(identifier.dropFirst(prefix.count))
            if let separator = suffix.lastIndex(of: ":") {
                let title = String(suffix[..<separator])
                let instance = String(suffix[suffix.index(after: separator)...])
                if Int(instance) != nil {
                    let folded = canonicalVolatileTitle(namespaceValue: namespace, title: title)
                    return "\(canonicalPrefix)\(folded):\(instance)"
                }
            }
            let folded = canonicalVolatileTitle(namespaceValue: namespace, title: suffix)
            return "\(canonicalPrefix)\(folded)"
        }
        return identifier
    }

    public static func canonicalPersistentIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let canonical = canonicalPersistentIdentifier(identifier)
            guard seen.insert(canonical).inserted else {
                return nil
            }
            return canonical
        }
    }

    public static func canonicalIStatMetricTitle(_ raw: String) -> String {
        let normalized = raw
            .replacing(/[-+]?\d+(?:[.,]\d+)?/, with: "#")
            // Unit prefixes shift with magnitude — `812 B/s` becomes `4 KB/s`
            // becomes `1.2 MB/s` — so the prefix has to go the same way the
            // digits did.
            .replacing(/#\s*[KMGTPE]?[Bb]\/s/, with: "# B/s")
            .replacing(/#\s*[KMGTPE]?[Bb]/, with: "# B")
        guard isIStatWeatherTitle(normalized) else {
            return normalized
        }
        return iStatWeatherIdentityTitle
    }

    /// The one identity every iStat weather title collapses to.
    ///
    /// Not a normalized form of any real title, deliberately: matching one
    /// would mean the identity changes the day iStat rewords its forecast.
    public static let iStatWeatherIdentityTitle = "iStat.Weather"

    /// Recognizes an iStat weather title after numeric normalization.
    ///
    /// The forecast carries the sky condition as prose — `Clear`,
    /// `Partly cloudy`, `Mostly cloudy`, `Thunderstorms` — and that text is not
    /// a value the digit rule can reach. Measured 2026-07-31: three conditions
    /// had already minted three separate entries in `knownItemIdentifiers` for
    /// the single weather item, each one able to be filed into a different
    /// section. The condition list is open-ended, so this matches the parts of
    /// the sentence that are *not* weather-dependent and discards the rest
    /// rather than trying to enumerate conditions.
    private static func isIStatWeatherTitle(_ normalized: String) -> Bool {
        if normalized == iStatWeatherIdentityTitle {
            return true
        }
        // Both markers survive every condition and every unit setting: the
        // sentence always opens with the current reading and always closes with
        // the precipitation chance.
        return normalized.hasPrefix("Currently ") || normalized.contains("chance of rain")
    }

    /// Creates a tag with the given namespace, title, window identifier,
    /// and instance index.
    public init(namespace: Namespace, title: String, windowID: CGWindowID? = nil, instanceIndex: Int = 0) {
        self.namespace = namespace
        self.title = title
        self.windowID = windowID
        self.instanceIndex = instanceIndex
    }

    /// Creates a tag for the control item with the given identifier.
    private init(controlItem identifier: ControlItemIdentifier) {
        self.init(namespace: .thaw, title: identifier.rawValue, instanceIndex: 0)
    }
}

// MARK: MenuBarItemTag Constants

public extension MenuBarItemTag {
    // MARK: Special Item Lists

    /// Fixed items in the legacy Control Center-hosted layout. Keep this list
    /// explicit rather than deriving it from the current OS namespace.
    private static let legacyImmovableItems: [MenuBarItemTag] = [
        MenuBarItemTag(namespace: .controlCenter, title: "Clock"),
        MenuBarItemTag(namespace: .controlCenter, title: "BentoBox-0"),
        siri,
        ssMenuAgent,
    ]

    /// An array of tags for items whose movement is prevented by macOS.
    ///
    /// These items have fixed positions at the trailing end of the menu bar,
    /// and cannot be hidden.
    ///
    /// This list contains the "Clock", "Control Center", "Siri", and
    /// "Screen Sharing" (ssMenuAgent) items.
    static var immovableItems: [MenuBarItemTag] {
        [clock, controlCenter, siri, ssMenuAgent]
    }

    /// An array of tags for items that can be moved, but cannot be hidden.
    static var nonHideableItems: [MenuBarItemTag] {
        [visibleControlItem, audioVideoModule, faceTime, screenCaptureUI, gameMode]
    }

    /// An array of tags for items representing Ice's control items.
    static let controlItems = ControlItemIdentifier.allCases.map(\.tag)

    /// Apple modules observed under `com.apple.MenuBarAgent` on macOS 27 that
    /// behave as fixed trailing system controls. Other MenuBarAgent modules
    /// (Wi-Fi, Bluetooth, Sound, Focus, Now Playing, etc.) remain movable.
    static let menuBarAgentAnchoredModuleTitles: Set<String> = [
        "Clock",
        "ControlCenter",
        "BentoBox-0",
        "Siri",
        "com.apple.menuextra.clock",
        "com.apple.menuextra.controlcenter",
        "com.apple.menuextra.siri",
    ]

    /// Separate Apple/system agents that Thaw should display but not move.
    private static let fixedSystemAgentNamespaces: Set<Namespace> = [
        .gamePolicyAgent,
        .screenCaptureUI,
        .ssMenuAgent,
    ]

    /// Canonical sort rank for anchored system items at the trailing edge of
    /// a hidden or always-hidden section. Lower values sort first (leftmost
    /// among the trailing group). Non-anchored items return a value larger
    /// than any anchored rank so they always precede anchored items.
    static func anchoredSystemItemRank(_ tag: MenuBarItemTag) -> Int {
        if tag.title == controlCenter.title
            || tag.title == "ControlCenter"
            || tag.title == "com.apple.menuextra.controlcenter"
        {
            return 0
        }
        if tag == .siri {
            return 1
        }
        if tag.title == clock.title
            || tag.title == "com.apple.menuextra.clock"
        {
            return 2
        }
        return 3
    }

    // MARK: Control Items

    /// The tag for Ice's control item for the "Visible" section.
    static let visibleControlItem = MenuBarItemTag(controlItem: .visible)

    /// The tag for Ice's control item for the "Hidden" section.
    static let hiddenControlItem = MenuBarItemTag(controlItem: .hidden)

    /// The tag for Ice's control item for the "Always-Hidden" section.
    static let alwaysHiddenControlItem = MenuBarItemTag(controlItem: .alwaysHidden)

    // MARK: Other Special Items

    /// The namespace used by system-owned menu bar items (Clock, BentoBox, AudioVideoModule…).
    ///
    /// On macOS 26 the hosting process is Control Center; on macOS 27+ it is MenuBarAgent.
    private static var systemHostNamespace: Namespace {
        if #available(macOS 27, *) {
            .menuBarAgent
        } else {
            .controlCenter
        }
    }

    /// The tag for the system item that appears in the menu bar
    /// during screen or audio capture.
    static var audioVideoModule: MenuBarItemTag {
        MenuBarItemTag(namespace: systemHostNamespace, title: "AudioVideoModule")
    }

    /// The tag for the system "Clock" item.
    static var clock: MenuBarItemTag {
        MenuBarItemTag(namespace: systemHostNamespace, title: "Clock")
    }

    /// The tag for the system "Control Center" item.
    static var controlCenter: MenuBarItemTag {
        MenuBarItemTag(namespace: systemHostNamespace, title: "BentoBox-0")
    }

    /// The tag for the system "FaceTime" item.
    static var faceTime: MenuBarItemTag {
        MenuBarItemTag(namespace: systemHostNamespace, title: "FaceTime")
    }

    /// The tag for the system "Music Recognition" item.
    static var musicRecognition: MenuBarItemTag {
        MenuBarItemTag(namespace: systemHostNamespace, title: "MusicRecognition")
    }

    /// The tag for the system item that appears in the menu bar
    /// during recordings started by the macOS "Screenshot" tool.
    static let screenCaptureUI = MenuBarItemTag(namespace: .screenCaptureUI, title: "Item-0")

    /// The tag for the system "Siri" item.
    static let siri = MenuBarItemTag(namespace: .systemUIServer, title: "Siri")

    /// The tag for the system "SSMenuAgent" item (Screen Sharing menu extra).
    ///
    /// macOS prevents this item from being repositioned via Command+drag.
    /// The item visually follows the cursor during the drag, but springs
    /// back to its original position on mouse-up.
    static let ssMenuAgent = MenuBarItemTag(namespace: .ssMenuAgent, title: "Item-0")

    /// The tag for the system "Time Machine" item.
    static let timeMachine = MenuBarItemTag(namespace: .systemUIServer, title: "com.apple.menuextra.TimeMachine")

    /// The tag for the system "Game Mode" item.
    static let gameMode = MenuBarItemTag(namespace: .gamePolicyAgent, title: "Item-0")
}

// MARK: - MenuBarItemTag.Namespace

public extension MenuBarItemTag {
    /// A type that represents a menu bar item namespace.
    enum Namespace: Hashable, CustomStringConvertible, Sendable {
        /// The `null` namespace.
        case null
        /// A namespace represented by a string.
        case string(String)
        /// A namespace represented by a UUID.
        case uuid(UUID)

        /// A textual representation of the namespace.
        public var description: String {
            switch self {
            case .null: "null"
            case let .string(string): string
            case let .uuid(uuid): uuid.uuidString
            }
        }

        /// A Boolean value that indicates whether this namespace is
        /// the `null` namespace.
        public var isNull: Bool {
            switch self {
            case .null: true
            case .string, .uuid: false
            }
        }

        /// A Boolean value that indicates whether this namespace is
        /// represented by a string.
        public var isString: Bool {
            switch self {
            case .string: true
            case .uuid, .null: false
            }
        }

        /// A Boolean value that indicates whether this namespace is
        /// represented by a UUID.
        public var isUUID: Bool {
            switch self {
            case .uuid: true
            case .null, .string: false
            }
        }

        /// A Boolean value that indicates whether this namespace is the system
        /// process that owns menu bar item windows at the CG layer.
        ///
        /// On macOS 26 the hosting process is Control Center
        /// (`com.apple.controlcenter`); on macOS 27 and later it is
        /// MenuBarAgent (`com.apple.MenuBarAgent`).
        public var isMenuBarHostingNamespace: Bool {
            if #available(macOS 27, *) {
                return self == .menuBarAgent
            } else {
                return self == .controlCenter
            }
        }

        /// Creates a namespace with the given optional value.
        ///
        /// - Parameter value: An optional value for the namespace.
        ///
        /// - Returns: A namespace represented by a string when `value`
        ///   is not `nil`. Otherwise, the `null` namespace.
        public static func optional(_ value: String?) -> Namespace {
            value.map { .string($0) } ?? .null
        }
    }
}

// MARK: MenuBarItemTag.Namespace Constants

public extension MenuBarItemTag.Namespace {
    /// The namespace for the "Thaw" process.
    static let thaw = string(ThawMenuBarIdentity.bundleIdentifier)

    /// The namespace for the "Control Center" process.
    static let controlCenter = string("com.apple.controlcenter")

    /// The namespace for the "MenuBarAgent" process (macOS 27+).
    static let menuBarAgent = string("com.apple.MenuBarAgent")

    /// The namespace for the "PasswordsMenuBarExtra" process.
    static let passwords = string("com.apple.Passwords.MenuBarExtra")

    /// The namespace for the "screencaptureui" process.
    static let screenCaptureUI = string("com.apple.screencaptureui")

    /// The namespace for the "SystemUIServer" process.
    static let systemUIServer = string("com.apple.systemuiserver")

    /// The namespace for the "TextInputMenuAgent" process.
    static let textInputMenuAgent = string("com.apple.TextInputMenuAgent")

    /// The namespace for the "SSMenuAgent" process (Screen Sharing menu extra).
    static let ssMenuAgent = string("com.apple.SSMenuAgent")

    /// The namespace for the "GamePolicyAgent" process (Game Mode).
    static let gamePolicyAgent = string("GamePolicyAgent")

    /// The namespace for the "WeatherMenu" process.
    static let weather = string("com.apple.weather.menu")
}

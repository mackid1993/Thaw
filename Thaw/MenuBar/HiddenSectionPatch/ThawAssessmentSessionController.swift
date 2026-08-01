//
//  ThawAssessmentSessionController.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import MenuBarModel
import os.log

/// A ``RuntimeSessionControllering`` that builds the assessment-mode allowlist
/// itself instead of delegating to `PlatformRuntimeKit`.
///
/// ## Why this exists
///
/// `RuntimeSessionController.apply(sectionAssignment:allItems:)` builds its
/// allowlist inside the closed `prk-bin` artifact by sweeping
/// `NSWorkspace.shared.runningApplications` and collecting each app's
/// `bundleIdentifier`. That is the *only* source; the item namespaces Thaw
/// passes in `allItems` are never consulted for it.
///
/// For almost every app that is correct, because the bundle identifier is also
/// the name MenuBarAgent files the app's status items under. iStat Menus is the
/// exception on this machine: `NSRunningApplication` resolves its status helper
/// to `com.bjango.istatmenus.status`, while MenuBarAgent keys the same five
/// items under the executable name `iStat Menus Menubar` — visible directly in
/// `com.apple.MenuBarAgent`'s `TrailingItemPreferredPositions`, which carries
/// entries such as `status:iStat Menus Menubar::com.bjango.istatmenus.cpu`.
///
/// The allowlist therefore names an owner MenuBarAgent never looks up, so the
/// moment the assertion is held at all, iStat's modules are not on the list and
/// stop being drawn — while remaining fully present in AX, reporting bounds, and
/// neither concealed nor removed. Measured across four separate bundles: the
/// behaviour is binary and completely independent of *which* bundle is
/// concealed, which is exactly what an allowlist miss looks like and is not what
/// a rendering bug looks like.
///
/// This controller reproduces the same call — `MBAssessmentModeConfiguration`
/// and `MBAssessmentModeAssertion` out of `MenuBarClientCore` — but emits every
/// name form each running app answers to (bundle identifier, executable base
/// name, localized name) rather than the bundle identifier alone. The rule is
/// general: it is not keyed to any particular app, and it repairs any owner the
/// system files under something other than its bundle identifier. An allowlist
/// entry is purely additive and cannot mis-address another app, which is what
/// makes extra spellings safe here even though a second *position* key is not.
///
/// ## Measured outcome — this does not fix iStat Menus
///
/// Tested 2026-08-01 with a 244-entry allowlist naming iStat five ways
/// (`com.bjango.istatmenus.status`, `com.bjango.istatmenus.agent`,
/// `iStat Menus Menubar`, `iStat Menus Helper`,
/// `iStat Menus Helper Graphics and Media`) and **zero** bundles concealed:
/// iStat's modules still stopped rendering, while every other app on the bar
/// rendered normally. Repeated with the narrow rule (only spellings already
/// present in `TrailingItemPreferredPositions`) — same result.
///
/// The allowlist's *contents* are therefore not the mechanism; merely holding
/// an assessment-mode assertion is. That also rules out the one-line change to
/// `prk-bin`'s `runningApplications` sweep that this controller was written to
/// prove out. Whatever suppresses iStat reacts to assessment mode itself, on
/// macOS's side or iStat's, and no allowlist Thaw can construct reaches it.
///
/// Kept because the plumbing is correct and independently useful: concealment
/// works, every other app is unaffected, and this is the only place Thaw can
/// shape the allowlist at all if the behaviour changes. Opt-in via
/// `ThawUseNativeAssertion`; when it is off, or when the private classes cannot
/// be resolved, ``MenuBarSectionController`` keeps using
/// `RuntimeSessionController` exactly as before.
@MainActor
final class ThawAssessmentSessionController: RuntimeSessionControllering {
    private static let log = DiagLog(category: "ThawAssertion")

    /// `MBSystemItemIdentifier` raw values. Everything outside a concealed set
    /// stays allowed; Thaw does not conceal system items through this path.
    private static let allSystemItemIDs = 0 ... 8

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"

    /// Strong reference. The assertion is only in force while it is alive, so
    /// letting this deallocate silently un-hides everything.
    private var assertion: AnyObject?

    private var configurationClass: AnyClass?
    private var assertionClass: AnyClass?
    private var lastAppliedAllowlist: Set<String>?

    private(set) var isHolding = false

    init() {
        loadPrivateClasses()
    }

    // MARK: - Availability

    var isHidingAvailable: Bool {
        configurationClass != nil && assertionClass != nil
    }

    @discardableResult
    func refreshAvailability() -> Bool {
        if !isHidingAvailable {
            loadPrivateClasses()
        }
        return isHidingAvailable
    }

    func markExternallyTornDown() {
        assertion = nil
        isHolding = false
        lastAppliedAllowlist = nil
        Self.log.info("assertion marked externally torn down")
    }

    private func loadPrivateClasses() {
        if dlopen(Self.frameworkPath, RTLD_NOW) == nil,
           let error = dlerror().map({ String(cString: $0) })
        {
            Self.log.error("dlopen MenuBarClientCore failed: \(error)")
        }
        configurationClass = NSClassFromString("MBAssessmentModeConfiguration")
        assertionClass = NSClassFromString("MBAssessmentModeAssertion")
        if !isHidingAvailable {
            Self.log.error(
                "private assessment classes unavailable "
                    + "(configuration: \(self.configurationClass != nil), assertion: \(self.assertionClass != nil))"
            )
        }
    }

    // MARK: - Apply

    @discardableResult
    func apply(sectionAssignment: [String: MenuBarSection.Name], allItems: [MenuBarItem]) -> Bool {
        guard isHidingAvailable else { return false }

        let concealed = Self.concealedNamespaces(sectionAssignment: sectionAssignment, allItems: allItems)

        // Refuse to conceal on an empty item cache. Without live items every
        // namespace reads as unconcealed, and a moment later as concealed —
        // RuntimeSessionController guards the same case for the same reason.
        if !concealed.isEmpty, allItems.isEmpty {
            Self.log.error("item cache is empty while \(concealed.count) namespace(s) are concealed; skipping")
            return false
        }

        let allowlist = Self.allowedBundleIdentifiers(concealing: concealed)

        guard allowlist != lastAppliedAllowlist || !isHolding else {
            return false
        }

        let systemItems = Self.allSystemItemIDs.map { NSNumber(value: $0) } as NSArray
        let bundles = Array(allowlist).sorted() as NSArray

        guard let configuration = makeConfiguration(systemItems: systemItems, bundles: bundles) else {
            Self.log.error("failed to construct MBAssessmentModeConfiguration")
            return false
        }
        guard activate(configuration: configuration) else {
            Self.log.error("failed to activate MBAssessmentModeAssertion")
            return false
        }

        lastAppliedAllowlist = allowlist
        isHolding = true
        Self.log.info(
            "applying restriction: allowedBundles=\(allowlist.count), "
                + "concealed=\(concealed.sorted().joined(separator: ","))"
        )
        return true
    }

    @discardableResult
    func pulse(sectionAssignment: [String: MenuBarSection.Name], allItems: [MenuBarItem]) -> Bool {
        // Drop the assertion entirely, then rebuild. Re-activating in place does
        // not force MenuBarAgent to re-evaluate items it has already filed.
        assertion = nil
        isHolding = false
        lastAppliedAllowlist = nil
        return apply(sectionAssignment: sectionAssignment, allItems: allItems)
    }

    // MARK: - Allowlist construction

    /// Namespaces every one of whose live items is assigned to a concealed
    /// section. An app with even one visible item stays on the allowlist, since
    /// the assertion's granularity is the owner, not the item.
    private static func concealedNamespaces(
        sectionAssignment: [String: MenuBarSection.Name],
        allItems: [MenuBarItem]
    ) -> Set<String> {
        var concealedCandidates = Set<String>()
        var keepVisible = Set<String>()

        for item in allItems where !item.isControlItem {
            let namespace = item.tag.namespace.description
            guard !namespace.isEmpty else { continue }
            let section = sectionAssignment[item.uniqueIdentifier] ?? .visible
            switch section {
            case .hidden, .alwaysHidden:
                concealedCandidates.insert(namespace)
            default:
                keepVisible.insert(namespace)
            }
        }

        return concealedCandidates.subtracting(keepVisible)
    }

    /// Every running app's bundle identifier, minus the concealed ones, plus the
    /// name form for any app the system files under something other than its
    /// bundle identifier.
    private static func allowedBundleIdentifiers(concealing concealed: Set<String>) -> Set<String> {
        let systemNamespaces = MenuBarItemTag.Namespace.systemStatusNamespaces
        var allowed = Set<String>()
        var aliased = [String]()

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            guard !concealed.contains(bundleID) else { continue }
            allowed.insert(bundleID)

            // Emit every name form the app answers to. The narrow rule — only
            // spellings already present in the system's own position keys —
            // put `iStat Menus Menubar` on the list and iStat still went dark,
            // so the key MenuBarAgent matches on is not the position-key owner.
            // Widened to find it; an allowlist entry is additive and cannot
            // mis-address another app.
            let executableName = app.executableURL?.deletingPathExtension().lastPathComponent
            for candidate in [executableName, app.localizedName] {
                guard let candidate, !candidate.isEmpty, candidate != bundleID else { continue }
                guard !concealed.contains(candidate) else { continue }
                if allowed.insert(candidate).inserted, systemNamespaces.contains(candidate) {
                    aliased.append("\(bundleID)->\(candidate)")
                }
            }
        }

        // Thaw's own control items must never be concealed by its own assertion.
        allowed.insert(Constants.bundleIdentifier)

        if !aliased.isEmpty {
            log.info("allowlist aliases: \(aliased.joined(separator: ", "))")
        }
        return allowed.subtracting(concealed)
    }

    // MARK: - Private API plumbing

    /// `objc_msgSend` typed for `-initWithAllowedSystemItems:allowedBundleIdentifiers:`.
    ///
    /// `NSObject.perform(_:with:with:)` is not usable here: it cannot marshal
    /// this signature, and its `Unmanaged` result has the wrong ownership for an
    /// `alloc`/`init` pair, which would let ARC release the configuration out
    /// from under a long-lived assertion.
    private typealias InitConfigurationFn = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?
    private typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
    private typealias InitFn = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias ActivateFn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?) -> Void

    private static let msgSendPointer: UnsafeMutableRawPointer? = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        return dlsym(handle, "objc_msgSend")
    }()

    private func makeConfiguration(systemItems: NSArray, bundles: NSArray) -> AnyObject? {
        guard let pointer = Self.msgSendPointer, let configurationClass else { return nil }
        let alloc = unsafeBitCast(pointer, to: AllocFn.self)
        guard let raw = alloc(configurationClass, NSSelectorFromString("alloc")) else { return nil }
        let initialize = unsafeBitCast(pointer, to: InitConfigurationFn.self)
        return initialize(
            raw,
            NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"),
            systemItems,
            bundles
        )
    }

    private func activate(configuration: AnyObject) -> Bool {
        guard let pointer = Self.msgSendPointer, let assertionClass else { return false }

        if assertion == nil {
            let alloc = unsafeBitCast(pointer, to: AllocFn.self)
            guard let raw = alloc(assertionClass, NSSelectorFromString("alloc")) else { return false }
            let initialize = unsafeBitCast(pointer, to: InitFn.self)
            guard let instance = initialize(raw, NSSelectorFromString("init")) else { return false }
            assertion = instance
        }
        guard let assertion else { return false }

        // A nil completion handler is not safe if the callee invokes it
        // unconditionally; an empty block is. Extra arguments passed to a block
        // that declares none are harmless on arm64.
        let completion: @convention(block) () -> Void = {}
        let activate = unsafeBitCast(pointer, to: ActivateFn.self)
        activate(
            assertion,
            NSSelectorFromString("activateWithConfiguration:completionHandler:"),
            configuration,
            completion as AnyObject
        )
        return true
    }
}

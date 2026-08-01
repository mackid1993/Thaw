//
//  AssessmentAllowlistPatch.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import MenuBarModel
import ObjectiveC.runtime

/// Adds the missing owner spellings to the assessment-mode allowlist, in place,
/// wherever it is built.
///
/// ## The defect this repairs
///
/// `PlatformRuntimeKit` builds `allowedBundleIdentifiers` by sweeping
/// `NSWorkspace.shared.runningApplications` and collecting each app's
/// `bundleIdentifier`. MenuBarAgent, however, does not always file an app's
/// status items under its bundle identifier. When it cannot resolve a bundle for
/// the process that vends the items — helpers living outside a normal
/// application location, for instance — it falls back to the executable name,
/// and uses that name as the owner key everywhere, `TrailingItemPreferredPositions`
/// and the assessment allowlist alike.
///
/// For such an app the allowlist names an owner MenuBarAgent never looks up, so
/// the moment any assertion is held the app is treated as not-allowed and its
/// items stop being drawn — while remaining present in the accessibility tree,
/// reporting valid bounds, and never appearing in `concealedBundles`. Concealing
/// that app *directly* looks like it works, but only because it was going to be
/// dark either way.
///
/// This is a general condition, not a property of any one app: it applies to
/// every process whose owner key differs from its bundle identifier. On the
/// machine this was diagnosed on that set happens to be iStat Menus, whose five
/// modules macOS keys as `iStat Menus Menubar::com.bjango.istatmenus.*` while
/// `NSRunningApplication` reports `com.bjango.istatmenus.status`.
///
/// ## Why a swizzle rather than a replacement controller
///
/// The allowlist is assembled inside a binary-only artifact, so there is no
/// parameter to pass and no source to change. Rebuilding the assertion in-process
/// was tried first (``ThawAssessmentSessionController``) and is retained behind
/// `ThawUseNativeAssertion`, but a hand-rolled configuration activated without
/// concealing anything it was told to conceal — an instrument that cannot hide
/// cannot be used to test a hypothesis about hiding.
///
/// Intercepting the initializer keeps PlatformRuntimeKit's working
/// configuration exactly as it is and only widens the array on its way in. The
/// widening is strictly additive: an allowlist entry names an owner permitted to
/// remain visible, so an extra spelling can grant nothing that was not already
/// granted to the same process, and cannot address a different app. That is what
/// makes this safe here even though a second *position* key is not — a duplicate
/// position key makes MenuBarAgent lay the item out twice.
///
/// Concealed apps are unaffected by construction: PlatformRuntimeKit has already
/// removed them from the array before this sees it, so their alternate spellings
/// are never added and concealment keeps working.
///
/// ## Refuted — kept dormant
///
/// MenuBarAgent does not resolve a *wrong* owner string for these items. It
/// resolves **no owner at all**. Its own log (`subsystem == "com.apple.menubar"`,
/// category `statusItems`) emits `No server elements for status item: nil` for
/// exactly five items in every burst, ~4 ms after `didActivateVisibilityRestriction`,
/// constant regardless of what is concealed — while the bundle actually being
/// concealed is logged by name in the same burst. Restriction does not null an
/// owner; the `nil` is intrinsic to those items.
///
/// An allowlist is `[String]`. No string matches `nil`, at any spelling or width,
/// so those items are unconditionally not-allowed the moment any visibility
/// restriction is held, from any origin. This patch was observed running at
/// 03:30:51.134 — logging that it had added the process-name spelling — with the
/// five items going dark 4 ms later in the same second.
///
/// Left in place, off by default, because it is correct in itself and costs
/// nothing: it makes the allowlist name apps the way macOS keys them. It simply
/// does not address this defect, which has no client-side fix.
enum AssessmentAllowlistPatch {
    private static let log = DiagLog(category: "AllowlistPatch")
    private static var isInstalled = false

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"

    private typealias InitIMP = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?

    /// Installs the interception. Safe to call more than once; a failure at any
    /// step leaves the shipped behaviour untouched.
    static func installIfNeeded() {
        guard !isInstalled else { return }
        // Default OFF: the premise below was disproven after this was written.
        // See the refutation in the type documentation. Opt in with
        // `ThawEnableAllowlistSpellingPatch` if the server behaviour ever changes.
        guard UserDefaults.standard.bool(forKey: "ThawEnableAllowlistSpellingPatch") else {
            return
        }
        isInstalled = true

        if dlopen(frameworkPath, RTLD_NOW) == nil, let error = dlerror().map({ String(cString: $0) }) {
            log.error("dlopen MenuBarClientCore failed: \(error)")
        }
        guard let configurationClass = NSClassFromString("MBAssessmentModeConfiguration") else {
            log.error("MBAssessmentModeConfiguration unavailable; leaving the allowlist alone")
            return
        }
        let selector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        guard let method = class_getInstanceMethod(configurationClass, selector) else {
            log.error("initWithAllowedSystemItems:allowedBundleIdentifiers: not found")
            return
        }

        let originalIMP = unsafeBitCast(method_getImplementation(method), to: InitIMP.self)
        let replacement: @convention(block) (AnyObject, NSArray, NSArray) -> AnyObject? = {
            receiver, systemItems, bundleIdentifiers in
            let widened = Self.widened(bundleIdentifiers)
            return originalIMP(receiver, selector, systemItems, widened)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        log.info("allowlist spelling patch installed")
    }

    /// Returns the allowlist with an extra entry for every listed app whose
    /// status items macOS files under a name other than its bundle identifier.
    ///
    /// Both name forms are emitted when both qualify. The executable base name
    /// and the localized name are frequently identical, and nothing observable
    /// from this side distinguishes which one MenuBarAgent keyed on, so guessing
    /// between them would be the only way to get it wrong.
    private static func widened(_ bundleIdentifiers: NSArray) -> NSArray {
        guard let allowed = bundleIdentifiers as? [String], !allowed.isEmpty else {
            return bundleIdentifiers
        }
        let systemOwners = MenuBarItemTag.Namespace.systemStatusNamespaces
        guard !systemOwners.isEmpty else { return bundleIdentifiers }

        let allowedSet = Set(allowed)
        var additions = [String]()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  allowedSet.contains(bundleID),
                  // Only diverge where macOS has demonstrably filed this app
                  // under something else. An app the system already keys by
                  // bundle identifier needs nothing.
                  !systemOwners.contains(bundleID)
            else {
                continue
            }
            let candidates = [
                app.executableURL?.deletingPathExtension().lastPathComponent,
                app.localizedName,
            ]
            for candidate in candidates.compactMap({ $0 }) {
                guard systemOwners.contains(candidate),
                      !allowedSet.contains(candidate),
                      !additions.contains(candidate)
                else {
                    continue
                }
                additions.append(candidate)
                log.info("allowlist: adding owner spelling \(candidate) for \(bundleID)")
            }
        }

        // Tried and rejected: appending "", "(null)", "nil" and "<nil>" as
        // sentinels for the nil-owner case. MenuBarAgent still tore down the
        // same five items 9 ms after didActivateVisibilityRestriction, so a
        // bridged optional owner does not compare equal to any of them.
        guard !additions.isEmpty else { return bundleIdentifiers }
        return (allowed + additions) as NSArray
    }
}

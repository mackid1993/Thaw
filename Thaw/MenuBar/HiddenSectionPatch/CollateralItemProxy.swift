//
//  CollateralItemProxy.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import ApplicationServices
import MenuBarModel

/// Re-publishes status items that macOS permits but refuses to draw.
///
/// ## Why this exists
///
/// While any visibility restriction is held, MenuBarAgent stops drawing certain
/// third-party status items even though it has explicitly allowed them. Verified
/// from `subsystem == "com.apple.menubar"`: with a restriction active and the
/// items re-registered, MenuBarAgent logs `Creating status item <uuid>,
/// isAllowed: true` for every one of them — and no pixels ever arrive. The permit
/// is granted and the draw does not happen.
///
/// Because the decision is `true`, there is nothing to change on the allowlist.
/// Measured and eliminated before arriving here: the owner spelling, the owner
/// *identity* (relaunching the vending helper through LaunchServices moved
/// MenuBarAgent's attribution from `nil` to the real bundle identifier, with all
/// items allowed — still not drawn), nil sentinels in the allowlist, and
/// re-registration under an active restriction.
///
/// ## What makes this work rather than merely look like it works
///
/// The affected items stay fully live in the accessibility tree. Their titles
/// keep updating while they are not being drawn — sampled six seconds apart under
/// an active restriction, `CPU 46°` → `CPU 47°`, `CPU 16%` → `CPU 20%`,
/// `Upload 2 KB/s, Download 1 KB/s` → `Upload 3 KB/s, Download 4 KB/s`.
///
/// So a stand-in does not have to be a photograph of the last frame before
/// concealment, which is what made an earlier attempt at this look dead and
/// stale. Thaw publishes its own status item and renders the *live* title as
/// text, re-read from AX on a timer. A system monitor stays a system monitor.
///
/// Clicks are forwarded through ``MenuBarItemManager/pressItemViaAccessibility``,
/// an AX press on the real element — not synthesized input, and no cursor is
/// moved.
///
/// The proxies exist only while their originals are undrawn: when the last
/// restriction lifts, the originals draw again and every proxy is torn down in
/// the same pass, so the bar is never showing both.
@MainActor
final class CollateralItemProxy {
    private static let log = DiagLog(category: "CollateralProxy")

    /// Autosave prefix. Distinct from `Thaw.ControlItem.` so the existing
    /// orphan-key pruning does not treat these as section dividers.
    static let autosavePrefix = "Thaw.Proxy."

    private struct Proxy {
        let statusItem: NSStatusItem
        var item: MenuBarItem
        var lastRenderedTitle: String?
    }

    private weak var appState: AppState?
    private var proxies: [MenuBarItemTag: Proxy] = [:]
    private var refreshTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Whether anything is currently being stood in for.
    var isActive: Bool { !proxies.isEmpty }

    /// Tags Thaw is currently publishing a stand-in for. The image cache and the
    /// layout bars use this to avoid drawing the original a second time.
    var proxiedTags: Set<MenuBarItemTag> { Set(proxies.keys) }

    // MARK: - Lifecycle

    /// Brings the set of proxies in line with `items`, creating and removing as
    /// needed. Passing an empty array tears everything down.
    func synchronize(with items: [MenuBarItem]) {
        let desired = Dictionary(items.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })

        for (tag, proxy) in proxies where desired[tag] == nil {
            NSStatusBar.system.removeStatusItem(proxy.statusItem)
            proxies.removeValue(forKey: tag)
            Self.log.info("removed stand-in for \(tag.description)")
        }

        for (tag, item) in desired where proxies[tag] == nil {
            guard let proxy = makeProxy(for: item) else { continue }
            proxies[tag] = proxy
            Self.log.info("publishing stand-in for \(tag.description)")
        }

        for (tag, item) in desired {
            proxies[tag]?.item = item
        }

        if proxies.isEmpty {
            refreshTimer?.invalidate()
            refreshTimer = nil
        } else if refreshTimer == nil {
            // 1 Hz matches how fast these readouts actually change; anything
            // faster is a busy loop over AX for no visible benefit.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTitles() }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
        refreshTitles()
    }

    /// Removes every stand-in. Called when the last restriction lifts.
    func teardown() {
        guard !proxies.isEmpty else { return }
        for proxy in proxies.values {
            NSStatusBar.system.removeStatusItem(proxy.statusItem)
        }
        Self.log.info("tore down \(self.proxies.count) stand-in(s); originals draw again")
        proxies.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Construction

    private func makeProxy(for item: MenuBarItem) -> Proxy? {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosavePrefix + item.uniqueIdentifier
        guard let button = statusItem.button else {
            NSStatusBar.system.removeStatusItem(statusItem)
            return nil
        }
        button.target = self
        button.action = #selector(proxyClicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        // Monospaced digits so a changing readout does not shuffle the whole bar
        // sideways every second.
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        button.imagePosition = .noImage
        button.toolTip = item.tag.namespace.description
        return Proxy(statusItem: statusItem, item: item, lastRenderedTitle: nil)
    }

    // MARK: - Live text

    private func refreshTitles() {
        for (tag, proxy) in proxies {
            let live = Self.liveAXTitle(for: proxy.item) ?? proxy.item.title
            let parts = Self.readout(from: live, tag: tag)
            let key = "\(parts.label)|\(parts.value)"
            guard key != proxy.lastRenderedTitle else { continue }

            guard let button = proxy.statusItem.button else { continue }
            if parts.value.isEmpty, let cached = appState?.imageCache.image(for: tag) {
                // Nothing live to render: the original's own pixels are the most
                // faithful thing available, so use them.
                let image = NSImage(cgImage: cached.cgImage, size: .zero)
                image.size = NSSize(
                    width: CGFloat(cached.cgImage.width) / cached.scale,
                    height: CGFloat(cached.cgImage.height) / cached.scale
                )
                button.image = image
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.image = Self.stackedImage(label: parts.label, value: parts.value)
                button.imagePosition = .imageOnly
                button.title = ""
            }
            proxies[tag]?.lastRenderedTitle = key
        }
    }

    /// Draws a two-line readout the way a system monitor does — small label
    /// above, value below — rather than a single run of text.
    ///
    /// Vertical stacking is not decoration: it is what these modules look like,
    /// and it is also what keeps them narrow. A horizontal `CPU 42°` is nearly
    /// twice the width of the original for the same information, which on a
    /// notched bar is the difference between fitting and not.
    private nonisolated static func stackedImage(label: String, value: String) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.black,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.black,
        ]

        let labelText = label as NSString
        let valueText = value as NSString
        let labelSize = label.isEmpty ? .zero : labelText.size(withAttributes: labelAttributes)
        let valueSize = valueText.size(withAttributes: valueAttributes)
        let width = max(labelSize.width, valueSize.width) + 4
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        if !label.isEmpty {
            labelText.draw(
                at: NSPoint(x: (width - labelSize.width) / 2, y: height - labelSize.height - 2),
                withAttributes: labelAttributes
            )
            valueText.draw(
                at: NSPoint(x: (width - valueSize.width) / 2, y: 2),
                withAttributes: valueAttributes
            )
        } else {
            valueText.draw(
                at: NSPoint(x: (width - valueSize.width) / 2, y: (height - valueSize.height) / 2),
                withAttributes: valueAttributes
            )
        }
        image.unlockFocus()
        // Template so it follows the menu bar's own appearance in light, dark and
        // over a light wallpaper, exactly as the original does.
        image.isTemplate = true
        return image
    }

    /// Reads the item's current accessibility title.
    ///
    /// Deliberately re-read rather than taken from the cached `MenuBarItem`: the
    /// cache is refreshed on Thaw's own schedule and carries a canonicalized
    /// title for identity purposes, while what belongs on the bar is whatever the
    /// element says right now.
    private nonisolated static func liveAXTitle(for item: MenuBarItem) -> String? {
        let application = AXUIElementCreateApplication(item.ownerPID)
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            "AXExtrasMenuBar" as CFString,
            &extras
        ) == .success, let extras else {
            return nil
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            extras as! AXUIElement,
            kAXChildrenAttribute as CFString,
            &children
        ) == .success, let elements = children as? [AXUIElement] else {
            return nil
        }

        // Match by canonical identity, never by position: an undrawn item's
        // frame is a phantom, and matching on it lands on whichever element
        // reflowed into those pixels.
        for element in elements {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXTitleAttribute as CFString,
                &raw
            ) == .success, let title = raw as? String else {
                continue
            }
            let canonical = MenuBarItemTag.canonicalTitle(
                namespace: item.tag.namespace,
                title: title
            )
            if canonical == item.tag.title {
                return title
            }
        }
        return nil
    }

    /// Trims a title down to something that belongs in a menu bar.
    ///
    /// Some of these are full sentences — the weather module's title is
    /// `Currently 69° and Partly cloudy. High of 85°. Low of 67°. 12% chance of
    /// rain` — which is correct for accessibility and absurd on the bar. Take the
    /// leading measurement and drop the prose.
    /// Splits a live accessibility title into a label and a value.
    ///
    /// These titles are written for a screen reader, so they run to full
    /// sentences with several measurements. Take the first clause, find the first
    /// token carrying a number, and treat what precedes it as the label. A label
    /// is kept only when the source already wrote it as an initialism — CPU, GPU;
    /// prose like "Currently" or "Memory Pressure" is dropped rather than
    /// truncated, because the unit already says what the number is.
    ///
    /// General by construction: nothing here knows which app it is looking at.
    private nonisolated static func readout(
        from title: String?,
        tag: MenuBarItemTag
    ) -> (label: String, value: String) {
        guard let title, !title.isEmpty else { return ("", "") }
        let clause = title.prefix { $0 != "." && $0 != "," }
        let tokens = clause.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return ("", "") }

        guard let valueIndex = tokens.firstIndex(where: { $0.contains(where: \.isNumber) }) else {
            // No measurement at all: this is an icon-only item, and the caller
            // will prefer the original's captured pixels.
            return ("", "")
        }

        var value = tokens[valueIndex]
        // Only a real unit, never the next English word: "Currently 69° and
        // Partly cloudy" was rendering as "69° and".
        if valueIndex + 1 < tokens.count {
            let next = tokens[valueIndex + 1]
            if next.count <= 4, next.contains(where: { !$0.isLetter }) {
                value += " " + next
            }
        }

        guard valueIndex > 0 else { return ("", value) }
        let label = tokens[0]
        let isInitialism = label.count <= 4
            && label == label.uppercased()
            && label.allSatisfy(\.isLetter)
        return (isInitialism ? label : "", value)
    }

    // MARK: - Interaction

    @objc
    private func proxyClicked(_ sender: NSStatusBarButton) {
        guard let (_, proxy) = proxies.first(where: { $0.value.statusItem.button === sender }) else {
            return
        }
        guard let controller = appState?.menuBarManager.sectionController else { return }
        Self.log.info("stand-in clicked; forwarding to \(proxy.item.tag.description)")
        controller.openMenuBehindProxy(proxy.item)
    }
}

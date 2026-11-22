//
//  RehidePlacement.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

/// Resolves a physical drop in the requested native section without expanding its dividers.
nonisolated struct RehidePlacement {
    typealias Destination = MenuBarItemManager.MoveDestination

    let section: MenuBarSection.Name
    let display: CGRect
    let reservedNotch: ClosedRange<CGFloat>?
    let alwaysHiddenEnabled: Bool
    var otherDisplays: [CGRect] = []

    private var targetSection: MenuBarSection.Name {
        section == .alwaysHidden && !alwaysHiddenEnabled ? .hidden : section
    }

    func contains(_ item: MenuBarItem, in items: [MenuBarItem]) -> Bool {
        guard targetSection != .visible,
              !item.isControlItem,
              !item.bounds.isEmpty,
              let (hidden, alwaysHidden) = dividers(in: items),
              !otherDisplays.contains(where: { $0.contains(item.bounds.center) && !display.contains(item.bounds.center) }),
              (hidden.bounds.minY ... hidden.bounds.maxY).contains(item.bounds.midY)
        else { return false }
        let target: MenuBarItemManager.LayoutResetTarget = targetSection == .alwaysHidden ? .alwaysHidden : .hidden
        return target.contains(itemBounds: item.bounds, hiddenBounds: hidden.bounds, alwaysHiddenBounds: alwaysHidden?.bounds)
    }

    private func dividers(in items: [MenuBarItem]) -> (MenuBarItem, MenuBarItem?)? {
        func divider(_ tag: MenuBarItemTag) -> MenuBarItem? {
            let matches = items.filter {
                $0.tag == tag && $0.bounds.height > 0 && display.minY >= $0.bounds.minY && display.minY < $0.bounds.maxY
            }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let hidden = divider(.hiddenControlItem), (display.minX ... display.maxX).contains(hidden.bounds.maxX)
        else { return nil }
        guard alwaysHiddenEnabled else { return (hidden, nil) }
        guard let alwaysHidden = divider(.alwaysHiddenControlItem), alwaysHidden.bounds.maxX <= hidden.bounds.minX else { return nil }
        return (hidden, alwaysHidden)
    }

    func allows(_ destination: Destination, in items: [MenuBarItem]) -> Bool {
        let target = destination.targetItem
        let point = destination.targetPoint(in: target.bounds, on: display)
        guard targetSection != .visible,
              target.isOnScreen,
              items.filter({ $0.windowID == target.windowID }) == [target],
              target.bounds.intersects(display),
              display.contains(point),
              reservedNotch?.contains(point.x) != true,
              let (hidden, alwaysHidden) = dividers(in: items)
        else { return false }
        if target.isControlItem {
            switch destination {
            case .leftOfItem:
                if targetSection == .hidden {
                    return target.windowID == hidden.windowID && (alwaysHidden.map { point.x > $0.bounds.maxX } ?? true)
                }
                return target.windowID == alwaysHidden?.windowID
            case .rightOfItem:
                return targetSection == .hidden && target.windowID == alwaysHidden?.windowID && point.x < hidden.bounds.minX
            }
        }
        return display.contains(target.bounds.center) && contains(target, in: items)
    }

    func destination(primary: Destination?, alternate: Destination?, in items: [MenuBarItem]) -> Destination? {
        guard let (hidden, alwaysHidden) = dividers(in: items) else { return nil }
        let boundary = targetSection == .alwaysHidden ? alwaysHidden : hidden
        let oppositeBoundary = targetSection == .hidden ? alwaysHidden : nil
        let candidates = [primary, alternate, boundary.map(Destination.leftOfItem), oppositeBoundary.map(Destination.rightOfItem)]
        if let target = candidates.compactMap(\.self).first(where: { allows($0, in: items) }) {
            return target
        }
        // Reflow can expose a different item in the same section while both section edges are parked.
        let originalX = primary?.targetItem.bounds.minX ?? boundary?.bounds.minX ?? hidden.bounds.minX
        return items.filter { contains($0, in: items) }
            .sorted { abs($0.bounds.midX - originalX) < abs($1.bounds.midX - originalX) }
            .map { $0.bounds.midX < originalX ? Destination.rightOfItem($0) : .leftOfItem($0) }
            .first { allows($0, in: items) }
    }
}

extension MenuBarItemManager {
    func rehidePlacement(for section: MenuBarSection.Name, on displayID: CGDirectDisplayID) -> RehidePlacement? {
        guard let appState, let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return nil }
        let notch = screen.frameOfNotch.map { ($0.minX - 2) ... ($0.maxX + 2) }
        let display = CGDisplayBounds(displayID)
        let others = NSScreen.screens.map { CGDisplayBounds($0.displayID) }.reduce(into: [CGRect]()) { result, bounds in
            if bounds != display, !result.contains(bounds) {
                result.append(bounds)
            }
        }
        return RehidePlacement(
            section: section,
            display: display,
            reservedNotch: notch,
            alwaysHiddenEnabled: appState.settings.advanced.enableAlwaysHiddenSection,
            otherDisplays: others
        )
    }
}

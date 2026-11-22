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

    /// Only the ordinary hidden row and its original, immediately adjacent right window qualify.
    struct ExactSlot {
        let source: MenuBarItem
        let hiddenDivider: MenuBarItem
        let right: MenuBarItem
        let left: MenuBarItem?

        enum Observation: Equatable {
            case landed([CGRect])
            case visible([CGRect])
        }

        enum Phase {
            case ready, posted, visibleAwaitingIdle, recovering

            func decision(after observation: Observation?, idlePass: Bool) -> Decision {
                switch observation {
                case .landed: .finished
                case .visible where self == .recovering: .preserve
                case .visible where self == .visibleAwaitingIdle && idlePass: .recover
                case .visible: .waitForIdle
                case nil: .preserve
                }
            }
        }

        enum Decision { case finished, recover, waitForIdle, preserve }

        struct Readback {
            private var previous: Observation?

            mutating func stable(_ observation: Observation?) -> Observation? {
                defer { previous = observation }
                return previous == observation ? observation : nil
            }
        }

        static func sameBar(display: CGDirectDisplayID, space: CGSSpaceID, activeDisplay: CGDirectDisplayID?, activeSpace: CGSSpaceID) -> Bool {
            space != 0 && display == activeDisplay && space == activeSpace
        }

        static let pendingKey = "exactReturnInFlight"

        static func protectedTags(_ records: [String: [String: String]]) -> Set<String> {
            Set(records.compactMap { $0.value[pendingKey] == nil ? nil : $0.key })
        }

        private func current(_ original: MenuBarItem, in items: [MenuBarItem]) -> MenuBarItem? {
            let matches = items.filter { $0.windowID == original.windowID || $0.tag.tagIdentifier == original.tag.tagIdentifier }
            guard matches.count == 1, let match = matches.first, MenuBarItemManager.moveEndpointIsCurrent(match, expected: original)
            else { return nil }
            return match
        }

        private func collapsedDivider(in items: [MenuBarItem], placement: RehidePlacement) -> MenuBarItem? {
            guard let (divider, _) = placement.dividers(in: items),
                  MenuBarItemManager.moveEndpointIsCurrent(divider, expected: hiddenDivider),
                  divider.bounds.size == hiddenDivider.bounds.size else { return nil }
            return divider
        }

        private func neighbors(_ before: MenuBarItem, _ after: MenuBarItem, in items: [MenuBarItem]) -> Bool {
            guard abs(before.bounds.maxX - after.bounds.minX) <= 1 else { return false }
            return MenuBarItemManager.endpointsHaveCorrectPosition(
                .init(source: before, target: after, snapshot: items), for: .leftOfItem(after)
            )
        }

        func observation(in items: [MenuBarItem], placement: RehidePlacement) -> Observation? {
            guard let item = current(source, in: items), let anchor = current(right, in: items), placement.isParked(anchor, in: items), let divider = collapsedDivider(in: items, placement: placement), item.bounds.minY == placement.display.minY, !item.bounds.isEmpty
            else { return nil }
            let landed = placement.isParked(item, in: items) && neighbors(item, anchor, in: items)
            var frames = [item.bounds, anchor.bounds, divider.bounds]
            if let left {
                guard let witness = current(left, in: items), placement.isParked(witness, in: items), neighbors(witness, landed ? item : anchor, in: items) else { return nil }
                frames.append(witness.bounds)
            }
            if landed {
                return .landed(frames)
            }
            guard item.isOnScreen, placement.display.contains(item.bounds), item.bounds.minX >= divider.bounds.maxX, !placement.otherDisplays.contains(where: { $0.intersects(item.bounds) }) else { return nil }
            return .visible(frames)
        }

        func reachableRight(in items: [MenuBarItem], placement: RehidePlacement) -> Destination? {
            guard let anchor = current(right, in: items), placement.allows(.leftOfItem(anchor), in: items) else { return nil }
            return .leftOfItem(anchor)
        }

        func validPostedEndpoints(_ endpoints: MenuBarItemManager.CurrentMoveEndpoints, placement: RehidePlacement) -> Bool {
            guard MenuBarItemManager.moveEndpointIsCurrent(endpoints.source, expected: source), MenuBarItemManager.moveEndpointIsCurrent(endpoints.target, expected: right), current(source, in: endpoints.snapshot) != nil, let anchor = current(right, in: endpoints.snapshot), !placement.otherDisplays.contains(where: { $0.intersects(endpoints.source.bounds) })
            else { return false }
            return collapsedDivider(in: endpoints.snapshot, placement: placement) != nil && placement.isParked(anchor, in: endpoints.snapshot)
        }

        func destination(in items: [MenuBarItem], placement: RehidePlacement) -> Destination? {
            guard case .visible = observation(in: items, placement: placement), let anchor = current(right, in: items) else { return nil }
            return .leftOfItem(anchor)
        }
    }

    private func isParked(_ item: MenuBarItem, in items: [MenuBarItem]) -> Bool {
        guard section == .hidden, !item.isOnScreen, item.bounds.maxX < display.minX, item.bounds.minY == display.minY, contains(item, in: items) else { return false }
        let corridor = item.bounds.union(CGRect(x: display.minX, y: display.minY, width: 1, height: item.bounds.height))
        return !otherDisplays.contains { $0.intersects(corridor) }
    }

    func exactSlot(for source: MenuBarItem, destination: Destination, in items: [MenuBarItem]) -> ExactSlot? {
        guard case let .leftOfItem(right) = destination, source.sourcePID.map({ $0 > 0 }) == true, right.sourcePID.map({ $0 > 0 }) == true, source.windowID != right.windowID, [source, right].allSatisfy({ item in
            guard case let .string(bundleID) = item.tag.namespace else { return false }
            return bundleID.contains(".") && !bundleID.hasPrefix("com.apple.") && item.tag.namespace != .thaw && !item.isSystemClone
        }), source.isMovable, source.canBeHidden, right.canBeHidden else { return nil }
        let row = items.sorted { $0.bounds.minX < $1.bounds.minX }
        guard let index = row.firstIndex(where: { $0.windowID == source.windowID }) else { return nil }
        let left = index > 0 && isParked(row[index - 1], in: items) ? row[index - 1] : nil
        guard let (divider, _) = dividers(in: items) else { return nil }
        let slot = ExactSlot(source: source, hiddenDivider: divider, right: right, left: left)
        guard case .landed = slot.observation(in: items, placement: self) else { return nil }
        return slot
    }

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

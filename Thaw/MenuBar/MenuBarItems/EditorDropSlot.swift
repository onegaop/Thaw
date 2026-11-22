//
//  EditorDropSlot.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics

/// The user's exact insertion position, with the dragged items in final left-to-right order.
nonisolated struct EditorDropSlot {
    enum Decision: Equatable { case placed, move, reveal, refuse }

    let items: [MenuBarItem]
    let destination: MenuBarItemManager.MoveDestination

    static func isCurrent(
        displayID: CGDirectDisplayID,
        spaceID: CGSSpaceID,
        activeDisplayID: CGDirectDisplayID?,
        activeSpaceID: CGSSpaceID
    ) -> Bool {
        displayID != 0 && spaceID > 0 && displayID == activeDisplayID && spaceID == activeSpaceID
    }

    func decision(in snapshot: [MenuBarItem], placement: RehidePlacement) -> Decision {
        guard
            placement.section != .visible, placement.section != .alwaysHidden || placement.alwaysHiddenEnabled, !items.isEmpty, !items.contains(where: \.isControlItem), !destination.targetItem.isControlItem
        else { return .refuse }

        let row = snapshot.first {
            $0.tag == .hiddenControlItem && $0.bounds.minY <= placement.display.minY && $0.bounds.maxY > placement.display.minY
        }?.bounds
        guard let row else { return .refuse }
        let expected = items + [destination.targetItem]
        guard Set(expected.map(\.windowID)).count == expected.count else { return .refuse }
        var live = [MenuBarItem]()
        for item in expected {
            let matches = snapshot.filter { $0.windowID == item.windowID }
            guard
                matches.count == 1, let current = matches.first, !current.isSystemClone, MenuBarItemManager.moveEndpointIsCurrent(current, expected: item), belongsToMenuBar(current, row: row, placement: placement)
            else { return .refuse }
            live.append(current)
        }
        guard let anchor = live.popLast(), placement.contains(anchor, in: snapshot) else { return .refuse }
        let members = snapshot.filter { placement.contains($0, in: snapshot) }
        let ordered = switch destination {
        case .leftOfItem: live + [anchor]
        case .rightOfItem: [anchor] + live
        }
        let allInSection = live.allSatisfy { placement.contains($0, in: snapshot) }
        let inRequestedOrder = zip(ordered, ordered.dropFirst()).allSatisfy { left, right in
            guard let indices = MenuBarItemManager.moveEndpointIndices(
                in: members,
                sourceWindowID: left.windowID,
                destinationWindowID: right.windowID
            ) else { return false }
            return indices.source + 1 == indices.destination
        }
        if allInSection && inRequestedOrder {
            return .placed
        }
        if placement.allows(destination.replacingTarget(with: anchor), in: snapshot) {
            return .move
        }
        return anchor.bounds.maxX <= placement.display.minX ? .reveal : .refuse
    }

    /// Parked items share the native bar's row, while windows on a real left display do not belong to this bar.
    private func belongsToMenuBar(_ item: MenuBarItem, row: CGRect, placement: RehidePlacement) -> Bool {
        let bounds = item.bounds
        let display = placement.display
        guard
            !bounds.isEmpty, (row.minY ... row.maxY).contains(bounds.midY), !placement.otherDisplays.contains(where: { $0.contains(bounds.center) && !display.contains(bounds.center) })
        else { return false }
        if display.contains(bounds.center) {
            return item.isOnScreen
        }
        return bounds.maxX <= display.minX
    }
}

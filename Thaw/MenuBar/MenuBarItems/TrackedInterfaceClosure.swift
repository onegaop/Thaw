//
//  TrackedInterfaceClosure.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics

/// Confirms dismissal when the Window Server stops describing a previously identified interface.
nonisolated struct TrackedInterfaceClosure {
    enum State { case showing, absent, unknown }

    let beforeClick: Set<CGWindowID>
    private var firstClearRead: ContinuousClock.Instant?

    init(beforeClick: Set<CGWindowID>) {
        self.beforeClick = beforeClick
    }

    mutating func reset() {
        firstClearRead = nil
    }

    mutating func readAfterLoss(
        of tracked: WindowInfo,
        itemWindowID: CGWindowID,
        interfacePIDs: Set<pid_t>,
        visible: [WindowInfo]?,
        now: ContinuousClock.Instant
    ) -> State {
        guard beforeClick.contains(itemWindowID), !beforeClick.contains(tracked.windowID), interfacePIDs.contains(tracked.ownerPID), let visible, visible.contains(where: { $0.windowID == itemWindowID && interfacePIDs.contains($0.ownerPID) })
        else {
            reset()
            return .unknown
        }

        let hasInterface = visible.contains { window in
            guard interfacePIDs.contains(window.ownerPID) else { return false }
            if window.windowID == tracked.windowID, window.ownerPID == tracked.ownerPID {
                return true
            }
            if MenuBarItemManager.windowIsOpenInterface(
                ownerPID: window.ownerPID, layer: window.layer, height: window.bounds.height, interfacePIDs: interfacePIDs
            ) {
                return true
            }
            // A nested or replacement panel may be at an ordinary window level.
            return !beforeClick.contains(window.windowID) && window.bounds.height > MenuBarItemManager.maxMenuBarItemHeight
        }
        guard !hasInterface else {
            reset()
            return .showing
        }

        // Two separate reads leave room for a menu to replace its parent.
        guard let firstClearRead else {
            firstClearRead = now
            return .showing
        }
        return now - firstClearRead >= .milliseconds(200) ? .absent : .showing
    }
}

//
//  MenuBarItemManager+PendingAnchor.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

extension PendingLedger {
    nonisolated static func anchorIsReachable(
        _ destination: MenuBarItemManager.MoveDestination,
        display: CGRect,
        reservedNotch: ClosedRange<CGFloat>?
    ) -> Bool {
        let target = destination.targetItem
        let point = destination.targetPoint(in: target.bounds, on: display)
        return target.isOnScreen && !target.bounds.isEmpty && target.bounds.intersects(display)
            && display.contains(point) && reservedNotch?.contains(point.x) != true
    }
}

extension MenuBarItemManager {
    /// Only the pending move that opened the native section requires an on-screen neighbor.
    nonisolated struct PendingAnchor {
        let destination: MoveDestination
        let section: MenuBarSection.Name

        @MainActor
        func canDrop(on target: MenuBarItem, displayID: CGDirectDisplayID, dividers: [MenuBarItem]) -> Bool {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }), contains(target, dividers: dividers) else { return false }
            let notch = screen.frameOfNotch.map { ($0.minX - 2) ... ($0.maxX + 2) }
            return PendingLedger.anchorIsReachable(destination.replacingTarget(with: target), display: CGDisplayBounds(displayID), reservedNotch: notch)
        }

        func contains(_ item: MenuBarItem, dividers: [MenuBarItem]) -> Bool {
            guard let hidden = dividers.first(where: { $0.tag == .hiddenControlItem }) else { return false }
            let alwaysHidden = dividers.first { $0.tag == .alwaysHiddenControlItem }
            let expected: LayoutResetTarget = section == .alwaysHidden ? .alwaysHidden : .hidden
            return expected.contains(itemBounds: item.bounds, hiddenBounds: hidden.bounds, alwaysHiddenBounds: alwaysHidden?.bounds)
        }
    }

    @TaskLocal static var requiredPendingAnchor: PendingAnchor?

    /// Runs inside the move gate. Restore only the sections this move opened, using the latest user intent.
    func withPendingAnchor(
        _ anchor: PendingAnchor?,
        source: MenuBarItem,
        on displayID: CGDirectDisplayID?,
        budget: MoveTransactionBudget,
        shouldProceed: (@MainActor () -> Bool)?,
        perform: () async throws -> Void
    ) async throws {
        guard let anchor else { return try await perform() }
        guard let displayID else { throw EventError.unsafeMovePath(source) }
        let expected = anchor.destination.targetItem
        func canDrop() async throws -> Bool {
            let endpoints = try await resolveCurrentMoveEndpoints(source: source, destination: expected, on: displayID)
            guard !Task.isCancelled, shouldProceed?() != false else { throw EventError.moveSuperseded(source) }
            return anchor.canDrop(on: endpoints.target, displayID: displayID, dividers: endpoints.snapshot)
        }

        var revealed = [MenuBarSection]()
        func restoreSections() {
            for section in revealed.reversed() {
                section.updateControlItemState()
            }
            revealed.removeAll()
        }
        defer { restoreSections() }
        if try await !canDrop() {
            guard await !isAnyMenuBarItemMenuOpen() else { throw EventError.menuTrackingActive(source) }
            let names: [MenuBarSection.Name] = anchor.section == .alwaysHidden ? [.hidden, .alwaysHidden] : [.hidden]
            for name in names {
                guard let section = appState?.menuBarManager.section(withName: name), section.isEnabled else {
                    throw EventError.unsafeMovePath(source)
                }
                if section.controlItem.state == .hideSection {
                    revealed.append(section)
                    section.controlItem.state = .showSection
                }
            }
            guard !revealed.isEmpty else { throw EventError.unsafeMovePath(source) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while try await !canDrop() {
                guard ContinuousClock.now < deadline else { throw EventError.unsafeMovePath(source) }
                try await budget.sleep(for: .milliseconds(50))
            }
        }
        try await Self.$requiredPendingAnchor.withValue(anchor, operation: perform)
        restoreSections()
        try await waitForLayoutToSettle(item: source, target: expected, budget: budget)
        let landed = try await resolveCurrentMoveEndpoints(source: source, destination: expected, on: displayID, requiresFullSnapshot: true)
        let dividers = authoritativeMoveGeometryDividers()
        guard anchor.contains(landed.source, dividers: dividers), anchor.contains(landed.target, dividers: dividers), Self.endpointsHaveCorrectPosition(landed, for: anchor.destination)
        else { throw EventError.dropReverted(source) }
    }
}

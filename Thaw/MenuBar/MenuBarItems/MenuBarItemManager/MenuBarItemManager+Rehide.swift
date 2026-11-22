//
//  MenuBarItemManager+Rehide.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

extension MenuBarItemManager {
    enum RehideResult { case returned, userBusy, pending }

    func rehideItems(on displayID: CGDirectDisplayID, timeout: Duration = .seconds(2)) async throws -> [MenuBarItem] {
        try await Task<[MenuBarItem], any Error>.withTimeout(timeout) {
            await MenuBarItem.getMenuBarItems(on: displayID, option: .activeSpace).filter { !$0.isSystemClone }
        }
    }

    func returnShownItem(_ original: MenuBarItem, context: TemporarilyShownItemContext) async throws -> RehideResult {
        var result = RehideResult.pending
        let displayID = context.displayID
        let key = context.tag.tagIdentifier
        let section = pendingRelocations[key]
        let savedDestination = pendingReturnDestinations[key]
        guard original.windowID == context.shownWindowID else { return .pending }
        let isCurrent: @MainActor () -> Bool = {
            !Task.isCancelled && section != nil && self.pendingRelocations[key] == section
                && self.pendingReturnDestinations[key] == savedDestination && self.temporarilyShownItemContexts.contains { $0 === context }
                && context.isOnActiveBar
        }
        try await Self.performWithMoveGate(timeout: .milliseconds(250)) {
            guard context.isOnActiveBar else {
                result = .userBusy
                return
            }
            guard isCurrent(), let appState = self.appState, let plan = self.rehidePlacement(for: context.originalSection, on: displayID)
            else { return }
            @MainActor func snapshot(timeout: Duration = .seconds(2)) async throws -> (MenuBarItem, [MenuBarItem]) {
                let items = try await self.rehideItems(on: displayID, timeout: timeout)
                guard isCurrent(), let item = items.first(where: { Self.moveEndpointIsCurrent($0, expected: original) }) else {
                    throw EventError.moveSuperseded(original)
                }
                return (item, items)
            }
            @MainActor func destination(in items: [MenuBarItem]) -> MoveDestination? {
                let previous = context.returnDestination.targetItem
                let first = items.first(matchingTag: previous.tag, pid: previous.sourcePID ?? previous.ownerPID)
                let primary = first.map { context.returnDestination.replacingTarget(with: $0) }
                let second = context.fallbackNeighbor.flatMap { items.first(matchingTag: $0.tag, pid: $0.pid) }
                let alternate = second.map { neighbor in
                    switch context.returnDestination {
                    case .leftOfItem: MoveDestination.rightOfItem(neighbor)
                    case .rightOfItem: MoveDestination.leftOfItem(neighbor)
                    }
                }
                return plan.destination(primary: primary, alternate: alternate, in: items.filter { $0.windowID != original.windowID })
            }

            var (item, items) = try await snapshot()
            if plan.contains(item, in: items) {
                result = .returned
                return
            }

            var opened = [MenuBarSection]()
            var changedGeometry = false
            var hoverToken: UUID?
            @MainActor func protectHover() {
                if hoverToken == nil { hoverToken = appState.hidEventManager.returnHoverGate.begin(on: displayID) }
            }
            @MainActor func restore() {
                guard !opened.isEmpty else { return }
                for section in opened.reversed() {
                    section.updateControlItemState()
                }
                opened.removeAll()
            }
            defer {
                restore()
                if let hoverToken { appState.hidEventManager.returnHoverGate.finish(on: displayID, token: hoverToken) }
                if changedGeometry {
                    self.lastMoveOperationTimestamp = .now
                    self.isRevealingForRehide = false
                    self.scheduleCacheRetryAfterMidTransitionSkip(suppressAutomaticMoves: true, suppressSavedOrderPersistence: true)
                }
            }
            var target = destination(in: items)
            let start = ContinuousClock.now
            let safeToContinue: @MainActor () -> Bool = {
                isCurrent() && !appState.isDraggingMenuBarItem && (opened.isEmpty || !MouseHelpers.physicalPointerInputOccurred(since: start))
            }
            if target == nil {
                guard !context.didRevealForRehide,
                      item.windowID == context.shownWindowID,
                      item.isOnScreen,
                      plan.display.contains(item.bounds.center),
                      item.bounds.minY == plan.display.minY,
                      !appState.activeSpace.isFullscreen,
                      !appState.menuBarManager.isMenuBarHiddenBySystem
                else { return }
                guard self.hasUserPausedInput(for: .milliseconds(250)),
                      !appState.isDraggingMenuBarItem,
                      context.interfaceState != .showing,
                      await !self.isAnyMenuBarItemMenuOpen(),
                      isCurrent(),
                      self.hasUserPausedInput(for: .milliseconds(250)),
                      !MouseHelpers.physicalPointerInputOccurred(since: start) else {
                    result = .userBusy
                    return
                }
                let names: [MenuBarSection.Name] = context.originalSection == .alwaysHidden && plan.alwaysHiddenEnabled ? [.hidden, .alwaysHidden] : [.hidden]
                let sections = names.compactMap { appState.menuBarManager.section(withName: $0) }
                guard sections.count == names.count, sections.allSatisfy(\.isEnabled) else { return }
                opened = sections.filter { $0.controlItem.state == .hideSection }
                guard !opened.isEmpty else { return }
                protectHover()
                Self.diagLog.info("Temporarily revealing the native divider for return on display \(displayID)")
                context.didRevealForRehide = true
                changedGeometry = true
                self.isRevealingForRehide = true
                self.lastMoveOperationTimestamp = .now
                for section in opened {
                    section.controlItem.state = .showSection
                }
                let deadline = ContinuousClock.now + .seconds(1)
                repeat {
                    try await Task.sleep(for: .milliseconds(60))
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero else { return }
                    (item, items) = try await snapshot(timeout: remaining)
                    guard safeToContinue(), item.isOnScreen, plan.display.contains(item.bounds.center) else { return }
                    target = destination(in: items)
                } while target == nil && ContinuousClock.now < deadline
            }
            guard let target, safeToContinue() else { return }
            protectHover()
            let acceptsReturn = self.returnEndpointCheck(for: context.originalSection, destination: target, on: displayID)
            try await self.move(
                item: item,
                to: target,
                on: displayID,
                skipInputPause: true,
                options: .init(
                    maxMoveAttempts: 2,
                    shouldProceed: safeToContinue,
                    acceptsEndpoints: { endpoints, currentDisplayID in
                        safeToContinue() && acceptsReturn(endpoints, currentDisplayID)
                    },
                    isUserInitiated: true
                )
            )
            restore()
            await self.waitForLayoutToSettle(item: item, target: target.targetItem)
            let (landed, finalItems) = try await snapshot()
            guard let finalPlan = self.rehidePlacement(for: context.originalSection, on: displayID), finalPlan.contains(landed, in: finalItems)
            else { throw EventError.dropReverted(item) }
            result = .returned
        }
        return result
    }
}

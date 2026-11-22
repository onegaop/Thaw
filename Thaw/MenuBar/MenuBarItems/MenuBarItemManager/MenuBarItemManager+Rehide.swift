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

    func returnShownItem(_ original: MenuBarItem, context: TemporarilyShownItemContext, allowIdleRecovery: Bool) async throws -> RehideResult {
        var result = RehideResult.pending
        let displayID = context.displayID
        let key = context.tag.tagIdentifier
        let section = pendingRelocations[key]
        var savedDestination = pendingReturnDestinations[key]
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
                if context.exactReturnPhase == .recovering, let slot = context.exactSlot {
                    return slot.reachableRight(in: items, placement: plan)
                }
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
            if context.exactReturnPhase == .ready, plan.contains(item, in: items) {
                result = .returned
                return
            }
            let reachable = destination(in: items)
            let hiddenSection = appState.menuBarManager.section(withName: .hidden)
            let wouldReveal = reachable == nil && !context.didRevealForRehide && hiddenSection?.isEnabled == true &&
                hiddenSection?.controlItem.state == .hideSection
            if let slot = context.exactSlot, context.exactReturnPhase != .ready ||
                (savedDestination != nil && wouldReveal && context.interfaceState == .absent && slot.destination(in: items, placement: plan) != nil)
            {
                let decision = await self.exactReturnDecision(
                    slot: slot,
                    item: item,
                    items: items,
                    placement: plan,
                    context: context,
                    idlePass: allowIdleRecovery,
                    appState: appState,
                    isCurrent: isCurrent
                ) {
                    context.exactReturnPhase = .posted
                    savedDestination?[RehidePlacement.ExactSlot.pendingKey] = String(slot.source.windowID)
                    self.pendingReturnDestinations[key] = savedDestination
                    self.persistPendingRelocations()
                    Self.diagLog.info("Direct temporary return on display \(displayID), source=\(slot.source.windowID) neighbor=\(slot.right.windowID)")
                }
                switch decision {
                case .finished: result = .returned; return
                case .waitForIdle: result = .userBusy; return
                case .preserve: return
                case .recover:
                    (item, items) = try await snapshot()
                    guard let freshPlan = self.rehidePlacement(for: .hidden, on: displayID), case .visible = slot.observation(in: items, placement: freshPlan), !MouseHelpers.isButtonPressed(), self.hasUserPausedInput(for: .milliseconds(250))
                    else { return }
                    context.exactReturnPhase = .recovering
                }
            }

            let recoveryScreen = context.exactReturnPhase == .recovering ? NSScreen.screens.first { $0.displayID == displayID } : nil
            if context.exactReturnPhase == .recovering, recoveryScreen == nil { return }
            var opened = [MenuBarSection]()
            var changedGeometry = false
            var hoverToken: UUID?
            @MainActor func protectHover() {
                if hoverToken == nil { hoverToken = appState.hidEventManager.returnHoverGate.begin(on: displayID) }
            }
            @MainActor func restore() {
                guard !opened.isEmpty else { return }
                for section in opened.reversed() {
                    section.updateControlItemState(for: recoveryScreen)
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
            var target = context.exactReturnPhase == .ready ? reachable : destination(in: items)
            let start = ContinuousClock.now
            let safeToContinue: @MainActor () -> Bool = {
                isCurrent() && !appState.isDraggingMenuBarItem && ((opened.isEmpty && context.exactReturnPhase != .recovering) || !MouseHelpers.physicalPointerInputOccurred(since: start))
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
                    maxMoveAttempts: context.exactReturnPhase == .recovering ? 1 : 2,
                    shouldProceed: safeToContinue,
                    acceptsEndpoints: { endpoints, currentDisplayID in
                        safeToContinue() && acceptsReturn(endpoints, currentDisplayID)
                    },
                    isUserInitiated: context.exactReturnPhase != .recovering
                )
            )
            restore()
            await self.waitForLayoutToSettle(item: item, target: target.targetItem)
            let (landed, finalItems) = try await snapshot()
            guard let finalPlan = self.rehidePlacement(for: context.originalSection, on: displayID), finalPlan.contains(landed, in: finalItems)
            else { throw EventError.dropReverted(item) }
            if let slot = context.exactSlot, context.exactReturnPhase != .ready {
                guard case .landed = await self.readExactReturn(slot, on: displayID, isCurrent: isCurrent) else { return }
            }
            result = .returned
        }
        return result
    }

    private func exactReturnDecision(
        slot: RehidePlacement.ExactSlot,
        item: MenuBarItem,
        items: [MenuBarItem],
        placement: RehidePlacement,
        context: TemporarilyShownItemContext,
        idlePass: Bool,
        appState: AppState,
        isCurrent: @escaping @MainActor () -> Bool,
        markPosted: @escaping @MainActor () -> Void
    ) async -> RehidePlacement.ExactSlot.Decision {
        let display = context.displayID
        let began = ContinuousClock.now
        let quiet: @MainActor () -> Bool = {
            isCurrent() && !appState.isDraggingMenuBarItem && !MouseHelpers.physicalPointerInputOccurred(since: began)
                && !appState.activeSpace.isFullscreen && !appState.menuBarManager.isMenuBarHiddenBySystem
        }
        func idle() async -> Bool {
            guard quiet(), !MouseHelpers.isButtonPressed(), hasUserPausedInput(for: .milliseconds(250)), context.interfaceState == .absent, await !isAnyMenuBarItemMenuOpen()
            else { return false }
            return quiet() && !MouseHelpers.isButtonPressed() && hasUserPausedInput(for: .milliseconds(250))
        }
        var hoverToken: UUID?
        defer {
            if let hoverToken {
                appState.hidEventManager.returnHoverGate.finish(on: display, token: hoverToken)
            }
        }
        if context.exactReturnPhase == .ready {
            guard await idle(), !moveCircuitBreaker.isOpen, !failureLedger.isUnderBackoff(for: item), let target = slot.destination(in: items, placement: placement)
            else { return .waitForIdle }
            hoverToken = appState.hidEventManager.returnHoverGate.begin(on: display)
            do {
                try await move(item: item, to: target, on: display, skipInputPause: true, options: .init(
                    maxMoveAttempts: 1,
                    shouldProceed: quiet,
                    acceptsEndpoints: { endpoints, active in
                        guard quiet(), active == display, let current = self.rehidePlacement(for: .hidden, on: active), Self.moveEndpointIsCurrent(endpoints.source, expected: slot.source) else { return false }
                        if context.exactReturnPhase == .posted {
                            return slot.validPostedEndpoints(endpoints, placement: current)
                        }
                        return !MouseHelpers.isButtonPressed() && slot.destination(in: endpoints.snapshot, placement: current) != nil
                    },
                    willPostMoveEvents: markPosted
                ))
            } catch {
                if context.exactReturnPhase == .ready {
                    context.exactReturnPhase = .visibleAwaitingIdle
                    return .waitForIdle
                }
            }
        }
        let observation = await readExactReturn(slot, on: display, isCurrent: quiet)
        let decision = context.exactReturnPhase.decision(after: observation, idlePass: idlePass)
        switch decision {
        case .waitForIdle: context.exactReturnPhase = .visibleAwaitingIdle
        case .recover: if await !idle() {
                return .waitForIdle
            }
        case .preserve where context.exactReturnPhase == .posted && context.unconfirmedReadPasses < 2:
            context.unconfirmedReadPasses += 1
            return .waitForIdle
        default: break
        }
        return decision
    }

    private func readExactReturn(
        _ slot: RehidePlacement.ExactSlot,
        on display: CGDirectDisplayID,
        isCurrent: @MainActor () -> Bool
    ) async -> RehidePlacement.ExactSlot.Observation? {
        var readback = RehidePlacement.ExactSlot.Readback()
        for pass in 0 ..< 5 {
            if pass > 0 {
                do { try await Task.sleep(for: .milliseconds(65)) } catch { return nil }
            }
            guard isCurrent() else { return nil }
            let items = try? await rehideItems(on: display, timeout: .milliseconds(160))
            guard isCurrent(), let placement = rehidePlacement(for: .hidden, on: display) else { return nil }
            let observation = items.flatMap { slot.observation(in: $0, placement: placement) }
            let stable = readback.stable(observation)
            if case .landed = stable {
                return stable
            }
            if pass == 4 {
                return stable
            }
        }
        return nil
    }
}

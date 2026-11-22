//
//  MenuBarItemManager+EditorDrop.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

extension MenuBarItemManager {
    /// Places one item beside a parked editor neighbor, then verifies its position after restoring the section.
    func moveForLayoutEditor(
        items: [MenuBarItem],
        to destination: MoveDestination,
        in section: MenuBarSection.Name,
        on displayID: CGDirectDisplayID,
        spaceID: CGSSpaceID,
        shouldProceed: @escaping @MainActor () -> Bool
    ) async throws {
        guard let first = items.first else { throw EventError.cannotComplete }
        // Native drags commit individually. A later group member can fail after the first has moved.
        guard items.count == 1 else { throw EventError.unsafeMovePath(first) }
        let slot = EditorDropSlot(items: [first], destination: destination)
        let isCurrent: @MainActor () -> Bool = {
            !Task.isCancelled && shouldProceed() && self.appState?.isDraggingMenuBarItem == false
                && EditorDropSlot.isCurrent(
                    displayID: displayID,
                    spaceID: spaceID,
                    activeDisplayID: Bridging.getActiveMenuBarDisplayID(),
                    activeSpaceID: Bridging.getActiveSpaceID()
                )
        }
        try await Self.performWithMoveGate(timeout: .seconds(2)) {
            guard isCurrent(), let appState = self.appState else { throw EventError.moveSuperseded(first) }
            let watched: Set<CGWindowID> = [first.windowID, destination.targetItem.windowID]
            var frames = [CGRect]()
            @MainActor func read(_ requested: EditorDropSlot, settling sections: [MenuBarSection] = [], timeout: Duration = .seconds(2)) async throws -> EditorDropSlot.Decision {
                let snapshot = try await self.rehideItems(on: displayID, timeout: timeout)
                guard isCurrent(), let placement = self.rehidePlacement(for: section, on: displayID) else { throw EventError.moveSuperseded(first) }
                for section in sections {
                    let tag: MenuBarItemTag = section.name == .alwaysHidden ? .alwaysHiddenControlItem : .hiddenControlItem
                    let dividers = snapshot.filter { $0.tag == tag && $0.bounds.minY <= placement.display.minY && $0.bounds.maxY > placement.display.minY }
                    guard
                        dividers.count == 1, let divider = dividers.first, !Self.isMidSectionTransition(
                            dividerWidth: divider.bounds.width,
                            isSectionCollapsed: section.controlItem.state == .hideSection
                        )
                    else { return .refuse }
                }
                frames = snapshot.filter {
                    watched.contains($0.windowID) || $0.tag == .hiddenControlItem || $0.tag == .alwaysHiddenControlItem
                }.sorted { $0.windowID < $1.windowID }.map(\.bounds)
                return requested.decision(in: snapshot, placement: placement)
            }
            var decision = try await read(slot)
            if decision == .placed {
                let previous = frames
                try await Task.sleep(for: .milliseconds(60))
                decision = try await read(slot)
                if decision == .placed, frames == previous {
                    return
                }
            }
            guard decision != .refuse else { throw EventError.unsafeMovePath(first) }
            guard await !self.isAnyMenuBarItemMenuOpen() else { throw EventError.menuTrackingActive(first) }
            guard isCurrent() else { throw EventError.moveSuperseded(first) }

            var opened = [MenuBarSection]()
            var didPostEvents = false
            var verified = false
            @MainActor func restore() {
                // Only these dividers were hidden before this drag. The pointer may now be on another display.
                for section in opened.reversed() where section.desiredState == .hideSection && section.controlItem.state == .showSection {
                    section.controlItem.state = .hideSection
                }
                opened.removeAll()
            }

            self.isRevealingForRehide = true
            self.lastMoveOperationTimestamp = .now
            defer {
                restore()
                if didPostEvents, !verified {
                    self.noteRefusedMove(of: first)
                }
                self.lastMoveOperationTimestamp = .now
                self.isRevealingForRehide = false
                self.scheduleCacheRetryAfterMidTransitionSkip(suppressAutomaticMoves: true, suppressSavedOrderPersistence: true)
            }
            if decision == .reveal {
                guard !appState.activeSpace.isFullscreen, !appState.menuBarManager.isMenuBarHiddenBySystem else { throw EventError.unsafeMovePath(first) }
                let names: [MenuBarSection.Name] = section == .alwaysHidden ? [.hidden, .alwaysHidden] : [.hidden]
                let sections = names.compactMap { appState.menuBarManager.section(withName: $0) }
                guard sections.count == names.count, sections.allSatisfy(\.isEnabled) else { throw EventError.unsafeMovePath(first) }
                let collapsed = sections.filter { $0.controlItem.state == .hideSection }
                guard !collapsed.isEmpty, collapsed.allSatisfy({ $0.desiredState == .hideSection }) else {
                    throw EventError.unsafeMovePath(first)
                }
                opened = collapsed
                for section in opened {
                    section.controlItem.state = .showSection
                }

                let deadline = ContinuousClock.now + .seconds(1)
                repeat {
                    try await Task.sleep(for: .milliseconds(60))
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero else { throw EventError.unsafeMovePath(first) }
                    decision = try await read(slot, settling: opened, timeout: remaining)
                } while decision != .move && decision != .placed
            }
            guard decision == .move || decision == .placed else { throw EventError.unsafeMovePath(first) }
            if decision == .move {
                let checksTarget = self.returnEndpointCheck(for: section, destination: destination, on: displayID)
                guard isCurrent() else { throw EventError.moveSuperseded(first) }
                try await self.move(
                    item: first,
                    to: destination,
                    on: displayID,
                    skipInputPause: true,
                    options: .init(
                        watchdogTimeout: Self.layoutWatchdogTimeout,
                        shouldProceed: isCurrent,
                        acceptsEndpoints: { endpoints, display in isCurrent() && checksTarget(endpoints, display) },
                        willPostMoveEvents: { didPostEvents = true },
                        isUserInitiated: true
                    )
                )
            }
            let changedSections = opened
            restore()
            await self.waitForLayoutToSettle(item: first, target: destination.targetItem)
            let deadline = ContinuousClock.now + .seconds(1)
            var lastPlaced: [CGRect]?
            repeat {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw EventError.dropReverted(first) }
                let placed = try await read(slot, settling: changedSections, timeout: remaining) == .placed
                verified = placed && frames == lastPlaced
                lastPlaced = placed ? frames : nil
                if !verified {
                    try await Task.sleep(for: .milliseconds(60))
                }
            } while !verified
        }
    }
}

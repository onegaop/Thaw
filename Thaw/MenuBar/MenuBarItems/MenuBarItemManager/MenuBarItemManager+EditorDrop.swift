//
//  MenuBarItemManager+EditorDrop.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

extension MenuBarItemManager {
    /// Holds the move gate until the whole editor selection has been checked against the user's original neighbor.
    func moveForLayoutEditor(
        items: [MenuBarItem],
        to destination: MoveDestination,
        in section: MenuBarSection.Name,
        on displayID: CGDirectDisplayID,
        spaceID: CGSSpaceID,
        shouldProceed: @escaping @MainActor () -> Bool
    ) async throws {
        guard let first = items.first else { throw EventError.cannotComplete }
        let slot = EditorDropSlot(items: items, destination: destination)
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
            let watched = Set(items.map(\.windowID) + [destination.targetItem.windowID])
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
            var attempted = [CGWindowID: MenuBarItem]()
            var verified = false
            @MainActor func restore() {
                for section in opened.reversed() {
                    section.updateControlItemState()
                }
                opened.removeAll()
            }

            self.isRevealingForRehide = true
            self.lastMoveOperationTimestamp = .now
            defer {
                restore()
                if !verified {
                    for member in attempted.values {
                        self.noteRefusedMove(of: member)
                    }
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
                opened = sections.filter { $0.controlItem.state == .hideSection }
                guard !opened.isEmpty else { throw EventError.unsafeMovePath(first) }
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
                // Inserting each member against the same neighbor preserves the original anchor for every gesture.
                let sequence = switch destination {
                case .leftOfItem: items
                case .rightOfItem: Array(items.reversed())
                }
                let checksTarget = self.returnEndpointCheck(for: section, destination: destination, on: displayID)
                for item in sequence {
                    guard isCurrent() else { throw EventError.moveSuperseded(item) }
                    try await self.move(
                        item: item,
                        to: destination,
                        on: displayID,
                        skipInputPause: true,
                        options: .init(
                            watchdogTimeout: Self.layoutWatchdogTimeout,
                            shouldProceed: isCurrent,
                            acceptsEndpoints: { endpoints, display in isCurrent() && checksTarget(endpoints, display) },
                            willPostMoveEvents: { attempted[item.windowID] = item },
                            isUserInitiated: true
                        )
                    )
                }
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

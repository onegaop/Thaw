//
//  PendingLedger.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Foundation

// MARK: - PendingLedger

/// Planner for temporarilyShow rehides whose app quit before the rehide
/// fired: pending relocations, stored neighbor anchors, and the
/// waitForRelaunch sentinel.
///
/// LayoutSolver decides over the current snapshot; this decides over the
/// per-entry retry state.
nonisolated enum PendingLedger {
    // MARK: - Result types

    /// A pending-relocation entry parsed from its raw string format.
    struct PendingEntry: Equatable {
        let tagIdentifier: String
        let kind: Kind

        enum Kind: Equatable {
            /// A normal pending relocation targeting a specific section.
            case section(MenuBarSection.Name)
            /// The rehide hit its retry cap; suppress moves until the windowID
            /// changes. setAt lets an app that never relaunches age out; nil
            /// is the old untimestamped format, treated as stale.
            case waitForRelaunch(windowID: CGWindowID, section: MenuBarSection.Name, setAt: Date?)
        }
    }

    /// A decision emitted by the pending-relocation planner.
    enum PendingMove: Equatable {
        /// The orchestrator clears the pending entry on success.
        case move(item: MenuBarItem, destination: MenuBarItemManager.MoveDestination)
        /// Clear without moving, e.g. the item is already in its target
        /// section, or the target was .visible.
        case clearEntry
        /// The sentinel's windowID changed (app relaunched); promote it to a
        /// regular section entry.
        case promoteWaitForRelaunch(section: MenuBarSection.Name)
        case skip(reason: SkipReason)

        enum SkipReason: Equatable {
            /// Currently temporarily-shown; the rehide flow owns this item.
            case activelyShown
            /// The app hasn't relaunched yet.
            case itemNotPresent
            /// Skipped to avoid re-saturating the event semaphore.
            case waitForRelaunchActive
        }
    }

    /// destinations is what temporarilyShow persisted at move time (a
    /// neighbor and which side of it). fallbackNeighbors is rebuilt each
    /// cycle and used when the stored neighbor is gone.
    struct PendingReturnInfo: Equatable {
        let destinations: [String: [String: String]]
        let fallbackNeighbors: [String: MenuBarItemTag]

        func savedDestination(for identifier: String, in items: [MenuBarItem]) -> MenuBarItemManager.MoveDestination? {
            guard let saved = destinations[identifier], let tag = saved["neighbor"],
                  let neighbor = items.first(where: { $0.tag.tagIdentifier == tag })
            else { return nil }
            return saved["position"] == "left" ? .leftOfItem(neighbor) : .rightOfItem(neighbor)
        }
    }

    /// The bar as observed this cycle, read once and shared by every entry.
    struct BarState {
        let items: [MenuBarItem]
        let controlItems: MenuBarItemManager.ControlItemPair
        let hiddenBounds: CGRect
        /// Live bounds, which win over an item's cached bounds.
        let boundsForWindowID: [CGWindowID: CGRect]
        /// Control discovery removes these windows from the list passed to the cache planner.
        var itemsIncludingDividers: [MenuBarItem] {
            let dividers = [controlItems.hidden, controlItems.alwaysHidden].compactMap(\.self)
            let dividerIDs = Set(dividers.map(\.windowID))
            return items.filter { !dividerIDs.contains($0.windowID) } + dividers
        }

        /// Tags the rehide flow currently owns.
        let activelyShownTags: Set<String>
        var alwaysHiddenEnabled = true
    }

    // MARK: - Planner

    /// Computes the next pending-relocation decision for a single entry.
    /// Pure; state changes and moves stay with the orchestrator.
    static nonisolated func planPendingMove(
        entry: PendingEntry,
        bar: BarState,
        returnInfo: PendingReturnInfo,
        now: Date = Date(),
        sentinelAgeCap: Duration? = nil,
        placement: RehidePlacement? = nil
    ) -> PendingMove {
        let items = bar.items
        let controlItems = bar.controlItems
        let hiddenBounds = bar.hiddenBounds
        let boundsForWindowID = bar.boundsForWindowID
        let activelyShownTags = bar.activelyShownTags
        if activelyShownTags.contains(entry.tagIdentifier) {
            return .skip(reason: .activelyShown)
        }

        let item = items.first { entry.tagIdentifier == $0.tag.tagIdentifier }

        // Promote on a new windowID. Otherwise skip, unless the sentinel is
        // older than the age cap (or untimestamped): that app won't relaunch,
        // and the item would stay out of the saved order forever. A nil cap
        // disables aging.
        if case let .waitForRelaunch(sentinelWindowID, sentinelSection, setAt) = entry.kind {
            guard let item else {
                return .skip(reason: .itemNotPresent)
            }
            if item.windowID == sentinelWindowID {
                let isStale: Bool = {
                    guard let sentinelAgeCap else { return false }
                    guard let setAt else { return true }
                    let ageSeconds = Int64(now.timeIntervalSince(setAt).rounded())
                    return ageSeconds >= sentinelAgeCap.components.seconds
                }()
                if let placement {
                    let itemsWithDividers = bar.itemsIncludingDividers
                    if placement.contains(item, in: itemsWithDividers) {
                        return .promoteWaitForRelaunch(section: sentinelSection)
                    }
                    if item.isOnScreen, placement.display.contains(item.bounds.center),
                       let neighbor = returnInfo.savedDestination(for: entry.tagIdentifier, in: items),
                       placement.allows(neighbor, in: itemsWithDividers) {
                        return .promoteWaitForRelaunch(section: sentinelSection)
                    }
                }
                if isStale {
                    return .promoteWaitForRelaunch(section: sentinelSection)
                }
                return .skip(reason: .waitForRelaunchActive)
            }
            return .promoteWaitForRelaunch(section: sentinelSection)
        }

        guard case let .section(targetSection) = entry.kind else {
            return .skip(reason: .itemNotPresent)
        }

        guard targetSection != .visible else {
            return .clearEntry
        }

        guard let item else {
            return .skip(reason: .itemNotPresent)
        }

        // Already hidden: clear the entry.
        let itemBounds = boundsForWindowID[item.windowID] ?? item.bounds
        let alwaysHiddenBounds = controlItems.alwaysHidden.map { boundsForWindowID[$0.windowID] ?? $0.bounds }
        let target: MenuBarItemManager.LayoutResetTarget = targetSection == .alwaysHidden && bar.alwaysHiddenEnabled ? .alwaysHidden : .hidden
        if target.contains(itemBounds: itemBounds, hiddenBounds: hiddenBounds, alwaysHiddenBounds: alwaysHiddenBounds) {
            return .clearEntry
        }

        // Stored neighbor, then fallback neighbor, then section boundary.
        if let destination = returnInfo.savedDestination(for: entry.tagIdentifier, in: items) {
            return .move(item: item, destination: destination)
        }

        if let fallbackTag = returnInfo.fallbackNeighbors[entry.tagIdentifier],
           let fallbackItem = items.first(where: { $0.tag.tagIdentifier == fallbackTag.tagIdentifier })
        {
            return .move(item: item, destination: .rightOfItem(fallbackItem))
        }

        switch targetSection {
        case .hidden:
            return .move(item: item, destination: .leftOfItem(controlItems.hidden))
        case .alwaysHidden:
            if let alwaysHidden = controlItems.alwaysHidden {
                return .move(item: item, destination: .leftOfItem(alwaysHidden))
            } else {
                return .move(item: item, destination: .leftOfItem(controlItems.hidden))
            }
        case .visible:
            return .clearEntry
        }
    }
}

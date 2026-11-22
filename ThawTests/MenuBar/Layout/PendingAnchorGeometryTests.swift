//
//  PendingAnchorGeometryTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Testing
@testable import Thaw

@Suite("Pending restoration anchor geometry")
struct PendingAnchorGeometryTests {
    private let display = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    private let notch: ClosedRange<CGFloat> = 751 ... 960

    private func item(_ id: CGWindowID, x: CGFloat, onScreen: Bool = true) -> MenuBarItem {
        .fixture(
            tag: .appItem(bundleID: "com.example.menu", title: String(id)),
            windowID: id,
            bounds: CGRect(x: x, y: 0, width: 36, height: 39),
            isOnScreen: onScreen
        )
    }

    private func reachable(_ destination: MenuBarItemManager.MoveDestination) -> Bool {
        PendingLedger.anchorIsReachable(destination, display: display, reservedNotch: notch)
    }

    @Test("The reported negative drop coordinates remain unreachable even if marked on screen")
    func parkedEndpoints() {
        for x: CGFloat in [-4098, -4065, -4031] {
            #expect(!reachable(.leftOfItem(item(10, x: x, onScreen: false))))
            #expect(!reachable(.leftOfItem(item(10, x: x))))
        }
        #expect(!reachable(.leftOfItem(item(10, x: 1080, onScreen: false))))
        #expect(reachable(.leftOfItem(item(10, x: 1080))))
    }

    @Test("Pending restore keeps the saved side while the parked lane reflows")
    func reportedDropBecomesReachable() {
        let source = item(20, x: 1200)
        let anchor = item(21, x: -4065, onScreen: false)
        let destination = MenuBarItemManager.MoveDestination.leftOfItem(anchor)
        let controls = MenuBarItemManager.ControlItemPair.fixture(
            hiddenAt: CGRect(x: -3893, y: 0, width: 5016, height: 39)
        )
        let key = source.tag.tagIdentifier
        let plan = PendingLedger.planPendingMove(
            entry: .init(tagIdentifier: key, kind: .section(.hidden)),
            bar: .init(items: [source, anchor], controlItems: controls, hiddenBounds: controls.hidden.bounds, boundsForWindowID: [:], activelyShownTags: []),
            returnInfo: .init(destinations: [key: ["neighbor": anchor.tag.tagIdentifier, "position": "left"]], fallbackNeighbors: [:])
        )
        #expect(plan == .move(item: source, destination: destination))
        #expect(!reachable(destination))
        #expect(!reachable(destination.replacingTarget(with: item(21, x: 920))))
        let freshDestination = destination.replacingTarget(with: item(21, x: 1010))
        #expect(reachable(freshDestination))
        #expect(freshDestination.targetPoint(in: freshDestination.targetItem.bounds, on: display).x == 1010)
    }

    @Test("Reachability follows the requested edge of an item over a notch")
    func notchAtRequestedEdge() {
        let anchor = item(10, x: 950)
        #expect(!reachable(.leftOfItem(anchor)))
        #expect(reachable(.rightOfItem(anchor)))
        #expect(PendingLedger.anchorIsReachable(.leftOfItem(anchor), display: display, reservedNotch: nil))
    }

    @Test("A wide divider that intersects the display can have an unreachable leading edge")
    func wideDivider() {
        let divider = MenuBarItem.fixture(
            tag: .hiddenControlItem,
            windowID: 11,
            bounds: CGRect(x: -3893, y: 0, width: 5016, height: 39)
        )
        #expect(!reachable(.leftOfItem(divider)))
        let edgeDivider = MenuBarItem.fixture(
            tag: .hiddenControlItem,
            windowID: 12,
            bounds: CGRect(x: 0, y: 0, width: 18, height: 39)
        )
        #expect(!reachable(.leftOfItem(edgeDivider)))
        #expect(reachable(.rightOfItem(edgeDivider)))
    }

    @Test("A legitimate coordinate on a left-hand display is reachable only on that display")
    func selectedDisplay() {
        let leftDisplay = CGRect(x: -1710, y: 0, width: 1710, height: 1112)
        let destination = MenuBarItemManager.MoveDestination.leftOfItem(item(10, x: -1420))
        #expect(!reachable(destination))
        #expect(PendingLedger.anchorIsReachable(destination, display: leftDisplay, reservedNotch: nil))
    }

    private var controlItems: MenuBarItemManager.ControlItemPair {
        .fixture(
            hiddenAt: CGRect(x: 400, y: 0, width: 10, height: 39),
            alwaysHiddenAt: CGRect(x: 100, y: 0, width: 10, height: 39)
        )
    }

    private func plan(
        source: MenuBarItem,
        neighbor: MenuBarItem,
        targetSection: MenuBarSection.Name = .hidden,
        storedPosition: String? = "left",
        otherItems: [MenuBarItem] = [],
        liveBounds: [CGWindowID: CGRect] = [:]
    ) -> PendingLedger.PendingMove {
        let key = source.tag.tagIdentifier
        let stored = storedPosition.map { [key: ["position": $0, "neighbor": neighbor.tag.tagIdentifier]] } ?? [:]
        return PendingLedger.planPendingMove(
            entry: .init(tagIdentifier: key, kind: .section(targetSection)),
            bar: .init(
                items: [neighbor, source] + otherItems,
                controlItems: controlItems,
                hiddenBounds: controlItems.hidden.bounds,
                boundsForWindowID: liveBounds,
                activelyShownTags: []
            ),
            returnInfo: .init(destinations: stored, fallbackNeighbors: [key: neighbor.tag])
        )
    }

    @Test("Stored and fallback neighbors in the wrong section resolve to the requested boundary")
    func wrongSectionNeighbors() throws {
        let source = item(20, x: 500)
        let visibleAnchor = item(21, x: 600)
        let hiddenAnchor = item(22, x: 250)
        let alwaysHiddenAnchor = item(23, x: 30)
        let alwaysHiddenDivider = try #require(controlItems.alwaysHidden)
        for position: String? in ["left", nil] {
            for neighbor in [visibleAnchor, alwaysHiddenAnchor] {
                let result = plan(source: source, neighbor: neighbor, storedPosition: position)
                #expect(result == .move(item: source, destination: .leftOfItem(controlItems.hidden)))
            }
            let result = plan(source: source, neighbor: hiddenAnchor, targetSection: .alwaysHidden, storedPosition: position)
            #expect(result == .move(item: source, destination: .leftOfItem(alwaysHiddenDivider)))
        }
    }

    @Test("Reaching the hidden section leaves a return to the exact neighboring slot pending")
    func interposedItemStillRequiresMove() {
        let source = item(20, x: 150)
        let neighbor = item(21, x: 300)
        let other = item(22, x: 220)
        #expect(plan(source: source, neighbor: neighbor, otherItems: [other]) == .move(item: source, destination: .leftOfItem(neighbor)))
        #expect(plan(source: neighbor, neighbor: source, storedPosition: "right", otherItems: [other]) == .move(item: neighbor, destination: .rightOfItem(source)))
    }

    @Test("Landing on the saved side clears the entry even with other sections populated")
    func landedOnCorrectSide() {
        let source = item(20, x: 150)
        let neighbor = item(21, x: 250)
        let unrelated = [item(22, x: 10), item(23, x: 520)]
        #expect(plan(source: source, neighbor: neighbor, otherItems: unrelated) == .clearEntry)
        #expect(plan(source: neighbor, neighbor: source, storedPosition: "right", otherItems: unrelated) == .clearEntry)
        #expect(plan(source: source, neighbor: neighbor, storedPosition: "right") == .move(item: source, destination: .rightOfItem(neighbor)))
    }

    @Test("Live bounds decide adjacency and target section when the cached snapshot is stale")
    func liveBoundsWin() {
        let source = item(20, x: 500)
        let neighbor = item(21, x: 250)
        let other = item(22, x: 600)
        let currentSource = item(20, x: 150).bounds
        #expect(plan(source: source, neighbor: neighbor, liveBounds: [20: currentSource]) == .clearEntry)
        let current: [CGWindowID: CGRect] = [20: currentSource, 22: item(22, x: 200).bounds]
        #expect(plan(source: source, neighbor: neighbor, otherItems: [other], liveBounds: current) == .move(item: source, destination: .leftOfItem(neighbor)))
        #expect(plan(source: source, neighbor: neighbor, liveBounds: [21: other.bounds]) == .move(item: source, destination: .leftOfItem(controlItems.hidden)))
    }
}

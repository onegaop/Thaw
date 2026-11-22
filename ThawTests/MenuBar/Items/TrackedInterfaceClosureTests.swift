//
//  TrackedInterfaceClosureTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Testing
@testable import Thaw

@Suite("Previously tracked interface dismissal")
struct TrackedInterfaceClosureTests {
    let now = ContinuousClock.now

    private func window(_ id: CGWindowID, owner: pid_t = 7, layer: CGWindowLevelKey = .normalWindow, height: CGFloat = 200) -> WindowInfo {
        WindowInfo(windowID: id, ownerPID: owner, bounds: CGRect(x: 0, y: 0, width: 100, height: height), layer: Int(CGWindowLevelForKey(layer)))
    }

    private var icon: WindowInfo {
        window(1, owner: 17, layer: .statusWindow, height: 24)
    }

    private var menu: WindowInfo {
        window(2, layer: .popUpMenuWindow)
    }

    private func read(
        _ probe: inout TrackedInterfaceClosure, after ms: Int, visible: [WindowInfo]?, tracked: WindowInfo? = nil
    ) -> TrackedInterfaceClosure.State {
        probe.readAfterLoss(of: tracked ?? menu, itemWindowID: 1, interfacePIDs: [7, 17], visible: visible, now: now + .milliseconds(ms))
    }

    @Test("A destroyed native menu or accessory panel closes after two clear readings")
    func confirmedClose() {
        for tracked in [menu, window(2, layer: .floatingWindow)] {
            var probe = TrackedInterfaceClosure(beforeClick: [1, 3])
            let visible = [icon, window(3), window(2, owner: 99)]
            #expect(read(&probe, after: 0, visible: visible, tracked: tracked) == .showing)
            #expect(read(&probe, after: 10, visible: visible, tracked: tracked) == .showing)
            #expect(read(&probe, after: 250, visible: visible, tracked: tracked) == .absent)
        }
    }

    @Test("An open replacement, nested menu, or reappearing original restarts the clock")
    func replacementKeepsIcon() {
        for replacement in [menu, window(3, owner: 17, layer: .popUpMenuWindow), window(4, layer: .floatingWindow)] {
            var probe = TrackedInterfaceClosure(beforeClick: [1, 3])
            #expect(read(&probe, after: 0, visible: [icon]) == .showing)
            #expect(read(&probe, after: 1000, visible: [icon, replacement]) == .showing)
            #expect(read(&probe, after: 2000, visible: [icon]) == .showing)
            #expect(read(&probe, after: 3000, visible: [icon]) == .absent)
        }
    }

    @Test("A failed read, a changed status-item owner, or a missing icon cannot prove closure")
    func failedReadRestartsClock() {
        let observations: [[WindowInfo]?] = [nil, [], [window(1, owner: 99)]]
        for observation in observations {
            var probe = TrackedInterfaceClosure(beforeClick: [1])
            #expect(read(&probe, after: 0, visible: [icon]) == .showing)
            #expect(read(&probe, after: 1000, visible: observation) == .unknown)
            #expect(read(&probe, after: 2000, visible: [icon]) == .showing)
        }
    }

    @Test("The original window must have belonged to the click")
    func inconclusiveBaseline() {
        for baseline: Set<CGWindowID> in [[], [1, 2]] {
            var probe = TrackedInterfaceClosure(beforeClick: baseline)
            #expect(read(&probe, after: 0, visible: [icon]) == .unknown)
        }
        var probe = TrackedInterfaceClosure(beforeClick: [1])
        #expect(read(&probe, after: 0, visible: [icon], tracked: window(2, owner: 99)) == .unknown)
    }
}

//
//  RehidePlacementTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Testing
@testable import Thaw

@Suite("Temporary item return placement")
struct RehidePlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)

    private func policy(_ section: MenuBarSection.Name = .hidden, alwaysHidden: Bool = false) -> RehidePlacement {
        RehidePlacement(section: section, display: screen, reservedNotch: 751 ... 960, alwaysHiddenEnabled: alwaysHidden)
    }

    private func item(_ id: CGWindowID, _ x: CGFloat, width: CGFloat = 36, onScreen: Bool = true, y: CGFloat = 0, tag: MenuBarItemTag? = nil) -> MenuBarItem {
        .fixture(
            tag: tag ?? .appItem(bundleID: "com.example.status", title: String(id)),
            windowID: id,
            bounds: CGRect(x: x, y: y, width: width, height: 39),
            isOnScreen: onScreen
        )
    }

    @Test("The collapsed native bar offers no drop at the reported negative coordinates")
    func noReachableSlotUntilNativeReveal() {
        for x: CGFloat in [-4065, -4098] {
            let neighbor = item(1, x, onScreen: false)
            let hidden = item(2, -3893, width: 5016, onScreen: false, tag: .hiddenControlItem)
            let source = item(3, 1200)
            let plan = policy()
            #expect(plan.destination(primary: .leftOfItem(neighbor), alternate: nil, in: [source, hidden, neighbor]) == nil)
            #expect(!plan.contains(source, in: [source, hidden, neighbor]))
            let exposed = item(1, 1030)
            let divider = item(2, 1115, width: 8, tag: .hiddenControlItem)
            #expect(plan.destination(primary: .leftOfItem(exposed), alternate: nil, in: [source, divider, exposed]) == .leftOfItem(exposed))
            let parked = item(3, x - 38, onScreen: false)
            #expect(plan.contains(parked, in: [parked, hidden, neighbor]))
        }
    }

    @Test("The reachable opposite neighbor wins over a boundary when the original neighbor moved sections")
    func alternateThenDivider() {
        let divider = item(2, 1100, tag: .hiddenControlItem)
        let stale = item(3, 1180)
        let alternate = item(4, 1010)
        let rows = [divider, stale, alternate]
        #expect(policy().destination(primary: .leftOfItem(stale), alternate: .rightOfItem(alternate), in: rows) == .rightOfItem(alternate))
        #expect(policy().destination(primary: .leftOfItem(stale), alternate: nil, in: [stale, divider]) == .leftOfItem(divider))
    }

    @Test("The drop edge itself must be reachable and outside the notch")
    func actualDropEdge() {
        let divider = item(2, 1100, tag: .hiddenControlItem)
        let neighbor = item(3, 950)
        let rows = [neighbor, divider]
        #expect(!policy().allows(.leftOfItem(neighbor), in: rows))
        #expect(policy().allows(.rightOfItem(neighbor), in: rows))
        let edge = item(2, 0, tag: .hiddenControlItem)
        #expect(!policy().allows(.leftOfItem(edge), in: [edge]))
    }

    @Test("An inaccessible boundary can use another reachable member of the same section")
    func alternateSectionMember() {
        let divider = item(2, 915, tag: .hiddenControlItem)
        let parked = item(3, -4100, onScreen: false)
        let member = item(4, 680)
        let wrongSection = item(5, 1050)
        let rows = [divider, parked, member, wrongSection]
        #expect(policy().destination(primary: .leftOfItem(parked), alternate: nil, in: rows) == .leftOfItem(member))
    }

    @Test("The right edge of the always-hidden divider is a hidden-section boundary")
    func oppositeBoundaryBetweenSections() {
        let always = item(1, 600, tag: .alwaysHiddenControlItem)
        let hidden = item(2, 880, tag: .hiddenControlItem)
        let rows = [always, hidden]
        #expect(policy(alwaysHidden: true).destination(primary: nil, alternate: nil, in: rows) == .rightOfItem(always))
        #expect(policy(.alwaysHidden, alwaysHidden: true).destination(primary: nil, alternate: nil, in: rows) == .leftOfItem(always))
        #expect(policy(alwaysHidden: true).destination(primary: nil, alternate: nil, in: [hidden]) == nil)
        #expect(policy(.alwaysHidden).destination(primary: nil, alternate: nil, in: [always]) == nil)
    }

    @Test("Landing must be in the real target section, on its row, with nonempty geometry")
    func rejectsWrongLanding() {
        let hidden = item(2, 1100, tag: .hiddenControlItem)
        let always = item(1, 500, tag: .alwaysHiddenControlItem)
        let rows = [hidden, always]
        let plan = policy(alwaysHidden: true)
        #expect(!plan.contains(item(3, 1200), in: rows))
        #expect(!plan.contains(item(3, 445), in: rows))
        #expect(!plan.contains(item(3, 1040, y: 538), in: rows))
        #expect(!plan.contains(item(3, 1040, width: 0), in: rows))
        #expect(plan.contains(item(3, 1040), in: rows))
        #expect(policy(.alwaysHidden, alwaysHidden: true).contains(item(3, 445), in: rows))
    }

    @Test("A left-hand display on the same row cannot masquerade as the selected display's hidden section")
    func rejectsOtherDisplay() {
        var plan = policy()
        plan.otherDisplays = [CGRect(x: -1710, y: 0, width: 1710, height: 1112)]
        let hidden = item(2, 1100, tag: .hiddenControlItem)
        let elsewhere = item(3, -280)
        let rows = [hidden, elsewhere]
        #expect(!plan.contains(elsewhere, in: rows))
        #expect(!plan.allows(.leftOfItem(elsewhere), in: rows))
        #expect(plan.contains(item(4, -4050, onScreen: false), in: rows))
        let foreignDivider = item(2, -250, tag: .hiddenControlItem)
        #expect(!plan.contains(item(4, -4050, onScreen: false), in: [foreignDivider]))
    }

    @Test("A stale, removed or ambiguous neighbor cannot receive a gesture")
    func validatesCurrentTarget() {
        let hidden = item(2, 1100, tag: .hiddenControlItem)
        let old = item(3, 1050)
        let moved = item(3, 1400)
        #expect(!policy().allows(.leftOfItem(old), in: [hidden]))
        #expect(!policy().allows(.leftOfItem(old), in: [hidden, moved]))
        #expect(!policy().allows(.leftOfItem(old), in: [hidden, old, moved]))
    }
}

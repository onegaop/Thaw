// Licensed under the GNU GPLv3

import CoreGraphics
import Testing
@testable import Thaw

@Suite("Layout editor native drop verification")
struct EditorDropSlotTests {
    private let screen = CGRect(x: 0, y: 0, width: 1710, height: 1112)

    private var placement: RehidePlacement {
        RehidePlacement(section: .hidden, display: screen, reservedNotch: 751 ... 960, alwaysHiddenEnabled: false)
    }

    private func item(
        _ id: CGWindowID,
        at x: CGFloat,
        y: CGFloat = 0,
        width: CGFloat = 32,
        onScreen: Bool = true,
        tag: MenuBarItemTag? = nil,
        owner: pid_t = 100,
        source: pid_t = 101
    ) -> MenuBarItem {
        .fixture(
            tag: tag ?? .appItem(bundleID: "com.example.EditorDrop", title: String(id)),
            windowID: id,
            bounds: CGRect(x: x, y: y, width: width, height: 33),
            sourcePID: source,
            ownerPID: owner,
            isOnScreen: onScreen
        )
    }

    private var divider: MenuBarItem { item(90, at: 1115, width: 8, tag: .hiddenControlItem) }

    @Test("A parked neighbor needs native reveal, then a verified drag to the original side")
    func revealMoveThenConfirmExactSlot() {
        let source = item(1, at: 1250)
        let parked = item(2, at: -4065, onScreen: false)
        let wide = item(90, at: -3893, width: 5016, onScreen: false, tag: .hiddenControlItem)
        let shown = item(2, at: 1040)
        let slot = EditorDropSlot(items: [source], destination: .leftOfItem(parked))

        #expect(slot.decision(in: [source, wide, parked], placement: placement) == .reveal)
        #expect(slot.decision(in: [divider, shown, source], placement: placement) == .move)
        #expect(slot.decision(in: [shown, divider, item(1, at: 1005)], placement: placement) == .placed)
        #expect(slot.decision(in: [shown, divider, item(1, at: 1080)], placement: placement) != .placed)
        let landed = item(1, at: -4098, onScreen: false)
        #expect(slot.decision(in: [parked, wide, landed], placement: placement) == .placed)
        // If WindowServer reverts after the divider is restored, a prior exposed success no longer counts.
        #expect(slot.decision(in: [parked, wide, source], placement: placement) == .reveal)
    }

    @Test("The source and anchor each require a unique live identity")
    func refusesRecycledMissingAndDuplicateEndpoints() {
        let source = item(1, at: 1250)
        let target = item(2, at: 1040)
        let slot = EditorDropSlot(items: [source], destination: .leftOfItem(target))
        let invalid: [[MenuBarItem]] = [
            [target], [source], [source, source, target], [source, target, target],
            [item(11, at: 1000, tag: source.tag), target],
            [source, item(12, at: 1040, tag: target.tag)],
            [item(1, at: 1000, owner: 500), target],
            [item(1, at: 1000, source: 500), target],
            [item(1, at: 1000, tag: target.tag), target],
            [source, item(2, at: 1040, owner: 500)],
            [source, item(2, at: 1040, source: 500)],
            [source, item(2, at: 1040, tag: source.tag)],
        ]
        for endpoints in invalid {
            #expect(slot.decision(in: [divider] + endpoints, placement: placement) == .refuse)
        }
    }

    @Test("Failure and vanished anchors never substitute another reachable neighbor")
    func noFallbackToWrongItemOrSection() {
        let source = item(1, at: 1250)
        let target = item(2, at: 1040)
        let spare = item(3, at: 1000)
        let slot = EditorDropSlot(items: [source], destination: .rightOfItem(target))

        #expect(slot.decision(in: [divider, source, spare], placement: placement) == .refuse)
        #expect(slot.decision(in: [divider, source, spare, item(2, at: 1210)], placement: placement) == .refuse)
        #expect(slot.decision(in: [divider, source, spare, target], placement: placement) == .move)
        #expect(slot.decision(in: [divider, item(1, at: 1080), spare, target], placement: placement) == .placed)
    }

    @Test("Group completion needs every member in order and contiguous with the original anchor")
    func verifiesEntireSelectionOnBothSides() {
        let first = item(1, at: 600)
        let second = item(2, at: 650)
        let target = item(3, at: 700)
        let left = EditorDropSlot(items: [first, second], destination: .leftOfItem(target))
        let right = EditorDropSlot(items: [first, second], destination: .rightOfItem(target))
        let complete = [second, divider, target, first]
        #expect(left.decision(in: complete, placement: placement) == .placed)
        #expect(right.decision(in: complete, placement: placement) != .placed)
        let targetAtLeft = item(3, at: 550)
        #expect(right.decision(in: [second, targetAtLeft, first, divider], placement: placement) == .placed)
        #expect(left.decision(in: [divider, item(1, at: 650), item(2, at: 600), target], placement: placement) != .placed)
        for x: CGFloat in [600, 625, 650, 675, 700] {
            #expect(left.decision(in: complete + [item(4, at: x)], placement: placement) != .placed)
        }
        #expect(left.decision(in: [divider, first, target], placement: placement) == .refuse)
        #expect(left.decision(in: [divider, first, item(2, at: 1200), target], placement: placement) != .placed)
    }

    @Test("A different display or menu row cannot borrow the selected display's slot")
    func refusesCrossDisplayMovesAndWrongRows() {
        let source = item(1, at: 1250)
        let target = item(2, at: 1040)
        let slot = EditorDropSlot(items: [source], destination: .leftOfItem(target))
        var twoDisplays = placement
        twoDisplays.otherDisplays = [screen.offsetBy(dx: -screen.width, dy: 0)]
        #expect(slot.decision(in: [divider, item(1, at: -400), target], placement: twoDisplays) == .refuse)
        #expect(slot.decision(in: [divider, source, item(2, at: -400)], placement: twoDisplays) == .refuse)
        #expect(slot.decision(in: [divider, source, item(2, at: -4100, y: 500, onScreen: false)], placement: twoDisplays) == .refuse)
        #expect(slot.decision(in: [divider, item(1, at: 1000, y: 500), target], placement: twoDisplays) == .refuse)
        #expect(slot.decision(in: [divider, item(1, at: 1000, y: 3), target], placement: twoDisplays) == .placed)
    }

    @Test("The requested drop edge must be reachable outside the camera housing")
    func checksRequestedEdgeInsteadOfItemCenter() {
        let source = item(1, at: 1250)
        let target = item(2, at: 950)
        let left = EditorDropSlot(items: [source], destination: .leftOfItem(target))
        let right = EditorDropSlot(items: [source], destination: .rightOfItem(target))
        let rows = [source, divider, target]

        #expect(left.decision(in: rows, placement: placement) == .refuse)
        #expect(right.decision(in: rows, placement: placement) == .move)
    }

    @Test("The always-hidden lane needs its own enabled divider and exact neighbor")
    func alwaysHiddenProvesIndependentLane() {
        let source = item(1, at: 1240)
        let target = item(2, at: 500)
        let always = item(91, at: 600, width: 8, tag: .alwaysHiddenControlItem)
        let slot = EditorDropSlot(items: [source], destination: .rightOfItem(target))
        let plan = RehidePlacement(section: .alwaysHidden, display: screen, reservedNotch: nil, alwaysHiddenEnabled: true)
        #expect(slot.decision(in: [divider, target, source], placement: plan) == .refuse)
        #expect(slot.decision(in: [divider, always, target, source], placement: plan) == .move)
        #expect(slot.decision(in: [divider, always, target, item(1, at: 540)], placement: plan) == .placed)
        #expect(slot.decision(in: [divider, always, target, item(1, at: 640)], placement: plan) != .placed)
        let disabled = RehidePlacement(section: .alwaysHidden, display: screen, reservedNotch: nil, alwaysHiddenEnabled: false)
        #expect(slot.decision(in: [divider, always, target, source], placement: disabled) == .refuse)
    }

    @Test("Display and Space must still both identify the editor's original native bar")
    func rejectsChangedDisplayOrSpace() {
        #expect(EditorDropSlot.isCurrent(displayID: 10, spaceID: 20, activeDisplayID: 10, activeSpaceID: 20))
        #expect(!EditorDropSlot.isCurrent(displayID: 10, spaceID: 20, activeDisplayID: 11, activeSpaceID: 20))
        #expect(!EditorDropSlot.isCurrent(displayID: 10, spaceID: 20, activeDisplayID: 10, activeSpaceID: 21))
        #expect(!EditorDropSlot.isCurrent(displayID: 10, spaceID: 20, activeDisplayID: nil, activeSpaceID: 20))
        #expect(!EditorDropSlot.isCurrent(displayID: 0, spaceID: 20, activeDisplayID: 0, activeSpaceID: 20))
        #expect(!EditorDropSlot.isCurrent(displayID: 10, spaceID: 0, activeDisplayID: 10, activeSpaceID: 0))
    }

    @MainActor
    @Test("A superseded editor drag stops at admission before native enumeration or reveal")
    func rejectsSupersededGeneration() async {
        let manager = MenuBarItemManager()
        let source = item(1, at: 1200)
        let target = item(2, at: -4065, onScreen: false)
        var checkedGeneration = false
        do {
            try await manager.moveForLayoutEditor(
                items: [source], to: .rightOfItem(target), in: .hidden, on: 1, spaceID: 2,
                shouldProceed: {
                    checkedGeneration = true
                    return false
                }
            )
            Issue.record("Superseded edit completed")
        } catch MenuBarItemManager.EventError.moveSuperseded(let rejected) {
            #expect(rejected == source)
        } catch {
            Issue.record("Unexpected admission error: \(error)")
        }
        #expect(checkedGeneration)
        #expect(!manager.isRevealingForRehide)
    }

    @MainActor
    @Test("A task cancelled while owning the gate does not start an editor gesture")
    func stopsCancelledTaskBeforeAdmission() async throws {
        let manager = MenuBarItemManager()
        let source = item(1, at: 1200)
        let target = item(2, at: -4065, onScreen: false)
        // Cancel after acquiring the permit to avoid a race with semaphore admission.
        try await Task { @MainActor in
            try await MenuBarItemManager.performWithMoveGate {
                withUnsafeCurrentTask { $0?.cancel() }
                #expect(Task.isCancelled)
                do {
                    try await manager.moveForLayoutEditor(
                        items: [source], to: .leftOfItem(target), in: .hidden, on: 1, spaceID: 2,
                        shouldProceed: {
                            Issue.record("Cancelled operation proceeded to generation validation")
                            return false
                        }
                    )
                    Issue.record("Cancelled edit completed")
                } catch MenuBarItemManager.EventError.moveSuperseded(let rejected) {
                    #expect(rejected == source)
                }
            }
        }.value
        #expect(!manager.isRevealingForRehide)
    }
}

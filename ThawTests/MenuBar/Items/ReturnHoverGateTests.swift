//
//  ReturnHoverGateTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Testing
@testable import Thaw

@Suite("Temporary return hover suppression")
struct ReturnHoverGateTests {
    @Test("Only the affected display waits for physical movement after restoration")
    func hardwareMovementRearms() {
        var gate = ReturnHoverGate()
        let now = ContinuousClock.now
        #expect(gate.permitsDelivery(on: 1, generation: nil))
        let generation = gate.begin(on: 1)
        #expect(!gate.permitsHover(on: 1) { _ in true })
        #expect(gate.permitsHover(on: 2) { _ in false })
        #expect(gate.permitsDelivery(on: 2, generation: nil))
        gate.finish(on: 1, token: generation, now: now)
        #expect(!gate.permitsHover(on: 1) { _ in false })
        #expect(!gate.permitsDelivery(on: 1, generation: generation))
        #expect(gate.permitsHover(on: 1) { $0 == now })
        #expect(gate.permitsHover(on: 1) { _ in false })
        #expect(gate.permitsDelivery(on: 1, generation: generation))
        #expect(!gate.permitsDelivery(on: 1, generation: nil))
    }

    @Test("An old cleanup or queued hover cannot open a newer panel")
    func successiveReturns() {
        var gate = ReturnHoverGate()
        let first = gate.begin(on: 1)
        let second = gate.begin(on: 1)
        gate.finish(on: 1, token: first)
        #expect(!gate.permitsHover(on: 1) { _ in true })
        gate.finish(on: 1, token: second)
        #expect(gate.permitsHover(on: 1) { _ in true })
        #expect(!gate.permitsDelivery(on: 1, generation: first))
        #expect(gate.permitsDelivery(on: 1, generation: second))
    }
}

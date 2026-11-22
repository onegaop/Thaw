//
//  ReturnHoverGate.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Foundation

/// Suppresses passive hover caused by a temporary return without blocking explicit activation.
nonisolated struct ReturnHoverGate {
    private enum Phase {
        case moving, awaitingMotion(ContinuousClock.Instant), ready
    }

    private struct Entry {
        let token: UUID
        var phase: Phase
    }

    private var entries = [CGDirectDisplayID: Entry]()

    mutating func begin(on display: CGDirectDisplayID) -> UUID {
        let token = UUID()
        entries[display] = Entry(token: token, phase: .moving)
        return token
    }

    mutating func finish(on display: CGDirectDisplayID, token: UUID, now: ContinuousClock.Instant = .now) {
        guard entries[display]?.token == token else { return }
        entries[display]?.phase = .awaitingMotion(now)
    }

    func generation(on display: CGDirectDisplayID) -> UUID? {
        entries[display]?.token
    }

    /// Only a fresh hardware movement, not a cursor warp or elapsed time, rearms hover.
    mutating func permitsHover(on display: CGDirectDisplayID, movedSince: (ContinuousClock.Instant) -> Bool) -> Bool {
        guard let entry = entries[display] else { return true }
        switch entry.phase {
        case .moving:
            return false
        case let .awaitingMotion(end):
            guard movedSince(end) else { return false }
            entries[display]?.phase = .ready
            return true
        case .ready:
            return true
        }
    }

    func permitsDelivery(on display: CGDirectDisplayID, generation: UUID?) -> Bool {
        guard let entry = entries[display] else { return generation == nil }
        if case .ready = entry.phase {
            return generation == entry.token
        }
        return false
    }
}

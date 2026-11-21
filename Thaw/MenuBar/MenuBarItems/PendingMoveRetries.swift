//
//  PendingMoveRetries.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics

/// Limits automatic attempts against the same neighbor while the saved return stays pending.
nonisolated struct PendingMoveRetries {
    struct Endpoints {
        let source: CGWindowID
        let anchor: CGWindowID
        let displayID: CGDirectDisplayID?
        let display: CGRect
        let target: CGRect
        let reachable: Bool

        func matches(_ other: Self) -> Bool {
            guard source == other.source, anchor == other.anchor, displayID == other.displayID, display == other.display, reachable == other.reachable
            else { return false }
            // Ignore small shifts as status items appear. A larger shift can expose a previously blocked drop after expanding.
            return abs(target.minX - other.target.minX) <= 4 * max(target.height, other.target.height)
        }
    }

    private struct Failure {
        let endpoints: Endpoints
        let count: Int
        let allowedAt: ContinuousClock.Instant?
        var nextProbe: ContinuousClock.Instant
    }

    private var failures = [String: Failure]()

    static func shouldRetry(_ error: any Error) -> Bool {
        switch error as? MenuBarItemManager.EventError {
        case .dropReverted, .unsafeMovePath: true
        default: false
        }
    }

    mutating func forget(_ identifier: String) {
        failures.removeValue(forKey: identifier)
    }

    mutating func shouldAttempt(
        _ identifier: String, endpoints: Endpoints?, now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard let previous = failures[identifier] else { return true }
        guard let endpoints, previous.endpoints.matches(endpoints) else {
            forget(identifier)
            return true
        }
        guard let allowedAt = previous.allowedAt, now >= allowedAt else { return false }
        failures[identifier]?.nextProbe = now.advanced(by: .seconds(30))
        return true
    }

    @discardableResult
    mutating func recordFailure(
        _ identifier: String, endpoints: Endpoints, now: ContinuousClock.Instant = .now
    ) -> Bool {
        let previous = failures[identifier].flatMap { $0.endpoints.matches(endpoints) ? $0 : nil }
        let count = (previous?.count ?? 0) + 1
        // After three retries, wait for a different window or a change in drop reachability.
        let allowedAt = count <= 3 ? now.advanced(by: MenuBarItemFailureLedger.backoffInterval(failureCount: count)) : nil
        failures[identifier] = Failure(endpoints: previous?.endpoints ?? endpoints, count: count, allowedAt: allowedAt, nextProbe: allowedAt ?? now.advanced(by: .seconds(300)))
        return allowedAt == nil
    }

    /// A rejected or busy cache pass can try again later without turning the normal three-second tick into a full scan.
    mutating func needsCachePass(windowIDs: [CGWindowID], now: ContinuousClock.Instant = .now) -> Bool {
        var needsPass = false
        for (identifier, failure) in failures {
            guard now >= failure.nextProbe, windowIDs.contains(failure.endpoints.source), windowIDs.contains(failure.endpoints.anchor)
            else { continue }
            // With an exhausted budget, only look for changed geometry. shouldAttempt still vetoes the drag.
            failures[identifier]?.nextProbe = now.advanced(by: failure.allowedAt == nil ? .seconds(300) : .seconds(30))
            needsPass = true
        }
        return needsPass
    }
}

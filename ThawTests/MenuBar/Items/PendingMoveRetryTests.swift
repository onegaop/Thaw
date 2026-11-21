//
//  PendingMoveRetryTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Testing
@testable import Thaw

@Suite("Pending item restoration retries")
struct PendingMoveRetryTests {
    private let item = MenuBarItem.fixture(tag: .appItem(bundleID: "example.source", title: "Source"), windowID: 10)

    private func endpoints(
        anchorID: CGWindowID = 20, x: CGFloat = -2000, displayID: CGDirectDisplayID = 1, reachable: Bool = false
    ) -> PendingMoveRetries.Endpoints {
        .init(
            source: 10, anchor: anchorID, displayID: displayID,
            display: CGRect(x: 0, y: 0, width: 1440, height: 900),
            target: CGRect(x: x, y: 0, width: 24, height: 22), reachable: reachable
        )
    }

    @Test("Only a refused drop or unsafe path schedules retries")
    func eligibleOutcomes() {
        #expect(PendingMoveRetries.shouldRetry(MenuBarItemManager.EventError.dropReverted(item)))
        #expect(PendingMoveRetries.shouldRetry(MenuBarItemManager.EventError.unsafeMovePath(item)))
        #expect(!PendingMoveRetries.shouldRetry(MenuBarItemManager.EventError.moveSuperseded(item)))
        #expect(!PendingMoveRetries.shouldRetry(CancellationError()))
        let error = MenuBarItemManager.EventError.unsafeMovePath(item)
        #expect(MenuBarItemManager.automaticMoveFailureDisposition(for: error) == .deferred)
        #expect(MenuBarItemManager.automaticMoveFailureDisposition(for: error, pendingRetriesExhausted: true) == .report)
    }

    @Test("With unchanged windows a due retry wakes once, and is scoped to the affected item")
    func dueProbe() {
        var retries = PendingMoveRetries()
        let plan = endpoints()
        let start = ContinuousClock.now
        let due = start.advanced(by: .seconds(30))
        retries.recordFailure("source", endpoints: plan, now: start)
        let affectedReady = retries.shouldAttempt("source", endpoints: plan, now: start)
        #expect(!affectedReady)
        let unrelatedReady = retries.shouldAttempt("other", endpoints: plan, now: start)
        #expect(unrelatedReady)
        let earlyProbe = retries.needsCachePass(windowIDs: [10, 20], now: start)
        #expect(!earlyProbe)
        let missingSourceProbe = retries.needsCachePass(windowIDs: [20], now: due)
        #expect(!missingSourceProbe)
        let missingAnchorProbe = retries.needsCachePass(windowIDs: [10], now: due)
        #expect(!missingAnchorProbe)
        let dueProbe = retries.needsCachePass(windowIDs: [10, 20], now: due)
        #expect(dueProbe)
        let duplicateProbe = retries.needsCachePass(windowIDs: [10, 20], now: due)
        #expect(!duplicateProbe)
        let retryReady = retries.shouldAttempt("source", endpoints: plan, now: due)
        #expect(retryReady)
        let deferredProbe = retries.needsCachePass(windowIDs: [10, 20], now: due.advanced(by: .seconds(30)))
        #expect(deferredProbe)
    }

    @Test("An unchanged refused placement stops after three delayed retries and reopens for new geometry")
    func boundedRefusals() {
        let plan = endpoints()
        var retries = PendingMoveRetries()
        var time = ContinuousClock.now
        for delay in [30, 60, 90] {
            retries.recordFailure("source", endpoints: plan, now: time)
            let prematureAttempt = retries.shouldAttempt("source", endpoints: plan, now: time.advanced(by: .seconds(delay - 1)))
            #expect(!prematureAttempt)
            time = time.advanced(by: .seconds(delay))
            let dueAttempt = retries.shouldAttempt("source", endpoints: plan, now: time)
            #expect(dueAttempt)
        }
        let exhausted = retries.recordFailure("source", endpoints: plan, now: time)
        #expect(exhausted)
        time = time.advanced(by: .seconds(3600))
        let exhaustedProbe = retries.needsCachePass(windowIDs: [10, 20], now: time)
        #expect(exhaustedProbe)
        let redundantProbe = retries.needsCachePass(windowIDs: [10, 20], now: time.advanced(by: .seconds(299)))
        #expect(!redundantProbe)
        let exhaustedAttempt = retries.shouldAttempt("source", endpoints: plan, now: time)
        #expect(!exhaustedAttempt)
        let changedAttempt = retries.shouldAttempt("source", endpoints: endpoints(x: 300, reachable: true), now: time)
        #expect(changedAttempt)
    }

    @Test("Small bar shifts preserve cooldown while a new display or substantial reachable-anchor reflow reopens it")
    func geometryChanges() {
        let initial = endpoints(x: 300, reachable: true)
        #expect(initial.matches(endpoints(x: 333, reachable: true)))
        #expect(!initial.matches(endpoints(x: 450, reachable: true)))
        #expect(!initial.matches(endpoints(x: 300, displayID: 2, reachable: true)))
        #expect(endpoints().matches(endpoints(x: -1967)))
        #expect(!endpoints().matches(endpoints(x: -1000)))
    }

    @Test("A new anchor or cleared registration discards old cooldown and automatic wake")
    func renewedRegistration() {
        let plan = endpoints()
        var retries = PendingMoveRetries()
        let time = ContinuousClock.now
        retries.recordFailure("source", endpoints: plan, now: time)
        let replacementReady = retries.shouldAttempt("source", endpoints: endpoints(anchorID: 21), now: time)
        #expect(replacementReady)
        retries.recordFailure("source", endpoints: plan, now: time)
        retries.forget("source")
        let cancelledProbe = retries.needsCachePass(windowIDs: [10, 20], now: time.advanced(by: .seconds(600)))
        #expect(!cancelledProbe)
        let newRegistrationReady = retries.shouldAttempt("source", endpoints: plan, now: time)
        #expect(newRegistrationReady)
    }
}

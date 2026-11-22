//
//  ApplicationTerminationTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import Testing
@testable import Thaw

@Suite("Application termination")
@MainActor
struct ApplicationTerminationTests {
    @Test("The request schedules termination instead of terminating inline")
    func requestSchedulesTheTermination() {
        var scheduledActions: [() -> Void] = []
        var terminateCalls = 0

        ApplicationTermination.request(
            schedule: { action in scheduledActions.append(action) },
            terminate: { terminateCalls += 1 }
        )

        // Nothing terminates synchronously: applicationShouldTerminate gets
        // to finish its asynchronous cleanup first.
        #expect(terminateCalls == 0)
        #expect(scheduledActions.count == 1)

        // Once the run loop unwinds, the scheduled action terminates.
        scheduledActions.forEach { $0() }
        #expect(terminateCalls == 1)
    }

    @Test("Each request schedules its own termination")
    func everyRequestSchedules() {
        var scheduledActions: [() -> Void] = []
        var terminateCalls = 0

        ApplicationTermination.request(
            schedule: { action in scheduledActions.append(action) },
            terminate: { terminateCalls += 1 }
        )
        ApplicationTermination.request(
            schedule: { action in scheduledActions.append(action) },
            terminate: { terminateCalls += 1 }
        )

        #expect(scheduledActions.count == 2)
        #expect(terminateCalls == 0)

        scheduledActions.forEach { $0() }
        #expect(terminateCalls == 2)
    }

    @Test("Repeated quit requests share one cleanup and one reply")
    func repeatedQuitDuringCleanup() async {
        let preparation = ApplicationTermination.Preparation()
        var restores = 0
        var replies = [Bool]()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let restore: @MainActor () async -> Void = { restores += 1 }
            let reply: @MainActor (Bool) -> Void = { timedOut in
                replies.append(timedOut)
                if replies.count == 1 {
                    finished.resume()
                }
            }
            let first = preparation.begin(restore: restore, reply: reply)
            let second = preparation.begin(restore: restore, reply: reply)
            #expect(first == .terminateLater)
            #expect(second == .terminateLater)
        }
        #expect(restores == 1)
        #expect(replies == [false])
        let final = preparation.begin(restore: { restores += 1 }, reply: { replies.append($0) })
        #expect(final == .terminateNow)
    }

    @Test("The watchdog replies inside the AppKit termination modal run loop")
    func timeoutInModalMode() {
        let preparation = ApplicationTermination.Preparation()
        var replies = [Bool]()
        let result = preparation.begin(
            timeout: 0.03,
            restore: { try? await Task.sleep(for: .seconds(60)) },
            reply: { replies.append($0) }
        )
        #expect(result == .terminateLater)
        let limit = Date(timeIntervalSinceNow: 0.5)
        while replies.isEmpty, Date() < limit {
            RunLoop.main.run(mode: .modalPanel, before: limit)
        }
        #expect(replies == [true])
        let final = preparation.begin(restore: {}, reply: { replies.append($0) })
        #expect(final == .terminateNow)
        #expect(replies.count == 1)
    }
}

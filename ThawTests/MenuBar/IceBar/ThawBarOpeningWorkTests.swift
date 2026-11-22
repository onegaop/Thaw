//
//  ThawBarOpeningWorkTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Testing
@testable import Thaw

@MainActor
@Suite("Thaw Bar opening work")
struct ThawBarOpeningWorkTests {
    @Test("The first icon pass finishes while the forced native return is still waiting")
    func slowReturn() async throws {
        var events = [String]()
        let (release, signal) = AsyncStream<Void>.makeStream()
        await ThawBarOpeningWork.run(
            needsLayoutSettle: false,
            isCurrent: { true },
            rehide: {
                // Bound the test if a regression starts awaiting this before the first capture.
                let timeout = Task {
                    try? await Task.sleep(for: .seconds(1))
                    signal.finish()
                }
                for await _ in release { break }
                timeout.cancel()
                events.append("returned")
                return true
            },
            settle: { Issue.record("Stable openings should not wait for display reflow") },
            refreshLayout: { events.append("layout") },
            capture: { events.append("capture"); return true },
            finishOpening: {
                events.append("ready")
                signal.yield(())
            }
        )
        let first = try #require(events.firstIndex(of: "ready"))
        let returned = try #require(events.firstIndex(of: "returned"))
        #expect(first < returned)
        #expect(events.last == "capture")
    }

    @Test("A switch waits for settled geometry before querying the new layout")
    func switching() async {
        var events = [String]()
        var hasTargetLayout = false
        await ThawBarOpeningWork.run(
            needsLayoutSettle: true,
            isCurrent: { true },
            rehide: { false },
            settle: { events.append("settle") },
            refreshLayout: { events.append("layout"); hasTargetLayout = true },
            capture: {
                events.append(hasTargetLayout ? "new display" : "stale layout skipped")
                return hasTargetLayout
            },
            finishOpening: { events.append("ready") }
        )
        #expect(events == ["stale layout skipped", "settle", "layout", "new display", "ready"])
    }

    @Test("A closed or replaced panel cannot publish after a delayed layout refresh")
    func staleOpening() async {
        var current = true
        var captures = 0
        await ThawBarOpeningWork.run(
            needsLayoutSettle: true,
            isCurrent: { current },
            rehide: { false },
            settle: { current = false },
            refreshLayout: { Issue.record("Read layout after closing") },
            capture: { captures += 1; return false },
            finishOpening: { Issue.record("Released a replaced presentation") }
        )
        #expect(captures == 1)
    }
}

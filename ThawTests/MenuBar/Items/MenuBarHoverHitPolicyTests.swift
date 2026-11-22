//
//  MenuBarHoverHitPolicyTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import Testing
@testable import Thaw

@Suite("Empty-space menu bar hover")
struct MenuBarHoverHitPolicyTests {
    private typealias Policy = MenuBarHoverHitPolicy
    private let physicalStrip = CGRect(x: 400, y: -900, width: 1600, height: 30)
    private let status = CGRect(x: 1860, y: -900, width: 34, height: 30)

    @Test("External status and actual empty gap use the physical CoreGraphics strip")
    func externalStatusAndGap() {
        let mainScreenStatus = CGRect(x: 1860, y: 0, width: 34, height: 30)
        #expect(Policy.statusRegion(
            at: CGPoint(x: 1877, y: -883), in: physicalStrip, windowBounds: [mainScreenStatus, status], maxItemWidth: 500
        ).region == .occupied)
        #expect(Policy.statusRegion(
            at: CGPoint(x: 1832, y: -883), in: physicalStrip, windowBounds: [mainScreenStatus, status], maxItemWidth: 500
        ).region == .empty)
    }

    @Test("Wrong-screen, parked and wide divider windows alone do not prove empty")
    func knownEvidenceIsNeeded() {
        let unrelated = [
            CGRect(x: 1860, y: 0, width: 34, height: 30),
            CGRect(x: -4200, y: -900, width: 24, height: 30),
            CGRect(x: -3100, y: -900, width: 5016, height: 30),
        ]
        let target = CGPoint(x: 1720, y: -885)
        #expect(Policy.statusRegion(at: target, in: physicalStrip, windowBounds: unrelated, maxItemWidth: 500).region == .unknown)
        #expect(Policy.statusRegion(at: target, in: physicalStrip, windowBounds: [], maxItemWidth: 500).region == .unknown)
        #expect(Policy.statusRegion(at: CGPoint(x: 1720, y: 15), in: physicalStrip, windowBounds: [status], maxItemWidth: 500).region == .unknown)
    }

    @Test("Approximate app menu rectangle moves to the selected display's own row")
    func verticalScreenApplicationMenuFallback() {
        let main = CGRect(x: 0, y: 0, width: 2752, height: 1152)
        let other = CGRect(x: 400, y: -900, width: 1600, height: 900)
        let menu = CGRect(x: 20, y: 1, width: 275, height: 29)
        let fallback = NSScreen.rebaseApplicationMenuFrame(menu, from: main, to: other)
        #expect(fallback == CGRect(x: 400, y: -899, width: 275, height: 29))
        #expect(Policy.appMenuRegion(
            at: CGPoint(x: 410, y: -887), in: physicalStrip, accessibilityHit: nil, fallbackFrame: menu, notchMinX: nil
        ) == .unknown)
        #expect(Policy.appMenuRegion(
            at: CGPoint(x: 410, y: -887), in: physicalStrip, accessibilityHit: nil, fallbackFrame: fallback, notchMinX: nil
        ) == .occupied)
        #expect(Policy.appMenuRegion(
            at: CGPoint(x: 700, y: -887), in: physicalStrip, accessibilityHit: nil, fallbackFrame: fallback, notchMinX: nil
        ) == .empty)
    }

    @Test("An AX element must describe the same point; absent or misplaced geometry is not a negative hit")
    func exactAxHitEvidence() {
        let point = CGPoint(x: 1869, y: -885)
        #expect(Policy.concretePointHit(frame: status, at: point, in: physicalStrip) == .occupied)
        #expect(Policy.concretePointHit(frame: status.offsetBy(dx: 0, dy: 900), at: point, in: physicalStrip) == .unknown)
        #expect(Policy.concretePointHit(frame: nil, at: point, in: physicalStrip) == .unknown)
    }

    @Test("Unknown app or status evidence and any discovered occupant veto a hover")
    func evidenceMustAgree() {
        for point: Policy.PointHit in [.gapWithoutElement, .neutral] {
            #expect(Policy.Evidence(status: .empty, appMenu: .empty, point: point).isEmpty)
        }
        #expect(!Policy.Evidence(status: .empty, appMenu: .unknown, point: .neutral).isEmpty)
        #expect(!Policy.Evidence(status: .unknown, appMenu: .empty, point: .neutral).isEmpty)
        #expect(!Policy.Evidence(status: .occupied, appMenu: .empty, point: .neutral).isEmpty)
        #expect(!Policy.Evidence(status: .empty, appMenu: .occupied, point: .neutral).isEmpty)
        #expect(!Policy.Evidence(status: .empty, appMenu: .empty, point: .occupied).isEmpty)
        #expect(!Policy.Evidence(status: .empty, appMenu: .empty, point: .unknown).isEmpty)
    }

    @Test("A missing point query only allows the central gap bounded by both actual native and app AX readings")
    func noPointQueryOutsideBoundedGap() {
        let center = CGPoint(x: 950, y: -885)
        #expect(Policy.missingPointHit(at: center, in: physicalStrip, actualAppMenuTrailingEdge: 670, nativeStatusLeadingEdge: 1850) == .gapWithoutElement)
        #expect(Policy.missingPointHit(at: center, in: physicalStrip, actualAppMenuTrailingEdge: nil, nativeStatusLeadingEdge: 1850) == .unknown)
        #expect(Policy.missingPointHit(at: center, in: physicalStrip, actualAppMenuTrailingEdge: 670, nativeStatusLeadingEdge: nil) == .unknown)
        #expect(Policy.missingPointHit(at: CGPoint(x: 1900, y: -885), in: physicalStrip, actualAppMenuTrailingEdge: 670, nativeStatusLeadingEdge: 1850) == .unknown)
        #expect(Policy.missingPointHit(at: CGPoint(x: 500, y: -885), in: physicalStrip, actualAppMenuTrailingEdge: 670, nativeStatusLeadingEdge: 1850) == .unknown)
    }

    @Test("A delayed hover cannot commit after switching screens, turning it off, or supersession")
    func delayedShowMustStillBeCurrent() {
        #expect(Policy.mayCommit(scheduledDisplay: 3, currentDisplay: 3, isCurrentTask: true, stillEnabled: true))
        #expect(!Policy.mayCommit(scheduledDisplay: 3, currentDisplay: 1, isCurrentTask: true, stillEnabled: true))
        #expect(!Policy.mayCommit(scheduledDisplay: 3, currentDisplay: nil, isCurrentTask: true, stillEnabled: true))
        #expect(!Policy.mayCommit(scheduledDisplay: 3, currentDisplay: 3, isCurrentTask: false, stillEnabled: true))
        #expect(!Policy.mayCommit(scheduledDisplay: 3, currentDisplay: 3, isCurrentTask: true, stillEnabled: false))
    }
}

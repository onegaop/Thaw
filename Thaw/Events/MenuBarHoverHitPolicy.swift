//
//  MenuBarHoverHitPolicy.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics

/// Keeps a real gap separate from missing or wrong-display coverage.
nonisolated enum MenuBarHoverHitPolicy {
    enum Region: String { case occupied, empty, unknown }
    enum PointHit: String { case occupied, neutral, gapWithoutElement, unknown }

    struct StatusReading {
        let region: Region
        let leadingEdge: CGFloat?
    }

    struct Evidence {
        let status: Region
        let appMenu: Region
        let point: PointHit

        var isEmpty: Bool {
            status == .empty && appMenu == .empty && (point == .neutral || point == .gapWithoutElement)
        }
    }

    static func statusRegion(
        at point: CGPoint,
        in strip: CGRect,
        windowBounds: some Sequence<CGRect>,
        maxItemWidth: CGFloat
    ) -> StatusReading {
        guard strip.contains(point) else { return .init(region: .unknown, leadingEdge: nil) }
        var leadingEdge: CGFloat?
        for bounds in windowBounds {
            // The private on-screen list can include parked windows, nearby
            // displays and our own wide inert dividers.
            guard !bounds.isEmpty, bounds.width <= maxItemWidth, bounds.height <= strip.height + 2, abs(bounds.minY - strip.minY) <= 2, strip.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            else { continue }
            if bounds.contains(point) {
                return .init(region: .occupied, leadingEdge: nil)
            }
            leadingEdge = min(leadingEdge ?? bounds.minX, bounds.minX)
        }
        return .init(region: leadingEdge == nil ? .unknown : .empty, leadingEdge: leadingEdge)
    }

    static func appMenuRegion(
        at point: CGPoint,
        in strip: CGRect,
        accessibilityHit: Bool?,
        fallbackFrame: CGRect?,
        notchMinX: CGFloat?
    ) -> Region {
        guard strip.contains(point) else { return .unknown }
        if let accessibilityHit {
            return accessibilityHit ? .occupied : .empty
        }
        guard let fallbackFrame, !fallbackFrame.isEmpty, abs(fallbackFrame.minY - strip.minY) <= 2, fallbackFrame.intersects(strip)
        else { return .unknown }
        let menuMaxX = min(fallbackFrame.maxX, notchMinX ?? strip.maxX)
        guard menuMaxX > strip.minX else { return .unknown }
        return point.x < menuMaxX ? .occupied : .empty
    }

    static func concretePointHit(frame: CGRect?, at point: CGPoint, in strip: CGRect) -> PointHit {
        guard let frame, !frame.isEmpty, frame.intersects(strip), frame.contains(point) else { return .unknown }
        return .occupied
    }

    /// Prefer a live AX hit. If the point lookup returned nothing, require a
    /// bounded central gap supported by both independent row readings.
    static func missingPointHit(
        at point: CGPoint,
        in strip: CGRect,
        actualAppMenuTrailingEdge: CGFloat?,
        nativeStatusLeadingEdge: CGFloat?
    ) -> PointHit {
        guard strip.contains(point), let actualAppMenuTrailingEdge, let nativeStatusLeadingEdge, point.x > actualAppMenuTrailingEdge, point.x < nativeStatusLeadingEdge
        else { return .unknown }
        return .gapWithoutElement
    }

    static func mayCommit(
        scheduledDisplay: CGDirectDisplayID,
        currentDisplay: CGDirectDisplayID?,
        isCurrentTask: Bool,
        stillEnabled: Bool
    ) -> Bool {
        isCurrentTask && stillEnabled && currentDisplay == scheduledDisplay
    }
}

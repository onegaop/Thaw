//
//  ThawBarOpeningWork.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Runs the opening capture independently of native item moves. Layout enumeration still waits for a changing bar.
@MainActor
enum ThawBarOpeningWork {
    static func run(
        needsLayoutSettle: Bool,
        isCurrent: @MainActor () -> Bool,
        rehide: @MainActor () async -> Bool,
        settle: @MainActor () async -> Void,
        refreshLayout: @MainActor () async -> Void,
        capture: @MainActor () async -> Bool,
        finishOpening: @MainActor () -> Void
    ) async {
        guard !Task.isCancelled, isCurrent() else { return }
        async let didRehide = rehide()

        // Reads an existing layout. The capture itself rejects another display's windows.
        let captured = await capture()
        guard !Task.isCancelled, isCurrent() else { return }
        if captured {
            finishOpening()
        }
        if needsLayoutSettle || !captured {
            await settle()
        }
        guard !Task.isCancelled, isCurrent() else { return }
        await refreshLayout()
        guard !Task.isCancelled, isCurrent() else { return }
        _ = await capture()
        guard !Task.isCancelled, isCurrent() else { return }
        finishOpening()

        // A returned icon can join the section after its other icons are already visible.
        if await didRehide, !Task.isCancelled, isCurrent() {
            await refreshLayout()
            guard !Task.isCancelled, isCurrent() else { return }
            _ = await capture()
        }
    }
}

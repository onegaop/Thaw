//
//  MenuBarItemImageCache+DisplaySnapshots.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

extension MenuBarItemImageCache {
    nonisolated struct CaptureAppearance: Equatable {
        let name: String
        let brightMenuBar: Bool?
        let scale: CGFloat
    }

    nonisolated struct CaptureContext: Equatable {
        let generation: UUID
        let displayID: CGDirectDisplayID
        let appearance: CaptureAppearance
    }

    nonisolated struct ThawBarCaptureSession: Equatable {
        let id = UUID()
        let started = ContinuousClock.now
        let displayID: CGDirectDisplayID
        let section: MenuBarSection.Name

        func logCaptureRequest(count: Int) {
            let elapsed = Int(started.duration(to: .now).milliseconds)
            MenuBarItemImageCache.diagLog.notice("Thaw Bar missing capture request: session=\(id) display=\(displayID) count=\(count) elapsedMs=\(elapsed)")
        }
    }

    private func appearance(on screen: NSScreen) -> CaptureAppearance {
        CaptureAppearance(
            name: NSApp.effectiveAppearance.name.rawValue,
            brightMenuBar: appState?.menuBarManager.averageColors[screen.displayID]?.isBright(for: screen),
            scale: screen.backingScaleFactor
        )
    }

    /// Window IDs belong to the layout's display. A fallback NSScreen cannot identify their pixels.
    func captureContext(for screen: NSScreen) -> CaptureContext? {
        let observed = appearance(on: screen)
        if thawBarSession?.displayID == screen.displayID, snapshotAppearances[screen.displayID] != observed {
            refreshOpeningAppearanceIfNeeded()
        }
        return captureContext(
            displayID: screen.displayID,
            nativeDisplayID: Bridging.getActiveMenuBarDisplayID(),
            layoutDisplayID: appState?.itemManager.itemCache.displayID,
            appearance: observed
        )
    }

    func captureContext(
        displayID: CGDirectDisplayID,
        nativeDisplayID: CGDirectDisplayID?,
        layoutDisplayID: CGDirectDisplayID?,
        appearance: CaptureAppearance
    ) -> CaptureContext? {
        guard nativeDisplayID == displayID, layoutDisplayID == displayID else { return nil }
        if let thawBarSession, thawBarSession.displayID != displayID { return nil }
        return CaptureContext(generation: captureGeneration, displayID: displayID, appearance: appearance)
    }

    func acceptsCapture(_ context: CaptureContext) -> Bool {
        guard !Task.isCancelled, appState?.hasPermission(.screenRecording) == true,
              let screen = NSScreen.screens.first(where: { $0.displayID == context.displayID })
        else { return false }
        return captureContext(for: screen) == context
    }

    func beginThawBarCapture(displayID: CGDirectDisplayID, section: MenuBarSection.Name) -> ThawBarCaptureSession {
        let session = ThawBarCaptureSession(displayID: displayID, section: section)
        endThawBarCapture()
        thawBarSession = session
        if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            invalidateSnapshotIfNeeded(on: displayID, appearance: appearance(on: screen))
        }
        isThawBarCapturePending = true
        return session
    }

    func endThawBarCapture() {
        warmRefreshTask?.cancel()
        warmRefreshTask = nil
        appearanceCaptureTask?.cancel()
        appearanceCaptureTask = nil
        thawBarSession = nil
        captureGeneration = UUID()
        openingAttempts.removeAll()
        isThawBarCapturePending = false
    }

    func finishThawBarCapture(for session: ThawBarCaptureSession) {
        guard thawBarSession == session, appearanceCaptureTask == nil else { return }
        isThawBarCapturePending = false
    }

    func imageForThawBar(for tag: MenuBarItemTag, on displayID: CGDirectDisplayID) -> CapturedImage? {
        guard thawBarSession?.displayID == displayID else { return nil }
        return imagesByDisplay[displayID]?[tag]
    }

    func refreshOpeningAppearanceIfNeeded() {
        guard let session = thawBarSession,
              let screen = NSScreen.screens.first(where: { $0.displayID == session.displayID })
        else { return }
        guard invalidateSnapshotIfNeeded(on: session.displayID, appearance: appearance(on: screen)) else { return }
        captureGeneration = UUID()
        openingAttempts.removeAll()
        isThawBarCapturePending = true
        appearanceCaptureTask?.cancel()
        let generation = captureGeneration
        appearanceCaptureTask = Task { [weak self] in
            guard let self else { return }
            _ = await captureMissingImages(for: session)
            guard generation == captureGeneration else { return }
            appearanceCaptureTask = nil
            isThawBarCapturePending = false
        }
    }

    @discardableResult
    func invalidateSnapshotIfNeeded(on displayID: CGDirectDisplayID, appearance: CaptureAppearance) -> Bool {
        guard snapshotAppearances[displayID] != appearance else { return false }
        imagesByDisplay.removeValue(forKey: displayID)
        capturedAtByDisplay.removeValue(forKey: displayID)
        snapshotAppearances[displayID] = appearance
        return true
    }

    /// Capture missing windows once per opening/appearance, sharing the live capture permit.
    /// A false result leaves the layout-stabilization caller responsible for retrying.
    @discardableResult
    func captureMissingImages(for session: ThawBarCaptureSession) async -> Bool {
        guard thawBarSession == session, !Task.isCancelled, let appState else { return false }
        guard appState.hasPermission(.screenRecording), !appState.settings.advanced.alwaysUseAppIconForMenuBarItems else {
            isThawBarCapturePending = false
            return true
        }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == session.displayID }), let context = captureContext(for: screen)
        else { return false }
        guard acceptsCapture(context) else { return false }
        if SpaceInfo.isFullscreen(Bridging.getCurrentSpaceID(for: session.displayID)) {
            isThawBarCapturePending = false
            return true
        }
        if !openingCaptureInFlight, openingBatch(for: session, appState: appState).isEmpty {
            isThawBarCapturePending = false
            scheduleWarmRefresh(for: session, context: context, appState: appState)
            return true
        }
        isThawBarCapturePending = true
        var finished = false
        await withCapturePermit {
            guard acceptsCapture(context) else { return }
            openingCaptureInFlight = true
            defer { openingCaptureInFlight = false }
            while acceptsCapture(context) {
                guard appState.hasPermission(.screenRecording), !appState.settings.advanced.alwaysUseAppIconForMenuBarItems, !openingBatch(for: session, appState: appState).isEmpty else {
                    finished = true
                    break
                }
                await awaitRefreshSlot(for: session.section)
                guard acceptsCapture(context) else { break }
                guard appState.hasPermission(.screenRecording), !appState.settings.advanced.alwaysUseAppIconForMenuBarItems, !SpaceInfo.isFullscreen(Bridging.getCurrentSpaceID(for: session.displayID))
                else {
                    finished = true
                    break
                }
                let items = openingBatch(for: session, appState: appState)
                guard !items.isEmpty else { continue }
                openingAttempts.formUnion(items.map(\.windowID))
                await refreshImages(
                    of: items,
                    scale: screen.backingScaleFactor,
                    context: context,
                    opening: session,
                    viaSCK: session.section == .visible
                )
            }
        }
        guard finished, acceptsCapture(context) else { return false }
        isThawBarCapturePending = false
        scheduleWarmRefresh(for: session, context: context, appState: appState)
        return true
    }

    /// With live refresh disabled, refresh aging real icons once after the row is ready.
    private func scheduleWarmRefresh(for session: ThawBarCaptureSession, context: CaptureContext, appState: AppState) {
        guard warmRefreshTask == nil, appState.settings.advanced.iconRefreshInterval <= 0,
              appState.hasPermission(.screenRecording), !appState.settings.advanced.alwaysUseAppIconForMenuBarItems
        else { return }
        let times = capturedAtByDisplay[session.displayID] ?? [:]
        let staleBefore = ContinuousClock.now - .seconds(1)
        let items = appState.itemManager.itemCache[session.section].filter { item in
            !openingAttempts.contains(item.windowID) && times[item.tag].map { $0 <= staleBefore } == true
        }
        guard !items.isEmpty else { return }
        warmRefreshTask = Task { [weak self] in
            guard let self else { return }
            await withCapturePermit {
                guard acceptsCapture(context) else { return }
                await awaitRefreshSlot(for: session.section)
                guard acceptsCapture(context), appState.hasPermission(.screenRecording), !appState.settings.advanced.alwaysUseAppIconForMenuBarItems, !SpaceInfo.isFullscreen(Bridging.getCurrentSpaceID(for: session.displayID))
                else { return }
                let live = Set(appState.itemManager.itemCache[session.section].map(\.windowID))
                let batch = items.filter { live.contains($0.windowID) }.prefix(MenuBarCaptureService.maxWindowCount)
                guard !batch.isEmpty else { return }
                await refreshImages(
                    of: Array(batch),
                    scale: context.appearance.scale,
                    context: context,
                    viaSCK: session.section == .visible
                )
            }
        }
    }

    private func openingBatch(for session: ThawBarCaptureSession, appState: AppState) -> [MenuBarItem] {
        Self.missingBatch(
            in: appState.itemManager.itemCache[session.section],
            stored: imagesByDisplay[session.displayID] ?? [:],
            attempted: openingAttempts
        )
    }

    static func missingBatch(
        in items: [MenuBarItem],
        stored: [MenuBarItemTag: CapturedImage],
        attempted: Set<CGWindowID>
    ) -> [MenuBarItem] {
        // Publish a small first batch promptly. Cap the entire opening too, including failures.
        let limit = attempted.isEmpty ? 8 : MenuBarCaptureService.maxWindowCount - attempted.count
        guard limit > 0 else { return [] }
        var seen = attempted
        var batch = [MenuBarItem]()
        for item in items where !item.isControlItem && item.windowID != 0 && stored[item.tag] == nil {
            guard seen.insert(item.windowID).inserted else { continue }
            batch.append(item)
            if batch.count == limit {
                break
            }
        }
        return batch
    }

    private func awaitRefreshSlot(for section: MenuBarSection.Name) async {
        let interval = Duration.seconds(
            MenuBarLiveRefreshPolicy.refreshInterval(for: section, target: Self.minIconRefreshInterval)
                ?? MenuBarCaptureService.minAlwaysHiddenInterval
        )
        let last: ContinuousClock.Instant? = switch section {
        case .hidden: lastHiddenRefreshAt
        case .alwaysHidden: lastAlwaysHiddenRefreshAt
        case .visible: lastSCKRefreshAt
        }
        if let last {
            try? await Task.sleep(until: last + interval, clock: .continuous)
        }
        guard !Task.isCancelled else { return }
        switch section {
        case .hidden: lastHiddenRefreshAt = .now
        case .alwaysHidden: lastAlwaysHiddenRefreshAt = .now
        case .visible: lastSCKRefreshAt = .now
        }
    }

    /// Only successful response frames enter the snapshot. A failed capture cannot certify an old global bitmap.
    func storeImages(_ captured: [MenuBarItemTag: CapturedImage], context: CaptureContext) {
        guard context.generation == captureGeneration, !captured.isEmpty else { return }
        let id = context.displayID
        invalidateSnapshotIfNeeded(on: id, appearance: context.appearance)
        var snapshot = imagesByDisplay[id] ?? [:]
        var changed = false
        for (tag, image) in captured where !CapturedImage.isVisuallyEqual(snapshot[tag], image) {
            snapshot[tag] = image
            changed = true
        }
        if changed {
            let excess = max(0, snapshot.count - Self.maxCacheSize)
            for tag in snapshot.keys.filter({ captured[$0] == nil }).prefix(excess) {
                snapshot.removeValue(forKey: tag)
            }
            if snapshot.count > Self.maxCacheSize {
                for tag in Array(snapshot.keys.prefix(snapshot.count - Self.maxCacheSize)) {
                    snapshot.removeValue(forKey: tag)
                }
            }
            imagesByDisplay[id] = snapshot
        }
        let now = ContinuousClock.now
        for tag in captured.keys where snapshot[tag] != nil {
            capturedAtByDisplay[id, default: [:]][tag] = now
        }
        if capturedAtByDisplay[id, default: [:]].count > snapshot.count {
            capturedAtByDisplay[id] = capturedAtByDisplay[id]?.filter { snapshot[$0.key] != nil }
        }
        if lastCaptureDisplayID != id {
            lastCaptureDisplayID = id
        }
    }

    func pruneDisconnectedSnapshots(connected: Set<CGDirectDisplayID>) {
        for disconnected in snapshotAppearances.keys where !connected.contains(disconnected) {
            snapshotAppearances.removeValue(forKey: disconnected)
            imagesByDisplay.removeValue(forKey: disconnected)
            capturedAtByDisplay.removeValue(forKey: disconnected)
        }
    }
}

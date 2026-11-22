//
//  MenuBarItemImageCacheSnapshotTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Testing
@testable import Thaw

@MainActor
@Suite("Thaw Bar capture provenance and missing-window batches")
struct MenuBarItemImageCacheSnapshotTests {
    typealias Cache = MenuBarItemImageCache

    private let light = Cache.CaptureAppearance(name: "light", brightMenuBar: true, scale: 2)
    private let dark = Cache.CaptureAppearance(name: "dark", brightMenuBar: false, scale: 2)

    private func item(_ id: CGWindowID) -> MenuBarItem {
        MenuBarItem(
            tag: MenuBarItemTag(namespace: .string("test.app"), title: "item", windowID: id),
            windowID: id, ownerPID: 1, sourcePID: nil, bounds: .zero, title: "item", isOnScreen: false
        )
    }

    private func glyph(_ gray: CGFloat) throws -> Cache.CapturedImage {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try .init(cgImage: #require(context.makeImage()), scale: 2)
    }

    @Test("Two screen snapshots keep their own pixels, including after a partial capture failure")
    func separateSnapshots() throws {
        let cache = Cache()
        let tag = item(1).tag
        let second = item(2).tag
        let white = try glyph(1), black = try glyph(0)
        func open(_ display: CGDirectDisplayID) -> Cache.CaptureContext {
            cache.thawBarSession = .init(displayID: display, section: .hidden)
            return .init(generation: cache.captureGeneration, displayID: display, appearance: light)
        }
        var context = open(100)
        cache.storeImages([tag: white, second: white], context: context)
        context = open(200)
        cache.images[second] = white // A previous display's global pixel cannot certify a failed response.
        cache.storeImages([tag: black], context: context)
        #expect(cache.imageForThawBar(for: tag, on: 200)?.cgImage === black.cgImage)
        #expect(cache.imageForThawBar(for: tag, on: 100) == nil)
        #expect(cache.imageForThawBar(for: second, on: 200) == nil)
        cache.endThawBarCapture()
        _ = open(100)
        #expect(cache.imageForThawBar(for: tag, on: 100)?.cgImage === white.cgImage)
        #expect(cache.imageForThawBar(for: second, on: 100)?.cgImage === white.cgImage)
        cache.pruneDisconnectedSnapshots(connected: [100])
        #expect(cache.imagesByDisplay[200] == nil)
    }

    @Test("Native display, layout, appearance and open generation all qualify a capture response")
    func responseProvenance() throws {
        let cache = Cache()
        cache.thawBarSession = .init(displayID: 100, section: .hidden)
        let before = try #require(cache.captureContext(displayID: 100, nativeDisplayID: 100, layoutDisplayID: 100, appearance: light))
        #expect(cache.captureContext(displayID: 100, nativeDisplayID: 200, layoutDisplayID: 100, appearance: light) == nil)
        #expect(cache.captureContext(displayID: 100, nativeDisplayID: 100, layoutDisplayID: 200, appearance: light) == nil)
        #expect(cache.captureContext(displayID: 200, nativeDisplayID: 200, layoutDisplayID: 200, appearance: light) == nil)
        #expect(cache.captureContext(displayID: 100, nativeDisplayID: 100, layoutDisplayID: 100, appearance: dark) != before)
        let tag = item(1).tag
        let image = try glyph(1)
        cache.storeImages([tag: image], context: before)
        #expect(!cache.invalidateSnapshotIfNeeded(on: 100, appearance: light))
        #expect(cache.invalidateSnapshotIfNeeded(on: 100, appearance: dark))
        #expect(cache.imageForThawBar(for: tag, on: 100) == nil)
        cache.endThawBarCapture()
        let reopened = cache.beginThawBarCapture(displayID: 100, section: .hidden)
        cache.storeImages([tag: image], context: before)
        #expect(cache.imageForThawBar(for: tag, on: 100) == nil)
        cache.finishThawBarCapture(for: reopened)
        #expect(!cache.isThawBarCapturePending)
    }

    @Test("Capture skips warm, duplicate and failed windows, and budgets new arrivals")
    func missingBatches() throws {
        let all = (1 ... 100).map { item(CGWindowID($0)) }
        let stored = [all[0].tag: try glyph(1)]
        var attempts = Set<CGWindowID>()
        let first = Cache.missingBatch(in: [all[1]] + all, stored: stored, attempted: attempts)
        #expect(first.map(\.windowID) == Array(2 ... 9))
        attempts.formUnion(first.map(\.windowID))
        // No successful response from the first batch. Its failed windows are not resubmitted.
        let next = Cache.missingBatch(in: all, stored: stored, attempted: attempts)
        #expect(next.map(\.windowID) == Array(10 ... 65))
        attempts.formUnion(next.map(\.windowID))
        #expect(attempts.count == MenuBarCaptureService.maxWindowCount)
        #expect(Cache.missingBatch(in: all, stored: stored, attempted: attempts).isEmpty)
        #expect(Cache.missingBatch(in: [all[0]], stored: stored, attempted: []).isEmpty)
        #expect(Cache.missingBatch(in: [all[0], item(101)], stored: stored, attempted: [2]).map(\.windowID) == [101])
    }
}

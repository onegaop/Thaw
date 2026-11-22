//
//  ThawBarOpeningCaptureTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI
import Testing
@testable import Thaw

@MainActor
@Suite("Thaw Bar first icon row")
struct ThawBarOpeningCaptureTests {
    typealias Source = ThawBarOpeningCapture.IconSource

    private func item(_ id: CGWindowID) -> MenuBarItem {
        let name = String(id)
        return MenuBarItem(
            tag: MenuBarItemTag(namespace: .string("test.app"), title: name, windowID: id),
            windowID: id, ownerPID: 1, sourcePID: nil,
            bounds: CGRect(x: 0, y: 0, width: id == 1 ? 16 : 32, height: 22), title: name, isOnScreen: false
        )
    }

    private func glyph(_ color: Color, bounds: CGRect) throws -> CGImage {
        try #require(ImageRenderer(content: color.frame(width: bounds.width, height: bounds.height)).cgImage)
    }

    /// Renders the production image/placeholder views. Red marks a fallback in the pixel checks.
    private func row(
        _ opening: ThawBarOpeningCapture, captures: [CGWindowID: CGImage], dark: Bool,
        prefersAppIcons: Bool = false, canCapture: Bool = true, refreshPending: Bool = false
    ) throws -> CGImage {
        let fallback = try glyph(.red, bounds: item(1).bounds)
        let view = HStack(spacing: 0) {
            ForEach([item(1), item(2)], id: \.windowID) { item in
                let capture = captures[item.windowID]
                if let source = opening.source(
                    for: item, hasCapture: capture != nil, prefersAppIcons: prefersAppIcons,
                    canCapture: canCapture, refreshPending: refreshPending
                ) {
                    let image = source == .capture ? capture : fallback
                    if let image {
                        opening.image(Image(decorative: image, scale: 1), source: source)
                            .frame(width: item.bounds.width, height: item.bounds.height)
                    }
                } else {
                    opening.placeholder(for: item.bounds, maxHeight: item.bounds.height)
                }
            }
        }
        .background(dark ? Color.black : .white)
        .environment(\.colorScheme, dark ? .dark : .light)
        return try #require(ImageRenderer(content: view).cgImage)
    }

    /// Compare actual RGBA bytes of a cell, excluding neighboring cells and scanline padding.
    private func pixels(_ image: CGImage, x: Int, width: Int) throws -> Data {
        let cropped = try #require(image.cropping(to: CGRect(x: x, y: 0, width: width, height: image.height)))
        var result = Data(count: width * image.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        }
        return result
    }

    @Test("Partial cache draws each available glyph immediately at the same position as a warm opening", arguments: [false, true])
    func partialRow(dark: Bool) throws {
        var reports = [Source]()
        let opening = ThawBarOpeningCapture { reports.append($0) }
        let first = try glyph(dark ? .white : .black, bounds: item(1).bounds)
        let second = try glyph(.gray, bounds: item(2).bounds)
        let cold = try row(opening, captures: [:], dark: dark)
        #expect(reports.isEmpty)
        let partial = try row(opening, captures: [1: first], dark: dark)
        #expect(reports == [.capture])
        let full = try row(opening, captures: [1: first, 2: second], dark: dark)
        opening.isPending = false
        let stable = try row(opening, captures: [1: first, 2: second], dark: dark)
        let reopened = try row(ThawBarOpeningCapture(), captures: [1: first, 2: second], dark: dark)
        #expect([cold, partial, full, stable, reopened].allSatisfy { $0.width == 48 && $0.height == 22 })
        #expect(try pixels(partial, x: 0, width: 16) != pixels(cold, x: 0, width: 16))
        #expect(try pixels(partial, x: 0, width: 16) == pixels(full, x: 0, width: 16))
        #expect(try pixels(partial, x: 16, width: 32) == pixels(cold, x: 16, width: 32))
        #expect(try pixels(partial, x: 16, width: 32) != pixels(full, x: 16, width: 32))
        #expect(try pixels(full, x: 0, width: 48) == pixels(stable, x: 0, width: 48))
        #expect(try pixels(full, x: 0, width: 48) == pixels(reopened, x: 0, width: 48))
        #expect(reports == [.capture])
    }

    @Test("Denied permission, preference and failed capture release fallback without masking later real icons")
    func permittedFallback() throws {
        var reports = [Source]()
        let opening = ThawBarOpeningCapture { reports.append($0) }
        let cold = try row(opening, captures: [:], dark: false)
        let denied = try row(opening, captures: [:], dark: false, canCapture: false)
        let preference = try row(opening, captures: [:], dark: false, prefersAppIcons: true)
        opening.isPending = false
        let failed = try row(opening, captures: [:], dark: false)
        #expect(try pixels(cold, x: 0, width: 48) != pixels(failed, x: 0, width: 48))
        #expect(try pixels(denied, x: 0, width: 48) == pixels(failed, x: 0, width: 48))
        #expect(try pixels(preference, x: 0, width: 48) == pixels(failed, x: 0, width: 48))
        #expect(reports == [.fallback])
        let capture = try glyph(.gray, bounds: item(1).bounds)
        // A quit app has no application icon. Its available capture still wins under the preference.
        _ = try row(opening, captures: [1: capture], dark: false, prefersAppIcons: true)
        #expect(reports == [.fallback, .capture])
    }

    @Test("Appearance refresh suppresses transient fallback and closing drops late appearances")
    func appearanceRefreshAndReopen() throws {
        var oldReports = [Source]()
        let old = ThawBarOpeningCapture { oldReports.append($0) }
        old.isPending = false
        let refreshed = try row(old, captures: [:], dark: true, refreshPending: true)
        #expect(oldReports.isEmpty)
        old.cancel()
        _ = try row(old, captures: [:], dark: true)
        #expect(oldReports.isEmpty)
        var newReports = [Source]()
        let new = ThawBarOpeningCapture { newReports.append($0) }
        let cold = try row(new, captures: [:], dark: true)
        #expect(try pixels(refreshed, x: 0, width: 48) == pixels(cold, x: 0, width: 48))
        #expect(newReports.isEmpty)
        _ = try row(new, captures: [1: glyph(.white, bounds: item(1).bounds)], dark: true)
        #expect(newReports == [.capture])
    }

    @Test("A mounted image changing from fallback to capture reports the first captured view once")
    func firstCaptureInSameHost() throws {
        var reports = [Source]()
        let opening = ThawBarOpeningCapture { reports.append($0) }
        let bitmap = try glyph(.gray, bounds: item(1).bounds)
        @ViewBuilder func cell(_ source: Source?) -> some View {
            if let source {
                opening.image(Image(decorative: bitmap, scale: 1), source: source)
                    .frame(width: 16, height: 22)
            } else {
                opening.placeholder(for: item(1).bounds, maxHeight: 22)
            }
        }
        let host = NSHostingView(rootView: cell(nil))
        host.frame = CGRect(x: 0, y: 0, width: 16, height: 22)
        host.layoutSubtreeIfNeeded()
        #expect(reports.isEmpty)
        for source: Source in [.fallback, .capture, .capture, .fallback] {
            host.rootView = cell(source)
            host.layoutSubtreeIfNeeded()
        }
        #expect(reports == [.fallback, .capture])
        #expect(host.window == nil)
    }

    @Test("Placeholder width follows native status item geometry across bar heights")
    func placeholderWidth() {
        #expect(ThawBarOpeningCapture.placeholderSize(for: item(2).bounds, maxHeight: 33) == CGSize(width: 48, height: 33))
        #expect(ThawBarOpeningCapture.placeholderSize(for: .zero, maxHeight: 24) == CGSize(width: 24, height: 24))
    }
}

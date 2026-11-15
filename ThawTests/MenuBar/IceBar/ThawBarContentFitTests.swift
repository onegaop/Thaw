//
//  ThawBarContentFitTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Testing
@testable import Thaw

/// A window keeps whole points, so a half-point content size never matched the panel's frame and
/// every layout pass resized and repositioned the Thaw Bar, logging the clamp each time.
@Suite("Thaw Bar content fitting")
struct ThawBarContentFitTests {
    private let halfPointIdeal = CGSize(width: 576.5, height: 47)
    private let roundedFrame = CGSize(width: 577, height: 47)

    @Test("Content that matches the frame needs no resize, and new content does")
    func matchingContentIsLeftAlone() {
        let fit = ThawBarContentFit()
        #expect(!fit.needsResize(ideal: roundedFrame, frameSize: roundedFrame))
        #expect(fit.needsResize(ideal: halfPointIdeal, frameSize: .zero))
    }

    @Test("A half-point size the window rounded is fitted once, not on every layout pass")
    func roundedSizeIsFittedOnce() {
        var fit = ThawBarContentFit()
        #expect(fit.needsResize(ideal: halfPointIdeal, frameSize: CGSize(width: 531, height: 47)))
        fit.noteResize(ideal: halfPointIdeal, frameSize: roundedFrame)
        #expect(!fit.needsResize(ideal: halfPointIdeal, frameSize: roundedFrame))
    }

    @Test("Changed content, or a frame changed from elsewhere, is fitted again")
    func changesAreFittedAgain() {
        var fit = ThawBarContentFit()
        fit.noteResize(ideal: halfPointIdeal, frameSize: roundedFrame)
        #expect(fit.needsResize(ideal: CGSize(width: 530.5, height: 47), frameSize: roundedFrame))
        #expect(fit.needsResize(ideal: halfPointIdeal, frameSize: CGSize(width: 600, height: 47)))
    }

    @Test("A hundred unchanged hover layouts fit a rounded size only once")
    func repeatedLayoutsRemainStable() {
        var fit = ThawBarContentFit()
        var frame = CGSize(width: 531, height: 47)
        var resizes = 0
        for _ in 0 ..< 100 {
            if fit.needsResize(ideal: halfPointIdeal, frameSize: frame) {
                resizes += 1
                frame = roundedFrame
                fit.noteResize(ideal: halfPointIdeal, frameSize: frame)
            }
        }
        #expect(resizes == 1)
    }

    @Test("Invalid or empty content cannot resize a window")
    func invalidContentIsIgnored() {
        let fit = ThawBarContentFit()
        for size in [CGSize.zero, CGSize(width: -1, height: 47), CGSize(width: CGFloat.infinity, height: 47), CGSize(width: CGFloat.nan, height: 47)] {
            #expect(!fit.needsResize(ideal: size, frameSize: roundedFrame))
        }
    }
}

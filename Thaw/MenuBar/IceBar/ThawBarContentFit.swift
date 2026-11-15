//
//  ThawBarContentFit.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics

/// The content size the Thaw Bar's panel was last fitted to, so a layout pass that changes nothing doesn't
/// refit it. AppKit sizes windows in whole points, so a half-point ideal size never equals the frame it produced.
nonisolated struct ThawBarContentFit: Equatable {
    private var ideal: CGSize?
    private var frameSize: CGSize?

    /// Whether the panel still has to take the content's ideal size.
    func needsResize(ideal: CGSize, frameSize: CGSize) -> Bool {
        guard ideal.width.isFinite, ideal.height.isFinite, ideal.width > 0, ideal.height > 0 else { return false }
        if ideal == frameSize {
            return false
        }
        return ideal != self.ideal || frameSize != self.frameSize
    }

    /// Records the frame size the panel took once ideal was applied.
    mutating func noteResize(ideal: CGSize, frameSize: CGSize) {
        self.ideal = ideal
        self.frameSize = frameSize
    }
}

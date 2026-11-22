//
//  ThawBarOpeningCapture.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

/// A capture attempt and its first visible images belong to one presentation.
@MainActor
@Observable
final class ThawBarOpeningCapture {
    enum IconSource: String {
        case capture, fallback
    }

    var isPending = true
    @ObservationIgnored private var onFirstIcon: ((IconSource) -> Void)?
    @ObservationIgnored private var appeared: Set<IconSource> = []

    init(onFirstIcon: ((IconSource) -> Void)? = nil) {
        self.onFirstIcon = onFirstIcon
    }

    func cancel() {
        onFirstIcon = nil
    }

    /// Missing items reserve their native width while an allowed capture is pending.
    /// A warm neighbor can display independently.
    func source(
        for item: MenuBarItem, hasCapture: Bool, prefersAppIcons: Bool, canCapture: Bool, refreshPending: Bool
    ) -> IconSource? {
        if !hasCapture, isPending || refreshPending, canCapture, !prefersAppIcons {
            return nil
        }
        return MenuBarItemIconFallback.shouldUseAppIcon(
            for: item, hasCapture: hasCapture, prefersAppIcon: prefersAppIcons
        ) ? .fallback : .capture
    }

    static func placeholderSize(for bounds: CGRect, maxHeight: CGFloat?) -> CGSize {
        let height = maxHeight.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (bounds.height.isFinite && bounds.height > 0 ? bounds.height : 22)
        guard bounds.width.isFinite, bounds.width > 0, bounds.height.isFinite, bounds.height > 0 else {
            return CGSize(width: height, height: height)
        }
        return CGSize(width: bounds.width * height / bounds.height, height: height)
    }

    func placeholder(for bounds: CGRect, maxHeight: CGFloat?) -> some View {
        let size = Self.placeholderSize(for: bounds, maxHeight: maxHeight)
        return Capsule()
            .fill(.secondary.opacity(0.22))
            .frame(width: min(size.width, 10), height: min(size.height, 3))
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    func image(_ image: Image, source: IconSource) -> some View {
        image
            .interpolation(.high)
            .antialiased(true)
            .resizable()
            .onAppear {
                if self.appeared.insert(source).inserted {
                    self.onFirstIcon?(source)
                }
            }
            .id(source)
    }
}

//
//  CompatibilityIsolationTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation
import Testing
@testable import Thaw

@Suite("Compatibility product isolation")
struct CompatibilityIsolationTests {
    @Test("The compatibility product does not share upstream storage")
    func independentStorage() {
        #expect(SharedConstants.storageDirectoryName == "Thaw Compat 26")
        #expect(SharedConstants.storageDirectoryName != "Thaw")
        #expect(SharedConstants.productIdentifier == "com.tony.thaw.compat26")
        #expect(SharedConstants.productIdentifier != "com.stonerl.thaw")
    }
}

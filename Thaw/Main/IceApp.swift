//
//  IceApp.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

/// The process entry point.
///
/// Wraps IceApp so command-line invocations can exit before AppKit starts.
/// IceApp can't: its delegate adaptor builds the whole AppState on init.
@main
enum ThawMain {
    static func main() {
        if CommandLine.arguments.contains("--compatibility-self-test") {
            let policyPasses = RehideStrategy.allCases.allSatisfy { current in
                RehideStrategy.allCases.allSatisfy { scheduled in
                    [false, true].allSatisfy { enabled in
                        [false, true].allSatisfy { cancelled in
                            current.allowsPendingRehide(
                                autoRehide: enabled,
                                taskCancelled: cancelled,
                                scheduledStrategy: scheduled
                            ) == (enabled && !cancelled && current == scheduled)
                        }
                    }
                }
            }
            let identityPasses = Bundle.main.bundleIdentifier == "com.tony.thaw.compat26"
            guard policyPasses, identityPasses else {
                print("FAIL: compatibility identity or pending-hide policy")
                Foundation.exit(1)
            }
            print("PASS: isolated bundle identity and all 36 pending-hide policy states. No menu-bar operations performed.")
            return
        }
        guard !LayoutResetCommand.runIfRequested() else {
            return
        }
        IceApp.main()
    }
}

struct IceApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        SettingsWindow(appState: appDelegate.appState)
        PermissionsWindow(appState: appDelegate.appState)
    }
}

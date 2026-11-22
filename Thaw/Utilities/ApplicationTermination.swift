//
//  ApplicationTermination.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

/// Requests app termination after event-tracking and presentation run loops
/// unwind so applicationShouldTerminate can complete its asynchronous cleanup.
@MainActor
enum ApplicationTermination {
    typealias Scheduler = (@escaping @MainActor () -> Void) -> Void

    static func request() {
        request(
            schedule: scheduleOnDefaultRunLoop,
            terminate: terminateApplication
        )
    }

    static func request(
        schedule: Scheduler,
        terminate: @escaping @MainActor () -> Void
    ) {
        schedule(terminate)
    }

    private static func scheduleOnDefaultRunLoop(
        _ action: @escaping @MainActor () -> Void
    ) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                action()
            }
        }
    }

    private static func terminateApplication() {
        NSApp.terminate(nil)
    }

    /// Owns the one outstanding AppKit quit request and its bounded cleanup.
    @MainActor
    final class Preparation {
        private var timeoutTimer: Timer?
        private var restoreTask: Task<Void, Never>?
        private var didReply = false

        func begin(
            timeout: TimeInterval = 2,
            restore: @escaping @MainActor () async -> Void,
            reply: @escaping @MainActor (_ timedOut: Bool) -> Void
        ) -> NSApplication.TerminateReply {
            if didReply {
                return .terminateNow
            }
            guard timeoutTimer == nil else { return .terminateLater }

            let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(timedOut: true, reply: reply) }
            }
            timeoutTimer = timer
            // AppKit waits for the reply in modal-panel mode and can starve a main-queue watchdog.
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .common)
            restoreTask = Task {
                guard !Task.isCancelled else { return }
                await restore()
                finish(timedOut: false, reply: reply)
            }
            return .terminateLater
        }

        private func finish(timedOut: Bool, reply: @MainActor (Bool) -> Void) {
            guard !didReply else { return }
            didReply = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil
            if timedOut {
                restoreTask?.cancel()
            }
            restoreTask = nil
            reply(timedOut)
        }
    }
}

# macOS 26 compatibility experiment

## Scope

This local branch is based on upstream `legacy/thaw-2`, commit
`9b1796fa1a4d5ef43a7d71cde1d1f62f4b8d8cbc` (2.2.0-beta.2).
It is **not Thaw 3 for macOS 26**. It retains Thaw 2's menu-bar backend.

The backport adopts the delayed-hide safety checks described in Thaw 3's
3.0.0-alpha.14 changelog (#1575): after an asynchronous wait, a pending hide
must not execute if automatic rehiding is off, its task was cancelled, or
its strategy has changed. It covers timed, focus-change and smart-click
paths. Existing Thaw 2 features remain unchanged.

## Compatibility findings

The inspected Thaw 3 snapshot was `1849d3663099020f901bcf6fc89b41270878ad3d`.
It can be compiled with Xcode 27.2 and a deployment-target override of 26.0.
That is not sufficient for a functioning backport:

- Its only backend is `RuntimeMenuBarBackend`, replacing the removed legacy backend.
- Its menu-bar inventory and hiding architecture expects Apple's macOS 27
  `com.apple.MenuBarAgent`, absent on the tested macOS 26.7.3 system.
- PlatformRuntimeKit 1.2.14 is a closed binary with Mach-O minimum OS 27.0.
  A minimal loader probe loaded it on 26 without calling any menu-bar API,
  but this does not establish API or behavior compatibility.
- Thaw 3's isolated MenuBarModel package, with only its deployment target
  changed to 26, passed 444 tests in 64 suites. Those are pure-model tests,
  not a live menu-bar validation.

Do not lower Thaw 3's Info.plist version and distribute it as compatible.
Do not patch its binary's platform declarations to conceal these limits.

## Feature boundary

| Feature | This macOS 26 branch |
| --- | --- |
| Existing Thaw 2 hide/show, profiles, triggers, groups and search | Retained upstream implementation |
| Delayed automatic-hide safety checks from Thaw 3 | Backported |
| Thaw 2.2 upstream fixes and settings changes | Present from upstream baseline |
| Thaw 3 macOS 27 hiding/layout backend | Not ported |
| Thaw 3 pop-out layout editor, widgets and new launcher | Not ported |
| Full Thaw 3 functional compatibility | Not claimed |

## Build isolation and safety

The build uses a separate derived-data directory and bundle identifier
`com.tony.thaw.compat26`.

The verified build uses an Apple Development
identity, including both XPC helpers and nested frameworks. It is not an
upstream-signed or notarized release. Do not assume it inherits the installed app's Accessibility or
Screen Recording permissions. Hosted app tests start the normal app and can
terminate other instances or change real settings, so only isolated tests
are appropriate while the user's menu bar is in active use.

## Backport checks

- Isolated SwiftPM compilation of the real `RehideStrategy.swift` and its
  full test file passed 20 tests on macOS 26.7.3. The added matrix covers all
  nine current/scheduled-strategy combinations and all four enabled/cancelled
  states. This tests the actual shared production decision, not a mock backend.
- Strict SwiftLint on all five changed Swift files reported zero violations.
- Xcode 27.2 Debug and universal arm64/x86_64 Release builds passed. The Release
  deliverable was signed after building; strict deep signature verification passed.
- Live hide/show and permission flows were deliberately not executed. They
  require a separate interactive trial and cannot be claimed from these tests.

## Independent product data and updates

This build is named **Thaw Compat 26**. Its default preferences use the
`com.tony.thaw.compat26` bundle domain. Profiles are stored under
`~/Library/Application Support/Thaw Compat 26/Profiles`, logs under
`~/Library/Logs/Thaw Compat 26`, and image cache under
`~/Library/Caches/com.tony.thaw.compat26`. Focus-filter distributed
notifications are namespaced to that product identifier. It does not
silently import or migrate the installed Thaw's profiles or preferences.

Only `thaw-compat26://` is registered. Existing `thaw://` links continue to
belong to upstream Thaw. This build has no upstream Sparkle feed or public
update key, and every updater entry point is disabled. Updating this local
fork requires a new manually reviewed build; selecting an update option
cannot replace it with an official package.

The menu bar itself remains shared macOS state. Separate storage does not
make it safe to run two menu-bar managers concurrently. Do not test layout
writes while upstream Thaw is managing the same menu bar.

Run `python3 scripts/check-compat-isolation.py` for four static safety checks
of URL registration, update configuration, private data paths and Focus
notifications. `CompatibilityIsolationTests` tests the actual shared
product constants without starting the app. These checks do not substitute
for an interactive permissions and hide/show trial.

## Installed product verification

The signed installed executable passed `--compatibility-self-test`, which runs
all 36 pending-hide policy combinations before AppState or AppKit starts.
A separately signed probe built from production CodeSigningInfo confirmed the
Apple Development team is detected. The app and both XPC helpers have
the same TeamIdentifier and satisfy the existing same-team code requirement.
No XPC validation was weakened or rewritten. The intermediate ad-hoc candidate
was re-signed before installation.

Live hide/show and clicking require a separate interactive trial.

## Display stability update (compat26.2)

Backported Thaw 3's `ThawBarContentFit` memo into the legacy hosting view.
AppKit can round a 576.5-point ideal width to a 577-point window. Previously,
every layout pass treated that as a new size and refitted/repositioned the bar.
The memo recognizes the already-applied pair. Genuine content changes or an
externally changed frame still trigger a fit. Non-finite/non-positive sizes
are ignored, and an unchanged origin no longer moves the window.

This does not change saved item order, display choice, colors, spacing, or
placement preferences. Five display-fitting regression tests were added;
all 26 isolated tests and strict lint passed. A 100-pass simulated layout
sequence fits the rounded size exactly once. Real hover appearance requires an interactive check.

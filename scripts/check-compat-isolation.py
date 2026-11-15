#!/usr/bin/env python3
"""Check the local fork's declared isolation without launching either app."""
import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ProductIsolationTests(unittest.TestCase):
    def test_url_registration_and_update_feed(self):
        with (ROOT / "Thaw/Resources/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        schemes = [scheme for item in info["CFBundleURLTypes"]
                   for scheme in item["CFBundleURLSchemes"]]
        self.assertEqual(schemes, ["thaw-compat26"])
        self.assertEqual(info["CFBundleDisplayName"], "Thaw Compat 26")
        self.assertNotIn("SUFeedURL", info)
        self.assertNotIn("SUPublicEDKey", info)
        self.assertFalse(info["SUEnableAutomaticChecks"])
        self.assertFalse(info["SUAutomaticallyUpdate"])

    def test_private_data_paths_are_not_upstream_literals(self):
        for relative in ["Thaw/Settings/Models/ProfileManager.swift",
                         "Thaw/Settings/Models/ThawFocusModeStore.swift",
                         "Thaw/MenuBar/MenuBarItems/MenuBarItemImageCache+Storage.swift",
                         "Shared/Utilities/DiagnosticLogger.swift"]:
            source = (ROOT / relative).read_text()
            with self.subTest(path=relative):
                self.assertNotIn('"Thaw/Profiles', source)
                self.assertNotIn('"com.stonerl.thaw/imageCache', source)
                self.assertNotIn('.appendingPathComponent("Thaw"', source)
                self.assertIn("SharedConstants.", source)

    def test_focus_notifications_are_product_scoped(self):
        for relative in ["Thaw/Settings/Models/ProfileManager.swift",
                         "Thaw/Settings/Models/FocusFilterIntent.swift"]:
            source = (ROOT / relative).read_text()
            self.assertNotIn('"com.stonerl.Thaw.focusFilter', source)
            self.assertIn("SharedConstants.productIdentifier", source)

    def test_updater_stays_disabled(self):
        constants = (ROOT / "Thaw/Utilities/Constants.swift").read_text()
        self.assertIn("static let updatesEnabled = false", constants)
        source = (ROOT / "Thaw/Main/Updates.swift").read_text()
        self.assertIn("guard Constants.updatesEnabled, !hasStartedUpdater", source)
        self.assertIn("guard Constants.updatesEnabled, hasStartedUpdater", source)


if __name__ == "__main__":
    unittest.main()

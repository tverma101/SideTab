import pathlib
import plistlib
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
ANDROID_APP_GRADLE = ROOT / "AndroidClient" / "app" / "build.gradle.kts"
ANDROID_MANIFEST = ROOT / "AndroidClient" / "app" / "src" / "main" / "AndroidManifest.xml"
GRADLE_WRAPPER = ROOT / "AndroidClient" / "gradle" / "wrapper" / "gradle-wrapper.properties"
MAC_PACKAGE = ROOT / "MacHost" / "Package.swift"
MAC_INFO = ROOT / "MacHost" / "Info.plist"
WORKFLOWS = ROOT / ".github" / "workflows"
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def root_version() -> str:
    return (ROOT / "VERSION").read_text().strip()


class RepositoryContractsTest(unittest.TestCase):
    def test_root_version_is_semver(self):
        self.assertRegex(root_version(), r"^\d+\.\d+\.\d+$")

    def test_android_version_is_derived_from_root_version(self):
        text = ANDROID_APP_GRADLE.read_text()
        self.assertIn('rootProject.file("../VERSION")', text)
        self.assertIn("versionName = appVersion", text)
        self.assertIn("versionCode = computedVersionCode", text)

    def test_application_identity_and_tracked_version_match(self):
        gradle = ANDROID_APP_GRADLE.read_text()
        self.assertIn('applicationId = "com.sidescreen.app"', gradle)
        self.assertIn('namespace = "com.sidescreen.app"', gradle)
        with MAC_INFO.open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info.get("CFBundleIdentifier"), "com.sidescreen.app")
        self.assertEqual(info.get("CFBundleVersion"), root_version())
        self.assertEqual(info.get("CFBundleShortVersionString"), root_version())

    def test_swift_package_has_real_test_target(self):
        package = MAC_PACKAGE.read_text()
        self.assertIn(".testTarget(", package)
        self.assertIn('name: "SideScreenTests"', package)
        self.assertIn('path: "Tests/SideScreenTests"', package)

    def test_gradle_wrapper_is_https_and_pinned(self):
        wrapper = GRADLE_WRAPPER.read_text()
        match = re.search(r"^distributionUrl=(.+)$", wrapper, re.MULTILINE)
        self.assertIsNotNone(match)
        url = match.group(1).replace("\\:", ":")
        self.assertTrue(url.startswith("https://services.gradle.org/distributions/"))
        self.assertRegex(url, r"gradle-\d+\.\d+(?:\.\d+)?-bin\.zip$")
        self.assertIn("validateDistributionUrl=true", wrapper)

    def test_android_activity_export_boundaries(self):
        root = ET.parse(ANDROID_MANIFEST).getroot()
        activities = root.find("application").findall("activity")
        exported = {
            activity.attrib.get(ANDROID_NS + "name"): activity.attrib.get(ANDROID_NS + "exported")
            for activity in activities
        }
        self.assertEqual(exported.get(".MainActivity"), "true")
        self.assertEqual(exported.get(".QRScannerActivity"), "false")
        self.assertEqual(exported.get(".LabActivity"), "false")

    def test_workflows_never_use_pull_request_target(self):
        for workflow in WORKFLOWS.glob("*.yml"):
            self.assertNotIn("pull_request_target", workflow.read_text(), workflow.name)

    def test_workflows_default_to_read_only_contents(self):
        for workflow in WORKFLOWS.glob("*.yml"):
            text = workflow.read_text()
            self.assertRegex(
                text,
                r"(?m)^permissions:\s*\n\s+contents:\s+read\s*$",
                workflow.name,
            )


if __name__ == "__main__":
    unittest.main()

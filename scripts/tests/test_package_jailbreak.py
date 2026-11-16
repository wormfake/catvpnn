import gzip
import hashlib
import io
from pathlib import Path
import plistlib
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_jailbreak as package


def read_deb(path):
    data = path.read_bytes()
    assert data[:8] == b"!<arch>\n"
    offset = 8
    result = {}
    while offset < len(data):
        header = data[offset:offset + 60]
        assert header[-2:] == b"`\n"
        size = int(header[48:58])
        name = header[:16].decode().strip().rstrip("/")
        result[name] = data[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2
    return result


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Runner.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "MinimumOSVersion": "15.0", "CFBundleIdentifier": package.BUNDLE_ID,
        }))
        (self.app / "Runner").write_bytes(b"\xcf\xfa\xed\xfe" + b"test executable")
        (self.app / "asset.txt").write_text("asset", encoding="utf-8")
        (self.app / "Helpers").mkdir()
        (self.app / "Helpers" / "CatVPNApi").write_bytes(b"\xcf\xfa\xed\xfe" + b"test helper")
        self.signed = []

    def sign(self, app, profile):
        self.signed.append(plistlib.loads(profile.read_bytes()))

    def test_three_packages_have_correct_paths_architectures_and_executable_modes(self):
        packages = []
        for variant, (arch, parent, _) in package.VARIANTS.items():
            with self.subTest(variant=variant):
                path, control = package.build_variant(self.app, variant, "1.0.5+2", self.root, self.sign)
                packages.append((path, control))
                archive = read_deb(path)
                self.assertEqual(archive["debian-binary"], b"2.0\n")
                self.assertIn(f"Architecture: {arch}\n", control)
                self.assertIn("firmware (>= 15.0)", control)
                self.assertIn("uikittools", control)
                for other in package.VARIANTS:
                    if other != variant:
                        self.assertIn(f"{package.PACKAGE_PREFIX}.{other}", control)
                with tarfile.open(fileobj=io.BytesIO(archive["data.tar.gz"])) as contents:
                    base = f"./{parent}/{package.APP_NAME}"
                    self.assertEqual(contents.getmember(f"{base}/Runner").mode, 0o755)
                    self.assertEqual(contents.getmember(f"{base}/asset.txt").mode, 0o644)
                    self.assertEqual(contents.getmember(f"{base}/Helpers/CatVPNApi").mode, 0o755)
                    prefix = "var/jb/" if variant == "rootless" else ""
                    daemon_path = f"./{prefix}Library/LaunchDaemons/{package.DAEMON_LABEL}.plist"
                    daemon = plistlib.loads(contents.extractfile(daemon_path).read())
                    self.assertEqual(daemon["ProgramArguments"], [f"/{parent}/{package.APP_NAME}/Helpers/CatVPNApi"])
                    self.assertEqual(daemon["UserName"], "mobile")
                    self.assertTrue(daemon["KeepAlive"])
                    self.assertTrue(daemon["RunAtLoad"])
                    self.assertEqual(contents.getmember(daemon_path).mode, 0o644)
                    self.assertTrue(all(m.uid == m.gid == 0 for m in contents))
                    self.assertFalse(any("containers/Bundle" in m.name for m in contents))
                with tarfile.open(fileobj=io.BytesIO(archive["control.tar.gz"])) as controls:
                    preinst = controls.extractfile("./preinst").read().decode()
                    self.assertIn(f'"{arch}"', preinst)
                    self.assertEqual(controls.getmember("./postinst").mode, 0o755)
                    self.assertNotIn("rm -rf", preinst)
                    self.assertNotIn("\r", preinst)
                    postinst = controls.extractfile("./postinst").read().decode()
                    prerm = controls.extractfile("./prerm").read().decode()
                    self.assertIn("launchctl load", postinst)
                    self.assertIn("launchctl unload", prerm)
                    self.assertIn("remove|deconfigure|upgrade", prerm)
        self.assertEqual(len(self.signed), 3)
        self.assertNotIn("com.apple.private.security.no-sandbox", self.signed[0])
        self.assertNotIn("com.apple.private.security.no-sandbox", self.signed[1])
        self.assertTrue(self.signed[2]["com.apple.private.security.no-sandbox"])
        package.write_indexes(self.root, packages)
        index = (self.root / "Packages").read_bytes()
        self.assertEqual(gzip.decompress((self.root / "Packages.gz").read_bytes()), index)
        for path, _ in packages:
            self.assertIn(hashlib.sha256(path.read_bytes()).hexdigest(), index.decode())
        release = (self.root / "Release").read_text()
        self.assertIn(hashlib.sha256(index).hexdigest(), release)

    def test_embedded_framework_can_raise_minimum_ios(self):
        framework = self.app / "Frameworks" / "Flutter.framework"
        framework.mkdir(parents=True)
        (framework / "Info.plist").write_bytes(plistlib.dumps({"MinimumOSVersion": "16.0"}))
        _, control = package.build_variant(self.app, "rootful", "1.0.5", self.root, self.sign)
        self.assertIn("firmware (>= 16.0)", control)

    def test_release_has_sileo_required_fields(self):
        # Sileo's RepoManager rejects Release files without Components, even
        # for flat repositories, then reports "Could not find release file".
        packages = [package.build_variant(self.app, variant, "1.0.5", self.root, self.sign)
                    for variant in package.VARIANTS]
        package.write_indexes(self.root, packages)
        fields = dict(line.split(":", 1) for line in
                      (self.root / "Release").read_text().splitlines()
                      if line and not line.startswith(" "))
        self.assertEqual(fields["Components"].strip(), "main")
        self.assertEqual(set(fields["Architectures"].split()),
                         {"iphoneos-arm", "iphoneos-arm64", "iphoneos-arm64e"})
        self.assertTrue(fields["Origin"].strip())
        self.assertIn("SHA256", fields)

    def test_signing_failure_never_emits_a_deb(self):
        def fail(app, profile):
            raise RuntimeError("signing failed")
        with self.assertRaisesRegex(RuntimeError, "signing failed"):
            package.build_variant(self.app, "roothide", "1.0.5", self.root, fail)
        self.assertEqual(list(self.root.rglob("*.deb")), [])

    def test_missing_daemon_cannot_produce_a_release(self):
        (self.app / "Helpers" / "CatVPNApi").unlink()
        with self.assertRaisesRegex(ValueError, "Missing CatVPNApi"):
            package.build_variant(self.app, "rootless", "1.0.6", self.root, self.sign)
        self.assertEqual(list(self.root.rglob("*.deb")), [])

    def test_never_overwrite_existing_package(self):
        path, _ = package.build_variant(self.app, "rootful", "1.0.5", self.root, self.sign)
        previous = path.read_bytes()
        with self.assertRaises(FileExistsError):
            package.build_variant(self.app, "rootful", "1.0.5", self.root, self.sign)
        self.assertEqual(path.read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()

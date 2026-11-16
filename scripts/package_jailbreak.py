#!/usr/bin/env python3
"""Build three independently signed Debian apps and a local APT repository.

Run on macOS after `flutter build ios --release --no-codesign`.
Only the Python standard library and Apple's codesign are needed.
"""

import argparse
import bz2
import gzip
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile


VARIANTS = {
    "rootful": ("iphoneos-arm", "Applications", "Rootful / Cydia"),
    "rootless": ("iphoneos-arm64", "var/jb/Applications", "Rootless / Sileo"),
    "roothide": ("iphoneos-arm64e", "Applications", "RootHide / Sileo"),
}
PACKAGE_PREFIX = "com.catvpn.nord"
BUNDLE_ID = "com.catvpn.nord.catvp"
APP_NAME = "CatVPNNord.app"
DAEMON_LABEL = "com.catvpn.nord.api"
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def is_macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as source:
        return source.read(4) in MACHO_MAGICS


def minimum_os(app):
    """Use the strictest deployment target from the app and embedded frameworks."""
    versions = [(15, 0)]
    for path in app.rglob("Info.plist"):
        info = plistlib.loads(path.read_bytes())
        value = info.get("MinimumOSVersion")
        if value:
            if not re.fullmatch(r"\d+(?:\.\d+){1,2}", value):
                raise ValueError(f"Invalid MinimumOSVersion in {path}")
            versions.append(tuple(map(int, value.split("."))))
    return ".".join(map(str, max(versions)))


def entitlements(variant):
    result = {
        "application-identifier": f"TEAMID.{BUNDLE_ID}",
        "keychain-access-groups": [f"TEAMID.{BUNDLE_ID}", BUNDLE_ID],
        "com.apple.developer.networking.vpn.api": ["allow-vpn"],
        "com.apple.private.security.container-required": BUNDLE_ID,
        "platform-application": True,
    }
    if variant == "roothide":
        # https://github.com/roothide/Developer/blob/master/entitlements.md
        result.update({
            "com.apple.private.security.no-sandbox": True,
            "com.apple.private.security.storage.AppBundles": True,
            "com.apple.private.security.storage.AppDataContainers": True,
        })
    return result


def sign_app(app, profile):
    """Sign inside-out, including Flutter/App frameworks, then seal the app."""
    sign = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    binaries = sorted((p for p in app.rglob("*") if is_macho(p)),
                      key=lambda p: len(p.parts), reverse=True)
    daemon_profile = profile.with_name("Daemon.entitlements")
    daemon_rights = plistlib.loads(profile.read_bytes())
    daemon_rights.pop("com.apple.private.security.container-required", None)
    daemon_rights.update({
        "com.apple.private.security.no-sandbox": True,
        "com.apple.private.security.storage.AppBundles": True,
        "com.apple.private.security.storage.AppDataContainers": True,
    })
    daemon_profile.write_bytes(plistlib.dumps(daemon_rights))
    for binary in binaries:
        if binary == app / "Helpers" / "CatVPNApi":
            subprocess.run(sign + ["--identifier", BUNDLE_ID, "--entitlements", str(daemon_profile), str(binary)], check=True)
            subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
        else:
            subprocess.run(sign + [str(binary)], check=True)
    frameworks = sorted(app.rglob("*.framework"), key=lambda p: len(p.parts), reverse=True)
    for framework in frameworks:
        subprocess.run(sign + [str(framework)], check=True)
    subprocess.run(sign + ["--entitlements", str(profile), str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def maintainer_scripts(variant):
    arch, app_parent, _ = VARIANTS[variant]
    prefix = "/var/jb" if variant == "rootless" else ""
    shell = f"#!{prefix}/bin/sh\nset -eu\n"
    environment = f'export PATH="{prefix}/usr/bin:{prefix}/bin:{prefix}/usr/sbin:{prefix}/sbin"\n'
    # RootHide's shell/tools interpret /Applications relative to jbroot. Never
    # guess a randomized .jbroot-* path or install via a TrollStore helper.
    app_path = f"/{app_parent}/{APP_NAME}"
    daemon_plist = f"{prefix}/Library/LaunchDaemons/{DAEMON_LABEL}.plist"
    preinst = shell + environment + f'''case "${{1:-}}" in
  install|upgrade)
    actual="$(dpkg --print-architecture)"
    if [ "$actual" != "{arch}" ]; then
      echo "CatVPN {variant}: expected {arch}, found $actual. Install the matching package." >&2
      exit 1
    fi
    ;;
esac
'''
    stop_service = f'''if launchctl list "{DAEMON_LABEL}" >/dev/null 2>&1; then
  launchctl unload "{daemon_plist}"
fi
'''
    postinst = shell + environment + f'''case "${{1:-}}" in
  configure|abort-upgrade|abort-remove|abort-deconfigure)
    {stop_service}
    uicache -p "{app_path}"
    launchctl load "{daemon_plist}"
    ;;
esac
'''
    if variant in ("rootless", "roothide"):
        preinst += '''if [ "${1:-}" = "upgrade" ] && [ -n "${2:-}" ] && dpkg --compare-versions "$2" le 1.0.4; then
  echo "Remove the old CatVPN package first, then install this version. The old installer used an external app container." >&2
  exit 1
fi
'''
    # prerm runs before dpkg removes the bundle, so uicache can still read it.
    prerm = shell + environment + f'''case "${{1:-}}" in
  remove|deconfigure|upgrade)
    {stop_service}
    ;;
esac
case "${{1:-}}" in
  remove|deconfigure) uicache -u "{app_path}" ;;
esac
'''
    return {"preinst": preinst, "postinst": postinst, "prerm": prerm}


def launch_daemon(variant):
    _, app_parent, _ = VARIANTS[variant]
    return {
        "Label": DAEMON_LABEL,
        "ProgramArguments": [f"/{app_parent}/{APP_NAME}/Helpers/CatVPNApi"],
        "UserName": "mobile",
        "GroupName": "mobile",
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "ProcessType": "Background",
    }


def tar_bytes(entries):
    """entries: (archive path, bytes, Unix mode). Normalize owners and timestamps."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, content, mode in sorted(entries):
            info = tarfile.TarInfo("./" + name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            info.mode = mode
            if content is None:
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            else:
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))
    return gzip.compress(buffer.getvalue(), mtime=0)


def write_deb(destination, control, data):
    with destination.open("wb") as output:
        output.write(b"!<arch>\n")
        for name, payload in [("debian-binary", b"2.0\n"),
                              ("control.tar.gz", control), ("data.tar.gz", data)]:
            header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(payload):<10}`\n"
            output.write(header.encode("ascii"))
            output.write(payload)
            if len(payload) % 2:
                output.write(b"\n")


def build_variant(source_app, variant, version, output, signer=sign_app):
    if not is_macho(source_app / "Helpers" / "CatVPNApi"):
        raise ValueError("Missing CatVPNApi helper; run scripts/build_ios_daemon.py first")
    arch, app_parent, label = VARIANTS[variant]
    package = f"{PACKAGE_PREFIX}.{variant}"
    other_packages = [PACKAGE_PREFIX] + [f"{PACKAGE_PREFIX}.{v}" for v in VARIANTS if v != variant]
    min_os = minimum_os(source_app)
    with tempfile.TemporaryDirectory(prefix="catvpn-package-") as temporary:
        stage = Path(temporary)
        app = stage / APP_NAME
        shutil.copytree(source_app, app, symlinks=True)
        profile = stage / "Jailbreak.entitlements"
        profile.write_bytes(plistlib.dumps(entitlements(variant)))
        signer(app, profile)

        archive_root = f"{app_parent}/{APP_NAME}"
        entries = []
        parent = Path(archive_root)
        while str(parent) != ".":
            entries.append((parent.as_posix(), None, 0o755))
            parent = parent.parent
        installed_size = 0
        for path in sorted(app.rglob("*")):
            relative = path.relative_to(app)
            name = f"{archive_root}/{relative.as_posix()}"
            if path.is_symlink():
                raise ValueError(f"Unexpected symlink in iOS app: {relative}")
            if path.is_dir():
                entries.append((name, None, 0o755))
            else:
                data = path.read_bytes()
                installed_size += len(data)
                entries.append((name, data, 0o755 if is_macho(path) else 0o644))
        prefix = "var/jb/" if variant == "rootless" else ""
        daemon_dir = prefix + "Library/LaunchDaemons"
        entries += [(prefix + "Library", None, 0o755), (daemon_dir, None, 0o755)]
        daemon_data = plistlib.dumps(launch_daemon(variant))
        entries.append((f"{daemon_dir}/{DAEMON_LABEL}.plist", daemon_data, 0o644))
        installed_size += len(daemon_data)
        control = (
            f"Package: {package}\nName: CatVPN Nord ({label})\nVersion: {version}\n"
            f"Architecture: {arch}\nMaintainer: CatVPN Nord\nSection: Networking\n"
            f"Depends: firmware (>= {min_os}), uikittools\n"
            f"Conflicts: {', '.join(other_packages)}\nReplaces: {PACKAGE_PREFIX}\n"
            f"Installed-Size: {(installed_size + 1023) // 1024}\n"
            f"Description: CatVPN Nord for {variant}; iOS {min_os}+; install only on matching jailbreak.\n"
        )
        controls = [("control", control.encode(), 0o644)]
        controls += [(name, content.encode(), 0o755)
                     for name, content in maintainer_scripts(variant).items()]
        destination = output / "debs" / f"{package}_{version}_{arch}.deb"
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            raise FileExistsError(f"Refusing to overwrite {destination}; choose a new version/output")
        write_deb(destination, tar_bytes(controls), tar_bytes(entries))
    return destination, control


def write_indexes(output, packages):
    records = []
    for path, control in packages:
        data = path.read_bytes()
        records.append(control + f"Filename: debs/{path.name}\nSize: {len(data)}\n"
                       + f"MD5sum: {hashlib.md5(data).hexdigest()}\n"
                       + f"SHA256: {hashlib.sha256(data).hexdigest()}\n")
    index = ("\n".join(records) + "\n").encode()
    (output / "Packages").write_bytes(index)
    (output / "Packages.gz").write_bytes(gzip.compress(index, mtime=0))
    (output / "Packages.bz2").write_bytes(bz2.compress(index))
    (output / "Packages.xz").write_bytes(lzma.compress(index))
    release = (
        "Origin: CatVPN Nord\nLabel: CatVPN Nord\nSuite: stable\nCodename: ios\n"
        "Architectures: iphoneos-arm iphoneos-arm64 iphoneos-arm64e\n"
        "Components: main\n"
        "Description: CatVPN Nord jailbreak packages\n"
    )
    for field, algorithm in [("MD5Sum", "md5"), ("SHA256", "sha256")]:
        release += f"{field}:\n"
        for name in ["Packages", "Packages.gz", "Packages.bz2", "Packages.xz"]:
            data = (output / name).read_bytes()
            release += f" {hashlib.new(algorithm, data).hexdigest()} {len(data)} {name}\n"
    (output / "Release").write_text(release, encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("build/ios/iphoneos/Runner.app"))
    parser.add_argument("--version", help="Debian package version; defaults to app version + build")
    parser.add_argument("--output", type=Path, default=Path("dist/jailbreak"))
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        parser.error(f"Expected bundle identifier {BUNDLE_ID}")
    executable = app / info["CFBundleExecutable"]
    if not is_macho(executable):
        parser.error("The app executable is missing or is not Mach-O")
    if list(app.rglob("*.appex")):
        parser.error("Embedded extensions need their own signing profiles")
    version = args.version or f"{info['CFBundleShortVersionString']}+{info['CFBundleVersion']}"
    if not re.fullmatch(r"[0-9][A-Za-z0-9.+~]*", version):
        parser.error("Invalid package version")
    if not shutil.which("codesign"):
        parser.error("Run on the macOS build runner: codesign is required; no unsigned packages are emitted")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Output must be empty to avoid mixing package versions")
    packages = [build_variant(app, variant, version, args.output) for variant in VARIANTS]
    write_indexes(args.output, packages)
    manifest = {
        "sourceExecutableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "sourceCommit": os.environ.get("GITHUB_SHA") or os.environ.get("CM_COMMIT"),
        "appVersion": info["CFBundleShortVersionString"],
        "appBuild": info["CFBundleVersion"],
        "minimumOSVersion": minimum_os(app),
        "packageVersion": version,
        "packages": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p, _ in packages},
    }
    (args.output / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    for path, _ in packages:
        print(path)


if __name__ == "__main__":
    main()

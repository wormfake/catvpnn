#!/usr/bin/env python3
"""Cross-compile the launchd helper into the already-built Flutter app."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, default=Path("build/ios/iphoneos/Runner.app"))
args = parser.parse_args()
if not (args.app / "Info.plist").is_file():
    parser.error("Build Runner.app first")
destination = args.app / "Helpers" / "CatVPNApi"
destination.parent.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
subprocess.run([
    "xcrun", "--sdk", "iphoneos", "swiftc", "-swift-version", "5", "-O",
    "-target", "arm64-apple-ios15.0", "-sdk", sdk,
    "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift",
    "-framework", "Foundation", "-framework", "Network", "-framework", "NetworkExtension", "-framework", "Security",
    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
    "-Xlinker", str(Path("ios/Daemon/Info.plist").resolve()),
    "ios/Daemon/LocalHTTPServer.swift", "ios/Daemon/SystemVPNBackend.swift", "ios/Daemon/main.swift",
    "-o", str(destination),
], check=True)
print(destination)

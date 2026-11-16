# CatVPN Nord

Flutter VPN client. Android connects using WireGuard; iOS uses the system
IKEv2 VPN service with NordVPN service credentials and can export a WireGuard
configuration when those credentials are missing. The iOS UI talks to a separate
launchd service on loopback, so API calls keep working after the UI closes.
iOS does not expose traffic
byte counters through NEVPNManager, so the UI shows unavailable counters.

## Jailbreak packages

Distribution repository: <https://wormfake.github.io/catvpnn/>.
Build source: <https://github.com/wormfake/catvpnn>.
GitHub Pages serves the repository; GitHub Actions or Codemagic compiles the app.

Each build emits **three different Debian packages**. Install exactly one:

| Package | Debian architecture | Installed application |
| --- | --- | --- |
| `com.catvpn.nord.rootful` | `iphoneos-arm` | `/Applications/CatVPNNord.app` |
| `com.catvpn.nord.rootless` | `iphoneos-arm64` | `/var/jb/Applications/CatVPNNord.app` |
| `com.catvpn.nord.roothide` | `iphoneos-arm64e` | `/Applications/CatVPNNord.app` inside RootHide's jbroot |

Choose by the jailbreak's `dpkg --print-architecture`, **not by the phone's CPU
or whether the package manager is Cydia or Sileo**. The pre-install script checks
this value even if someone attempts to force a mismatching package. The packages
also conflict with one another to prevent simultaneous installation.

The current Flutter/Xcode project requires **iOS 15.0 or newer**, including the
rootful package. Rootful does not imply support for iOS 13/14 or 32-bit devices.
The packager reads MinimumOSVersion from the app and its frameworks and uses
the highest value as its firmware dependency.

RootHide uses its own entitlement profile. Its shell resolves /Applications
inside jbroot; no randomized .jbroot-* directory is hard-coded. The app uses
system frameworks and bundle-relative Flutter frameworks. New dependencies on
jailbreak libraries must be rebuilt with the RootHide SDK instead of merely
changing the package architecture.

References: [Theos rootless layout](https://theos.dev/docs/rootless),
[RootHide paths](https://github.com/roothide/Developer/blob/master/roothide.md),
[RootHide entitlements](https://github.com/roothide/Developer/blob/master/entitlements.md).

### Upgrade from the old 1.0.4 packages

Remove the old rootless/RootHide package using its package manager **before**
installing the new package. Those old installers copied the app into a fixed
external container or installed it using TrollStore. The new installer refuses
an in-place upgrade from those versions so that two installations of the same
bundle ID are not registered together. If an independently installed TrollStore
copy remains, remove that copy through TrollStore first. Export any settings you
need before removing an old installation.

New packages let dpkg own the app directory, register it with uicache, and
unregister it before removal. They do not delete arbitrary app containers,
silently ignore signing errors, or invoke TrollStore to install another app.

## Build

Use Flutter **3.50.0** and Xcode on macOS (local, GitHub Actions, or Codemagic):

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
python3 -m unittest discover -s scripts/tests -v
python3 scripts/test_local_api.py
flutter build ios --release --no-codesign
python3 scripts/build_ios_daemon.py
python3 scripts/package_jailbreak.py
```

The output is `dist/jailbreak/`, containing `debs/*.deb`, the Packages indexes,
Release, and build-manifest.json with source/binary checksums. By default the
Debian version comes from the built app's version and build number; for this
source version the filenames end with `_1.0.6+3_<architecture>.deb`.
The output directory must be empty. `--output <new-directory>` and `--version`
are available for a separate release. No existing published package is overwritten.

The packager signs nested Mach-O binaries and frameworks before signing the app,
then runs `codesign --verify --deep --strict`. A signing failure stops packaging.
It requires macOS codesign: packaging tests run on Windows/Linux, but an IPA
compiled before a source change cannot contain that change.

The iOS workflow builds only the three jailbreak DEBs and APT indexes; it does
not create sideload or TrollStore IPAs. The GitHub artifact is
CatVPN-Nord-Jailbreak-DEBs.
The Codemagic workflow publishes the same files as build artifacts.
Both use the same packaging script. A green Pages deployment only confirms the
repository files were published, not that the application was compiled.

Before publishing, test launch, VPN permission, connect/disconnect, server
switching, background/resume, reinstall, and removal on each target jailbreak.
Host tests and codesign verification do not establish compatibility on a device.
Upload the new DEBs before replacing all Packages indexes and Release together;
keep the site's existing HTML/icon/IPA assets. No workflow auto-deploys packages.

Nord credentials can be entered in the app. For a private build, the existing
NORD_TOKEN, NORD_PRIV_KEY, NORD_USER, and NORD_PASS build variables remain
supported. Do not distribute a binary containing your personal credentials.

## Local change-IP API (iOS jailbreak)

Install the matching DEB, open CatVPN, and connect once with your NordVPN service
credentials. Then a script or Shortcuts action on the **same iPhone** can call:

```sh
curl --max-time 120 http://127.0.0.1:8787/changeip
curl --max-time 120 -X POST http://127.0.0.1:8787/v1/change-ip
curl http://127.0.0.1:8787/status
curl http://127.0.0.1:8787/health
```

No API key or Authorization header is required. The socket binds only to
127.0.0.1; it is not available on Wi-Fi/LAN. A remote browser origin is rejected.
Use `?country_id=234` or a POST JSON body `{"country_id":234}` to choose a NordVPN
country ID. Without an override, the service keeps the last connected country.

`/changeip` chooses a different IKEv2 server, waits for the previous tunnel to
stop, saves the new server and waits for an actual connected state. Its JSON
contains `state`, `serverHostname`, `countryId`, `previous_hostname`, `old_ip`,
`new_ip`, and `ip_changed`. A different server does not guarantee a different
public IP: `ip_changed` is false if the measured IP is unchanged, or null if an
IP lookup fails. Clients requiring a confirmed new IP must check this field.

An unconfigured VPN returns HTTP 412 (`VPN_NOT_CONFIGURED`). Concurrent changes
return 409 (`VPN_BUSY`); the service does not queue multiple rotations. Network
or tunnel failures return 502/504. Allow up to 120 seconds for a request. Status
remains available during a change, and the app refreshes its server/IP when it
returns to the foreground.

The DEB installs `com.catvpn.nord.api.plist` in the jailbreak's
Library/LaunchDaemons directory and a signed native helper inside the app bundle.
launchd runs it as mobile with RunAtLoad/KeepAlive, independently of Flutter.
The helper uses the same application identifier and Keychain group as the app;
the VPN password remains in Keychain. Installation loads the service, upgrades
stop/reload it, and removal unloads it. After a reboot, activate the jailbreak
and unlock the phone once before using the API. Closing CatVPN's UI does not
stop the helper; disabling the jailbreak does.

`scripts/test_local_api.py` exercises the real Swift socket server on macOS with
a fake VPN boundary (no Nord account/network tunnel). Device testing is still
needed to validate launchd, VPN profile authorization and Keychain access on each
jailbreak. These tests never claim that a host runner established an iOS tunnel.

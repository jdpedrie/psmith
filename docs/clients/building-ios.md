# Building and running the iOS app

The iOS app lives in `clients/psmithd-ios/` and builds against the shared `PsmithKit` / `PsmithUI` package one directory up. The Xcode project is generated from `clients/psmithd-ios/project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen); the `.xcodeproj` itself is gitignored and is not the source of truth. Never hand-edit the project file. Change `project.yml` and regenerate.

This is the build-and-run guide. For how the app is structured (layering, repositories, the stream hub, device tools), read [ios-reference.md](ios-reference.md).

## Prerequisites

- macOS 26 and Xcode 26 or newer. The app targets iOS 26 and builds with the Swift 6.2 toolchain, so an older Xcode will not have the right SDK.
- xcodegen: `brew install xcodegen`.
- A running `psmithd` to point the app at. The simulator can reach a local server at `http://localhost:8080`; a physical device needs a URL it can route to. See [../operations/installation.md](../operations/installation.md) to get the server up.

You do not need to install or run `buf` to build the app. The generated Swift bindings are checked into `PsmithKit/Generated/`; regenerate them only when a `.proto` changes (see [../operations/building-and-codegen.md](../operations/building-and-codegen.md)).

## The fast path: simulator

```bash
make ios-app-run
```

That one target does the whole loop: regenerates the Xcode project, converts the provider-logo SVGs to PNGs (iOS cannot decode raw SVG bytes from arbitrary file URLs), builds for the simulator, boots the simulator, installs the fresh bundle, and launches it. The simulator stays open across runs, so each subsequent `make ios-app-run` replaces the bundle in place and the launched process is the new binary every time.

The default simulator is `iPhone 17 Pro`. Override it per invocation:

```bash
make ios-app-run IOS_SIMULATOR='iPhone 16'
```

On first launch the app asks for the `psmithd` URL, probes it, then asks for credentials (the same users you create with `psmith useradd`). On the simulator, `http://localhost:8080` reaches a server running on the same Mac.

## The targets, one at a time

| Target | What it does |
|---|---|
| `make ios-project` | Runs `xcodegen generate` to write `PsmithiOS.xcodeproj` from `project.yml`. |
| `make logos-png` | Converts the provider-logo SVGs to PNGs. Idempotent; `ios-build` runs it for you. |
| `make ios-build` | `ios-project` + `logos-png`, then `xcodebuild` for the simulator. |
| `make ios-app-run` | `ios-build`, then boot the simulator, install, and launch. |

`ios-build` pins a project-local DerivedData path at `clients/psmithd-ios/.build`, so the build output lands at a predictable location (`.../Build/Products/Debug-iphonesimulator/PsmithiOS.app`) instead of a per-machine hash under `~/Library/Developer/Xcode/DerivedData`.

The bundle identifier is `dev.jdpedrie.PsmithiOS`.

## Running on a physical device

Plain `xcodebuild` targets the simulator. For a device, drive it through Xcode so it can sign:

1. `make ios-project` to generate the project.
2. Open `clients/psmithd-ios/PsmithiOS.xcodeproj` in Xcode.
3. Select your device as the run destination.
4. Under Signing & Capabilities the project is set to Automatic signing. A free Personal Team works. Provisioning profiles minted on a free team expire after seven days; a rebuild from Xcode re-mints them, so re-deploy when the app stops launching.
5. Point the app at a server URL the phone can reach. `localhost` is the phone itself, not your Mac, so use the Mac's LAN address or a tunnel. The app's transport security is relaxed for development (`NSAllowsArbitraryLoads`), so a plain `http://` URL works without TLS; tighten this once the server is behind TLS.

## Entitlements and permissions

`project.yml` declares the HealthKit entitlement and the Info.plist usage strings for camera, location, calendar, reminders, and Health. The HealthKit entitlement requires a signing team, so a device build needs one selected (the simulator does not enforce it). Permission prompts fire lazily: the system asks the first time the model actually invokes a tool that needs the data, not at launch. The strings the user sees are the `NS*UsageDescription` values in `project.yml`.

## Troubleshooting

- **Build looks stale or links a broken binary after changing a public `PsmithKit` type.** The incremental Swift cache can produce a bad binary across ABI changes. Wipe it: `rm -rf clients/psmithd-ios/.build` (and `clients/PsmithSwift/.build` if the package itself changed), then rebuild.
- **`xcodegen: command not found`.** `brew install xcodegen`.
- **Accessibility/automation commands hit the wrong simulator.** When you have more than one simulator, the build destination and any UI-automation tooling must agree on the device. Boot the one you intend (`xcrun simctl list devices booted`) and pass the matching `IOS_SIMULATOR`.
- **Provider logos missing in the UI.** `make logos-png` (it normally runs as part of `ios-build`).

## Related

- [ios-reference.md](ios-reference.md) — how the app is built internally.
- [../operations/building-and-codegen.md](../operations/building-and-codegen.md) — server build, codegen, and the Swift test layers.
- [../operations/installation.md](../operations/installation.md) — standing up a `psmithd` to connect to.

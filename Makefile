.PHONY: proto lint build run tidy migrate-up migrate-down sqlc test swift-build swift-test swift-test-l1 swift-test-l2 swift-test-l2-record mac-build mac-run mac-app mac-app-run ios-project ios-build ios-app-run logos-png

GOOSE_DRIVER ?= postgres
GOOSE_DBSTRING ?= postgres://clark:clark@localhost:5433/clark?sslmode=disable
GOOSE_MIGRATION_DIR ?= db/migrations

proto:
	buf generate

lint:
	buf lint
	go vet ./...

build:
	go build -o bin/reeved ./cmd/reeved

run:
	go run ./cmd/reeved

tidy:
	go mod tidy

sqlc:
	sqlc generate

migrate-up:
	GOOSE_DRIVER=$(GOOSE_DRIVER) GOOSE_DBSTRING="$(GOOSE_DBSTRING)" GOOSE_MIGRATION_DIR=$(GOOSE_MIGRATION_DIR) goose up

migrate-down:
	GOOSE_DRIVER=$(GOOSE_DRIVER) GOOSE_DBSTRING="$(GOOSE_DBSTRING)" GOOSE_MIGRATION_DIR=$(GOOSE_MIGRATION_DIR) goose down

test:
	go test ./...

swift-build:
	cd clients/ReeveSwift && swift build

# Layer 1 (behavior) tests: ReeveKit integration tests against a freshly-
# spawned reeved subprocess. Each test gets a uuid-suffixed user; the server
# binds an ephemeral port and uses an isolated, per-process database that's
# dropped at exit.
swift-test-l1:
	cd clients/ReeveSwift && swift test --filter ReeveKitTests

# Layer 2 (layout) tests: ReeveMac SwiftUI snapshot tests. References live
# in clients/reeved-mac/Tests/ReeveMacSnapshotTests/__Snapshots__/ and are
# checked into git. Compares pixels against the committed baselines and
# fails on diff. NSHostingView's `cacheDisplay(in:to:)` doesn't capture
# Liquid Glass / Metal effects; baselines therefore record text + layout
# structure (which is where most regressions land anyway).
swift-test-l2:
	cd clients/reeved-mac && swift test --filter ReeveMacSnapshotTests

# Re-baseline after intentional UI changes — sets the pointfreeco
# RECORD_SNAPSHOTS env var so every assertion writes its current output
# to disk (overwriting committed PNGs). Review the diff in git before
# committing.
swift-test-l2-record:
	cd clients/reeved-mac && RECORD_SNAPSHOTS=1 swift test --filter ReeveMacSnapshotTests

# Run all swift tests — L1 (behavior) + L2 (layout snapshots).
swift-test: swift-test-l1 swift-test-l2

mac-build:
	cd clients/reeved-mac && swift build --target ReeveMac

mac-run:
	cd clients/reeved-mac && swift run ReeveMac

# Generates AppIcon.icns from the source PNG. Apple's iconutil expects a
# .iconset directory containing per-size pngs; sips downsamples the source.
clients/reeved-mac/AppBundle/AppIcon.icns: clients/reeved-mac/AppBundle/AppIcon.png
	rm -rf clients/reeved-mac/AppBundle/AppIcon.iconset
	mkdir -p clients/reeved-mac/AppBundle/AppIcon.iconset
	sips -z 16 16     clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_16x16.png      >/dev/null
	sips -z 32 32     clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_16x16@2x.png   >/dev/null
	sips -z 32 32     clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_32x32.png      >/dev/null
	sips -z 64 64     clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_32x32@2x.png   >/dev/null
	sips -z 128 128   clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_128x128.png    >/dev/null
	sips -z 256 256   clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256   clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_256x256.png    >/dev/null
	sips -z 512 512   clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512   clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_512x512.png    >/dev/null
	sips -z 1024 1024 clients/reeved-mac/AppBundle/AppIcon.png --out clients/reeved-mac/AppBundle/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	iconutil -c icns clients/reeved-mac/AppBundle/AppIcon.iconset -o clients/reeved-mac/AppBundle/AppIcon.icns
	rm -rf clients/reeved-mac/AppBundle/AppIcon.iconset

# Wraps the SwiftPM-built executable in a .app bundle so macOS sees it as a
# proper app (registers a CFBundleIdentifier, gets a Dock icon, can be
# screenshot/automated by tools that filter by bundle).
mac-app: mac-build clients/reeved-mac/AppBundle/AppIcon.icns
	rm -rf clients/reeved-mac/.build/ReeveMac.app
	mkdir -p clients/reeved-mac/.build/ReeveMac.app/Contents/MacOS
	mkdir -p clients/reeved-mac/.build/ReeveMac.app/Contents/Resources
	cp clients/reeved-mac/AppBundle/Info.plist clients/reeved-mac/.build/ReeveMac.app/Contents/Info.plist
	cp clients/reeved-mac/AppBundle/AppIcon.icns clients/reeved-mac/.build/ReeveMac.app/Contents/Resources/AppIcon.icns
	cp clients/reeved-mac/.build/debug/ReeveMac clients/reeved-mac/.build/ReeveMac.app/Contents/MacOS/ReeveMac
	# SwiftPM resource bundles. The provider-logo SVGs moved to
	# ReeveUI/Resources/Logos/ as part of the iOS-share refactor —
	# the bundle is now ReeveSwift_ReeveUI.bundle (auto-named by SPM
	# from <package>_<target>). Goes inside Contents/Resources/ so the
	# .app stays a proper sealable bundle (unsealed root content
	# breaks codesign).
	if [ -e clients/reeved-mac/.build/debug/ReeveSwift_ReeveUI.bundle ]; then \
		cp -R clients/reeved-mac/.build/debug/ReeveSwift_ReeveUI.bundle \
			clients/reeved-mac/.build/ReeveMac.app/Contents/Resources/ReeveSwift_ReeveUI.bundle; \
	fi
	# Ad-hoc re-sign with the Info.plist's bundle ID. The default SwiftPM
	# signature uses an auto-generated identifier ("ReeveMac-<hash>") which
	# doesn't match CFBundleIdentifier — the mismatch silently breaks
	# UNUserNotificationCenter (system has no idea which app the
	# permission grant belongs to). Re-signing with --identifier fixes it.
	codesign --force --deep --sign - --identifier dev.jdpedrie.ReeveMac \
		clients/reeved-mac/.build/ReeveMac.app

mac-app-run: mac-app
	-pkill -x ReeveMac
	# Invoke the binary directly. `open clients/.../ReeveMac.app` is filtered
	# by Launch Services to whichever copy of the bundle id it has registered
	# (typically a /Applications install), which silently bypasses the freshly
	# built bundle here. Running the executable inside the freshly built
	# bundle wins regardless of LS state.
	clients/reeved-mac/.build/ReeveMac.app/Contents/MacOS/ReeveMac &

# --- iOS ---

# Pinned simulator for the build/run loop. iPhone 17 Pro is the default
# device the iOS plan's snapshot harness will record against; switching
# requires touching one variable here.
IOS_SIMULATOR ?= iPhone 17 Pro
IOS_BUNDLE_ID := dev.jdpedrie.ReeveiOS
IOS_DERIVED_APP := clients/reeved-ios/.build/Build/Products/Debug-iphonesimulator/ReeveiOS.app

# Regenerate the Xcode project from project.yml. xcodegen is the
# git-friendly source of truth — never hand-edit project.pbxproj.
ios-project:
	cd clients/reeved-ios && xcodegen generate

# Convert provider-logo SVGs into matching PNGs so iOS — which can't
# decode raw SVG bytes from arbitrary file URLs — can render them via
# UIImage(named:in:with:). Mac keeps using the SVGs via NSImage. Idempotent.
logos-png:
	scripts/convert-svgs-to-pngs.sh

# Build the iOS app for the simulator. Pinned to a project-local
# DerivedData path so `make ios-app-run` can find the bundle without
# parsing xcodebuild's per-machine hash.
ios-build: ios-project logos-png
	xcodebuild \
		-project clients/reeved-ios/ReeveiOS.xcodeproj \
		-scheme ReeveiOS \
		-configuration Debug \
		-destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR),OS=latest' \
		-derivedDataPath clients/reeved-ios/.build \
		build

# Build, boot the simulator, install the freshly-built bundle, and
# launch. The simulator stays open across runs so subsequent installs
# replace the existing bundle in place — the launched PID is the new
# binary every time.
ios-app-run: ios-build
	xcrun simctl boot '$(IOS_SIMULATOR)' 2>/dev/null || true
	open -a Simulator
	xcrun simctl install booted $(IOS_DERIVED_APP)
	xcrun simctl launch booted $(IOS_BUNDLE_ID)

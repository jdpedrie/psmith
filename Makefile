.PHONY: proto lint build run tidy migrate-up migrate-down sqlc test web-generate swift-build swift-test swift-test-l1 swift-test-l2 swift-test-l2-record mac-build mac-run mac-app mac-app-run ios-project ios-build ios-app-run logos-png

TEMPL_VERSION ?= v0.3.1020

GOOSE_DRIVER ?= postgres
GOOSE_DBSTRING ?= postgres://clark:clark@localhost:5433/clark?sslmode=disable
GOOSE_MIGRATION_DIR ?= db/migrations

proto:
	buf generate

lint:
	buf lint
	go vet ./...

build:
	go build -o bin/spaltd ./cmd/spaltd

run:
	go run ./cmd/spaltd

tidy:
	go mod tidy

sqlc:
	sqlc generate

# Regenerate the web client's templ templates (internal/web/*.templ -> *_templ.go).
# Run after editing any .templ file; the generated files are checked in.
web-generate:
	go run github.com/a-h/templ/cmd/templ@$(TEMPL_VERSION) generate ./internal/web/

migrate-up:
	GOOSE_DRIVER=$(GOOSE_DRIVER) GOOSE_DBSTRING="$(GOOSE_DBSTRING)" GOOSE_MIGRATION_DIR=$(GOOSE_MIGRATION_DIR) goose up

migrate-down:
	GOOSE_DRIVER=$(GOOSE_DRIVER) GOOSE_DBSTRING="$(GOOSE_DBSTRING)" GOOSE_MIGRATION_DIR=$(GOOSE_MIGRATION_DIR) goose down

test:
	go test ./...

swift-build:
	cd clients/SpaltSwift && swift build

# Layer 1 (behavior) tests: SpaltKit integration tests against a freshly-
# spawned spaltd subprocess. Each test gets a uuid-suffixed user; the server
# binds an ephemeral port and uses an isolated, per-process database that's
# dropped at exit.
swift-test-l1:
	cd clients/SpaltSwift && swift test --filter SpaltKitTests

# Layer 2 (layout) tests: SpaltMac SwiftUI snapshot tests. References live
# in clients/spaltd-mac/Tests/SpaltMacSnapshotTests/__Snapshots__/ and are
# checked into git. Compares pixels against the committed baselines and
# fails on diff. NSHostingView's `cacheDisplay(in:to:)` doesn't capture
# Liquid Glass / Metal effects; baselines therefore record text + layout
# structure (which is where most regressions land anyway).
swift-test-l2:
	cd clients/spaltd-mac && swift test --filter SpaltMacSnapshotTests

# Re-baseline after intentional UI changes — sets the pointfreeco
# RECORD_SNAPSHOTS env var so every assertion writes its current output
# to disk (overwriting committed PNGs). Review the diff in git before
# committing.
swift-test-l2-record:
	cd clients/spaltd-mac && RECORD_SNAPSHOTS=1 swift test --filter SpaltMacSnapshotTests

# Run all swift tests — L1 (behavior) + L2 (layout snapshots).
swift-test: swift-test-l1 swift-test-l2

mac-build:
	# --product (not --target) so SwiftPM runs the link step and
	# writes .build/debug/SpaltMac. `--target` alone compiles
	# without linking, leaving mac-app's cp step looking for a
	# binary that was never produced.
	cd clients/spaltd-mac && swift build --product SpaltMac

mac-run:
	cd clients/spaltd-mac && swift run SpaltMac

# Generates AppIcon.icns from the source PNG. Apple's iconutil expects a
# .iconset directory containing per-size pngs; sips downsamples the source.
clients/spaltd-mac/AppBundle/AppIcon.icns: clients/spaltd-mac/AppBundle/AppIcon.png
	rm -rf clients/spaltd-mac/AppBundle/AppIcon.iconset
	mkdir -p clients/spaltd-mac/AppBundle/AppIcon.iconset
	sips -z 16 16     clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_16x16.png      >/dev/null
	sips -z 32 32     clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_16x16@2x.png   >/dev/null
	sips -z 32 32     clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_32x32.png      >/dev/null
	sips -z 64 64     clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_32x32@2x.png   >/dev/null
	sips -z 128 128   clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_128x128.png    >/dev/null
	sips -z 256 256   clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256   clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_256x256.png    >/dev/null
	sips -z 512 512   clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512   clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_512x512.png    >/dev/null
	sips -z 1024 1024 clients/spaltd-mac/AppBundle/AppIcon.png --out clients/spaltd-mac/AppBundle/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	iconutil -c icns clients/spaltd-mac/AppBundle/AppIcon.iconset -o clients/spaltd-mac/AppBundle/AppIcon.icns
	rm -rf clients/spaltd-mac/AppBundle/AppIcon.iconset

# Wraps the SwiftPM-built executable in a .app bundle so macOS sees it as a
# proper app (registers a CFBundleIdentifier, gets a Dock icon, can be
# screenshot/automated by tools that filter by bundle).
mac-app: mac-build clients/spaltd-mac/AppBundle/AppIcon.icns
	rm -rf clients/spaltd-mac/.build/SpaltMac.app
	mkdir -p clients/spaltd-mac/.build/SpaltMac.app/Contents/MacOS
	mkdir -p clients/spaltd-mac/.build/SpaltMac.app/Contents/Resources
	cp clients/spaltd-mac/AppBundle/Info.plist clients/spaltd-mac/.build/SpaltMac.app/Contents/Info.plist
	cp clients/spaltd-mac/AppBundle/AppIcon.icns clients/spaltd-mac/.build/SpaltMac.app/Contents/Resources/AppIcon.icns
	cp clients/spaltd-mac/.build/debug/SpaltMac clients/spaltd-mac/.build/SpaltMac.app/Contents/MacOS/SpaltMac
	# SwiftPM resource bundles. The provider-logo SVGs moved to
	# SpaltUI/Resources/Logos/ as part of the iOS-share refactor —
	# the bundle is now SpaltSwift_SpaltUI.bundle (auto-named by SPM
	# from <package>_<target>). Goes inside Contents/Resources/ so the
	# .app stays a proper sealable bundle (unsealed root content
	# breaks codesign).
	if [ -e clients/spaltd-mac/.build/debug/SpaltSwift_SpaltUI.bundle ]; then \
		cp -R clients/spaltd-mac/.build/debug/SpaltSwift_SpaltUI.bundle \
			clients/spaltd-mac/.build/SpaltMac.app/Contents/Resources/SpaltSwift_SpaltUI.bundle; \
	fi
	# Ad-hoc re-sign with the Info.plist's bundle ID. The default SwiftPM
	# signature uses an auto-generated identifier ("SpaltMac-<hash>") which
	# doesn't match CFBundleIdentifier — the mismatch silently breaks
	# UNUserNotificationCenter (system has no idea which app the
	# permission grant belongs to). Re-signing with --identifier fixes it.
	codesign --force --deep --sign - --identifier dev.jdpedrie.SpaltMac \
		clients/spaltd-mac/.build/SpaltMac.app

mac-app-run: mac-app
	-pkill -x SpaltMac
	# Invoke the binary directly. `open clients/.../SpaltMac.app` is filtered
	# by Launch Services to whichever copy of the bundle id it has registered
	# (typically a /Applications install), which silently bypasses the freshly
	# built bundle here. Running the executable inside the freshly built
	# bundle wins regardless of LS state.
	clients/spaltd-mac/.build/SpaltMac.app/Contents/MacOS/SpaltMac &

# --- iOS ---

# Pinned simulator for the build/run loop. iPhone 17 Pro is the default
# device the iOS plan's snapshot harness will record against; switching
# requires touching one variable here.
IOS_SIMULATOR ?= iPhone 17 Pro
IOS_BUNDLE_ID := dev.jdpedrie.SpaltiOS
IOS_DERIVED_APP := clients/spaltd-ios/.build/Build/Products/Debug-iphonesimulator/SpaltiOS.app

# Regenerate the Xcode project from project.yml. xcodegen is the
# git-friendly source of truth — never hand-edit project.pbxproj.
ios-project:
	cd clients/spaltd-ios && xcodegen generate

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
		-project clients/spaltd-ios/SpaltiOS.xcodeproj \
		-scheme SpaltiOS \
		-configuration Debug \
		-destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR),OS=latest' \
		-derivedDataPath clients/spaltd-ios/.build \
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

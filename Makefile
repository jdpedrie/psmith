.PHONY: proto lint build run tidy migrate-up migrate-down sqlc test swift-build swift-test swift-test-l1 swift-test-l2 swift-test-l2-record mac-build mac-run mac-app mac-app-run

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
	cd clients/reeved-mac && swift build

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
	# SwiftPM resource bundle (ReeveMac/Logos/*.svg). The auto-generated
	# Bundle.module accessor expects it next to the .app — `Bundle.main.bundleURL
	# .appendingPathComponent("reeved-mac_ReeveMac.bundle")` — not inside
	# Contents/Resources/. The if-guard makes mac-app idempotent for
	# pre-resource-era builds where the bundle doesn't exist.
	if [ -e clients/reeved-mac/.build/debug/reeved-mac_ReeveMac.bundle ]; then \
		cp -R clients/reeved-mac/.build/debug/reeved-mac_ReeveMac.bundle \
			clients/reeved-mac/.build/ReeveMac.app/reeved-mac_ReeveMac.bundle; \
	fi

mac-app-run: mac-app
	-pkill -x ReeveMac
	# Invoke the binary directly. `open clients/.../ReeveMac.app` is filtered
	# by Launch Services to whichever copy of the bundle id it has registered
	# (typically a /Applications install), which silently bypasses the freshly
	# built bundle here. Running the executable inside the freshly built
	# bundle wins regardless of LS state.
	clients/reeved-mac/.build/ReeveMac.app/Contents/MacOS/ReeveMac &

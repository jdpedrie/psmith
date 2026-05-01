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
	go build -o bin/clarkd ./cmd/clarkd

run:
	go run ./cmd/clarkd

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
	cd clients/ClarkSwift && swift build

# Layer 1 (behavior) tests: ClarkKit integration tests against a freshly-
# spawned clarkd subprocess. Each test gets a uuid-suffixed user; the server
# binds an ephemeral port and uses an isolated, per-process database that's
# dropped at exit.
swift-test-l1:
	cd clients/ClarkSwift && swift test --filter ClarkKitTests

# Layer 2 (layout) tests: ClarkMac SwiftUI snapshot tests. References live
# in clients/clarkd-mac/Tests/ClarkMacSnapshotTests/__Snapshots__/ and are
# checked into git. Compares pixels against the committed baselines and
# fails on diff. NSHostingView's `cacheDisplay(in:to:)` doesn't capture
# Liquid Glass / Metal effects; baselines therefore record text + layout
# structure (which is where most regressions land anyway).
swift-test-l2:
	cd clients/clarkd-mac && swift test --filter ClarkMacSnapshotTests

# Re-baseline after intentional UI changes — sets the pointfreeco
# RECORD_SNAPSHOTS env var so every assertion writes its current output
# to disk (overwriting committed PNGs). Review the diff in git before
# committing.
swift-test-l2-record:
	cd clients/clarkd-mac && RECORD_SNAPSHOTS=1 swift test --filter ClarkMacSnapshotTests

# Run all swift tests — L1 (behavior) + L2 (layout snapshots).
swift-test: swift-test-l1 swift-test-l2

mac-build:
	cd clients/clarkd-mac && swift build

mac-run:
	cd clients/clarkd-mac && swift run ClarkMac

# Generates AppIcon.icns from the source PNG. Apple's iconutil expects a
# .iconset directory containing per-size pngs; sips downsamples the source.
clients/clarkd-mac/AppBundle/AppIcon.icns: clients/clarkd-mac/AppBundle/AppIcon.png
	rm -rf clients/clarkd-mac/AppBundle/AppIcon.iconset
	mkdir -p clients/clarkd-mac/AppBundle/AppIcon.iconset
	sips -z 16 16     clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_16x16.png      >/dev/null
	sips -z 32 32     clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_16x16@2x.png   >/dev/null
	sips -z 32 32     clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_32x32.png      >/dev/null
	sips -z 64 64     clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_32x32@2x.png   >/dev/null
	sips -z 128 128   clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_128x128.png    >/dev/null
	sips -z 256 256   clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256   clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_256x256.png    >/dev/null
	sips -z 512 512   clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512   clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_512x512.png    >/dev/null
	sips -z 1024 1024 clients/clarkd-mac/AppBundle/AppIcon.png --out clients/clarkd-mac/AppBundle/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	iconutil -c icns clients/clarkd-mac/AppBundle/AppIcon.iconset -o clients/clarkd-mac/AppBundle/AppIcon.icns
	rm -rf clients/clarkd-mac/AppBundle/AppIcon.iconset

# Wraps the SwiftPM-built executable in a .app bundle so macOS sees it as a
# proper app (registers a CFBundleIdentifier, gets a Dock icon, can be
# screenshot/automated by tools that filter by bundle).
mac-app: mac-build clients/clarkd-mac/AppBundle/AppIcon.icns
	rm -rf clients/clarkd-mac/.build/ClarkMac.app
	mkdir -p clients/clarkd-mac/.build/ClarkMac.app/Contents/MacOS
	mkdir -p clients/clarkd-mac/.build/ClarkMac.app/Contents/Resources
	cp clients/clarkd-mac/AppBundle/Info.plist clients/clarkd-mac/.build/ClarkMac.app/Contents/Info.plist
	cp clients/clarkd-mac/AppBundle/AppIcon.icns clients/clarkd-mac/.build/ClarkMac.app/Contents/Resources/AppIcon.icns
	cp clients/clarkd-mac/.build/debug/ClarkMac clients/clarkd-mac/.build/ClarkMac.app/Contents/MacOS/ClarkMac
	# SwiftPM resource bundle (ClarkMac/Logos/*.svg). The auto-generated
	# Bundle.module accessor expects it next to the .app — `Bundle.main.bundleURL
	# .appendingPathComponent("clarkd-mac_ClarkMac.bundle")` — not inside
	# Contents/Resources/. The if-guard makes mac-app idempotent for
	# pre-resource-era builds where the bundle doesn't exist.
	if [ -e clients/clarkd-mac/.build/debug/clarkd-mac_ClarkMac.bundle ]; then \
		cp -R clients/clarkd-mac/.build/debug/clarkd-mac_ClarkMac.bundle \
			clients/clarkd-mac/.build/ClarkMac.app/clarkd-mac_ClarkMac.bundle; \
	fi

mac-app-run: mac-app
	-pkill -x ClarkMac
	# Invoke the binary directly. `open clients/.../ClarkMac.app` is filtered
	# by Launch Services to whichever copy of the bundle id it has registered
	# (typically a /Applications install), which silently bypasses the freshly
	# built bundle here. Running the executable inside the freshly built
	# bundle wins regardless of LS state.
	clients/clarkd-mac/.build/ClarkMac.app/Contents/MacOS/ClarkMac &

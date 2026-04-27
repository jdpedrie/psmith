.PHONY: proto lint build run tidy migrate-up migrate-down sqlc test swift-build swift-test mac-build mac-run mac-app mac-app-run

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

swift-test:
	cd clients/ClarkSwift && swift test

mac-build:
	cd clients/clarkd-mac && swift build

mac-run:
	cd clients/clarkd-mac && swift run ClarkMac

# Wraps the SwiftPM-built executable in a .app bundle so macOS sees it as a
# proper app (registers a CFBundleIdentifier, gets a Dock icon, can be
# screenshot/automated by tools that filter by bundle).
mac-app: mac-build
	rm -rf clients/clarkd-mac/.build/ClarkMac.app
	mkdir -p clients/clarkd-mac/.build/ClarkMac.app/Contents/MacOS
	cp clients/clarkd-mac/AppBundle/Info.plist clients/clarkd-mac/.build/ClarkMac.app/Contents/Info.plist
	cp clients/clarkd-mac/.build/debug/ClarkMac clients/clarkd-mac/.build/ClarkMac.app/Contents/MacOS/ClarkMac

mac-app-run: mac-app
	-pkill -x ClarkMac
	open clients/clarkd-mac/.build/ClarkMac.app

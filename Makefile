.PHONY: build test app run clean worker

build:
	swift build

worker:
	swift build --product ScannerWorker

test:
	swift test

app:
	./scripts/build-app.sh debug

app-release:
	./scripts/build-app.sh release

run: app
	open dist/MacStorageStudio.app

clean:
	swift package clean
	rm -rf dist .build

# Velora — build orchestration (SwiftPM + hand-rolled .app; no Xcode).

.PHONY: build release app run sounds clean

build:
	swift build

release:
	swift build -c release

app:
	./scripts/make-app.sh release

run: build
	.build/debug/Velora

sounds:
	./scripts/make-sounds.sh

clean:
	rm -rf .build build

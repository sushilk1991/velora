# Velora — build orchestration (SwiftPM + hand-rolled .app; no Xcode).

.PHONY: build release app dmg verify-dmg run sounds clean test

build:
	swift build

release:
	swift build -c release

app:
	./scripts/make-app.sh release

dmg:
	./scripts/make-dmg.sh release

verify-dmg:
	./scripts/verify-dmg.sh "$(DMG)"

run: build
	.build/debug/Velora

sounds:
	./scripts/make-sounds.sh

clean:
	rm -rf .build build

test:
	cd engine && uv run pytest -q

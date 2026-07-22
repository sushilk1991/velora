# Velora — build orchestration (SwiftPM + hand-rolled .app; no Xcode).

.PHONY: build release app dmg verify-dmg run sounds clean test test-swift \
	test-engine test-site test-release-scripts test-coverage test-live-audio \
	test-ios perf-test

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

test: test-swift test-engine test-site test-release-scripts

test-swift: build
	.build/debug/Velora --selftest

test-engine:
	cd engine && uv run pytest -q

test-site:
	python3 scripts/test-site.py

test-release-scripts:
	./scripts/test-signing-config.sh

test-coverage:
	cd engine && uv run pytest -q --cov=velora_engine --cov-branch \
		--cov-report=term-missing --cov-fail-under=80

test-live-audio: build
	VELORA_LIVE_AUDIO_SELFTEST=1 .build/debug/Velora --selftest

test-ios:
	xcodebuild test -quiet \
		-project ios/VeloraMobile.xcodeproj \
		-scheme Velora \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
		CODE_SIGNING_ALLOWED=NO

perf-test:
	swift build
	VELORA_PERF_SELFTEST=1 .build/debug/Velora --selftest

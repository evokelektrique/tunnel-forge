# Shortcuts for the checks we run most often. Keep the actual build logic in
# Flutter, Gradle, and CMake.

ANDROID_DIR := android
GRADLEW := ./gradlew

.PHONY: help
help:
	@printf '%s\n' \
		'Common targets:' \
		'  make format          Format Dart and Android native C sources' \
		'  make check           Run analysis, Android lint, and native C checks' \
		'  make test            Run Flutter, Android unit, and native C tests' \
		'  make build-debug     Build the Android debug APK' \
		'  make build-release   Build signed split-ABI APKs using .env' \
		'' \
		'Focused targets:' \
		'  make flutter-format  Format Dart sources' \
		'  make flutter-analyze Run Flutter analyzer' \
		'  make flutter-test    Run Flutter tests' \
		'  make android-lint    Run Android lint for debug' \
		'  make android-test    Run Android debug unit tests' \
		'  make native-format   Format Android native C sources' \
		'  make native-check    Run native C format, lint, and unit-test checks' \
		'  make native-test     Run native C unit tests'

.PHONY: format
format: flutter-format native-format

.PHONY: check
check: flutter-analyze android-lint native-check

.PHONY: test
test: flutter-test android-test native-test

.PHONY: build-debug
build-debug:
	cd $(ANDROID_DIR) && $(GRADLEW) :app:assembleDebug

.PHONY: build-release
build-release:
	@set -eu; \
		test -f .env || { echo 'Missing .env; copy .env.example and configure release signing.' >&2; exit 1; }; \
		set -a; . ./.env; set +a; \
		: "$${TUNNEL_FORGE_ANDROID_KEYSTORE_PASSWORD:?Set TUNNEL_FORGE_ANDROID_KEYSTORE_PASSWORD in .env}"; \
		: "$${TUNNEL_FORGE_ANDROID_KEY_ALIAS:?Set TUNNEL_FORGE_ANDROID_KEY_ALIAS in .env}"; \
		: "$${TUNNEL_FORGE_ANDROID_KEY_PASSWORD:?Set TUNNEL_FORGE_ANDROID_KEY_PASSWORD in .env}"; \
		if [ -n "$${TUNNEL_FORGE_ANDROID_KEYSTORE_PATH:-}" ] && [ -n "$${TUNNEL_FORGE_ANDROID_KEYSTORE_BASE64:-}" ]; then \
			echo 'Set only one keystore source in .env: KEYSTORE_PATH or KEYSTORE_BASE64.' >&2; exit 1; \
		elif [ -n "$${TUNNEL_FORGE_ANDROID_KEYSTORE_BASE64:-}" ]; then \
			umask 077; \
			keystore_tmp=$$(mktemp); \
			trap 'rm -f "$$keystore_tmp"' EXIT; \
			printf '%s' "$$TUNNEL_FORGE_ANDROID_KEYSTORE_BASE64" | base64 --decode > "$$keystore_tmp"; \
			export TUNNEL_FORGE_ANDROID_KEYSTORE_PATH="$$keystore_tmp"; \
		else \
			: "$${TUNNEL_FORGE_ANDROID_KEYSTORE_PATH:?Set a keystore path or base64 keystore in .env}"; \
		fi; \
		case "$$TUNNEL_FORGE_ANDROID_KEYSTORE_PATH" in /*) ;; \
			*) export TUNNEL_FORGE_ANDROID_KEYSTORE_PATH="$$PWD/$$TUNNEL_FORGE_ANDROID_KEYSTORE_PATH" ;; esac; \
		test -s "$$TUNNEL_FORGE_ANDROID_KEYSTORE_PATH" || { echo 'Keystore file is missing or empty.' >&2; exit 1; }; \
		flutter build apk --release --split-per-abi

.PHONY: flutter-format
flutter-format:
	dart format lib test

.PHONY: flutter-analyze
flutter-analyze:
	flutter analyze

.PHONY: flutter-test
flutter-test:
	flutter test

.PHONY: android-lint
android-lint:
	cd $(ANDROID_DIR) && $(GRADLEW) :app:lintDebug

.PHONY: android-test
android-test:
	cd $(ANDROID_DIR) && $(GRADLEW) --stacktrace :app:testDebugUnitTest

.PHONY: native-format
native-format:
	cd $(ANDROID_DIR) && $(GRADLEW) :app:formatAndroidNativeC

.PHONY: native-check
native-check:
	cd $(ANDROID_DIR) && $(GRADLEW) :app:checkNativeC

.PHONY: native-test
native-test:
	cd $(ANDROID_DIR) && $(GRADLEW) :app:testNativeC

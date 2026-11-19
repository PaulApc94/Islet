# Convenience targets. Everything real lives in the scripts, so `make` is
# optional: ./install.sh works on its own.

APP := build/Islet.app

.DEFAULT_GOAL := build
.PHONY: build install uninstall run test icon clean

# Swift Testing's macro plugin lives in a toolchain subfolder that the compiler
# does not always find by itself with the Command Line Tools (the test target
# then fails to compile about one time in two). Naming the folder makes it
# deterministic; with other toolchains the folder is absent and nothing is added.
TESTING_PLUGINS := $(shell dirname "$$(xcrun --find swift 2>/dev/null)" 2>/dev/null)/../lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc "$(TESTING_PLUGINS)")

# Unit tests of the island's logic (state machine, geometry, playback clock).
test:
	swift test $(TEST_FLAGS)

# Release build assembled into $(APP), ad-hoc signed.
build:
	@bash scripts/build-app.sh

# Build, then copy to /Applications (or ~/Applications) and launch.
install:
	@bash install.sh

uninstall:
	@bash uninstall.sh

# Build and launch straight from build/. A running Islet is stopped first
# (bounded wait): `open` would otherwise just bring the old instance forward
# instead of starting the fresh build.
run: build
	@pkill -x Islet 2>/dev/null || true
	@n=0; while pgrep -x Islet >/dev/null 2>&1 && [ $$n -lt 50 ]; do sleep 0.1; n=$$((n + 1)); done
	@open $(APP)

# Regenerate the committed icon from its drawing code.
icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build

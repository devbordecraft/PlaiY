BUILD_DIR  := build/apple-debug
APP_DIR    := app
SCHEME     := PlaiY
CONFIG     := Debug
NPROCS     := $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)
PREFIX     := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
APP_PATH    = $(shell xcodebuild -project $(APP_DIR)/PlaiY.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/^ *BUILT_PRODUCTS_DIR/{print $$3}')/PlaiY.app

.PHONY: all core xcodegen app run clean core-ios core-ios-sim app-ios core-tvos app-tvos deps-ios deps-tvos

all: app

# ── macOS ──

core:
	@echo "==> Building C++ core (macOS)..."
	@cmake -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=$(CONFIG) -DCMAKE_PREFIX_PATH=$(PREFIX) -S .
	@cmake --build $(BUILD_DIR) --parallel $(NPROCS)

xcodegen:
	@echo "==> Generating Xcode project..."
	@cd $(APP_DIR) && xcodegen generate

app: core xcodegen
	@echo "==> Building macOS app..."
	@cd $(APP_DIR) && xcodebuild -project PlaiY.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) build 2>&1 | grep -E '(BUILD|error:)' || true

run: app
	@echo "==> Launching PlaiY..."
	@open "$(APP_PATH)"

# ── iOS ──

core-ios:
	@echo "==> Building C++ core (iOS device)..."
	@cmake -B build/ios-$(CONFIG) \
		-DCMAKE_BUILD_TYPE=$(CONFIG) \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
		-DCMAKE_PREFIX_PATH=$(CURDIR)/deps/ios \
		-S .
	@cmake --build build/ios-$(CONFIG) --parallel $(NPROCS)

core-ios-sim:
	@echo "==> Building C++ core (iOS simulator)..."
	@cmake -B build/ios-sim-$(CONFIG) \
		-DCMAKE_BUILD_TYPE=$(CONFIG) \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT=iphonesimulator \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
		-DCMAKE_PREFIX_PATH=$(CURDIR)/deps/ios-sim \
		-S .
	@cmake --build build/ios-sim-$(CONFIG) --parallel $(NPROCS)

app-ios: core-ios xcodegen
	@echo "==> Building iOS app..."
	@cd $(APP_DIR) && xcodebuild -project PlaiY.xcodeproj \
		-scheme PlaiY-iOS -configuration $(CONFIG) \
		-destination 'generic/platform=iOS' build 2>&1 | grep -E '(BUILD|error:)' || true

# ── tvOS ──

core-tvos:
	@echo "==> Building C++ core (tvOS)..."
	@cmake -B build/tvos-$(CONFIG) \
		-DCMAKE_BUILD_TYPE=$(CONFIG) \
		-DCMAKE_SYSTEM_NAME=tvOS \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
		-DCMAKE_PREFIX_PATH=$(CURDIR)/deps/tvos \
		-S .
	@cmake --build build/tvos-$(CONFIG) --parallel $(NPROCS)

app-tvos: core-tvos xcodegen
	@echo "==> Building tvOS app..."
	@cd $(APP_DIR) && xcodebuild -project PlaiY.xcodeproj \
		-scheme PlaiY-tvOS -configuration $(CONFIG) \
		-destination 'generic/platform=tvOS' build 2>&1 | grep -E '(BUILD|error:)' || true

# ── vcpkg dependencies ──

deps-ios:
	@echo "==> Installing iOS dependencies via vcpkg..."
	@vcpkg install --triplet=arm64-ios --x-install-root=deps/ios \
		--overlay-triplets=triplets

deps-tvos:
	@echo "==> Installing tvOS dependencies via vcpkg..."
	@vcpkg install --triplet=arm64-tvos --x-install-root=deps/tvos \
		--overlay-triplets=triplets

# ── Clean ──

clean:
	@rm -rf build/apple-debug build/apple-release
	@rm -rf build/ios-Debug build/ios-Release build/ios-sim-Debug build/ios-sim-Release
	@rm -rf build/tvos-Debug build/tvos-Release
	@cd $(APP_DIR) && xcodebuild -project PlaiY.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) clean 2>/dev/null || true
	@echo "Cleaned."

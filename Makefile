BUILD_DIR  := build/apple-debug
APP_DIR    := app
SCHEME     := PlaiY
CONFIG     := Debug
NPROCS     := $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)
PREFIX     := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
APP_PATH    = $(shell xcodebuild -project $(APP_DIR)/PlaiY.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/^ *BUILT_PRODUCTS_DIR/{print $$3}')/PlaiY.app

.PHONY: all core xcodegen app run clean

all: app

core:
	@echo "==> Building C++ core..."
	@cmake -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=$(CONFIG) -DCMAKE_PREFIX_PATH=$(PREFIX) -S .
	@cmake --build $(BUILD_DIR) --parallel $(NPROCS)

xcodegen:
	@echo "==> Generating Xcode project..."
	@cd $(APP_DIR) && xcodegen generate

app: core xcodegen
	@echo "==> Building app..."
	@cd $(APP_DIR) && xcodebuild -project PlaiY.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) build 2>&1 | grep -E '(BUILD|error:)' || true

run: app
	@echo "==> Launching PlaiY..."
	@open "$(APP_PATH)"

clean:
	@rm -rf $(BUILD_DIR)
	@cd $(APP_DIR) && xcodebuild -project PlaiY.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) clean 2>/dev/null || true
	@echo "Cleaned."

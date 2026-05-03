ROOT := ../..
BUILD_DIR := build
FRAMEWORK_DIR ?= $(ROOT)/build/Release
SYPHON_FRAMEWORK := $(FRAMEWORK_DIR)/Syphon.framework
SDK := $(shell xcrun --show-sdk-path)
CC := xcrun clang

COMMON_FLAGS := -fobjc-arc -fblocks -isysroot $(SDK) -mmacosx-version-min=10.13 -F$(FRAMEWORK_DIR)
COMMON_LIBS := -framework Cocoa -framework Metal -framework IOSurface -framework Syphon

.PHONY: all apps framework server client clean

all: apps

apps: server client

framework:
	xcodebuild -project $(ROOT)/Syphon.xcodeproj -scheme Syphon -configuration Release build

server: $(BUILD_DIR)/Simple\ Syphon\ Server.app/Contents/MacOS/SimpleSyphonServer

client: $(BUILD_DIR)/Simple\ Syphon\ Client.app/Contents/MacOS/SimpleSyphonClient

$(BUILD_DIR)/Simple\ Syphon\ Server.app/Contents/MacOS/SimpleSyphonServer: SimpleSyphonServer/main.m SimpleSyphonServer/Info.plist
	test -d "$(SYPHON_FRAMEWORK)"
	mkdir -p "$(BUILD_DIR)/Simple Syphon Server.app/Contents/MacOS" "$(BUILD_DIR)/Simple Syphon Server.app/Contents/Frameworks"
	cp SimpleSyphonServer/Info.plist "$(BUILD_DIR)/Simple Syphon Server.app/Contents/Info.plist"
	rsync -a --delete "$(SYPHON_FRAMEWORK)" "$(BUILD_DIR)/Simple Syphon Server.app/Contents/Frameworks/"
	$(CC) $(COMMON_FLAGS) -Wl,-rpath,@executable_path/../Frameworks SimpleSyphonServer/main.m $(COMMON_LIBS) -o "$@"

$(BUILD_DIR)/Simple\ Syphon\ Client.app/Contents/MacOS/SimpleSyphonClient: SimpleSyphonClient/main.m SimpleSyphonClient/Info.plist
	test -d "$(SYPHON_FRAMEWORK)"
	mkdir -p "$(BUILD_DIR)/Simple Syphon Client.app/Contents/MacOS" "$(BUILD_DIR)/Simple Syphon Client.app/Contents/Frameworks"
	cp SimpleSyphonClient/Info.plist "$(BUILD_DIR)/Simple Syphon Client.app/Contents/Info.plist"
	rsync -a --delete "$(SYPHON_FRAMEWORK)" "$(BUILD_DIR)/Simple Syphon Client.app/Contents/Frameworks/"
	$(CC) $(COMMON_FLAGS) -Wl,-rpath,@executable_path/../Frameworks SimpleSyphonClient/main.m $(COMMON_LIBS) -o "$@"

clean:
	rm -rf "$(BUILD_DIR)"

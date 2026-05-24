ROOT := ../..
BUILD_DIR := build
FRAMEWORK_DIR ?= $(ROOT)/build/Release
SYPHON_FRAMEWORK := $(FRAMEWORK_DIR)/Syphon.framework
DEVELOPER_DIR ?= $(firstword $(wildcard /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer) $(shell xcode-select -p 2>/dev/null))
SDK := $(shell DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun --show-sdk-path)
CC := DEVELOPER_DIR="$(DEVELOPER_DIR)" xcrun clang
XCODEBUILD := DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild

COMMON_FLAGS := -fobjc-arc -fblocks -isysroot $(SDK) -mmacosx-version-min=10.13 -F$(FRAMEWORK_DIR)
COMMON_LIBS := -framework Cocoa -framework Metal -framework CoreVideo -framework IOSurface -framework Syphon

.PHONY: all apps framework metal-toolchain server client clean

all: apps

apps: server client

framework:
	@test -x "$(DEVELOPER_DIR)/usr/bin/xcodebuild" || (echo "Xcode is required. Install Xcode.app or run: make framework DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"; exit 1)
	$(XCODEBUILD) -project $(ROOT)/Syphon.xcodeproj -scheme Syphon -configuration Release SYMROOT="$(abspath $(ROOT)/build)" build

metal-toolchain:
	@test -x "$(DEVELOPER_DIR)/usr/bin/xcodebuild" || (echo "Xcode is required. Install Xcode.app or run: make metal-toolchain DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"; exit 1)
	$(XCODEBUILD) -downloadComponent MetalToolchain

server: $(BUILD_DIR)/Syphon\ Metal\ Benchmark\ Server.app/Contents/MacOS/SyphonMetalBenchmarkServer

client: $(BUILD_DIR)/Syphon\ Metal\ Benchmark\ Client.app/Contents/MacOS/SyphonMetalBenchmarkClient

$(BUILD_DIR)/Syphon\ Metal\ Benchmark\ Server.app/Contents/MacOS/SyphonMetalBenchmarkServer: BenchmarkServer/main.m BenchmarkServer/Info.plist
	test -d "$(SYPHON_FRAMEWORK)"
	mkdir -p "$(BUILD_DIR)/Syphon Metal Benchmark Server.app/Contents/MacOS" "$(BUILD_DIR)/Syphon Metal Benchmark Server.app/Contents/Frameworks"
	cp BenchmarkServer/Info.plist "$(BUILD_DIR)/Syphon Metal Benchmark Server.app/Contents/Info.plist"
	rsync -a --delete "$(SYPHON_FRAMEWORK)" "$(BUILD_DIR)/Syphon Metal Benchmark Server.app/Contents/Frameworks/"
	$(CC) $(COMMON_FLAGS) -Wl,-rpath,@executable_path/../Frameworks BenchmarkServer/main.m $(COMMON_LIBS) -o "$@"

$(BUILD_DIR)/Syphon\ Metal\ Benchmark\ Client.app/Contents/MacOS/SyphonMetalBenchmarkClient: BenchmarkClient/main.m BenchmarkClient/Info.plist
	test -d "$(SYPHON_FRAMEWORK)"
	mkdir -p "$(BUILD_DIR)/Syphon Metal Benchmark Client.app/Contents/MacOS" "$(BUILD_DIR)/Syphon Metal Benchmark Client.app/Contents/Frameworks"
	cp BenchmarkClient/Info.plist "$(BUILD_DIR)/Syphon Metal Benchmark Client.app/Contents/Info.plist"
	rsync -a --delete "$(SYPHON_FRAMEWORK)" "$(BUILD_DIR)/Syphon Metal Benchmark Client.app/Contents/Frameworks/"
	$(CC) $(COMMON_FLAGS) -Wl,-rpath,@executable_path/../Frameworks BenchmarkClient/main.m $(COMMON_LIBS) -o "$@"

clean:
	rm -rf "$(BUILD_DIR)"

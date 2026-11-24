SCHEME         := Berth
DERIVED_DATA   := build
CONFIG_DEBUG   := Debug
CONFIG_RELEASE := Release

APP_NAME       := Berth
VERSION        := $(shell cat ../VERSION)
LSREGISTER     := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

FIXTURE        := $(abspath ../fixtures/export.json)

XCODEBUILD     = xcodebuild -project BerthApp.xcodeproj -derivedDataPath $(DERIVED_DATA) \
                   MARKETING_VERSION=$(VERSION)

.PHONY: all generate build smoke check release clean

all: build

generate:
	xcodegen generate

# Builds unregister their own product, which Xcode registers with Launch
# Services, so a development build never shadows an installed site app.
build: generate
	$(XCODEBUILD) -scheme $(SCHEME) -configuration $(CONFIG_DEBUG) build
	@$(LSREGISTER) -u "$(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/$(APP_NAME).app" 2>/dev/null || true

# A Codable type compiles whether or not its keys match the CLI's export, so
# the build proves nothing about decoding; this does.
smoke: generate
	$(XCODEBUILD) -scheme BerthSmoke -configuration $(CONFIG_DEBUG) build
	"$(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/BerthSmoke" "$(FIXTURE)"

check: build smoke

release: generate
	$(XCODEBUILD) -scheme $(SCHEME) -configuration $(CONFIG_RELEASE) build
	@$(LSREGISTER) -u "$(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIG_RELEASE)/$(APP_NAME).app" 2>/dev/null || true

clean:
	rm -rf $(DERIVED_DATA)

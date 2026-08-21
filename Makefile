SHELL := /bin/sh

PROJECT := kual-next
VERSION := $(strip $(shell cat VERSION))
BUILD_DIR := build
DIST_DIR := dist
HOST_CC ?= cc
HOST_CFLAGS ?= -O2 -g -std=c11 -Wall -Wextra -Wpedantic -Werror
SSH ?= ssh
SCP ?= scp
CPPFLAGS := -Iinclude -Ithird_party -DKUAL_NEXT_VERSION='"$(VERSION)"'
CORE_SOURCES := src/util.c src/config.c src/condition.c src/menu.c
HOST_SOURCES := $(CORE_SOURCES) third_party/yxml.c src/main.c
HOST_BINARY := $(BUILD_DIR)/host/$(PROJECT)

FBINK_DIR := $(CURDIR)/third_party/FBInk
FBINK_LIB := $(FBINK_DIR)/Release/libfbink.a
FBINK_FEATURE_STAMP := $(BUILD_DIR)/vendor/.fbink-opentype-build
TC_ROOT ?= $(CURDIR)/.toolchains
TC_TRIPLE := arm-kindlehf-linux-gnueabihf
TC_BIN := $(TC_ROOT)/$(TC_TRIPLE)/bin
DEVICE_CC := $(TC_BIN)/$(TC_TRIPLE)-gcc
DEVICE_STRIP := $(TC_BIN)/$(TC_TRIPLE)-strip
DEVICE_READELF := $(TC_BIN)/$(TC_TRIPLE)-readelf
DEVICE_CFLAGS := -Os -std=c11 -Wall -Wextra -Wpedantic -march=armv7-a -mtune=cortex-a7 -mfpu=neon -mfloat-abi=hard -mthumb -ffunction-sections -fdata-sections
DEVICE_LDFLAGS := -static -Wl,--gc-sections
DEVICE_SOURCES := $(CORE_SOURCES) src/main.c src/ui_fbink.c
DEVICE_OBJECTS := $(patsubst src/%.c,$(BUILD_DIR)/kindle/%.o,$(DEVICE_SOURCES)) \
	$(BUILD_DIR)/kindle/yxml.o
DEVICE_BINARY := $(BUILD_DIR)/kindle/$(PROJECT)
PACKAGE := $(DIST_DIR)/$(PROJECT)-$(VERSION)-kindlehf.zip

.PHONY: all host test toolchain kindle check package deploy clean
all: host

host: $(HOST_BINARY)

$(HOST_BINARY): $(HOST_SOURCES) include/kual.h third_party/jsmn.h third_party/yxml.h VERSION
	mkdir -p $(@D)
	$(HOST_CC) $(CPPFLAGS) $(HOST_CFLAGS) -DKUAL_HOST -o $@ $(HOST_SOURCES)

test: $(HOST_BINARY)
	KUAL_TEST_VERSION="$(VERSION)" sh ./tests/run.sh $(HOST_BINARY)
	sh ./tests/check-fonts.sh
	sh ./tests/check-deploy.sh
	sh ./tests/check-toolchain.sh
	sh ./tests/check-release.sh
	actionlint

toolchain:
	KUAL_TC_ROOT="$(TC_ROOT)" sh ./scripts/install-prebuilt-toolchain.sh

$(FBINK_FEATURE_STAMP): $(FBINK_DIR)/Makefile $(FBINK_DIR)/fbink.h
	PATH="$(TC_BIN):$$PATH" $(MAKE) -C "$(FBINK_DIR)" cleanstaticlib
	PATH="$(TC_BIN):$$PATH" $(MAKE) -C "$(FBINK_DIR)" staticlib KINDLE=1 MINIMAL=1 BITMAP=1 DRAW=1 INPUT=1 OPENTYPE=1 CROSS_TC=$(TC_TRIPLE)
	mkdir -p $(@D)
	touch $@

$(FBINK_LIB): $(FBINK_FEATURE_STAMP)
	test -f $@

$(BUILD_DIR)/kindle/%.o: src/%.c include/kual.h third_party/jsmn.h third_party/yxml.h VERSION $(FBINK_FEATURE_STAMP)
	mkdir -p $(@D)
	$(DEVICE_CC) $(CPPFLAGS) -I$(FBINK_DIR) $(DEVICE_CFLAGS) -c -o $@ $<

$(BUILD_DIR)/kindle/yxml.o: third_party/yxml.c third_party/yxml.h $(FBINK_FEATURE_STAMP)
	mkdir -p $(@D)
	$(DEVICE_CC) $(CPPFLAGS) $(DEVICE_CFLAGS) -c -o $@ $<

$(DEVICE_BINARY): $(DEVICE_OBJECTS) $(FBINK_LIB)
	$(DEVICE_CC) $(DEVICE_CFLAGS) $(DEVICE_LDFLAGS) -o $@ $(DEVICE_OBJECTS) $(FBINK_LIB) -lm
	$(DEVICE_STRIP) --strip-all $@

kindle: $(DEVICE_BINARY)

check: test $(DEVICE_BINARY)
	file $(DEVICE_BINARY)
	$(DEVICE_READELF) -A $(DEVICE_BINARY) | grep -q 'Tag_ABI_VFP_args: VFP registers'
	! $(DEVICE_READELF) -d $(DEVICE_BINARY) 2>/dev/null | grep -q NEEDED

package: check
	rm -rf "$(BUILD_DIR)/package"
	mkdir -p "$(BUILD_DIR)/package/kual-next/bin" "$(BUILD_DIR)/package/kual-next/fonts" "$(BUILD_DIR)/package/kual-next/LICENSES" "$(BUILD_DIR)/package/documents" "$(DIST_DIR)"
	cp $(DEVICE_BINARY) "$(BUILD_DIR)/package/kual-next/bin/kual-next"
	cp LICENSE "$(BUILD_DIR)/package/kual-next/LICENSES/KUAL-Next-GPL-3.0-or-later.txt"
	cp third_party/JSMN-LICENSE "$(BUILD_DIR)/package/kual-next/LICENSES/jsmn-MIT.txt"
	cp third_party/YXML-LICENSE "$(BUILD_DIR)/package/kual-next/LICENSES/yxml-MIT.txt"
	cp assets/fonts/OFL.txt "$(BUILD_DIR)/package/kual-next/LICENSES/Noto-SIL-OFL-1.1.txt"
	cp assets/fonts/NotoSans.ttf "$(BUILD_DIR)/package/kual-next/fonts/NotoSans.ttf"
	cp assets/fonts/NotoSansSymbols.ttf "$(BUILD_DIR)/package/kual-next/fonts/NotoSansSymbols.ttf"
	cp assets/fonts/NotoSansSymbols2-Regular.otf "$(BUILD_DIR)/package/kual-next/fonts/NotoSansSymbols2-Regular.otf"
	cp assets/icons/kual-next.png "$(BUILD_DIR)/package/kual-next/icon.png"
	cp "$(FBINK_DIR)/LICENSE" "$(BUILD_DIR)/package/kual-next/LICENSES/FBInk-GPL-3.0-or-later.txt"
	cp "assets/KUAL Next.sh" "$(BUILD_DIR)/package/documents/KUAL Next.sh"
	find "$(BUILD_DIR)/package" -exec touch -d '2000-01-01 00:00:00 UTC' {} +
	cd "$(BUILD_DIR)/package" && find . -type f -print | LC_ALL=C sort | zip -X -q "$(CURDIR)/$(PACKAGE)" -@

deploy:
	@test -n "$(KINDLE_HOST)" || { echo "KINDLE_HOST is required (for example: make deploy KINDLE_HOST=root@kindle)" >&2; exit 2; }
	$(MAKE) package
	SSH="$(SSH)" SCP="$(SCP)" sh ./scripts/deploy-kindle.sh "$(KINDLE_HOST)" "$(PACKAGE)"

clean:
	@if [ -f "$(FBINK_DIR)/Makefile" ]; then PATH="$(TC_BIN):$$PATH" $(MAKE) -C "$(FBINK_DIR)" cleanstaticlib; fi
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"

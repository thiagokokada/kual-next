SHELL := /bin/sh

PROJECT := kual-next
VERSION := 0.1.0
BUILD_DIR := build
DIST_DIR := dist
HOST_CC ?= cc
HOST_CFLAGS ?= -O2 -g -std=c11 -Wall -Wextra -Wpedantic -Werror
CPPFLAGS := -Iinclude -Ithird_party
CORE_SOURCES := src/util.c src/config.c src/condition.c src/menu.c
HOST_SOURCES := $(CORE_SOURCES) src/main.c
HOST_BINARY := $(BUILD_DIR)/host/$(PROJECT)

FBINK_DIR ?= ../FBInk
FBINK_REV ?= 886f25f13368859ad8a899b88d04c26e19cda32e
FBINK_STAGE := $(BUILD_DIR)/vendor/FBInk-src
TC_ROOT ?= $(CURDIR)/.toolchains
TOOLCHAIN_FHS ?= kual-toolchain-fhs
TC_TRIPLE := arm-kindlehf-linux-gnueabihf
TC_BIN := $(TC_ROOT)/$(TC_TRIPLE)/bin
DEVICE_CC := $(TC_BIN)/$(TC_TRIPLE)-gcc
DEVICE_STRIP := $(TC_BIN)/$(TC_TRIPLE)-strip
DEVICE_READELF := $(TC_BIN)/$(TC_TRIPLE)-readelf
DEVICE_CFLAGS := -Os -std=c11 -Wall -Wextra -Wpedantic -march=armv7-a -mtune=cortex-a7 -mfpu=neon -mfloat-abi=hard -mthumb -ffunction-sections -fdata-sections
DEVICE_LDFLAGS := -static -Wl,--gc-sections
DEVICE_SOURCES := $(CORE_SOURCES) src/main.c src/ui_fbink.c
DEVICE_OBJECTS := $(patsubst src/%.c,$(BUILD_DIR)/kindle/%.o,$(DEVICE_SOURCES))
DEVICE_BINARY := $(BUILD_DIR)/kindle/$(PROJECT)

.PHONY: all host test toolchain kindle check package clean
all: host

host: $(HOST_BINARY)

$(HOST_BINARY): $(HOST_SOURCES) include/kual.h third_party/jsmn.h
	mkdir -p $(@D)
	$(HOST_CC) $(CPPFLAGS) $(HOST_CFLAGS) -DKUAL_HOST -o $@ $(HOST_SOURCES)

test: $(HOST_BINARY)
	sh ./tests/run.sh $(HOST_BINARY)

toolchain:
	KUAL_TC_ROOT="$(TC_ROOT)" $(TOOLCHAIN_FHS) -c 'exec sh ./scripts/bootstrap-toolchain.sh'

$(FBINK_STAGE)/.staged: scripts/stage-fbink.sh
	sh ./scripts/stage-fbink.sh "$(abspath $(FBINK_DIR))" "$(FBINK_REV)" "$(abspath $(FBINK_STAGE))"

$(FBINK_STAGE)/Release/libfbink.a: $(FBINK_STAGE)/.staged
	PATH="$(TC_BIN):$$PATH" $(MAKE) -C "$(FBINK_STAGE)" staticlib KINDLE=1 MINIMAL=1 BITMAP=1 DRAW=1 INPUT=1 CROSS_TC=$(TC_TRIPLE)

$(BUILD_DIR)/kindle/%.o: src/%.c include/kual.h third_party/jsmn.h $(FBINK_STAGE)/.staged
	mkdir -p $(@D)
	$(DEVICE_CC) $(CPPFLAGS) -I$(FBINK_STAGE) $(DEVICE_CFLAGS) -c -o $@ $<

$(DEVICE_BINARY): $(DEVICE_OBJECTS) $(FBINK_STAGE)/Release/libfbink.a
	$(DEVICE_CC) $(DEVICE_CFLAGS) $(DEVICE_LDFLAGS) -o $@ $(DEVICE_OBJECTS) $(FBINK_STAGE)/Release/libfbink.a -lm
	$(DEVICE_STRIP) --strip-all $@

kindle: $(DEVICE_BINARY)

check: test $(DEVICE_BINARY)
	file $(DEVICE_BINARY)
	$(DEVICE_READELF) -A $(DEVICE_BINARY) | grep -q 'Tag_ABI_VFP_args: VFP registers'
	! $(DEVICE_READELF) -d $(DEVICE_BINARY) 2>/dev/null | grep -q NEEDED

package: check
	rm -rf "$(BUILD_DIR)/package"
	mkdir -p "$(BUILD_DIR)/package/kual-next/bin" "$(BUILD_DIR)/package/kual-next/LICENSES" "$(BUILD_DIR)/package/documents" "$(DIST_DIR)"
	cp $(DEVICE_BINARY) "$(BUILD_DIR)/package/kual-next/bin/kual-next"
	cp LICENSE "$(BUILD_DIR)/package/kual-next/LICENSES/KUAL-Next-GPL-3.0-or-later.txt"
	cp third_party/JSMN-LICENSE "$(BUILD_DIR)/package/kual-next/LICENSES/jsmn-MIT.txt"
	cp "$(FBINK_STAGE)/LICENSE" "$(BUILD_DIR)/package/kual-next/LICENSES/FBInk-GPL-3.0-or-later.txt"
	cp "assets/KUAL Next.sh" "$(BUILD_DIR)/package/documents/KUAL Next.sh"
	find "$(BUILD_DIR)/package" -exec touch -d '2000-01-01 00:00:00 UTC' {} +
	cd "$(BUILD_DIR)/package" && find . -type f -print | LC_ALL=C sort | zip -X -q "$(CURDIR)/$(DIST_DIR)/$(PROJECT)-$(VERSION)-kindlehf.zip" -@

clean:
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"

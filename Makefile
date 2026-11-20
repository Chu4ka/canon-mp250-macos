SHELL := /bin/sh
PREFIX := $(shell /bin/sh scripts/deps-prefix.sh)
export CANON_MP250_DEPS_PREFIX := $(PREFIX)
export MACOSX_DEPLOYMENT_TARGET := 27.0
CC ?= clang
CFLAGS ?= -O2 -Wall -Wextra -Wpedantic
CPPFLAGS += -I$(PREFIX)/include -I$(PREFIX)/include/libusb-1.0
APP_DEFS = -DCANON_MP250_DATA_PATH='"/usr/local/share/canon-mp250/gutenprint/5.3/xml"' \
	-DAPP_VERSION='"$(shell /bin/cat VERSION)"'
COMMON_LIBS = $(PREFIX)/lib/libusb-1.0.a -framework IOKit -framework CoreFoundation -framework Security
APP_ARCHIVES = $(PREFIX)/lib/libpappl.a $(PREFIX)/lib/libgutenprint.a $(PREFIX)/lib/libusb-1.0.a \
	$(PREFIX)/lib/libssl.a $(PREFIX)/lib/libcrypto.a
PAPPL_LIBS = $(APP_ARCHIVES) -lcups -lz -liconv -lpthread -lm \
	-framework IOKit -framework CoreFoundation -framework Security \
	-framework AppKit -framework SystemConfiguration

.PHONY: all deps clean check smoke release install uninstall

all: build/bin/canon-mp250-app build/bin/mp250-diag

deps:
	./scripts/bootstrap-deps.sh

build/bin:
	mkdir -p $@

build/bin/canon-mp250-app: src/canon_mp250_app.c VERSION Makefile $(APP_ARCHIVES) | build/bin
	$(CC) $(CPPFLAGS) $(APP_DEFS) $(CFLAGS) -std=c11 -o $@ $< $(PAPPL_LIBS)

build/bin/mp250-diag: src/mp250_diag.c Makefile $(PREFIX)/lib/libusb-1.0.a | build/bin
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c11 -o $@ $< $(COMMON_LIBS)

build/bin/make-test-raster: tests/make_test_raster.c | build/bin
	$(CC) $(CFLAGS) -std=c11 -o $@ $< -lcups

check: all build/bin/make-test-raster
	@check_spool=$$(mktemp -d "$${TMPDIR:-/private/tmp}/mp250-check.XXXXXX") && \
	trap 'rmdir "$$check_spool"' EXIT && \
	STP_DATA_PATH=$(PREFIX)/share/gutenprint/5.3/xml build/bin/canon-mp250-app drivers \
	  -o "spool-directory=$$check_spool"
	plutil -lint packaging/*.plist
	file build/bin/canon-mp250-app build/bin/mp250-diag

smoke: all build/bin/make-test-raster
	./tests/smoke-render.sh

release: all
	./scripts/build-release.sh

install: release
	./scripts/install.sh

uninstall:
	sudo ./scripts/uninstall.sh

clean:
	rm -f build/bin/canon-mp250-app build/bin/mp250-diag build/bin/make-test-raster

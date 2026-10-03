# SPDX-License-Identifier: GPL-2.0
# Stesso schema di eventservice: le regole implicite di make compilano i .c
# con CC/CFLAGS/LDFLAGS e i .cpp con CXX/CXXFLAGS del toolchain di LibreELEC.
# rf35h-scrape usa libcurl: flag e librerie da pkg-config, che in LibreELEC
# punta al sysroot del target (config/functions esporta PKG_CONFIG*).

PKG_CONFIG ?= pkg-config
CXXFLAGS   += -std=c++11
BINS_C     = rf35h-tty rf35h-idle rf35h-i2c rf35h-rumble rf35h-ledd
BINS_CXX   = rf35h-scrape
PREFIX     = /usr

.PHONY: all
all: $(BINS_C) $(BINS_CXX)

rf35h-scrape: rf35h-scrape.cpp
	$(CXX) $(CXXFLAGS) $(shell $(PKG_CONFIG) --cflags libcurl) -o $@ $< $(LDFLAGS) $(shell $(PKG_CONFIG) --libs libcurl)

.PHONY: install
install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	install $(BINS_C) $(BINS_CXX) $(DESTDIR)$(PREFIX)/bin

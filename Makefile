# Build snapcam from the command line (no Xcode required).
# Requires: Xcode Command Line Tools (swiftc / swift)

PRODUCT = snapcam
SOURCE = main.swift
PREFIX ?= /usr/local

.PHONY: all build run clean install uninstall

all: build

build:
	swift build -c release
	cp .build/release/$(PRODUCT) .

# Alternative: build directly with swiftc (no Package.swift needed)
build-swiftc:
	swiftc -o $(PRODUCT) $(SOURCE)

run: build
	./$(PRODUCT) -h

clean:
	swift package clean
	rm -f $(PRODUCT)

install: build
	install -d $(PREFIX)/bin
	install -m 755 .build/release/$(PRODUCT) $(PREFIX)/bin/$(PRODUCT)

uninstall:
	rm -f $(PREFIX)/bin/$(PRODUCT)

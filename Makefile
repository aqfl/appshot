# appshot Makefile
#   make            build ./.build/appshot
#   make install    build + install to ~/.local/bin (replaces the previous binary)
#   make uninstall  remove installed binary and source copy
#   make clean      remove build output
#
# Override the location:  make install PREFIX=/usr/local   (may need sudo)

PREFIX   ?= $(HOME)/.local
BINDIR   := $(PREFIX)/bin
SHAREDIR := $(PREFIX)/share/appshot
SRC      := appshot.swift
BUILD    := .build
BIN      := $(BUILD)/appshot

.PHONY: all build install uninstall clean

all: build

build: $(BIN)

$(BIN): $(SRC)
	@mkdir -p $(BUILD)
	swiftc -O $(SRC) -o $(BIN)

install: build
	@mkdir -p $(BINDIR) $(SHAREDIR)
	install -m 644 $(SRC) $(SHAREDIR)/$(SRC)
	install -m 755 $(BIN) $(BINDIR)/appshot
	@if [ -e $(BINDIR)/appshot-bin ]; then \
		install -m 755 $(BIN) $(BINDIR)/appshot-bin; \
		echo "Also refreshed $(BINDIR)/appshot-bin (used by the zsh function)"; \
	fi
	@echo "Installed -> $(BINDIR)/appshot"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "Note: $(BINDIR) is not on your PATH";; esac

uninstall:
	rm -f $(BINDIR)/appshot $(BINDIR)/appshot-bin
	rm -rf $(SHAREDIR)

clean:
	rm -rf $(BUILD)

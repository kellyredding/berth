.PHONY: build install clean test lint format check dev

BERTH_ROOT ?= $(HOME)/.berth
BINDIR     ?= $(BERTH_ROOT)/bin
LINKDIR    ?= $(HOME)/.local/bin
BUILDDIR   ?= build

test:
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

# `dev` before `test`: the integration specs run the built binary as a
# subprocess, so they have nothing to run until it exists.
check: lint dev test

dev:
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/berth src/berth.cr

build:
	@mkdir -p $(BUILDDIR)
	crystal build --release --no-debug -o $(BUILDDIR)/berth src/berth.cr

# Two compilations on purpose: `check` runs the specs against the dev binary,
# `build` produces the optimized one that is installed.
install: check build
	install -d $(BINDIR) $(LINKDIR)
	install -m 755 $(BUILDDIR)/berth $(BINDIR)/berth
	ln -sfn $(BINDIR)/berth $(LINKDIR)/berth
	@echo "installed $(BINDIR)/berth"
	@echo "linked    $(LINKDIR)/berth"

clean:
	rm -rf $(BUILDDIR) lib .shards

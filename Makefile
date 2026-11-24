.PHONY: all check build dev test lint format clean \
        cli-build cli-check cli-dev cli-test cli-lint cli-format cli-install cli-clean \
        app-check

APP_DIR := BerthApp

all: cli-build

# --- Crystal CLI ---

cli-build:   ; $(MAKE) -C tools/berth build
cli-check:   ; $(MAKE) -C tools/berth check
cli-dev:     ; $(MAKE) -C tools/berth dev
cli-test:    ; $(MAKE) -C tools/berth test
cli-lint:    ; $(MAKE) -C tools/berth lint
cli-format:  ; $(MAKE) -C tools/berth format
cli-install: ; $(MAKE) -C tools/berth install
cli-clean:   ; $(MAKE) -C tools/berth clean

# --- Swift app ---

# Fails rather than passing while there is no app, so a green app-check always
# means an app was built and smoke-checked.
app-check:
ifeq ($(wildcard $(APP_DIR)/Makefile),)
	@echo "app-check: there is no $(APP_DIR)/ yet, so there is no app to build or check" >&2
	@exit 1
else
	$(MAKE) -C $(APP_DIR) check
endif

# --- Aggregates ---

build: cli-build
clean: cli-clean

# `check` is the CLI's gate and `app-check` the app's; a change touching both
# sides needs both. Delegated rather than restated, so the steps cannot drift.
check:  cli-check
dev:    cli-dev
test:   cli-test
lint:   cli-lint
format: cli-format

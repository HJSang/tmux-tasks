# tmux-tasks — install/uninstall the `tmt` command.
#
# PREFIX controls the install root. Default ~/.local (no sudo needed).
# For a system-wide install:  sudo make install PREFIX=/usr/local

PREFIX ?= $(HOME)/.local
BINDIR  = $(PREFIX)/bin
# bash-completion.d location differs; this is the common user path.
COMPDIR = $(PREFIX)/share/bash-completion/completions

.PHONY: all install uninstall lint test help

all: help

install:
	@mkdir -p "$(BINDIR)"
	@install -m 0755 bin/tmt "$(BINDIR)/tmt"
	@mkdir -p "$(COMPDIR)"
	@install -m 0644 completions/tmt.bash "$(COMPDIR)/tmt" 2>/dev/null || true
	@echo "installed tmt -> $(BINDIR)/tmt"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
	  *) echo "NOTE: $(BINDIR) is not on your PATH. Add:  export PATH=\"$(BINDIR):$$PATH\"";; esac

uninstall:
	@rm -f "$(BINDIR)/tmt" "$(COMPDIR)/tmt"
	@echo "removed tmt from $(BINDIR)"

lint:
	@command -v shellcheck >/dev/null && shellcheck bin/tmt || echo "shellcheck not installed; skipping"

test:
	@bash test/test.sh

help:
	@echo "targets:"
	@echo "  make install    [PREFIX=~/.local]   install tmt + completion"
	@echo "  make uninstall  [PREFIX=~/.local]   remove tmt"
	@echo "  make lint                            run shellcheck"
	@echo "  make test                            run the smoke test"

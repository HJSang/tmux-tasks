#!/usr/bin/env bash
#
# tmux-tasks installer. Works on Linux and macOS.
#
# Usage:
#   ./install.sh                         # install to ~/.local/bin
#   PREFIX=/usr/local ./install.sh       # custom prefix (may need sudo)
#   curl -fsSL <raw-url>/install.sh | bash
#
# When piped from curl (no local checkout), it clones the repo to a temp dir
# first. Set TMT_REPO to override the clone source.

set -euo pipefail

TMT_REPO="${TMT_REPO:-https://github.com/HJSang/tmux-tasks.git}"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
COMPDIR="$PREFIX/share/bash-completion/completions"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v tmux >/dev/null || err "tmux is required but not installed (Linux: apt/dnf install tmux; macOS: brew install tmux)"

# Locate the source: local checkout if bin/tmt sits next to us, else clone.
SRC=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "$(dirname "${BASH_SOURCE[0]}")/bin/tmt" ]]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  command -v git >/dev/null || err "git required to fetch the source"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  log "cloning $TMT_REPO"
  git clone --depth 1 "$TMT_REPO" "$TMP/tmux-tasks" >/dev/null 2>&1 || err "clone failed"
  SRC="$TMP/tmux-tasks"
fi

log "installing to $BINDIR"
mkdir -p "$BINDIR"
install -m 0755 "$SRC/bin/tmt" "$BINDIR/tmt"

if [[ -f "$SRC/completions/tmt.bash" ]]; then
  mkdir -p "$COMPDIR"
  install -m 0644 "$SRC/completions/tmt.bash" "$COMPDIR/tmt" 2>/dev/null || true
fi

log "installed: $("$BINDIR/tmt" version)"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) printf '\033[33mNOTE:\033[0m add %s to your PATH:\n  export PATH="%s:$PATH"\n' "$BINDIR" "$BINDIR" ;;
esac

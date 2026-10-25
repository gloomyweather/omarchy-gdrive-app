#!/bin/bash
# Installs omarchy-gdrive for the current user and hooks it into Omarchy.
# Safe to run again: files are replaced, nothing is duplicated.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-gdrive"

say() { printf '\033[1m::\033[0m %s\n' "$*"; }

missing=()
for pkg in rclone fuse3 libsecret curl jq libnotify nautilus-python wl-clipboard; do
  pacman -Qq "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if ((${#missing[@]})); then
  say "installing missing packages: ${missing[*]} (needs sudo)"
  if command -v omarchy-pkg-add >/dev/null; then
    omarchy-pkg-add "${missing[@]}"
  else
    sudo pacman -S --needed "${missing[@]}"
  fi
fi

# A copy, not a link to the checkout: the repo can move or change freely.
say "copying files to $APP_DIR"
mkdir -p "$APP_DIR"
for dir in bin lib systemd shell-plugin nautilus share config; do
  rm -rf "${APP_DIR:?}/$dir.new"
  cp -r "$REPO/$dir" "$APP_DIR/$dir.new"
  rm -rf "${APP_DIR:?}/$dir"
  mv "$APP_DIR/$dir.new" "$APP_DIR/$dir"
done
for doc in README.md OAUTH.md TROUBLESHOOTING.md LICENSE; do
  install -m 644 "$REPO/$doc" "$APP_DIR/$doc"
done
chmod 755 "$APP_DIR/bin/omarchy-gdrive"

"$APP_DIR/bin/omarchy-gdrive" install "$@"

if [[ ! -s ${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf ]] ||
  ! ls "${XDG_CONFIG_HOME:-$HOME/.config}"/omarchy-gdrive/mounts/*.env >/dev/null 2>&1; then
  say "next: omarchy-gdrive setup (or Omarchy menu → Google Drive → Set up)"
fi

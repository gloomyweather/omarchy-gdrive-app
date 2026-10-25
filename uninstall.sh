#!/bin/bash
# Removes omarchy-gdrive. Files in Google Drive are never touched.
#   --purge-config  also delete the Google login (rclone remote, keyring password)
#   --purge-cache   also delete the local cache (refused while uploads are pending)

set -euo pipefail

BIN="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-gdrive/bin/omarchy-gdrive"
[[ -x $BIN ]] || BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/omarchy-gdrive"
exec "$BIN" uninstall "$@"

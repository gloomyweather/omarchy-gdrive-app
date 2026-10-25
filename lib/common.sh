# shellcheck shell=bash
# Shared paths and helpers for omarchy-gdrive. Sourced by bin/omarchy-gdrive.

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

APP_DIR="$DATA_HOME/omarchy-gdrive"
BIN="$APP_DIR/bin/omarchy-gdrive"
CONF_DIR="$CONFIG_HOME/omarchy-gdrive"
CONF_FILE="$CONF_DIR/gdrive.conf"
MOUNTS_DIR="$CONF_DIR/mounts"
OFFLINE_CONF_DIR="$CONF_DIR/offline"
STATE_DIR="$STATE_HOME/omarchy-gdrive"
MNT_ROOT="$STATE_DIR/mnt"
CACHE_ROOT="$CACHE_HOME/omarchy-gdrive"
RUN_DIR="$RUNTIME_DIR/omarchy-gdrive"
RCLONE_CONFIG_FILE="$CONFIG_HOME/rclone/rclone.conf"

# The rclone config password lives in the Secret Service (gnome-keyring).
KEYRING_ATTRS=(service omarchy-gdrive kind rclone-config)
PASSWORD_CMD="secret-tool lookup ${KEYRING_ATTRS[*]}"

ICON_NAME="omarchy-gdrive"
GLYPH="󰊶"

say() { printf '\033[1m::\033[0m %s\n' "$*"; }
warn() { printf '\033[33m::\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m::\033[0m %s\n' "$*" >&2
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# Settings with defaults; the user file overrides them.
load_config() {
  REMOTE=gdrive
  LINK_DIR="$HOME/GoogleDrive"
  HOTKEY="SUPER + CTRL + G"
  VFS_CACHE_MAX_SIZE=10G
  VFS_CACHE_MAX_AGE=168h
  VFS_CACHE_MIN_FREE_SPACE=20G
  VFS_WRITE_BACK=5s
  DIR_CACHE_TIME=72h
  POLL_INTERVAL=1m
  VFS_REFRESH=true
  LOW_LEVEL_RETRIES=2
  CONTIMEOUT=15s
  TIMEOUT=2m
  EXPORT_FORMATS=link.html
  NAUTILUS_TRASH=false
  STOP_WAIT=60
  NOTIFY_CONNECTED=true
  LOG_LEVEL=NOTICE
  EXTRA_FLAGS=""
  OFFLINE_DIR="$HOME/GoogleDrive/Offline"
  OFFLINE_MAX_DELETE=25
  if [[ -f $CONF_FILE ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
  fi
  LINK_DIR="${LINK_DIR%/}"
  OFFLINE_DIR="${OFFLINE_DIR%/}"
}

# rclone with our encrypted config. Never prompts: a missing password fails.
rc_clone() {
  rclone --config "$RCLONE_CONFIG_FILE" --password-command "$PASSWORD_CMD" --ask-password=false "$@"
}

keyring_get() { secret-tool lookup "${KEYRING_ATTRS[@]}" 2>/dev/null; }

config_encrypted() {
  [[ -f $RCLONE_CONFIG_FILE ]] && grep -q '^RCLONE_ENCRYPT_V0:' "$RCLONE_CONFIG_FILE"
}

remote_configured() {
  [[ -f $RCLONE_CONFIG_FILE ]] || return 1
  rc_clone listremotes 2>/dev/null | grep -qxF "$REMOTE:"
}

# Mount names in display order: my drive, shared with me, then shared drives.
mount_names() {
  local f name rest=()
  [[ -d $MOUNTS_DIR ]] || return 0
  [[ -f $MOUNTS_DIR/mydrive.env ]] && echo mydrive
  [[ -f $MOUNTS_DIR/shared.env ]] && echo shared
  for f in "$MOUNTS_DIR"/*.env; do
    [[ -e $f ]] || continue
    name="$(basename "$f" .env)"
    [[ $name == mydrive || $name == shared ]] || rest+=("$name")
  done
  ((${#rest[@]})) && printf '%s\n' "${rest[@]}" | sort
  return 0
}

valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; }

# Loads one mount description into M_* variables.
load_mount() {
  local name="$1"
  valid_name "$name" || die "invalid mount name: $name"
  [[ -f $MOUNTS_DIR/$name.env ]] || die "no such mount: $name"
  M_LABEL="" M_KIND="" M_TEAM_DRIVE_ID="" M_BOOKMARK=""
  # shellcheck source=/dev/null
  source "$MOUNTS_DIR/$name.env"
  M_NAME="$name"
  M_MNT="$MNT_ROOT/$name"
  M_SOCK="$RUN_DIR/$name.sock"
  M_CACHE="$CACHE_ROOT/$name"
  M_LINK="$LINK_DIR/$(link_name "$M_LABEL")"
  M_UNIT="omarchy-gdrive@$name.service"
  M_STATE="$RUN_DIR/$name.json"
  M_FLAGS=()
  case "$M_KIND" in
    mydrive) ;;
    shared) M_FLAGS+=(--drive-shared-with-me) ;;
    teamdrive) M_FLAGS+=("--drive-team-drive=$M_TEAM_DRIVE_ID") ;;
    *) die "unknown mount type for $name: $M_KIND" ;;
  esac
}

# Writes a mount description. Values are %q-quoted, so any label is safe.
save_mount() {
  local name="$1" label="$2" kind="$3" team="${4:-}" bookmark="${5:-}"
  mkdir -p "$MOUNTS_DIR"
  {
    echo "# Created by omarchy-gdrive. To choose drives again: omarchy-gdrive setup --mounts"
    printf 'M_LABEL=%q\n' "$label"
    printf 'M_KIND=%q\n' "$kind"
    printf 'M_TEAM_DRIVE_ID=%q\n' "$team"
    printf 'M_BOOKMARK=%q\n' "$bookmark"
  } >"$MOUNTS_DIR/$name.env"
}

# File name for a link in LINK_DIR: no slashes, no leading dots.
link_name() {
  local s="${1//\//∕}"
  s="${s#"${s%%[!.]*}"}"
  [[ -n $s ]] || s="Google Drive"
  printf '%s' "$s"
}

# file:// URI for a path, each segment percent-encoded.
file_uri() {
  jq -rn --arg p "$1" '"file://" + ($p | split("/") | map(@uri) | join("/"))'
}

# POST to a mount's rc socket. Prints the JSON reply; fails if unreachable.
rc_call() {
  local sock="$1" method="$2" body="${3:-}"
  [[ -n $body ]] || body='{}'
  [[ -S $sock ]] || return 1
  curl -sS --fail-with-body --max-time "${RC_TIMEOUT:-5}" --unix-socket "$sock" \
    -H 'Content-Type: application/json' -d "$body" "http://localhost/$method" 2>/dev/null
}

unit_active() { systemctl --user is-active --quiet "$1"; }

# Desktop notification. Usage: notify [-u urgency] [-r id-file] [-A action=Label ...] title body
# With -r the previous notification from the same id-file is replaced.
notify() {
  local icon="$DATA_HOME/icons/hicolor/scalable/apps/$ICON_NAME.svg" idfile="" id args
  [[ -f $icon ]] || icon="$ICON_NAME"
  args=(-a "Google Drive" -i "$icon")
  while (($#)); do
    case "$1" in
      -u) args+=(-u "$2"); shift 2 ;;
      -r) idfile="$2"; shift 2 ;;
      -A) args+=(-A "$2"); shift 2 ;;
      -t) args+=(-t "$2"); shift 2 ;;
      *) break ;;
    esac
  done
  have notify-send || return 0
  if [[ -n $idfile ]]; then
    mkdir -p "$RUN_DIR"
    id="$(cat "$idfile" 2>/dev/null || true)"
    [[ $id =~ ^[0-9]+$ ]] && args+=(-r "$id")
    notify-send "${args[@]}" -p "$@" 2>/dev/null | head -n1 >"$idfile.tmp" && mv -f "$idfile.tmp" "$idfile"
  else
    notify-send "${args[@]}" "$@" 2>/dev/null || true
  fi
}

# True when Google answers. Cheap NetworkManager check first, then a real HTTPS request.
online() {
  local state
  if have nmcli; then
    state="$(nmcli -t -f STATE general 2>/dev/null || true)"
    [[ $state == disconnected || $state == asleep ]] && return 1
  fi
  curl -s --max-time 6 -o /dev/null "${OMARCHY_GDRIVE_PROBE_URL:-https://www.googleapis.com/}"
}

# Finds the mount that holds a path (via the link in LINK_DIR or the real
# mountpoint) and sets M_* plus REL, the path inside the drive.
resolve_path() {
  local path="$1" name root
  path="${path%/}"
  while read -r name; do
    load_mount "$name"
    for root in "$M_LINK" "$M_MNT"; do
      if [[ $path == "$root" ]]; then
        REL=""
        return 0
      elif [[ $path == "$root"/* ]]; then
        REL="${path#"$root"/}"
        return 0
      fi
    done
  done < <(mount_names)
  return 1
}

# State file the Nautilus extension reads (it must not touch the network).
write_mounts_json() {
  local name items=()
  mkdir -p "$STATE_DIR"
  while read -r name; do
    load_mount "$name"
    items+=("$(jq -cn --arg name "$name" --arg label "$M_LABEL" --arg kind "$M_KIND" \
      --arg mnt "$M_MNT" --arg link "$M_LINK" \
      '{name: $name, label: $label, kind: $kind, mountpoint: $mnt, link: $link}')")
  done < <(mount_names)
  printf '%s\n' "${items[@]}" | jq -s --arg bin "$BIN" --arg offline "$OFFLINE_DIR" \
    '{bin: $bin, offline_dir: $offline, mounts: map(select(. != null))}' >"$STATE_DIR/mounts.json.tmp"
  mv -f "$STATE_DIR/mounts.json.tmp" "$STATE_DIR/mounts.json"
}

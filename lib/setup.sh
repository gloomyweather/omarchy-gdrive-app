# shellcheck shell=bash
# Interactive setup: keyring password, encrypted rclone config, OAuth, mounts.

DEPS=(rclone fusermount3 secret-tool curl jq notify-send findmnt flock)
DEP_PKGS=(rclone fuse3 libsecret curl jq libnotify util-linux util-linux)

ask() { # ask "question" [default] -> prints answer
  local q="$1" def="${2:-}" reply
  if have gum; then
    gum input --prompt "$q " --value "$def"
  else
    read -r -p "$q [$def] " reply
    printf '%s' "${reply:-$def}"
  fi
}

ask_secret() {
  local q="$1" reply
  if have gum; then
    gum input --password --prompt "$q "
  else
    read -r -s -p "$q " reply
    echo >&2
    printf '%s' "$reply"
  fi
}

confirm() { # confirm "question" [yes|no default]
  local q="$1" def="${2:-yes}" reply
  if have gum; then
    if [[ $def == yes ]]; then gum confirm "$q"; else gum confirm --default=false "$q"; fi
  else
    read -r -p "$q [$([[ $def == yes ]] && echo Y/n || echo y/N)] " reply
    reply="${reply:-$([[ $def == yes ]] && echo y || echo n)}"
    [[ $reply == [yY]* ]]
  fi
}

require_tty() {
  [[ -t 0 && -t 1 ]] || die "this command is interactive, run it in a terminal"
}

check_deps() {
  local i missing=()
  for i in "${!DEPS[@]}"; do
    have "${DEPS[$i]}" || missing+=("${DEP_PKGS[$i]}")
  done
  ((${#missing[@]})) || return 0
  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  warn "missing packages: ${missing[*]}"
  if [[ -t 0 ]] && have omarchy-pkg-add && confirm "Install them now (needs sudo)?"; then
    omarchy-pkg-add "${missing[@]}"
  else
    die "install them: sudo pacman -S --needed ${missing[*]}"
  fi
}

ensure_conf() {
  mkdir -p "$CONF_DIR" "$MOUNTS_DIR"
  chmod 700 "$CONF_DIR"
  [[ -f $CONF_FILE ]] || install -m 644 "$APP_DIR/config/gdrive.conf.default" "$CONF_FILE"
}

ensure_keyring_password() {
  [[ -n $(keyring_get) ]] && return 0
  say "creating a password for rclone.conf encryption and storing it in the keyring"
  head -c 32 /dev/urandom | base64 -w0 |
    secret-tool store --label="omarchy-gdrive: rclone config password" "${KEYRING_ATTRS[@]}" ||
    die "could not write to the keyring (is gnome-keyring running?)"
  [[ -n $(keyring_get) ]] || die "the keyring did not return the stored password"
}

encrypt_config() {
  RCLONE_PASSWORD_CHANGE=1 rclone --config "$RCLONE_CONFIG_FILE" config encryption set \
    --password-command "$PASSWORD_CMD" >/dev/null || die "could not encrypt $RCLONE_CONFIG_FILE"
}

ensure_encrypted_config() {
  local others
  mkdir -p "$(dirname "$RCLONE_CONFIG_FILE")"
  chmod 700 "$(dirname "$RCLONE_CONFIG_FILE")"
  if [[ ! -s $RCLONE_CONFIG_FILE ]]; then
    (umask 077 && : >"$RCLONE_CONFIG_FILE")
    encrypt_config
  elif config_encrypted; then
    rc_clone config encryption check >/dev/null 2>&1 ||
      die "$RCLONE_CONFIG_FILE is encrypted with another password. Remove that encryption (rclone config encryption remove) and run setup again."
  else
    others="$(rclone --config "$RCLONE_CONFIG_FILE" listremotes 2>/dev/null | grep -vxF "$REMOTE:" | paste -sd' ' || true)"
    if [[ -n $others ]]; then
      warn "$RCLONE_CONFIG_FILE has other remotes: $others"
      warn "the whole file will be encrypted; run rclone from a terminal as: omarchy-gdrive rclone ..."
      confirm "Encrypt rclone.conf?" || die "cancelled"
    fi
    encrypt_config
  fi
  chmod 600 "$RCLONE_CONFIG_FILE"
}

create_remote() {
  local id secret
  cat <<'EOF'

You need your own Google OAuth client ID (rclone's shared one is being retired in 2026).
Step-by-step guide: https://github.com/gloomyweather/omarchy-gdrive-app/blob/main/OAUTH.md
  (~/.local/share/omarchy-gdrive/README.md)

EOF
  while :; do
    id="$(ask "Client ID:")"
    [[ $id =~ ^[0-9]+-[A-Za-z0-9_]+\.apps\.googleusercontent\.com$ ]] && break
    warn "that does not look like a client ID (...apps.googleusercontent.com)"
  done
  secret="$(ask_secret "Client secret:")"
  [[ -n $secret ]] || die "empty client secret"
  say "a browser opens now: sign in to Google and allow access"
  rc_clone config delete "$REMOTE" >/dev/null 2>&1 || true
  rc_clone config create "$REMOTE" drive client_id="$id" client_secret="$secret" scope=drive >/dev/null ||
    die "could not sign in to Google"
}

verify_remote() {
  local about total msg
  about="$(rc_clone about "$REMOTE:" --json 2>&1)" || die "Google Drive does not answer: $about"
  msg="signed in. Used $(human "$(jq -r '.used // 0' <<<"$about")")"
  total="$(jq -r '.total // empty' <<<"$about")"
  [[ -n $total ]] && msg+=" of $(human "$total")"
  say "$msg"
}

slugify() {
  local s
  s="$(printf '%s' "$1" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//' | cut -c1-30)"
  printf '%s' "$s"
}

# Name for a shared drive mount: reuse an existing one with the same ID.
teamdrive_name() {
  local id="$1" label="$2" f base name n=2
  for f in "$MOUNTS_DIR"/td-*.env; do
    [[ -e $f ]] || continue
    if grep -qxF "M_TEAM_DRIVE_ID=$(printf '%q' "$id")" "$f"; then
      basename "$f" .env
      return 0
    fi
  done
  base="$(slugify "$label")"
  [[ -n $base ]] || base="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-10)"
  name="td-$base"
  while [[ -e $MOUNTS_DIR/$name.env ]]; do
    name="td-$base-$n"
    n=$((n + 1))
  done
  printf '%s' "$name"
}

remove_mount() {
  local name="$1"
  load_mount "$name"
  systemctl --user disable --now "$M_UNIT" >/dev/null 2>&1 || true
  [[ -L $M_LINK ]] && rm -f "$M_LINK"
  rm -f "$MOUNTS_DIR/$name.env" "$RUN_DIR/$name.json" "$RUN_DIR/$name.notified"
  is_mounted "$M_MNT" || rmdir "$M_MNT" 2>/dev/null || true
  say "removed: $M_LABEL"
}

choose_mounts() {
  local drives count i id label chosen=() keep=() selected name existing
  save_mount mydrive "My Drive" mydrive "" "Google Drive"
  keep+=(mydrive)

  if confirm "Connect \"Shared with me\" (files others shared with you)?"; then
    save_mount shared "Shared with me" shared "" "Shared with me"
    keep+=(shared)
  fi

  say "looking for shared drives..."
  drives="$(rc_clone backend drives "$REMOTE:" 2>/dev/null || echo '[]')"
  count="$(jq 'length' <<<"$drives")"
  if ((count > 0)); then
    local labels=()
    for ((i = 0; i < count; i++)); do labels+=("$(jq -r ".[$i].name" <<<"$drives")"); done
    if have gum; then
      mapfile -t chosen < <(gum choose --no-limit --selected="$(IFS=,; echo "${labels[*]}")" \
        --header "Which shared drives to connect? (space: select, enter: done)" "${labels[@]}")
    else
      for label in "${labels[@]}"; do
        confirm "Connect shared drive \"$label\"?" && chosen+=("$label")
      done
    fi
    for selected in "${chosen[@]}"; do
      for ((i = 0; i < count; i++)); do
        [[ $(jq -r ".[$i].name" <<<"$drives") == "$selected" ]] || continue
        id="$(jq -r ".[$i].id" <<<"$drives")"
        name="$(teamdrive_name "$id" "$selected")"
        save_mount "$name" "$selected" teamdrive "$id" "$selected"
        keep+=("$name")
      done
    done
  else
    say "no shared drives"
  fi

  # Drop mounts that were not chosen this time.
  while read -r existing; do
    printf '%s\n' "${keep[@]}" | grep -qxF "$existing" || remove_mount "$existing"
  done < <(mount_names)
}

wait_connected() {
  local i state
  say "connecting..."
  for ((i = 0; i < 60; i++)); do
    state="$(status_json | jq -r .state)"
    [[ $state == connected || $state == syncing || $state == error ]] && break
    sleep 1
  done
  cmd_status
}

cmd_setup() {
  local mode="${1:-}" choice
  require_tty
  check_deps
  load_config
  ensure_conf
  load_config
  ensure_keyring_password
  ensure_encrypted_config

  if [[ $mode != --mounts ]]; then
    if remote_configured; then
      choice="$(if have gum; then
        gum choose --header "Google sign-in is already set up ($REMOTE:)" "Keep it" "Sign in again" "Replace the client ID"
      else
        echo "Keep it"
      fi)"
      case "$choice" in
        "Sign in again") cmd_reconnect --no-start ;;
        "Replace the client ID") create_remote ;;
      esac
    else
      create_remote
    fi
    verify_remote
  fi

  choose_mounts
  integrate_mounts
  cmd_connect
  wait_connected
  cat <<EOF

Done. Google Drive: $LINK_DIR (and bookmarks in Files).
Open: Super+Ctrl+G · Menu: Omarchy → Google Drive · Settings: $CONF_FILE
EOF
}

cmd_reconnect() {
  local units
  require_tty
  load_config
  remote_configured || die "Google Drive is not set up yet. Run: omarchy-gdrive setup"
  mapfile -t units < <(all_units)
  # Running mounts would write their old token back over the new one.
  ((${#units[@]})) && systemctl --user stop "${units[@]}" 2>/dev/null || true
  say "a browser opens now: sign in to Google and allow access"
  rc_clone config reconnect "$REMOTE:" || die "could not sign in again"
  verify_remote
  rm -f "$RUN_DIR"/*.notified
  [[ ${1:-} == --no-start ]] && return 0
  cmd_connect
  wait_connected
}

# shellcheck shell=bash
# Hooks omarchy-gdrive into the desktop and takes it out again.
# Every step is idempotent: running it twice changes nothing the second time.

UNIT_DIR="$CONFIG_HOME/systemd/user"
PLUGIN_ID="gdrive.status"
PLUGIN_DIR="$CONFIG_HOME/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$CONFIG_HOME/omarchy/shell.json"
MENU_FILE="$CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc"
BINDINGS_FILE="$CONFIG_HOME/hypr/bindings.lua"
HOOKS_DIR="$CONFIG_HOME/omarchy/hooks"
NAUTILUS_EXT="$DATA_HOME/nautilus-python/extensions/omarchy_gdrive.py"
DESKTOP_FILE="$DATA_HOME/applications/omarchy-gdrive.desktop"
ICON_FILE="$DATA_HOME/icons/hicolor/scalable/apps/$ICON_NAME.svg"
BOOKMARKS_FILE="$CONFIG_HOME/gtk-3.0/bookmarks"
BOOKMARKS_STATE="$STATE_DIR/bookmarks"
LOCAL_BIN="$HOME/.local/bin/omarchy-gdrive"
UNITS=(omarchy-gdrive@.service omarchy-gdrive-failed@.service omarchy-gdrive-check.service omarchy-gdrive-check.timer
  omarchy-gdrive-offline.service omarchy-gdrive-offline.timer)

QUIET=0
info() { ((QUIET)) || say "$@"; }

# Replace the block between "<comment> >>> omarchy-gdrive >>>" markers.
# mode "append" adds it at the end, "after-brace" right after the first "{"
# line (JSONC: our entries end with commas, so nothing after them breaks).
put_block() {
  local file="$1" comment="$2" body="$3" mode="${4:-append}" tmp
  local begin="$comment >>> omarchy-gdrive >>>" end="$comment <<< omarchy-gdrive <<<"
  tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$file" >"$tmp"
  if [[ $mode == append ]]; then
    sed -i -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' "$tmp"
    [[ -n $body ]] && printf '\n%s\n%s\n%s\n' "$begin" "$body" "$end" >>"$tmp"
  elif [[ -n $body ]]; then
    # Body via ENVIRON: awk -v would eat backslashes.
    BLOCK="$body" awk -v b="$begin" -v e="$end" '
      !done && $0 ~ /^[[:space:]]*\{[[:space:]]*$/ { print; print b; print ENVIRON["BLOCK"]; print e; done = 1; next }
      { print }
    ' "$tmp" >"$tmp.2" && mv -f "$tmp.2" "$tmp"
  fi
  if ! cmp -s "$tmp" "$file"; then
    cat "$tmp" >"$file" # in place: keeps symlinks and permissions
  fi
  rm -f "$tmp"
}

has_block() { grep -qF -e "$2 >>> omarchy-gdrive >>>" "$1" 2>/dev/null; }

backup_once() {
  [[ -f $1 && ! -e $1.bak.omarchy-gdrive ]] && cp -p "$1" "$1.bak.omarchy-gdrive"
  return 0
}

shell_running() { have omarchy-shell && [[ $(omarchy-shell shell ping 2>/dev/null) == ok ]]; }

# --- pieces -----------------------------------------------------------------

install_cli_link() {
  local found
  mkdir -p "$(dirname "$LOCAL_BIN")"
  ln -sfn "$BIN" "$LOCAL_BIN"
  found="$(command -v omarchy-gdrive 2>/dev/null || true)"
  if [[ -n $found && $(readlink -f "$found") != "$(readlink -f "$BIN")" ]]; then
    warn "another omarchy-gdrive comes first in PATH: $found"
    warn "the menu, bar and hotkey use this one by full path, but a terminal will run that one"
  fi
}

install_units() {
  local u changed=0
  mkdir -p "$UNIT_DIR"
  for u in "${UNITS[@]}"; do
    if ! cmp -s "$APP_DIR/systemd/$u" "$UNIT_DIR/$u"; then
      install -m 644 "$APP_DIR/systemd/$u" "$UNIT_DIR/$u"
      changed=1
    fi
  done
  systemctl --user daemon-reload
  systemctl --user enable --now omarchy-gdrive-check.timer omarchy-gdrive-offline.timer >/dev/null 2>&1 || true
  ((changed)) && info "systemd: units updated"
  return 0
}

install_plugin() {
  local placed
  mkdir -p "$PLUGIN_DIR"
  cp -r "$APP_DIR/shell-plugin/$PLUGIN_ID/." "$PLUGIN_DIR/"
  placed="$(jq -r --arg id "$PLUGIN_ID" '[.. | objects | select(.id? == $id)] | length' "$SHELL_JSON" 2>/dev/null || echo 0)"
  if ((placed > 0)); then
    return 0
  fi
  if ! shell_running; then
    warn "the Omarchy shell is not running: the bar widget is added on the next omarchy-gdrive repair"
    return 0
  fi
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  sleep 1
  if omarchy-plugin-enable "$PLUGIN_ID" --section right --after omarchy.tray >/dev/null 2>&1 ||
    omarchy-plugin-enable "$PLUGIN_ID" --section right >/dev/null 2>&1; then
    info "bar: Google Drive indicator added"
  else
    warn "could not add the bar indicator, try: omarchy plugin enable $PLUGIN_ID"
  fi
}

install_nautilus() {
  mkdir -p "$(dirname "$NAUTILUS_EXT")"
  if ! cmp -s "$APP_DIR/nautilus/omarchy_gdrive.py" "$NAUTILUS_EXT"; then
    install -m 644 "$APP_DIR/nautilus/omarchy_gdrive.py" "$NAUTILUS_EXT"
    info "Files: extension installed (restart Files: nautilus -q)"
  fi
}

menu_block() {
  local term="omarchy-launch-floating-terminal-with-presentation"
  cat <<EOF
  "gdrive": {"icon":"$GLYPH","label":"Google Drive","aliases":["gdrive","google-drive"]},
  "gdrive.open": {"icon":"󰝰","label":"Open","when":"[[ -d '$MOUNTS_DIR' ]]","action":"$BIN open"},
  "gdrive.connect": {"icon":"󰌘","label":"Connect","when":"[[ -d '$MOUNTS_DIR' ]] && ! $BIN _any-active","action":"$BIN connect"},
  "gdrive.disconnect": {"icon":"󰌙","label":"Disconnect","when":"$BIN _any-active","action":"$BIN disconnect"},
  "gdrive.status": {"icon":"󰋽","label":"Status","action":"$term '$BIN status'"},
  "gdrive.offline": {"icon":"󰲁","label":"Offline folders","when":"[[ -n \$(ls -A '$OFFLINE_CONF_DIR' 2>/dev/null) ]]"},
  "gdrive.offline.sync": {"icon":"󰑐","label":"Sync now","action":"$BIN offline sync"},
  "gdrive.offline.resync": {"icon":"󰑓","label":"Resync","when":"$BIN _offline-locked","action":"$term '$BIN offline resync'"},
  "gdrive.offline.list": {"icon":"󰉹","label":"List","action":"$term '$BIN offline list'"},
  "gdrive.reconnect": {"icon":"󰌆","label":"Sign in again","when":"[[ -d '$MOUNTS_DIR' ]]","action":"$term '$BIN reconnect'"},
  "gdrive.setup": {"icon":"󰒓","label":"Set up","action":"$term '$BIN setup'"},
  "gdrive.settings": {"icon":"󰘮","label":"Settings","when":"[[ -f '$CONF_FILE' ]]","action":"omarchy-launch-config-editor '$CONF_FILE'"},
  "gdrive.logs": {"icon":"󰧮","label":"Log","action":"$term '$BIN logs'"},
  "gdrive.repair": {"icon":"󰁨","label":"Repair","action":"$BIN repair --notify"},
EOF
  # Extension rows always follow the default ones, so keep System last by
  # hiding the default row and re-adding it as a link after Google Drive.
  # The hidden id still opens via `omarchy menu summon system`.
  [[ ${MENU_SYSTEM_LAST:-false} == true ]] || return 0
  local sys_icon
  sys_icon="$(grep -o '"system": *{"icon":"[^"]*"' "${OMARCHY_PATH:-/usr/share/omarchy}/default/omarchy/omarchy-menu.jsonc" 2>/dev/null |
    sed 's/.*"icon":"//; s/"$//')"
  [[ -n $sys_icon ]] || return 0
  cat <<EOF
  "system": {"when":"false"},
  "gdrive-system": {"icon":"$sys_icon","label":"System","target":"system"},
EOF
}

install_menu() {
  [[ -f $MENU_FILE ]] || {
    mkdir -p "$(dirname "$MENU_FILE")"
    printf '{\n}\n' >"$MENU_FILE"
  }
  backup_once "$MENU_FILE"
  put_block "$MENU_FILE" "//" "$(menu_block)" after-brace
}

install_binding() {
  local keys line taken
  [[ -f $BINDINGS_FILE ]] || {
    warn "no $BINDINGS_FILE, hotkey not added"
    return 0
  }
  keys="${HOTKEY-SUPER + CTRL + G}"
  if [[ -z $keys ]]; then
    put_block "$BINDINGS_FILE" "--" ""
    return 0
  fi
  # Refuse to steal a key Omarchy or the user already uses for something else.
  if have omarchy-menu-keybindings; then
    taken="$(omarchy-menu-keybindings --print 2>/dev/null |
      awk -v k="$(tr -d ' +' <<<"$keys")" '{ split($0, p, "→"); key = p[1]; gsub(/[ +]/, "", key); if (key == k && p[2] !~ /Google Drive/) print p[2] }' | head -n1)"
    if [[ -n $taken ]]; then
      warn "$keys is already taken by:$taken. Skipped (change HOTKEY in $CONF_FILE)"
      return 0
    fi
  fi
  line="o.bind(\"$keys\", \"Google Drive\", \"$BIN open\")"
  grep -qxF "$line" "$BINDINGS_FILE" && return 0
  backup_once "$BINDINGS_FILE"
  local hypr=0 before after
  have hyprctl && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && hypr=1
  ((hypr)) && before="$(hyprctl configerrors 2>/dev/null || true)"
  put_block "$BINDINGS_FILE" "--" "$line"
  if ((hypr)); then
    hyprctl reload >/dev/null 2>&1 || true
    after="$(hyprctl configerrors 2>/dev/null || true)"
    if [[ $after != "$before" ]]; then
      warn "Hyprland reported an error after adding the hotkey, removing it:"
      printf '%s\n' "$after" >&2
      put_block "$BINDINGS_FILE" "--" ""
      hyprctl reload >/dev/null 2>&1 || true
      return 0
    fi
  fi
  info "Hyprland: $keys opens Google Drive"
}

theme_icon() {
  local colors="$STATE_HOME/omarchy/current/theme/colors.toml" accent
  [[ -f $ICON_FILE && -f $colors ]] || return 0
  accent="$(sed -nE 's/^accent[[:space:]]*=[[:space:]]*"(#[0-9a-fA-F]{6})".*/\1/p' "$colors" | head -n1)"
  [[ -n $accent ]] && sed -i -E "s/fill=\"#[0-9a-fA-F]{3,8}\"/fill=\"$accent\"/" "$ICON_FILE"
  touch "$DATA_HOME/icons/hicolor"
  gtk-update-icon-cache -q -t -f "$DATA_HOME/icons/hicolor" >/dev/null 2>&1 || true
}

install_desktop() {
  mkdir -p "$(dirname "$ICON_FILE")" "$(dirname "$DESKTOP_FILE")"
  [[ -f $ICON_FILE ]] || install -m 644 "$APP_DIR/share/omarchy-gdrive.svg" "$ICON_FILE"
  theme_icon
  sed "s|@BIN@|$BIN|g" "$APP_DIR/share/omarchy-gdrive.desktop" >"$DESKTOP_FILE.tmp"
  if cmp -s "$DESKTOP_FILE.tmp" "$DESKTOP_FILE"; then
    rm -f "$DESKTOP_FILE.tmp"
  else
    mv -f "$DESKTOP_FILE.tmp" "$DESKTOP_FILE"
    update-desktop-database -q "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
    info "launcher: Google Drive added"
  fi
}

install_hooks() {
  mkdir -p "$HOOKS_DIR/post-update.d" "$HOOKS_DIR/theme-set.d"
  printf '#!/bin/bash\n# Re-applies omarchy-gdrive integration after omarchy update.\n[[ -x %q ]] && %q repair --quiet\nexit 0\n' "$BIN" "$BIN" \
    >"$HOOKS_DIR/post-update.d/omarchy-gdrive"
  printf '#!/bin/bash\n# Recolors the omarchy-gdrive icon for the new theme.\n[[ -x %q ]] && %q _theme\nexit 0\n' "$BIN" "$BIN" \
    >"$HOOKS_DIR/theme-set.d/omarchy-gdrive"
  chmod 755 "$HOOKS_DIR/post-update.d/omarchy-gdrive" "$HOOKS_DIR/theme-set.d/omarchy-gdrive"
}

# Links in LINK_DIR, Nautilus bookmarks and the state file for the extension.
integrate_mounts() {
  local name target lines=() old=() current=() f
  load_config
  mkdir -p "$MNT_ROOT"
  while read -r name; do
    load_mount "$name"
    [[ -d $M_MNT ]] || lock_mountpoint "$M_MNT"
    mkdir -p "$LINK_DIR"
    if [[ -L $M_LINK || ! -e $M_LINK ]]; then
      [[ $(readlink "$M_LINK" 2>/dev/null) == "$M_MNT" ]] || ln -sfn "$M_MNT" "$M_LINK"
    else
      warn "$M_LINK exists and is not a link, skipped"
    fi
    lines+=("$(file_uri "$M_LINK") ${M_BOOKMARK:-$M_LABEL}")
    current+=("$M_LINK")
  done < <(mount_names)

  # Our links that are no longer current (mount removed or renamed).
  for f in "$LINK_DIR"/*; do
    [[ -L $f ]] || continue
    target="$(readlink "$f")"
    [[ $target == "$MNT_ROOT"/* ]] || continue
    printf '%s\n' "${current[@]}" | grep -qxF "$f" || rm -f "$f"
  done

  # Bookmarks: drop the lines we added last time, add the current ones.
  mkdir -p "$(dirname "$BOOKMARKS_FILE")" "$STATE_DIR"
  touch "$BOOKMARKS_FILE"
  [[ -f $BOOKMARKS_STATE ]] && mapfile -t old <"$BOOKMARKS_STATE"
  {
    grep -vxF -f <(printf '%s\n' "${old[@]}" "${lines[@]}" | grep -v '^$') "$BOOKMARKS_FILE" || true
    ((${#lines[@]})) && printf '%s\n' "${lines[@]}"
  } >"$BOOKMARKS_FILE.tmp"
  if cmp -s "$BOOKMARKS_FILE.tmp" "$BOOKMARKS_FILE"; then
    rm -f "$BOOKMARKS_FILE.tmp"
  else
    cat "$BOOKMARKS_FILE.tmp" >"$BOOKMARKS_FILE"
    rm -f "$BOOKMARKS_FILE.tmp"
    info "Files: bookmarks updated"
  fi
  if ((${#lines[@]})); then printf '%s\n' "${lines[@]}" >"$BOOKMARKS_STATE"; else rm -f "$BOOKMARKS_STATE"; fi
  write_mounts_json
}

# --- commands ---------------------------------------------------------------

cmd_install() {
  local notify_done=0
  while (($#)); do
    case "$1" in
      --quiet) QUIET=1 ;;
      --notify) notify_done=1 QUIET=1 ;;
    esac
    shift
  done
  load_config
  [[ -f $CONF_FILE ]] || ensure_conf
  load_config
  install_cli_link
  install_units
  install_nautilus
  install_desktop
  install_hooks
  install_menu
  install_binding
  install_plugin
  [[ -n $(mount_names) ]] && integrate_mounts
  if [[ -f $CONF_DIR/reconnect-after-install ]]; then
    local reconnect
    mapfile -t reconnect <"$CONF_DIR/reconnect-after-install"
    rm -f "$CONF_DIR/reconnect-after-install"
    if ((${#reconnect[@]})); then
      systemctl --user enable --now --no-block "${reconnect[@]}" >/dev/null 2>&1 || true
      info "connecting again: ${reconnect[*]}"
    fi
  fi
  info "done"
  if ((notify_done)); then notify "Google Drive" "Integration checked and restored."; fi
  return 0
}

cmd_uninstall() {
  local purge_config=0 purge_cache=0 name units=() dirty u
  while (($#)); do
    case "$1" in
      --purge-config) purge_config=1 ;;
      --purge-cache) purge_cache=1 ;;
      -h | --help)
        echo "usage: omarchy-gdrive uninstall [--purge-config] [--purge-cache]"
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
    shift
  done
  load_config

  if ((purge_cache)); then
    dirty="$(grep -rlE '"Dirty": ?true' "$CACHE_ROOT"/*/vfsMeta 2>/dev/null | head -n3 || true)"
    [[ -z $dirty ]] || die "the cache holds files that are not uploaded yet, keeping it. Connect, wait for the uploads, then try again."
  fi

  say "stopping Google Drive (pending uploads finish first if online)"
  mapfile -t units < <(all_units)
  # Remember what was connected, so a reinstall without --purge-config
  # brings exactly that back.
  if ((!purge_config)) && [[ -d $CONF_DIR ]]; then
    for u in "${units[@]}"; do
      systemctl --user is-enabled --quiet "$u" 2>/dev/null && echo "$u"
    done >"$CONF_DIR/reconnect-after-install"
  fi
  ((${#units[@]})) && { systemctl --user disable --now "${units[@]}" >/dev/null 2>&1 || true; }
  systemctl --user disable --now omarchy-gdrive-check.timer omarchy-gdrive-offline.timer >/dev/null 2>&1 || true
  systemctl --user stop omarchy-gdrive-check.service omarchy-gdrive-offline.service >/dev/null 2>&1 || true
  while read -r name; do
    load_mount "$name"
    is_mounted "$M_MNT" && { fusermount3 -uz "$M_MNT" 2>/dev/null || true; }
  done < <(mount_names)
  for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
  systemctl --user daemon-reload
  systemctl --user reset-failed 'omarchy-gdrive*' >/dev/null 2>&1 || true

  if [[ -d $PLUGIN_DIR ]]; then
    shell_running && { omarchy-plugin-disable "$PLUGIN_ID" >/dev/null 2>&1 || true; }
    rm -rf "$PLUGIN_DIR"
    shell_running && { omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true; }
  fi
  [[ -f $MENU_FILE ]] && put_block "$MENU_FILE" "//" "" after-brace
  if [[ -f $BINDINGS_FILE ]] && has_block "$BINDINGS_FILE" "--"; then
    put_block "$BINDINGS_FILE" "--" ""
    have hyprctl && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && { hyprctl reload >/dev/null 2>&1 || true; }
  fi
  rm -f "$NAUTILUS_EXT" "$DESKTOP_FILE" "$ICON_FILE" \
    "$HOOKS_DIR/post-update.d/omarchy-gdrive" "$HOOKS_DIR/theme-set.d/omarchy-gdrive"
  update-desktop-database -q "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
  gtk-update-icon-cache -q -t -f "$DATA_HOME/icons/hicolor" >/dev/null 2>&1 || true

  # Bookmarks and links we made; mountpoints only if empty and unmounted.
  if [[ -f $BOOKMARKS_STATE && -f $BOOKMARKS_FILE ]]; then
    grep -vxF -f "$BOOKMARKS_STATE" "$BOOKMARKS_FILE" >"$BOOKMARKS_FILE.tmp" || true
    cat "$BOOKMARKS_FILE.tmp" >"$BOOKMARKS_FILE"
    rm -f "$BOOKMARKS_FILE.tmp" "$BOOKMARKS_STATE"
  fi
  local f
  for f in "$LINK_DIR"/*; do
    [[ -L $f && $(readlink "$f") == "$MNT_ROOT"/* ]] && rm -f "$f"
  done
  while read -r name; do
    load_mount "$name"
    is_mounted "$M_MNT" || rmdir "$M_MNT" 2>/dev/null || true
  done < <(mount_names)
  rmdir "$MNT_ROOT" 2>/dev/null || true
  rm -rf "$STATE_DIR/bisync" "$RUN_DIR"
  rm -f "$STATE_DIR/mounts.json" "$STATE_DIR/offline.json" "$STATE_DIR/offline-list.json" "$STATE_DIR/offline.lock"
  rmdir "$STATE_DIR" 2>/dev/null || true
  rmdir "$LINK_DIR" 2>/dev/null || true
  [[ -d $OFFLINE_DIR ]] && say "offline copies are kept: $OFFLINE_DIR"

  if ((purge_cache)); then
    rm -rf "$CACHE_ROOT"
    say "cache deleted"
  fi
  if ((purge_config)); then
    if [[ -f $RCLONE_CONFIG_FILE ]]; then
      rc_clone config delete "$REMOTE" >/dev/null 2>&1 || true
      if [[ -z $(rc_clone listremotes 2>/dev/null) ]]; then
        rm -f "$RCLONE_CONFIG_FILE"
        rmdir "$(dirname "$RCLONE_CONFIG_FILE")" 2>/dev/null || true
      elif config_encrypted; then
        # Other remotes stay, unencrypted as they were before setup.
        rc_clone config encryption remove >/dev/null 2>&1 || warn "could not remove the encryption of $RCLONE_CONFIG_FILE"
      fi
    fi
    secret-tool clear "${KEYRING_ATTRS[@]}" 2>/dev/null || true
    rm -rf "$CONF_DIR"
    say "config and Google sign-in deleted (revoke the app access at myaccount.google.com/permissions)"
  else
    say "settings and sign-in kept: $CONF_DIR, $RCLONE_CONFIG_FILE (delete with --purge-config)"
  fi

  rm -f "$LOCAL_BIN"
  [[ $APP_DIR == "$DATA_HOME/omarchy-gdrive" ]] && rm -rf "$APP_DIR"
  say "omarchy-gdrive removed. Your Google Drive files are untouched. Restart Files: nautilus -q"
}

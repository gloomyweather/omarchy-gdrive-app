# shellcheck shell=bash
# Offline folders: a local copy kept in sync both ways with rclone bisync.
#
# rclone's VFS cache cannot pin files, so "offline" is a separate local
# folder in OFFLINE_DIR, synced every 15 minutes and when the network returns.

OFFLINE_STATE="$STATE_DIR/offline.json"
BISYNC_DIR="$STATE_DIR/bisync"

offline_ids() {
  local f
  for f in "$OFFLINE_CONF_DIR"/*.env; do
    [[ -e $f ]] && basename "$f" .env
  done
  return 0
}

load_offline() {
  O_MOUNT="" O_REL="" O_LOCAL=""
  [[ -f $OFFLINE_CONF_DIR/$1.env ]] || die "no such offline folder: $1"
  # shellcheck source=/dev/null
  source "$OFFLINE_CONF_DIR/$1.env"
  O_ID="$1"
}

offline_status() { jq -r --arg id "$1" '.[$id].status // "new"' "$OFFLINE_STATE" 2>/dev/null || echo new; }

offline_set_status() {
  local id="$1" status="$2" message="${3:-}"
  mkdir -p "$STATE_DIR"
  [[ -s $OFFLINE_STATE ]] || echo '{}' >"$OFFLINE_STATE"
  jq --arg id "$id" --arg s "$status" --arg m "${message:0:300}" --arg t "$(date +%s)" \
    '.[$id] = ((.[$id] // {}) + {status: $s, message: $m, time: ($t | tonumber)})' \
    "$OFFLINE_STATE" >"$OFFLINE_STATE.tmp" && mv -f "$OFFLINE_STATE.tmp" "$OFFLINE_STATE"
}

# Publishes the list for the Nautilus extension and the menu.
offline_publish() {
  local id items=()
  mkdir -p "$STATE_DIR"
  [[ -s $OFFLINE_STATE ]] || echo '{}' >"$OFFLINE_STATE"
  while read -r id; do
    [[ -n $id ]] || continue
    load_offline "$id"
    load_mount "$O_MOUNT"
    items+=("$(jq -cn --arg id "$id" --arg local "$O_LOCAL" --arg drive "$M_LINK/$O_REL" \
      --arg mnt "$M_MNT/$O_REL" --arg mount "$O_MOUNT" --arg rel "$O_REL" \
      '{id: $id, local: $local, drive: $drive, mountpath: $mnt, mount: $mount, rel: $rel}')")
  done < <(offline_ids)
  printf '%s\n' "${items[@]}" | jq -s --slurpfile st "$OFFLINE_STATE" \
    'map(select(. != null) | . + {status: ($st[0][.id].status // "new")})' >"$STATE_DIR/offline-list.json.tmp"
  mv -f "$STATE_DIR/offline-list.json.tmp" "$STATE_DIR/offline-list.json"
}

offline_summary() {
  local n locked=0 errors=0 id s
  n="$(offline_ids | wc -l)"
  ((n > 0)) || return 0
  while read -r id; do
    s="$(offline_status "$id")"
    [[ $s == locked ]] && locked=$((locked + 1))
    [[ $s == error ]] && errors=$((errors + 1))
  done < <(offline_ids)
  if ((locked)); then
    echo "Offline folders: $n, need resync: $locked"
  elif ((errors)); then
    echo "Offline folders: $n, sync errors: $errors"
  else
    echo "Offline folders: $n"
  fi
}

# Finds the offline record for a path (the local copy or the folder in Drive).
offline_find() {
  local path="${1%/}" id
  while read -r id; do
    [[ -n $id ]] || continue
    load_offline "$id"
    [[ $path == "$O_LOCAL" ]] && return 0
    if resolve_path "$path" 2>/dev/null && [[ $M_NAME == "$O_MOUNT" && $REL == "$O_REL" ]]; then
      return 0
    fi
  done < <(offline_ids)
  return 1
}

run_bisync() {
  local id="$1" resync="${2:-}" force="${3:-}" args out code
  load_offline "$id"
  load_mount "$O_MOUNT"
  mkdir -p "$BISYNC_DIR/$id" "$O_LOCAL" "$OFFLINE_DIR/.backup"
  args=(
    bisync "$REMOTE:$O_REL" "$O_LOCAL"
    "${M_FLAGS[@]}"
    --workdir "$BISYNC_DIR/$id"
    --resilient --recover --max-lock 5m
    --conflict-resolve newer --conflict-loser num --conflict-suffix conflict
    --max-delete "$OFFLINE_MAX_DELETE"
    --create-empty-src-dirs
    --compare size,modtime
    --drive-skip-gdocs
    --backup-dir2 "$OFFLINE_DIR/.backup/$id"
    --log-level INFO --color NEVER
  )
  # First run (no listings yet) or an explicit recovery.
  if [[ -n $resync || -z $(ls -A "$BISYNC_DIR/$id" 2>/dev/null) ]]; then
    args+=(--resync --resync-mode newer)
  fi
  [[ -n $force ]] && args+=(--force)
  set +e
  out="$(rc_clone "${args[@]}" 2>&1)"
  code=$?
  # "All files were changed" is a safety stop, not a lockout. In a small
  # folder it just means every file was edited. Go ahead only if nothing would
  # be deleted on either side (--force also lifts --max-delete).
  if ((code != 0)) && grep -q 'all files were changed' <<<"$out" &&
    [[ $(deletions "$out") == 0 ]] && ! grep -qi 'must run --resync' <<<"$out"; then
    out="$(rc_clone "${args[@]}" --force 2>&1)"
    code=$?
  fi
  set -e
  printf '%s\n' "$out" | grep -E 'NOTICE|ERROR' | tail -n 20
  if ((code == 0)); then
    offline_set_status "$id" ok
  elif ((code == 7)) || grep -qi 'must run --resync' <<<"$out"; then
    offline_set_status "$id" locked "$(grep -iE 'error|critical' <<<"$out" | tail -n1)"
  else
    offline_set_status "$id" error "$(grep -E 'ERROR' <<<"$out" | tail -n1)"
  fi
  return "$code"
}

# Sum of "N deleted" from bisync's per-path change summaries.
deletions() {
  grep -oE 'Path[12]: +[0-9]+ changes:.*' <<<"$1" | grep -oE '[0-9]+ deleted' | awk '{ s += $1 } END { print s + 0 }'
}

# Timer entry point: sync everything, quietly.
cmd__offline-sync() {
  local id before after
  load_config
  [[ -n $(offline_ids) ]] || return 0
  online || return 0
  exec 8>"$STATE_DIR/offline.lock"
  flock -n 8 || return 0
  while read -r id; do
    load_offline "$id"
    before="$(offline_status "$id")"
    run_bisync "$id" >/dev/null 2>&1 || true
    after="$(offline_status "$id")"
    if [[ $before == new && $after == ok ]]; then
      notify "Available offline" "\"$(basename "$O_LOCAL")\": $O_LOCAL"
    elif [[ $after == locked && $before != locked ]]; then
      notify -u critical "Offline folder stopped" \
        "\"$(basename "$O_LOCAL")\": sync is locked after an error. Google Drive menu → Offline folders → Resync."
    elif [[ $after == error && $before != error ]]; then
      if jq -e --arg id "$id" '.[$id].message | test("too many deletes")' "$OFFLINE_STATE" >/dev/null 2>&1; then
        notify -u critical "Offline folder: many deletions" \
          "\"$(basename "$O_LOCAL")\": more than $OFFLINE_MAX_DELETE% of the files were deleted, sync stopped. Get them back: Google Drive menu → Offline folders → Resync. Delete them in the cloud too: omarchy-gdrive offline sync --force"
      else
        notify "Offline folder: error" "\"$(basename "$O_LOCAL")\": will retry in 15 minutes. Details: omarchy-gdrive offline list"
      fi
    fi
  done < <(offline_ids)
  offline_publish
}

# Some offline folder is locked or stopped with an error.
cmd__offline-locked() {
  local id s
  while read -r id; do
    s="$(offline_status "$id")"
    [[ $s == locked || $s == error ]] && return 0
  done < <(offline_ids)
  return 1
}

offline_add() {
  local path="${1%/}" base dest n=2 id
  resolve_path "$path" || die "not in Google Drive: $path"
  [[ -n $REL ]] || die "a whole drive cannot be made offline: pick a folder inside it"
  [[ -d $path ]] || die "only folders can be made available offline"
  if offline_find "$path"; then
    notify "Google Drive" "\"$(basename "$path")\" is already available offline: $O_LOCAL"
    return 0
  fi
  resolve_path "$path"
  base="$(link_name "$(basename "$REL")")"
  dest="$OFFLINE_DIR/$base"
  while [[ -e $dest ]]; do
    dest="$OFFLINE_DIR/$base ($n)"
    n=$((n + 1))
  done
  id="$(printf '%s:%s' "$M_NAME" "$REL" | sha1sum | cut -c1-12)"
  mkdir -p "$OFFLINE_CONF_DIR" "$dest"
  {
    echo "# omarchy-gdrive offline folder. Remove: omarchy-gdrive offline remove <path>"
    printf 'O_MOUNT=%q\nO_REL=%q\nO_LOCAL=%q\n' "$M_NAME" "$REL" "$dest"
  } >"$OFFLINE_CONF_DIR/$id.env"
  offline_set_status "$id" new
  offline_publish
  notify "Google Drive" "Preparing the offline copy of \"$base\": $dest"
  systemctl --user start --no-block omarchy-gdrive-offline.service
}

offline_remove() {
  local path="$1"
  offline_find "$path" || die "not an offline folder: $path"
  rm -f "$OFFLINE_CONF_DIR/$O_ID.env"
  rm -rf "${BISYNC_DIR:?}/$O_ID"
  jq --arg id "$O_ID" 'del(.[$id])' "$OFFLINE_STATE" >"$OFFLINE_STATE.tmp" 2>/dev/null &&
    mv -f "$OFFLINE_STATE.tmp" "$OFFLINE_STATE"
  rmdir "$OFFLINE_CONF_DIR" 2>/dev/null || true
  offline_publish
  notify "Offline copy turned off" "\"$(basename "$O_LOCAL")\" is no longer synced. The local files stay in $O_LOCAL"
}

cmd_offline() {
  local sub="${1:-list}" id
  shift || true
  load_config
  case "$sub" in
    add)
      (($#)) || die "usage: omarchy-gdrive offline add <folder in Google Drive>"
      offline_add "$1"
      ;;
    remove)
      (($#)) || die "usage: omarchy-gdrive offline remove <folder>"
      offline_remove "$1"
      ;;
    sync)
      if [[ ${1:-} == --force ]]; then
        # Confirmed by the user: push even large deletions through.
        shift
        online || die "no network"
        while read -r id; do
          load_offline "$id"
          if (($#)); then
            offline_find "$1" || die "not an offline folder: $1"
            [[ $O_ID == "$id" ]] || continue
          fi
          say "syncing \"$(basename "$O_LOCAL")\" without the mass-deletion guard"
          run_bisync "$id" "" force || warn "failed, see above"
        done < <(offline_ids)
        offline_publish
        return 0
      fi
      if (($#)); then
        offline_find "$1" || die "not an offline folder: $1"
        notify "Google Drive" "Syncing \"$(basename "$O_LOCAL")\"..."
      fi
      systemctl --user start --no-block omarchy-gdrive-offline.service
      ;;
    resync)
      [[ -n $(offline_ids) ]] || die "no offline folders"
      online || die "no network"
      while read -r id; do
        load_offline "$id"
        [[ ${1:-} == --all || $(offline_status "$id") != ok ]] || continue
        say "resyncing \"$(basename "$O_LOCAL")\" (the newer version of a file wins, nothing is deleted)"
        run_bisync "$id" resync || warn "failed, see above"
      done < <(offline_ids)
      offline_publish
      ;;
    list)
      [[ -n $(offline_ids) ]] || {
        say "no offline folders. Add one: right-click a folder in Google Drive → Make available offline"
        return 0
      }
      while read -r id; do
        load_offline "$id"
        load_mount "$O_MOUNT"
        printf '\033[1m%s\033[0m  [%s]\n  cloud: %s\n  local: %s\n' "$(basename "$O_LOCAL")" \
          "$(offline_status "$id")" "$M_LINK/$O_REL" "$O_LOCAL"
        jq -r --arg id "$id" '.[$id].message // empty | select(. != "") | "  error: " + .' "$OFFLINE_STATE" 2>/dev/null || true
      done < <(offline_ids)
      ;;
    *) die "usage: omarchy-gdrive offline add|remove|sync [--force]|resync|list" ;;
  esac
}

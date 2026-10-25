# shellcheck shell=bash
# Web links for files in the mounts (used by the Nautilus extension).
#
# Deliberately not `rclone link`: that creates a public "anyone with the
# link" share. These are the normal private URLs; access stays as it was.

# Prints the Google Drive URL for a local path, or fails with a message.
drive_url() {
  local path="$1" body reply id isdir
  resolve_path "$path" || {
    echo "not in Google Drive: $path" >&2
    return 1
  }
  if [[ -z $REL ]]; then
    case "$M_KIND" in
      mydrive) echo "https://drive.google.com/drive/my-drive" ;;
      shared) echo "https://drive.google.com/drive/shared-with-me" ;;
      teamdrive) echo "https://drive.google.com/drive/folders/$M_TEAM_DRIVE_ID" ;;
    esac
    return 0
  fi
  body="$(jq -cn --arg fs "$REMOTE:" --arg remote "$REL" '{fs: $fs, remote: $remote, opt: {noModTime: true, noMimeType: true}}')"
  if reply="$(RC_TIMEOUT=20 rc_call "$M_SOCK" operations/stat "$body")"; then
    reply="$(jq -c '.item' <<<"$reply")"
  else
    # Mount not running: ask rclone directly. List the parent, because
    # `lsjson --stat` leaves the ID empty for directories.
    local parent=""
    [[ $REL == */* ]] && parent="${REL%/*}"
    reply="$(rc_clone lsjson --no-modtime --no-mimetype "${M_FLAGS[@]}" \
      --drive-export-formats "$EXPORT_FORMATS" "$REMOTE:$parent" 2>/dev/null |
      jq -c --arg n "${REL##*/}" 'map(select(.Name == $n))[0]' || echo null)"
  fi
  id="$(jq -r '.ID // empty' <<<"$reply" 2>/dev/null || true)"
  if [[ -z $id ]]; then
    echo "\"$(basename "$path")\" is not uploaded yet" >&2
    return 1
  fi
  isdir="$(jq -r '.IsDir // false' <<<"$reply")"
  if [[ $isdir == true ]]; then
    echo "https://drive.google.com/drive/folders/$id"
  else
    echo "https://drive.google.com/open?id=$id"
  fi
}

cmd_web() {
  local path url err
  load_config
  (($#)) || die "usage: omarchy-gdrive web <path>..."
  for path in "$@"; do
    if url="$(drive_url "$path" 2>"$RUN_DIR/web.err")"; then
      setsid -f xdg-open "$url" >/dev/null 2>&1
    else
      err="$(cat "$RUN_DIR/web.err")"
      notify "Google Drive" "$err"
    fi
  done
  rm -f "$RUN_DIR/web.err"
}

cmd_link() {
  local path url urls=() errors=()
  load_config
  mkdir -p "$RUN_DIR"
  (($#)) || die "usage: omarchy-gdrive link <path>..."
  for path in "$@"; do
    if url="$(drive_url "$path" 2>"$RUN_DIR/link.err")"; then
      urls+=("$url")
    else
      errors+=("$(cat "$RUN_DIR/link.err")")
    fi
  done
  rm -f "$RUN_DIR/link.err"
  if ((${#urls[@]})); then
    printf '%s\n' "${urls[@]}" | sed -z 's/\n$//' | wl-copy
    if ((${#urls[@]} == 1)); then
      notify "Link copied" "${urls[0]}"
    else
      notify "Links copied" "${#urls[@]} links"
    fi
    [[ -t 1 ]] && printf '%s\n' "${urls[@]}"
  fi
  if ((${#errors[@]})); then
    notify "Google Drive" "$(printf '%s\n' "${errors[@]}")"
    return 1
  fi
}

# shellcheck shell=bash
# Mount lifecycle (called by the systemd units), health checks and status.

# Merge key/value pairs into a mount's runtime state file.
# Usage: state_set name key value [key value ...]   (values are strings)
state_set() {
  local name="$1" file="$RUN_DIR/$1.json" filter='.' args=() i=0
  shift
  while (($# >= 2)); do
    args+=(--arg "k$i" "$1" --arg "v$i" "$2")
    filter+=" | .[\$k$i] = \$v$i"
    i=$((i + 1))
    shift 2
  done
  mkdir -p "$RUN_DIR"
  chmod 700 "$RUN_DIR"
  [[ -s $file ]] || echo '{}' >"$file"
  jq "${args[@]}" "$filter" "$file" >"$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file"
  : "$name"
}

state_get() {
  jq -r --arg k "$2" '.[$k] // empty' "$RUN_DIR/$1.json" 2>/dev/null || true
}

is_mounted() { findmnt -rn -T "$1" -o TARGET 2>/dev/null | grep -qxF "$1"; }

# Read-only while not mounted, so nothing gets saved into the empty folder.
lock_mountpoint() {
  mkdir -p "$1"
  is_mounted "$1" || chmod 555 "$1"
}

# Classify an rclone error message.
classify() {
  local text="$1"
  if grep -qiE 'invalid_grant|expired or revoked|cannot fetch token|couldn.t fetch token|unauthorized_client|invalid_client|oauth2:|401 Unauthorized|empty token' <<<"$text"; then
    echo auth
  elif grep -qiE 'unable to decrypt configuration|didn.t find section in config|failed to load config|password-command' <<<"$text"; then
    echo config
  elif grep -qiE 'storageQuotaExceeded|quotaExceeded|rateLimitExceeded|userRateLimitExceeded' <<<"$text"; then
    echo quota
  elif grep -qiE 'no such host|network is unreachable|dial tcp|i/o timeout|connection refused|TLS handshake timeout|context deadline exceeded|connection reset' <<<"$text"; then
    echo network
  elif grep -qiE 'not empty|mountpoint|Transport endpoint|fusermount' <<<"$text"; then
    echo mountpoint
  else
    echo error
  fi
}

reconnect_hint() {
  systemd-run --user --quiet --collect --unit="omarchy-gdrive-notify-$RANDOM" -- \
    "$BIN" _notify-auth "$1" >/dev/null 2>&1 || true
}

# ExecStartPre: clean a stale mount, then wait for the network.
cmd__prestart() {
  local name="$1" start=$SECONDS told=0
  load_config
  load_mount "$name"
  mkdir -p "$RUN_DIR" "$M_CACHE" "$MNT_ROOT"
  chmod 700 "$RUN_DIR"
  rm -f "$M_SOCK"
  if is_mounted "$M_MNT" || ! ls "$M_MNT" >/dev/null 2>&1; then
    fusermount3 -uz "$M_MNT" 2>/dev/null || true
  fi
  lock_mountpoint "$M_MNT"
  state_set "$name" phase waiting-network health ok message ""
  until online; do
    if ((SECONDS - start >= 30 && !told)); then
      told=1
      notify -r "$RUN_DIR/notify-network.id" "No network" "Google Drive will connect by itself when the internet is back."
    fi
    sleep 3
  done
  state_set "$name" phase starting
}

# ExecStart: becomes rclone (exec keeps the PID, so Type=notify works).
cmd__mount() {
  local name="$1" args leftovers
  load_config
  load_mount "$name"

  # Something was written into the folder while it was not mounted: rclone
  # refuses non-empty mountpoints, so move it aside instead of failing.
  if [[ -n $(ls -A "$M_MNT" 2>/dev/null) ]]; then
    leftovers="$LINK_DIR/Not uploaded ($(link_name "$M_LABEL")) $(date +%F-%H%M%S)"
    chmod 755 "$M_MNT"
    mkdir -p "$leftovers"
    mv -- "$M_MNT"/* "$M_MNT"/.[!.]* "$leftovers"/ 2>/dev/null || true
    notify -u critical "Google Drive: local files moved" \
      "Files were saved into \"$M_LABEL\" while it was disconnected. They were moved to \"$leftovers\"; upload them by hand."
  fi
  chmod 755 "$M_MNT"

  args=(
    mount "$REMOTE:" "$M_MNT"
    --config "$RCLONE_CONFIG_FILE"
    --password-command "$PASSWORD_CMD"
    --ask-password=false
    --cache-dir "$M_CACHE"
    --vfs-cache-mode full
    --vfs-cache-max-size "$VFS_CACHE_MAX_SIZE"
    --vfs-cache-max-age "$VFS_CACHE_MAX_AGE"
    --vfs-cache-min-free-space "$VFS_CACHE_MIN_FREE_SPACE"
    --vfs-write-back "$VFS_WRITE_BACK"
    --dir-cache-time "$DIR_CACHE_TIME"
    --poll-interval "$POLL_INTERVAL"
    --low-level-retries "$LOW_LEVEL_RETRIES"
    --contimeout "$CONTIMEOUT"
    --timeout "$TIMEOUT"
    --drive-export-formats "$EXPORT_FORMATS"
    --rc --rc-addr "unix://$M_SOCK" --rc-no-auth
    --log-level "$LOG_LEVEL"
    "${M_FLAGS[@]}"
  )
  [[ $VFS_REFRESH == true ]] && args+=(--vfs-refresh)
  # GLib treats mounts with device "none" as system-internal and refuses to
  # trash there, so Nautilus offers a real delete (rclone sends it to the
  # Google Drive trash) instead of uploading a .Trash-1000 folder.
  [[ $NAUTILUS_TRASH == true ]] || args+=(--devname none)
  if [[ -n $EXTRA_FLAGS ]]; then
    local extra
    read -r -a extra <<<"$EXTRA_FLAGS"
    args+=("${extra[@]}")
  fi
  exec rclone "${args[@]}"
}

# ExecStartPost: the mount is ready.
cmd__started() {
  local name="$1" n labels=()
  load_config
  load_mount "$name"
  chmod 600 "$RCLONE_CONFIG_FILE" 2>/dev/null || true
  state_set "$name" phase connected health ok message "" failure "" since "$(date +%s)"
  rm -f "$RUN_DIR/$name.notified"
  [[ $NOTIFY_CONNECTED == true ]] || return 0
  # Mounts start together at login: wait a moment and send one notification
  # listing all of them (each later start replaces it).
  sleep 2
  exec 9>"$RUN_DIR/notify.lock"
  flock 9
  while read -r n; do
    [[ $(state_get "$n" phase) == connected ]] || continue
    load_mount "$n"
    labels+=("$M_LABEL")
  done < <(mount_names)
  ((${#labels[@]})) || return 0
  notify -r "$RUN_DIR/notify-connected.id" "Google Drive connected" "$(printf '%s\n' "${labels[@]}")"
}

# Wait (bounded) for pending uploads, then unmount lazily.
cmd__stop() {
  local name="$1" stats queued told=0 waited=0
  load_config
  load_mount "$name"
  state_set "$name" phase stopping
  while ((waited < STOP_WAIT)); do
    stats="$(RC_TIMEOUT=3 rc_call "$M_SOCK" vfs/stats)" || break
    queued="$(jq -r '(.diskCache.uploadsInProgress // 0) + (.diskCache.uploadsQueued // 0)' <<<"$stats")"
    ((queued > 0)) || break
    online || break
    if ((!told)); then
      told=1
      notify -r "$RUN_DIR/notify-stop.id" "Google Drive" "Finishing $queued uploads. This takes up to $STOP_WAIT s."
    fi
    sleep 1
    waited=$((waited + 1))
  done
  fusermount3 -uz "$M_MNT" 2>/dev/null || true
}

# ExecStopPost: tidy up and explain failures.
cmd__poststop() {
  local name="$1" result="${SERVICE_RESULT:-success}" log kind last
  load_config
  load_mount "$name"
  rm -f "$M_SOCK"
  if is_mounted "$M_MNT" || ! ls "$M_MNT" >/dev/null 2>&1; then
    fusermount3 -uz "$M_MNT" 2>/dev/null || true
  fi
  lock_mountpoint "$M_MNT"
  if [[ $result == success ]]; then
    state_set "$name" phase stopped
    return 0
  fi
  log="$(journalctl --user -u "$M_UNIT" -n 40 -o cat --no-pager 2>/dev/null | grep -vE '^(Started|Stopped|Starting|Stopping) ' || true)"
  kind="$(classify "$log")"
  state_set "$name" phase failed health "$kind" failure "$kind" \
    message "$(grep -iE 'error|critical|fatal' <<<"$log" | tail -n1 | cut -c1-300)"
  last="$(cat "$RUN_DIR/$name.notified" 2>/dev/null || true)"
  [[ $last == "$kind" ]] && return 0
  echo "$kind" >"$RUN_DIR/$name.notified"
  # Only what needs the user's action is reported right away. A crash is
  # retried by systemd; if that keeps failing, OnFailure= runs _failed.
  case "$kind" in
    auth) reconnect_hint "$name" ;;
    config)
      notify -u critical "Google Drive: cannot open the config" \
        "Could not decrypt rclone.conf with the password from the keyring. Run: omarchy-gdrive setup"
      ;;
    quota)
      notify -u critical "Google Drive: quota exceeded" "\"$M_LABEL\": Google limited requests or storage. Details: omarchy-gdrive status"
      ;;
    *) rm -f "$RUN_DIR/$name.notified" ;;
  esac
}

# OnFailure= (omarchy-gdrive-failed@.service): systemd gave up restarting.
cmd__failed() {
  local name="$1" kind msg
  load_config
  load_mount "$name"
  kind="$(state_get "$name" failure)"
  [[ -n $kind && $(cat "$RUN_DIR/$name.notified" 2>/dev/null) == "$kind" ]] && return 0
  echo "${kind:-error}" >"$RUN_DIR/$name.notified"
  msg="$(state_get "$name" message)"
  notify -u critical "Google Drive: \"$M_LABEL\" does not connect" \
    "${msg:+$msg
}Details: omarchy-gdrive status. Retry: Google Drive menu → Connect."
}

# Notification with a «Reconnect» button; runs outside the unit's cgroup.
cmd__notify-auth() {
  local name="$1" action
  load_config
  load_mount "$name"
  action="$(notify -u critical -A reconnect="Sign in again" "Google Drive: sign in again" \
    "Google no longer accepts the saved sign-in (\"$M_LABEL\"). Click \"Sign in again\" or pick it in the Google Drive menu.")" || true
  if [[ $action == reconnect ]]; then
    omarchy-launch-floating-terminal-with-presentation "$BIN reconnect"
  fi
}

# Periodic health check (omarchy-gdrive-check.timer).
cmd__check() {
  local name about kind msg stats errored prev was_online now_online space
  load_config
  mkdir -p "$RUN_DIR" "$STATE_DIR"
  now_online=0
  online && now_online=1
  was_online="$(cat "$RUN_DIR/online" 2>/dev/null || echo 1)"
  echo "$now_online" >"$RUN_DIR/online"
  if ((now_online && !was_online)) && [[ -n $(ls -A "$OFFLINE_CONF_DIR" 2>/dev/null) ]]; then
    systemctl --user start --no-block omarchy-gdrive-offline.service 2>/dev/null || true
  fi

  while read -r name; do
    load_mount "$name"
    unit_active "$M_UNIT" || continue
    if ((now_online)); then
      if about="$(RC_TIMEOUT=30 rc_call "$M_SOCK" operations/about "$(jq -cn --arg fs "$REMOTE:" '{fs: $fs}')")"; then
        state_set "$name" health ok message "" \
          quota_used "$(jq -r '.used // empty' <<<"$about")" quota_total "$(jq -r '.total // empty' <<<"$about")"
        rm -f "$RUN_DIR/$name.notified"
      else
        msg="$(jq -r '.error // empty' <<<"$about" 2>/dev/null || true)"
        if [[ -z $msg ]]; then
          # No answer at all (timed out): Google is unreachable for rclone.
          kind=network msg="Google does not answer"
        else
          kind="$(classify "$msg")"
        fi
        case "$kind" in
          auth)
            state_set "$name" health auth message "${msg:0:300}"
            if [[ $(cat "$RUN_DIR/$name.notified" 2>/dev/null) != auth ]]; then
              echo auth >"$RUN_DIR/$name.notified"
              reconnect_hint "$name"
            fi
            ;;
          network) state_set "$name" health network message "${msg:0:300}" ;;
          *) state_set "$name" message "${msg:0:300}" ;;
        esac
      fi
    else
      state_set "$name" health network
    fi

    stats="$(rc_call "$M_SOCK" vfs/stats)" || continue
    errored="$(jq -r '.diskCache.erroredFiles // 0' <<<"$stats")"
    prev="$(state_get "$name" errored_files)"
    state_set "$name" errored_files "$errored"
    if ((errored > ${prev:-0})); then
      notify -u critical "Google Drive: uploads failed" \
        "\"$M_LABEL\": $errored files failed to upload. rclone will retry; log: omarchy-gdrive logs"
    fi
    space="$(jq -r '.diskCache.outOfSpace // false' <<<"$stats")"
    if [[ $space == true && $(state_get "$name" out_of_space) != true ]]; then
      notify -u critical "Google Drive: low disk space" "The cache of \"$M_LABEL\" ran out of free disk space. Free some space or lower the cache size in the settings."
    fi
    state_set "$name" out_of_space "$space"
  done < <(mount_names)
}

# Bytes as "1.5 GB".
human() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    s = (i == 1) ? sprintf("%d", b) : sprintf("%.1f", b)
    sub(/\.0$/, "", s); printf "%s %s", s, u[i]
  }'
}

failure_text() {
  case "$1" in
    auth) echo "sign in again" ;;
    config) echo "cannot decrypt the config" ;;
    quota) echo "quota exceeded" ;;
    network) echo "cannot reach Google" ;;
    mountpoint) echo "mountpoint error" ;;
    *) echo "connection error" ;;
  esac
}

# One mount's status as a JSON object.
mount_status_json() {
  local name="$1" active sub result key value phase health msg stats uploads=0 errored=0 cache=0 state text
  load_mount "$name"
  active="" sub="" result=""
  while IFS='=' read -r key value; do
    case "$key" in
      ActiveState) active="$value" ;;
      SubState) sub="$value" ;;
      Result) result="$value" ;;
    esac
  done < <(systemctl --user show "$M_UNIT" -p ActiveState -p SubState -p Result 2>/dev/null)
  phase="$(state_get "$name" phase)"
  health="$(state_get "$name" health)"
  msg="$(state_get "$name" message)"
  if [[ $active == active ]] && stats="$(RC_TIMEOUT=2 rc_call "$M_SOCK" vfs/stats)"; then
    uploads="$(jq -r '(.diskCache.uploadsInProgress // 0) + (.diskCache.uploadsQueued // 0)' <<<"$stats")"
    errored="$(jq -r '.diskCache.erroredFiles // 0' <<<"$stats")"
    cache="$(jq -r '.diskCache.bytesUsed // 0' <<<"$stats")"
  fi
  case "$active" in
    active)
      if [[ $health == auth ]]; then
        state=error text="sign in again"
      elif ((errored > 0)); then
        state=error text="upload errors: $errored"
      elif [[ $health == network ]]; then
        state=offline text="no network"
      elif ((uploads > 0)); then
        state=syncing text="uploading: $uploads"
      else
        state=connected text="connected"
      fi
      ;;
    activating | reloading)
      if [[ $phase == waiting-network ]]; then
        state=offline text="waiting for network"
      elif [[ $sub == auto-restart ]]; then
        state=error text="$(failure_text "$(state_get "$name" failure)"), retrying"
      else
        state=starting text="connecting"
      fi
      ;;
    failed) state=error text="$(failure_text "$(state_get "$name" failure)")" ;;
    *) state=disconnected text="disconnected" ;;
  esac
  ((cache > 0)) && text+=" · cache $(human "$cache")"
  jq -cn --arg name "$name" --arg label "$M_LABEL" --arg state "$state" --arg text "$text" \
    --arg message "$msg" --arg unit "$M_UNIT" --arg link "$M_LINK" --arg result "$result" \
    --argjson uploads "$uploads" --argjson errored "$errored" --argjson cache "$cache" \
    --arg used "$(state_get "$name" quota_used)" --arg total "$(state_get "$name" quota_total)" \
    '{name: $name, label: $label, state: $state, text: $text, message: $message, unit: $unit,
      link: $link, result: $result, uploads: $uploads, errored: $errored, cacheBytes: $cache,
      quotaUsed: ($used | tonumber? // null), quotaTotal: ($total | tonumber? // null)}'
}

status_json() {
  local name items=() agg tooltip used="" total="" offline_state
  load_config
  if [[ ! -d $MOUNTS_DIR || -z $(mount_names) ]]; then
    jq -cn '{state: "unconfigured", text: "Google Drive is not set up", tooltip: "Google Drive is not set up: Omarchy menu → Google Drive → Set up", mounts: []}'
    return 0
  fi
  while read -r name; do
    items+=("$(mount_status_json "$name")")
  done < <(mount_names)
  agg="$(printf '%s\n' "${items[@]}" | jq -s '
    def rank: {"error": 5, "syncing": 4, "offline": 3, "starting": 2, "connected": 1, "disconnected": 0}[.];
    {mounts: ., state: (map(.state) | max_by(rank)),
     uploads: (map(.uploads) | add), errored: (map(.errored) | add)}
    | if .state == "disconnected" then . else
        # Mounts the user switched off do not make an otherwise healthy set look broken.
        .state = ([.mounts[].state | select(. != "disconnected")] | max_by(rank))
      end')"
  # Quota of the account (same for every mount; take the first known).
  used="$(jq -r '[.mounts[] | select(.quotaUsed != null)][0].quotaUsed // empty' <<<"$agg")"
  total="$(jq -r '[.mounts[] | select(.quotaTotal != null)][0].quotaTotal // empty' <<<"$agg")"
  tooltip="$(jq -r '.mounts[] | "\(.label): \(.text)"' <<<"$agg")"
  if [[ -n $used ]]; then
    if [[ -n $total ]]; then
      tooltip+=$'\n'"Used $(human "$used") of $(human "$total")"
    else
      tooltip+=$'\n'"Used $(human "$used")"
    fi
  fi
  offline_state="$(offline_summary 2>/dev/null || true)"
  [[ -n $offline_state ]] && tooltip+=$'\n'"$offline_state"
  if [[ $offline_state == *"need resync"* || $offline_state == *"sync errors"* ]]; then
    agg="$(jq '.state = "error"' <<<"$agg")"
  fi
  jq -c --arg tooltip "$tooltip" '. + {tooltip: ("Google Drive\n" + $tooltip)}' <<<"$agg"
}

cmd_status() {
  local json name
  load_config
  if [[ ${1:-} == --json ]]; then
    status_json
    return 0
  fi
  json="$(status_json)"
  if [[ $(jq -r .state <<<"$json") == unconfigured ]]; then
    say "Google Drive is not set up. Run: omarchy-gdrive setup"
    return 0
  fi
  jq -r '.tooltip' <<<"$json"
  echo
  while read -r name; do
    load_mount "$name"
    printf '\033[1m%s\033[0m  %s\n' "$M_LABEL" "$M_UNIT"
    printf '  folder: %s\n' "$M_LINK"
    jq -r --arg n "$name" '.mounts[] | select(.name == $n) | "  state: \(.text)" + (if .message != "" then "\n  last error: \(.message)" else "" end)' <<<"$json"
  done < <(mount_names)
  echo
  echo "Log: omarchy-gdrive logs   Settings: $CONF_FILE"
}

cmd_logs() {
  journalctl --user -u 'omarchy-gdrive*' -n "${1:-200}" --no-pager
}

all_units() {
  local name
  while read -r name; do echo "omarchy-gdrive@$name.service"; done < <(mount_names)
}

cmd_connect() {
  local units
  load_config
  mapfile -t units < <(all_units)
  ((${#units[@]})) || die "Google Drive is not set up. Run: omarchy-gdrive setup"
  systemctl --user reset-failed "${units[@]}" 2>/dev/null || true
  systemctl --user enable --no-block --now "${units[@]}" 2>/dev/null
  say "connecting: ${units[*]}"
}

cmd_disconnect() {
  local units
  load_config
  mapfile -t units < <(all_units)
  ((${#units[@]})) || return 0
  # disable: stays off after the next login too, until "connect".
  systemctl --user disable --now "${units[@]}" 2>/dev/null || true
  say "Google Drive disconnected (connect again: omarchy-gdrive connect)"
}

cmd_restart() {
  local units
  load_config
  mapfile -t units < <(all_units)
  ((${#units[@]})) || die "Google Drive is not set up. Run: omarchy-gdrive setup"
  write_mounts_json
  systemctl --user reset-failed "${units[@]}" 2>/dev/null || true
  systemctl --user restart --no-block "${units[@]}"
  say "restarting: ${units[*]}"
}

any_active() {
  local unit
  while read -r unit; do unit_active "$unit" && return 0; done < <(all_units)
  return 1
}

cmd_open() {
  local target="${1:-}"
  load_config
  if [[ -z $target ]]; then
    target="$LINK_DIR"
    if [[ ! -d $LINK_DIR || -z $(mount_names) ]]; then
      notify "Google Drive is not set up" "Omarchy menu → Google Drive → Set up"
      return 0
    fi
    any_active || notify "Google Drive is disconnected" "Connect: Omarchy menu → Google Drive → Connect"
  fi
  setsid -f uwsm-app -- nautilus --new-window "$target" >/dev/null 2>&1 || setsid -f nautilus --new-window "$target" >/dev/null 2>&1
}

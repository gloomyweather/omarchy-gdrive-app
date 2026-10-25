# Troubleshooting

Start with `omarchy-gdrive status` and `omarchy-gdrive logs`.
Live log: `journalctl --user -u 'omarchy-gdrive@*' -f`. For more detail set
`LOG_LEVEL=INFO` in the settings and run `omarchy-gdrive restart`.

**The hotkey, menu entry or bar icon is gone.** `omarchy refresh hyprland` or
`omarchy refresh shell` reset those files. Run `omarchy-gdrive repair`
(also in the menu). After `omarchy update` this happens automatically.

**"Sign in again" notification, `invalid_grant` in the log.** Google no longer
accepts the saved sign-in. Run `omarchy-gdrive reconnect`. If this happens every
7 days, your Google app is still in Testing: see step 4 of [OAUTH.md](OAUTH.md).

**A folder does not open: "Transport endpoint is not connected".** A stale mount.
```bash
omarchy-gdrive status          # shows the mount names, e.g. mydrive
fusermount3 -uz ~/.local/state/omarchy-gdrive/mnt/mydrive
omarchy-gdrive restart
```
The service also does this by itself before every start.

**`rateLimitExceeded` / `userRateLimitExceeded` / error 403.** Make sure your own
client ID is used: `omarchy-gdrive rclone config show gdrive` shows `client_id`
(do not share that output, it contains your token). Check **Quotas** of the Google
Drive API in Google Cloud. rclone slows down and retries by itself.

**No network.** At login the service waits for the network as long as needed;
the bar icon is dimmed and a notification appears after 30 seconds. If the network
drops later, every folder still opens (their listings are loaded at connect,
`VFS_REFRESH=true`), cached files open, and saved files upload once the network is
back. A file that was never opened cannot be read offline: the app opening it waits
until rclone gives up, which can take minutes. Use offline folders for files you
need without network.

**Offline folder: "sync stopped".** If a sync would delete more than 25% of the
files, it stops to protect you. To get the files back: menu → Google Drive →
Offline folders → Resync (nothing is deleted, the newer copy of a file wins).
If the deletion was intended: `omarchy-gdrive offline sync --force`.

**"Local files moved".** While a drive is disconnected its folder is read-only.
If files ended up there anyway, they are moved to `~/GoogleDrive/Not uploaded (...)`
on the next connect. Upload them by hand.

**The cache uses too much space.** Lower `VFS_CACHE_MAX_SIZE` or `VFS_CACHE_MAX_AGE`
in the settings. The limit is soft: open files and pending uploads are kept.

**Thumbnails.** Files treats the mount as a local disk and makes thumbnails for
pictures, which downloads them once. To stop that for every folder: Files →
Preferences → show thumbnails: never.

**No Google Drive items in the right-click menu.** Run `nautilus -q` and open Files again.

## Settings

`~/.config/omarchy-gdrive/gdrive.conf`, apply with `omarchy-gdrive restart`.
Every setting is explained in the file. The main ones:

| Setting | Default | What it does |
|---|---|---|
| `VFS_CACHE_MAX_SIZE` | `10G` | cache size per mount (soft limit) |
| `VFS_CACHE_MAX_AGE` | `168h` | how long a file stays cached after last use |
| `VFS_CACHE_MIN_FREE_SPACE` | `20G` | the cache stops growing below this free space |
| `VFS_REFRESH` | `true` | load all folder listings at connect (for offline use) |
| `LOW_LEVEL_RETRIES` | `2` | fewer: faster errors offline; more: more tolerant of hiccups |
| `EXPORT_FORMATS` | `link.html` | Google Docs as browser links; `docx,xlsx,pptx,svg` to export |
| `NAUTILUS_TRASH` | `false` | `true` uses the Files trash (creates `.Trash-1000` in the cloud) |
| `HOTKEY` | `SUPER + CTRL + G` | empty for none; run `omarchy-gdrive repair` after a change |

## Where things live

| Path | What |
|---|---|
| `~/.local/share/omarchy-gdrive/` | the program; `~/.local/bin/omarchy-gdrive` links to it |
| `~/.config/omarchy-gdrive/` | settings, mounts, offline folders |
| `~/.config/rclone/rclone.conf` | Google sign-in, encrypted, password in the keyring |
| `~/.config/systemd/user/omarchy-gdrive*` | one service per mount, health check, offline sync timer |
| `~/.local/state/omarchy-gdrive/mnt/` | the real mountpoints (hidden on purpose) |
| `~/GoogleDrive/` | links to the mounts, used by the bookmarks |
| `~/.cache/omarchy-gdrive/` | rclone cache, one per mount |
| `~/.config/omarchy/plugins/gdrive.status/` | bar icon |
| `~/.local/share/nautilus-python/extensions/omarchy_gdrive.py` | right-click menu |
| `>>> omarchy-gdrive >>>` blocks | in `~/.config/hypr/bindings.lua` and `~/.config/omarchy/extensions/omarchy-menu.jsonc` |

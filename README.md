# omarchy-gdrive

Google Drive as a normal folder on [Omarchy](https://omarchy.org/).
Open, edit and save your Drive files from Files, the terminal or any app.
Built on [rclone](https://rclone.org/).

- **Files**: bookmarks for My Drive, Shared with me and your shared drives
- **Right-click**: open in Google Drive, copy link, make available offline
- **Bar**: a Drive icon that shows connected, uploading, offline or error
- **Menu**: Omarchy menu → Google Drive
- **Hotkey**: `Super + Ctrl + G` opens Drive
- **Auto-connect** at login, waits for the network, finishes uploads at shutdown

## Install

You need Omarchy 4 (the `quattro` branch: Hyprland with a Lua config and the Quickshell bar).

**1. Install the plugin**

```bash
git clone https://github.com/gloomyweather/omarchy-gdrive-app.git ~/.local/src/omarchy-gdrive
~/.local/src/omarchy-gdrive/install.sh
nautilus -q
```

The installer asks for your sudo password if it needs packages (rclone and a few small tools).

**2. Create your Google key** (about 10 minutes, once)

Google needs to know which app is asking for your Drive. Follow **[OAUTH.md](OAUTH.md)**.
At the end you have a *Client ID* and a *Client secret*.

**3. Connect**

```bash
omarchy-gdrive setup
```

Or use the Omarchy menu: **Google Drive → Set up**. Paste the Client ID and the secret,
sign in to Google in the browser that opens, and pick the drives you want.

Done. Your Drive is in the Files sidebar and in `~/GoogleDrive`.

## Use

| To | Do |
|---|---|
| Open Drive | `Super + Ctrl + G`, the Drive icon in the bar, or the sidebar in Files |
| See what is going on | Hover the bar icon, or run `omarchy-gdrive status` |
| Disconnect / connect | Omarchy menu → Google Drive, or `omarchy-gdrive disconnect` / `connect` |
| Sign in again | Omarchy menu → Google Drive → Sign in again |
| Change settings | Omarchy menu → Google Drive → Settings, then `omarchy-gdrive restart` |

Good to know:

- Google Docs, Sheets and Slides appear as `Name.link.html` and open in your browser.
- Deleting a file moves it to the Google Drive trash. Restore it at drive.google.com.
- Saved files upload in the background a few seconds after you close them.
- Without network, folders and already opened files still work. New changes upload later.
  Need files that were never opened? Right-click a folder → **Make available offline**.
- After `omarchy refresh ...` the hotkey, menu or bar icon may be gone: run `omarchy-gdrive repair`.

Run `omarchy-gdrive help` for all commands. Problems? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Uninstall

```bash
omarchy-gdrive uninstall                  # keeps your Google sign-in and settings
omarchy-gdrive uninstall --purge-config   # also deletes the sign-in and settings
```

Files in Google Drive are never touched.

## Privacy

Everything runs on your computer and talks only to Google. Your sign-in is stored
in an encrypted rclone config, its password is in your keyring. Nothing is sent
anywhere else. See the [privacy policy](https://gloomyweather.github.io/omarchy-gdrive-app/privacy.html).

## License

[MIT](LICENSE)

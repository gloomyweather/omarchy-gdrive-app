"""Google Drive actions in the Nautilus context menu (omarchy-gdrive).

The menu is built from small JSON state files only: no network and no stat
calls on the FUSE mount, so opening a menu can never hang Nautilus. The
actions run `omarchy-gdrive` asynchronously; it talks to rclone and reports
back with a notification.
"""

import json
import os

from gi import require_version

require_version("Nautilus", "4.1")

from gi.repository import GObject, Gio, Nautilus

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "omarchy-gdrive",
)
MOUNTS_FILE = os.path.join(STATE_DIR, "mounts.json")
OFFLINE_FILE = os.path.join(STATE_DIR, "offline-list.json")


class _JsonFile:
    """A JSON file re-read only when its mtime changes."""

    def __init__(self, path, empty):
        self.path = path
        self.empty = empty
        self.mtime = None
        self.data = empty

    def get(self):
        try:
            mtime = os.stat(self.path).st_mtime_ns
        except OSError:
            self.mtime, self.data = None, self.empty
            return self.data
        if mtime != self.mtime:
            try:
                with open(self.path, encoding="utf-8") as handle:
                    self.data = json.load(handle)
                self.mtime = mtime
            except (OSError, ValueError):
                self.data = self.empty
        return self.data


def _inside(path, root):
    return bool(root) and (path == root or path.startswith(root.rstrip("/") + "/"))


class GoogleDriveMenu(GObject.GObject, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self._mounts = _JsonFile(MOUNTS_FILE, {})
        self._offline = _JsonFile(OFFLINE_FILE, [])

    # --- path helpers -------------------------------------------------------

    def _bin(self):
        return self._mounts.get().get("bin")

    def _drive_mount(self, path):
        for mount in self._mounts.get().get("mounts", []):
            for root in (mount.get("link"), mount.get("mountpoint")):
                if _inside(path, root):
                    return mount, path != root.rstrip("/")
        return None, False

    def _offline_entry(self, path):
        for entry in self._offline.get():
            if path in (entry.get("local"), entry.get("drive"), entry.get("mountpath")):
                return entry
        return None

    @staticmethod
    def _path(file):
        location = file.get_location()
        return location.get_path() if location else None

    # --- actions ------------------------------------------------------------

    def _run(self, _menu, args):
        binary = self._bin()
        if binary:
            Gio.Subprocess.new([binary] + args, Gio.SubprocessFlags.NONE)

    def _item(self, name, label, icon, args):
        item = Nautilus.MenuItem(
            name=f"OmarchyGDrive::{name}", label=label, icon=icon
        )
        item.connect("activate", self._run, args)
        return item

    def _items(self, files, background=False):
        if not self._bin():
            return []
        paths = []
        for file in files:
            path = self._path(file)
            if not path:
                return []
            paths.append(path)
        if not paths:
            return []

        items = []
        in_drive = all(self._drive_mount(p)[0] for p in paths)
        if in_drive:
            single = len(paths) == 1
            items.append(
                self._item(
                    "web" + ("-bg" if background else ""),
                    "Open in Google Drive" if single else f"Open {len(paths)} in Google Drive",
                    "web-browser",
                    ["web"] + paths,
                )
            )
            items.append(
                self._item(
                    "link" + ("-bg" if background else ""),
                    "Copy Google Drive link" if single else f"Copy {len(paths)} Google Drive links",
                    "insert-link",
                    ["link"] + paths,
                )
            )

        if len(paths) == 1 and not background:
            path = paths[0]
            entry = self._offline_entry(path)
            if entry:
                items.append(self._item("offline-sync", "Sync offline copy", "view-refresh", ["offline", "sync", path]))
                items.append(self._item("offline-remove", "Remove from offline", "list-remove", ["offline", "remove", path]))
            elif in_drive and files[0].is_directory() and self._drive_mount(path)[1]:
                items.append(self._item("offline-add", "Make available offline", "folder-download", ["offline", "add", path]))
        return items

    # Nautilus 4 passes (files); older bindings passed (window, files).
    def get_file_items(self, *args):
        return self._items(args[-1])

    def get_background_items(self, *args):
        return self._items([args[-1]], background=True)

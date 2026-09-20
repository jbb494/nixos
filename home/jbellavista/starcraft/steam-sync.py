import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Callable

import vdf


APP_ID = 3129101785
SIGNED_APP_ID = APP_ID - 2**32
HOME = Path.home()
STEAM_ROOT = HOME / ".local/share/Steam"
SHORTCUTS_PATH = STEAM_ROOT / "userdata/81643880/config/shortcuts.vdf"
CONFIG_PATH = STEAM_ROOT / "config/config.vdf"
PREFIX = STEAM_ROOT / f"steamapps/compatdata/{APP_ID}/pfx"
BATTLE_NET_LAUNCHER = (
    PREFIX
    / "drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe"
)
BATTLE_NET_CONFIG = (
    PREFIX
    / "drive_c/users/steamuser/AppData/Roaming/Battle.net/Battle.net.config"
)
BATTLE_NET_INSTALLER = Path(os.environ["BATTLE_NET_INSTALLER"])
LAUNCH_OPTIONS = (
    "$HOME/.local/state/nix/profiles/home-manager/home-path/bin/"
    "starcraft-gamescope %command%"
)
STARCRAFT_ARGUMENTS = '--exec="launch S2"'


def replace_atomically(path: Path, write: Callable[[Path], None]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)

    try:
        write(temporary_path)
        temporary_path.chmod(0o644)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def sync_shortcut() -> None:
    if SHORTCUTS_PATH.exists():
        with SHORTCUTS_PATH.open("rb") as shortcuts_file:
            data = vdf.binary_load(shortcuts_file)
    else:
        data = {"shortcuts": {}}

    shortcuts = data.setdefault("shortcuts", {})
    executable = (
        BATTLE_NET_LAUNCHER
        if BATTLE_NET_LAUNCHER.exists()
        else BATTLE_NET_INSTALLER
    )
    launch_options = (
        f"{LAUNCH_OPTIONS} {STARCRAFT_ARGUMENTS}"
        if BATTLE_NET_LAUNCHER.exists()
        else LAUNCH_OPTIONS
    )
    executable_value = f'"{executable}"'
    start_directory = f"{executable.parent}/"
    created = False
    shortcut = next(
        (
            value
            for value in shortcuts.values()
            if int(value.get("appid", 0)) & 0xFFFFFFFF == APP_ID
        ),
        None,
    )

    if shortcut is None:
        shortcut = next(
            (
                value
                for value in shortcuts.values()
                if value.get("AppName") == "Battle.net-Setup.exe"
            ),
            None,
        )

    if shortcut is None:
        indexes = [int(key) for key in shortcuts if key.isdigit()]
        created = True
        shortcut = {
            "appid": SIGNED_APP_ID,
            "AppName": "StarCraft II",
            "Exe": executable_value,
            "StartDir": start_directory,
            "icon": "",
            "ShortcutPath": "",
            "LaunchOptions": launch_options,
            "IsHidden": 0,
            "AllowDesktopConfig": 1,
            "AllowOverlay": 1,
            "OpenVR": 0,
            "Devkit": 0,
            "DevkitGameID": "",
            "DevkitOverrideAppID": 0,
            "LastPlayTime": 0,
            "FlatpakAppID": "",
            "sortas": "",
            "tags": {},
        }
        shortcuts[str(max(indexes, default=-1) + 1)] = shortcut

    changed = created or (
        shortcut.get("appid") != SIGNED_APP_ID
        or shortcut.get("AppName") != "StarCraft II"
        or shortcut.get("Exe") != executable_value
        or shortcut.get("StartDir") != start_directory
        or shortcut.get("LaunchOptions") != launch_options
    )
    shortcut["appid"] = SIGNED_APP_ID
    shortcut["AppName"] = "StarCraft II"
    shortcut["Exe"] = executable_value
    shortcut["StartDir"] = start_directory
    shortcut["LaunchOptions"] = launch_options

    if not changed:
        return

    if SHORTCUTS_PATH.exists():
        shutil.copy2(
            SHORTCUTS_PATH,
            SHORTCUTS_PATH.with_suffix(".vdf.nix-backup"),
        )

    def write_shortcuts(path: Path) -> None:
        with path.open("wb") as shortcuts_file:
            vdf.binary_dump(data, shortcuts_file)

    replace_atomically(SHORTCUTS_PATH, write_shortcuts)


def sync_proton_mapping() -> None:
    if CONFIG_PATH.exists():
        with CONFIG_PATH.open(encoding="utf-8") as config_file:
            data = vdf.load(config_file)
    else:
        data = {}

    steam = (
        data.setdefault("InstallConfigStore", {})
        .setdefault("Software", {})
        .setdefault("Valve", {})
        .setdefault("Steam", {})
    )
    mappings = steam.setdefault("CompatToolMapping", {})
    desired = {
        "name": "proton_experimental",
        "config": "",
        "priority": "250",
    }

    if mappings.get(str(APP_ID)) == desired:
        return

    mappings[str(APP_ID)] = desired

    if CONFIG_PATH.exists():
        shutil.copy2(CONFIG_PATH, CONFIG_PATH.with_suffix(".vdf.nix-backup"))

    def write_config(path: Path) -> None:
        with path.open("w", encoding="utf-8") as config_file:
            vdf.dump(data, config_file, pretty=True)

    replace_atomically(CONFIG_PATH, write_config)


def sync_battlenet_config() -> None:
    if not BATTLE_NET_CONFIG.exists():
        return

    with BATTLE_NET_CONFIG.open(encoding="utf-8") as config_file:
        data = json.load(config_file)

    client = data.setdefault("Client", {})
    streaming = client.setdefault("Streaming", {})
    changed = (
        client.get("HardwareAcceleration") != "false"
        or streaming.get("StreamingEnabled") != "false"
    )
    client["HardwareAcceleration"] = "false"
    streaming["StreamingEnabled"] = "false"

    if not changed:
        return

    shutil.copy2(
        BATTLE_NET_CONFIG,
        BATTLE_NET_CONFIG.with_suffix(".config.nix-backup"),
    )

    def write_battlenet_config(path: Path) -> None:
        with path.open("w", encoding="utf-8") as config_file:
            json.dump(data, config_file, indent=4)
            config_file.write("\n")

    replace_atomically(BATTLE_NET_CONFIG, write_battlenet_config)


sync_shortcut()
sync_proton_mapping()
sync_battlenet_config()

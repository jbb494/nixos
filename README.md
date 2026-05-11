# NixOS EVO15

Declarative NixOS configuration for the Slimbook EVO15-AI9-STP laptop.

## Installer Flow

Boot the graphical NixOS installer USB, connect networking, then run:

```sh
loadkeys es
nmtui
sudo nix --experimental-features "nix-command flakes" run github:jbb494/nixos#install-evo15
```

The installer command is intentionally guarded. It refuses to continue unless the target disk looks like the EVO15 SSD and you confirm the destructive install prompt.

During install:

- `disko`/`cryptsetup` asks interactively for the disk encryption passphrase.
- The installer asks interactively for the `jbellavista` login/sudo password after NixOS is installed under `/mnt`.
- Passwords are not stored in this repository.

## Disk Layout

- `/boot`: 1 GiB EFI system partition.
- `/`: LUKS2 encrypted Btrfs root.
- Btrfs subvolumes for `/`, `/home`, `/nix`, and `/var/log`.
- No disk swap; `zramSwap` is enabled instead.

## Keyboard Policy

- Console and LUKS prompt: plain `es` keymap for safety.
- Laptop GUI default: `es(cat)` with `us` as secondary layout.
- Ergodox GUI devices: `ergodox-dvorak` with `us` as secondary layout.
- Hyprland layout switch fallback: `Super+F12`.

The first boot should verify actual Hyprland device names with:

```sh
hyprctl devices
```

## Non-Destructive Checks

From a machine with Nix installed:

```sh
nix flake show
nix build .#checks.x86_64-linux.xkb-ergodox
nix build .#packages.x86_64-linux.install-evo15
nix build .#nixosConfigurations.evo15.config.system.build.toplevel --dry-run
```

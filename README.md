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

## Post-Install Checklist

- Reboot into the installed system and unlock LUKS with the passphrase chosen during install.
- Log in as `jbellavista` with the password chosen during install.
- Restore the personal SSH private key to `~/.ssh/id_ed25519_personal`; do not commit private keys to this repository.
- Ensure SSH key permissions are strict: `chmod 700 ~/.ssh` and `chmod 600 ~/.ssh/id_ed25519_personal`.
- Verify the personal GitHub SSH alias: `ssh -T github.com-personal`.
- Verify personal Git identity selection in `~/personal` repositories: `git config --show-origin user.email`.
- Add any non-personal Git/SSH identities locally after install; keep those out of this public repository.
- Run `hyprctl devices` and update the Ergodox per-device match if the device name differs.

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

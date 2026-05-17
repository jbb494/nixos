# NixOS EVO15

Declarative NixOS configuration for the Slimbook EVO15-AI9-STP laptop.

## Prepare Installer USB

From the current Linux system:

1. Download the graphical NixOS installer ISO from `https://channels.nixos.org/nixos-25.11/latest-nixos-graphical-x86_64-linux.iso`.
2. Identify the USB disk with `lsblk`; use the whole disk path, for example `/dev/sdX`, not a partition like `/dev/sdX1`.
3. Unmount any mounted USB partitions.
4. Write the ISO to the USB disk.
5. Reboot and select the USB device from the firmware boot menu.

Example write command:

```sh
sudo dd if=nixos-graphical.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

This wipes the selected USB disk.

## Installer Flow

Boot the graphical NixOS installer USB, connect networking, then run:

```sh
loadkeys es
nmtui
sudo nix --experimental-features "nix-command flakes" run github:jbb494/nixos#install-evo15
```

The installer command is intentionally guarded. It refuses to continue unless the target disk looks like the EVO15 SSD and you confirm the destructive install prompt. By default it installs `evo15-bootstrap`, a bootstrap configuration that avoids building the full desktop/home-manager closure inside the RAM-backed installer.

During install:

- `disko`/`cryptsetup` asks interactively for the disk encryption passphrase.
- The installer asks interactively for the `jbellavista` login/sudo password after NixOS is installed under `/mnt`.
- Passwords are not stored in this repository.

After rebooting into the bootstrap system, unlock LUKS, log in, connect networking if needed, then switch to the full desktop configuration:

```sh
sudo nixos-rebuild switch --flake github:jbb494/nixos#evo15
```

If you intentionally want to install the full configuration directly from the installer, override the target configuration:

```sh
sudo env NIXOS_FLAKE_REF=github:jbb494/nixos#evo15 nix --experimental-features "nix-command flakes" run github:jbb494/nixos#install-evo15
```

## Post-Install Checklist

- Reboot into the installed system and unlock LUKS with the passphrase chosen during install.
- Log in as `jbellavista` with the password chosen during install.
- SSH authorized keys are intentionally not stored in this repository. If you want SSH access after install, add a key from a trusted client with `ssh-copy-id -i ~/.ssh/id_ed25519_<host>.pub jbellavista@<new-host-ip>`.
- If creating a host-specific SSH key, use `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_<host> -C "jbellavista@<host>"`, then copy only the public key with `ssh-copy-id`.
- If using private GitHub identities, keep repository remotes and dependency URLs on normal `github.com` URLs. Home Manager configures `~/personal` repositories to rewrite `github.com` to the personal SSH alias locally, so public repos do not need machine-specific hostnames in `package.json` or `.git/config`.
- For other private GitHub identities, keep the Git rewrite in a private local include outside this repository. Example shape:

  ```ini
  [url "git@github.com-private:"]
    insteadOf = git@github.com:

  [url "ssh://git@github.com-private/"]
    insteadOf = ssh://git@github.com/

  [url "git+ssh://git@github.com-private/"]
    insteadOf = git+ssh://git@github.com/
  ```

  With this setup, raw remotes stay portable, for example `git@github.com:org/repo.git`, while Git displays and accesses them through the local alias. Check raw vs rewritten with `git config --get remote.origin.url` and `git remote get-url origin`.
- Verify the personal GitHub SSH alias: `ssh -T github.com-personal`.
- Verify personal Git identity selection in `~/personal` repositories: `git config --show-origin user.email`.
- Add any non-personal Git/SSH identities locally after install; keep those out of this public repository.
- Run `sudo nixos-rebuild switch --flake github:jbb494/nixos#evo15` if you are still on the EVO15 bootstrap configuration.
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
nix build .#nixosConfigurations.evo15-bootstrap.config.system.build.toplevel --dry-run
nix build .#nixosConfigurations.evo15.config.system.build.toplevel --dry-run
```

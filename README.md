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

The installer command is intentionally guarded. It refuses to continue unless the target disk looks like the EVO15 SSD and you confirm the destructive install prompt. By default it installs `evo15-minimal`, a bootstrap configuration that avoids building the full desktop/home-manager closure inside the RAM-backed installer.

During install:

- `disko`/`cryptsetup` asks interactively for the disk encryption passphrase.
- The installer asks interactively for the `jbellavista` login/sudo password after NixOS is installed under `/mnt`.
- Passwords are not stored in this repository.

After rebooting into the minimal system, unlock LUKS, log in, connect networking if needed, then switch to the full desktop configuration:

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
- RollnRoll integration is optional. The default flake uses a local stub and does not need RollnRoll SSH access.
- If enabling RollnRoll integration, restore the RollnRoll SSH private key to `~/.ssh/id_ed25519_rollnroll` and update permissions with `chmod 600 ~/.ssh/id_ed25519_rollnroll`.
- If using the SSH alias form instead of `github.com`, create a temporary bootstrap `~/.ssh/config` entry for the private devtools input:

  ```sshconfig
  Host github.com-rollnroll
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_rollnroll
    IdentitiesOnly yes
  ```

  Home Manager manages this SSH host after the first successful RollnRoll-enabled switch, but Nix needs the bootstrap entry before it can fetch private inputs. The managed Home Manager SSH config is allowed to replace this temporary file.
- Build with the private RollnRoll input only on machines that should use it: `sudo env GIT_SSH_COMMAND='ssh -i /home/jbellavista/.ssh/id_ed25519_rollnroll -o IdentitiesOnly=yes' nixos-rebuild switch --flake .#evo15 --override-input rollnroll-devtools git+ssh://git@github.com/joan-lgtm/devtools.git`.
- Verify the personal GitHub SSH alias: `ssh -T github.com-personal`.
- If RollnRoll integration is enabled, verify the RollnRoll GitHub SSH alias: `ssh -T github.com-rollnroll`.
- Verify personal Git identity selection in `~/personal` repositories: `git config --show-origin user.email`.
- Add any non-personal Git/SSH identities locally after install; keep those out of this public repository.
- Run `sudo nixos-rebuild switch --flake github:jbb494/nixos#evo15` if you are still on the minimal bootstrap configuration.
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
nix build .#nixosConfigurations.evo15-minimal.config.system.build.toplevel --dry-run
nix build .#nixosConfigurations.evo15.config.system.build.toplevel --dry-run
```

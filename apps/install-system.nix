{ writeShellApplication
, coreutils
, cryptsetup
, diskoPackage
, gnugrep
, nixosInstallTools
, util-linux
, installName
, defaultDisk
, defaultFlakeRef
, flakeRefExample ? defaultFlakeRef
, diskModelPattern
, diskDescription
, requireUefi ? true
, postInstallInstructions ? ""
}:

writeShellApplication {
  name = installName;

  runtimeInputs = [
    coreutils
    cryptsetup
    diskoPackage
    gnugrep
    nixosInstallTools
    util-linux
  ];

  text = ''
    set -euo pipefail

    disk="''${NIXOS_INSTALL_DISK:-${defaultDisk}}"
    flake_ref="''${NIXOS_FLAKE_REF:-${defaultFlakeRef}}"

    if [[ "''${flake_ref}" != *#* ]]; then
      echo "NIXOS_FLAKE_REF must include a NixOS configuration attribute, for example ${flakeRefExample}" >&2
      exit 1
    fi

    flake_base="''${flake_ref%#*}"
    flake_attr="''${flake_ref##*#}"

    if [[ "''${EUID}" -ne 0 ]]; then
      echo "Run this from the NixOS installer as root, for example:"
      echo "  sudo nix --experimental-features 'nix-command flakes' run github:jbb494/nixos#${installName}"
      exit 1
    fi

    ${if requireUefi then ''
      if [[ ! -d /sys/firmware/efi ]]; then
        echo "Refusing to continue: the installer was not booted in UEFI mode." >&2
        echo "Reboot and choose the boot menu entry prefixed with UEFI for the NixOS USB." >&2
        exit 1
      fi
    '' else ""}

    if [[ ! -b "''${disk}" ]]; then
      echo "Disk not found: ''${disk}" >&2
      exit 1
    fi

    echo "Target disk:"
    lsblk -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS "''${disk}"
    echo

    if ! lsblk -dn -o MODEL "''${disk}" | grep -q "${diskModelPattern}"; then
      echo "Refusing to continue: ''${disk} does not look like ${diskDescription}." >&2
      echo "Override only if you know what you are doing: NIXOS_INSTALL_DISK=/dev/yourdisk" >&2
      exit 1
    fi

    echo "This will destroy all data on ''${disk}, create LUKS encryption, and install NixOS."
    printf "Continue? [y/N] "
    read -r confirmation

    if [[ ! "''${confirmation}" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 1
    fi

    # Pre-build the system into the nix store while swap is still available.
    # disko-install would otherwise do this build itself, AFTER we have
    # disabled swap on the target disk -- which can OOM the installer.
    toplevel_ref="''${flake_base}#nixosConfigurations.''${flake_attr}.config.system.build.toplevel"
    echo "Pre-building system toplevel: ''${toplevel_ref}"
    nix --experimental-features 'nix-command flakes' build --no-link --option max-jobs 1 --option cores 2 "''${toplevel_ref}"

    # Disable any active swap that lives on the target disk; disko cannot
    # repartition a device that is in use. Other swaps are left alone.
    target_devices="$(${util-linux}/bin/lsblk -nrpo NAME "''${disk}")"

    while read -r swap_name _; do
      [[ -z "''${swap_name}" || "''${swap_name}" == "Filename" ]] && continue
      swap_device="$(readlink -f "''${swap_name}" 2>/dev/null || true)"
      [[ -z "''${swap_device}" ]] && swap_device="''${swap_name}"

      if printf '%s\n' "''${target_devices}" | grep -Fxq "''${swap_device}"; then
        echo "Disabling swap on ''${swap_name} (lives on target disk)"
        swapoff "''${swap_name}"
      fi
    done < /proc/swaps

    echo
    echo "Disk encryption passphrase:"
    echo "  disko/cryptsetup will ask for the LUKS passphrase during formatting."
    echo "  Use the plain Spanish keyboard mapping used by 'loadkeys es'."
    echo
    echo "Starting disko-install using ''${flake_ref}"
    disko-install \
      --write-efi-boot-entries \
      --flake "''${flake_ref}" \
      --disk main "''${disk}"

    cleanup_installed_mount() {
      set +e
      umount -R /mnt 2>/dev/null
      cryptsetup luksClose crypted 2>/dev/null
    }
    trap cleanup_installed_mount EXIT

    stop_for_debugging() {
      trap - EXIT
      echo
      echo "Installation stopped for debugging."
      echo "The installed system is still mounted at /mnt and the LUKS volume is open as /dev/mapper/crypted."
      echo "From another terminal or SSH session in the installer, inspect it with:"
      echo "  nixos-enter --root /mnt --command 'id jbellavista'"
      echo "  nixos-enter --root /mnt --command 'passwd -S jbellavista'"
      echo "When done, clean up with:"
      echo "  umount -R /mnt"
      echo "  cryptsetup luksClose crypted"
      exit 1
    }

    set_user_password() {
      local user="$1"
      local password_one=""
      local password_two=""
      local password_status=""
      local retry_password=""

      nixos-enter --root /mnt --command "id -u $user >/dev/null" || {
        echo "User does not exist in the installed system: $user" >&2
        stop_for_debugging
      }

      if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        echo "No usable controlling TTY for password entry." >&2
        echo "Run the installer from a local terminal/TTY, or set the password manually from another installer shell." >&2
        stop_for_debugging
      fi

      while true; do
        printf "New password for %s: " "$user" > /dev/tty
        IFS= read -r -s password_one < /dev/tty || {
          echo "Failed to read password from /dev/tty." >&2
          stop_for_debugging
        }
        printf "\nRetype new password for %s: " "$user" > /dev/tty
        IFS= read -r -s password_two < /dev/tty || {
          echo "Failed to read password confirmation from /dev/tty." >&2
          stop_for_debugging
        }
        printf "\n" > /dev/tty

        if [[ -z "$password_one" ]]; then
          echo "Password cannot be empty." >&2
          continue
        fi

        if [[ "$password_one" != "$password_two" ]]; then
          echo "Passwords do not match." >&2
          password_one=""
          password_two=""
          continue
        fi

        if printf '%s:%s\n' "$user" "$password_one" | nixos-enter --root /mnt --command "chpasswd"; then
          password_one=""
          password_two=""
          password_status="$(nixos-enter --root /mnt --command "passwd -S $user" || true)"
          if printf '%s\n' "$password_status" | grep -q "^$user P "; then
            echo "Password set for $user."
            return 0
          fi

          echo "chpasswd returned successfully, but $user does not report a usable password:" >&2
          printf '%s\n' "$password_status" >&2
        else
          password_one=""
          password_two=""
          echo "Password setup failed." >&2
        fi

        printf "Try setting the password again? [Y/n] " > /dev/tty
        IFS= read -r retry_password < /dev/tty || stop_for_debugging
        if [[ "$retry_password" =~ ^[Nn]$ ]]; then
          echo "Refusing to finish install without a $user password." >&2
          stop_for_debugging
        fi
      done
    }

    echo
    echo "Re-opening the LUKS volume to set the user password."
    cryptsetup luksClose crypted 2>/dev/null || true
    echo "Enter the same passphrase you just used:"
    cryptsetup luksOpen /dev/disk/by-partlabel/disk-main-luks crypted

    mount -o subvol=/root /dev/mapper/crypted /mnt
    mount --mkdir -o subvol=/home /dev/mapper/crypted /mnt/home
    mount --mkdir -o subvol=/nix /dev/mapper/crypted /mnt/nix
    mount --mkdir -o subvol=/log /dev/mapper/crypted /mnt/var/log
    mount --mkdir /dev/disk/by-partlabel/disk-main-ESP /mnt/boot

    echo
    echo "Set the login and sudo password for jbellavista now."
    echo "This password is written to the installed system and is not stored in Git."
    echo "Do not reboot until this step reports success."
    set_user_password jbellavista

    umount -R /mnt
    cryptsetup luksClose crypted
    trap - EXIT

    ${postInstallInstructions}

    echo
    echo "Installation complete. Reboot when ready. Keep the installer USB nearby for the first boot."
  '';
}

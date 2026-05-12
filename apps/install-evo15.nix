{ writeShellApplication
, coreutils
, diskoPackage
, gnugrep
, nixosInstallTools
, util-linux
}:

writeShellApplication {
  name = "install-evo15";

  runtimeInputs = [
    coreutils
    diskoPackage
    gnugrep
    nixosInstallTools
    util-linux
  ];

  text = ''
    set -euo pipefail

    disk="''${NIXOS_INSTALL_DISK:-/dev/nvme0n1}"
    flake_ref="''${NIXOS_FLAKE_REF:-github:jbb494/nixos#evo15-minimal}"

    if [[ "''${flake_ref}" != *#* ]]; then
      echo "NIXOS_FLAKE_REF must include a NixOS configuration attribute, for example github:jbb494/nixos#evo15-minimal" >&2
      exit 1
    fi

    flake_base="''${flake_ref%#*}"
    flake_attr="''${flake_ref##*#}"
    full_flake_ref="''${NIXOS_FULL_FLAKE_REF:-''${flake_base}#evo15}"

    if [[ "''${EUID}" -ne 0 ]]; then
      echo "Run this from the NixOS installer as root, for example:"
      echo "  sudo nix --experimental-features 'nix-command flakes' run github:jbb494/nixos#install-evo15"
      exit 1
    fi

    if [[ ! -b "''${disk}" ]]; then
      echo "Disk not found: ''${disk}" >&2
      exit 1
    fi

    echo "Target disk:"
    lsblk -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS "''${disk}"
    echo

    if ! lsblk -dn -o MODEL "''${disk}" | grep -q "SSDPR-PX600L-512-80"; then
      echo "Refusing to continue: ''${disk} does not look like the EVO15 512GB SSD." >&2
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
    # disabled swap on the target disk -- which OOMs the installer.
    toplevel_ref="''${flake_base}#nixosConfigurations.''${flake_attr}.config.system.build.toplevel"
    echo "Pre-building system toplevel: ''${toplevel_ref}"
    nix --experimental-features 'nix-command flakes' build --no-link --option max-jobs 1 --option cores 2 "''${toplevel_ref}"

    # Disable any active swap that lives on the target disk; disko cannot
    # repartition a device that is in use. Other swaps are left alone.
    target_devices="$(
      while read -r device; do
        readlink -f "''${device}"
      done < <(lsblk -nrpo NAME "''${disk}")
    )"

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

    if ! mountpoint -q /mnt; then
      echo "Installation did not leave /mnt mounted; cannot set the user password." >&2
      exit 1
    fi

    echo
    echo "Set the login and sudo password for jbellavista now."
    echo "This password is written to the installed system and is not stored in Git."
    nixos-enter --root /mnt --command "passwd jbellavista"

    if [[ "''${flake_attr}" == "evo15-minimal" ]]; then
      echo
      echo "After reboot, switch to the full desktop configuration:"
      echo "  sudo nixos-rebuild switch --flake ''${full_flake_ref}"
    fi

    echo
    echo "Reboot when ready. Keep the installer USB nearby for the first boot."
  '';
}

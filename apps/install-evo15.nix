{ writeShellApplication
, coreutils
, diskoPackage
, gnugrep
, util-linux
}:

writeShellApplication {
  name = "install-evo15";

  runtimeInputs = [
    coreutils
    diskoPackage
    gnugrep
    util-linux
  ];

  text = ''
    set -euo pipefail

    disk="''${NIXOS_INSTALL_DISK:-/dev/nvme0n1}"
    flake_ref="''${NIXOS_FLAKE_REF:-github:jbb494/nixos#evo15}"

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
    printf "Type INSTALL-EVO15 to continue: "
    read -r confirmation

    if [[ "''${confirmation}" != "INSTALL-EVO15" ]]; then
      echo "Cancelled."
      exit 1
    fi

    echo "Starting disko-install using ''${flake_ref}"
    disko-install \
      --write-efi-boot-entries \
      --flake "''${flake_ref}" \
      --disk main "''${disk}"

    if mountpoint -q /mnt; then
      echo
      echo "Installation finished. Setting the jbellavista password inside /mnt."
      echo "If this step fails, boot once with the temporary password 'nixos' and run passwd."
      nixos-enter --root /mnt --command "passwd jbellavista" || true
    fi

    echo
    echo "Reboot when ready. Keep the installer USB nearby for the first boot."
  '';
}

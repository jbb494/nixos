{ callPackage, diskoPackage, nixosInstallTools }:

callPackage ./install-system.nix {
  inherit diskoPackage nixosInstallTools;
  installName = "install-desktop";
  defaultDisk = "/dev/nvme0n1";
  defaultFlakeRef = "github:jbb494/nixos#desktop-bootstrap";
  flakeRefExample = "github:jbb494/nixos#desktop-bootstrap";
  diskModelPattern = "WD_BLACK SN7100 2TB";
  diskDescription = "the desktop WD_BLACK SN7100 2TB NVMe";
  postInstallInstructions = ''
    if [[ "''${flake_attr}" == "desktop-bootstrap" ]]; then
      echo
      echo "After reboot, switch to the full desktop configuration with:"
      echo "  sudo nixos-rebuild boot --flake ''${flake_base}#desktop"
      echo "  sudo reboot"
    fi
  '';
}

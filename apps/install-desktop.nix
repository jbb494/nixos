{ callPackage, diskoPackage, nixosInstallTools }:

callPackage ./install-system.nix {
  inherit diskoPackage nixosInstallTools;
  installName = "install-desktop";
  defaultDisk = "/dev/nvme0n1";
  defaultFlakeRef = "github:jbb494/nixos#desktop-bootstrap";
  flakeRefExample = "github:jbb494/nixos#desktop-bootstrap";
  diskModelPattern = "Samsung SSD 980 PRO 2TB";
  diskDescription = "the desktop Samsung 980 PRO 2TB NVMe";
  postInstallInstructions = ''
    if [[ "''${flake_attr}" == "desktop-bootstrap" ]]; then
      echo
      echo "After reboot, switch to the full desktop configuration with:"
      echo "  sudo nixos-rebuild boot --flake ''${flake_base}#desktop"
      echo "  sudo reboot"
    fi
  '';
}
